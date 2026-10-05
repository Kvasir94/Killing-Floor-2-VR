"""
UE3 package (.upk/.u/.umap) header reader for Killing Floor 2.

KF2 packages are FileVersion 871 / LicenseeVersion 1117 and ship uncompressed,
so the name/import/export tables can be walked directly. This yields a complete
object inventory of BrewedPC without any third-party extractor.
"""
import struct, sys, os, json

TAG = 0x9E2A83C1

class Reader:
    def __init__(self, buf):
        self.b, self.p = buf, 0
    def u32(self):
        v = struct.unpack_from('<I', self.b, self.p)[0]; self.p += 4; return v
    def i32(self):
        v = struct.unpack_from('<i', self.b, self.p)[0]; self.p += 4; return v
    def i64(self):
        v = struct.unpack_from('<q', self.b, self.p)[0]; self.p += 8; return v
    def u64(self):
        v = struct.unpack_from('<Q', self.b, self.p)[0]; self.p += 8; return v
    def raw(self, n):
        v = self.b[self.p:self.p+n]; self.p += n; return v
    def fstring(self):
        n = self.i32()
        if n == 0: return ''
        if n < 0:
            s = self.raw(-n * 2).decode('utf-16-le', 'replace')
        else:
            s = self.raw(n).decode('latin-1', 'replace')
        return s.rstrip('\x00')
    def fname(self, names):
        idx = self.i32(); num = self.i32()
        nm = names[idx] if 0 <= idx < len(names) else f'<bad:{idx}>'
        return f'{nm}_{num-1}' if num > 0 else nm


def read_header(path):
    with open(path, 'rb') as f:
        head = f.read(4096)
        r = Reader(head)
        if r.u32() != TAG:
            raise ValueError('not a UE3 package')
        ver = r.i32()
        file_ver, lic_ver = ver & 0xFFFF, (ver >> 16) & 0xFFFF
        total_header = r.i32()
        folder = r.fstring()
        flags = r.u32()
        name_count, name_off = r.i32(), r.i32()
        export_count, export_off = r.i32(), r.i32()
        import_count, import_off = r.i32(), r.i32()
        depends_off = r.i32()
        info = dict(path=path, file_version=file_ver, licensee_version=lic_ver,
                    folder=folder, flags=flags,
                    name_count=name_count, name_offset=name_off,
                    export_count=export_count, export_offset=export_off,
                    import_count=import_count, import_offset=import_off,
                    header_size=total_header, size=os.path.getsize(path))
        # name table
        f.seek(name_off)
        nbuf = f.read(max(0, (export_off or total_header) - name_off))
        nr = Reader(nbuf)
        names = []
        for _ in range(name_count):
            try:
                names.append(nr.fstring()); nr.u64()   # UE3 name flags
            except Exception:
                break
        info['names_read'] = len(names)
        # import table
        f.seek(import_off)
        ibuf = f.read(max(0, depends_off - import_off) if depends_off > import_off else 1 << 20)
        ir = Reader(ibuf)
        imports = []
        for _ in range(import_count):
            try:
                pkg = ir.fname(names); cls = ir.fname(names)
                outer = ir.i32(); obj = ir.fname(names)
                imports.append(dict(package=pkg, cls=cls, outer=outer, name=obj))
            except Exception:
                break
        # export table
        f.seek(export_off)
        ebuf = f.read(max(0, import_off - export_off) if import_off > export_off else 1 << 22)
        er = Reader(ebuf)
        exports = []
        for _ in range(export_count):
            try:
                cls_idx = er.i32(); super_idx = er.i32(); outer = er.i32()
                obj = er.fname(names)
                arch = er.i32(); oflags = er.u64()
                ssize = er.i32(); soff = er.i32()
                exports.append(dict(cls=cls_idx, name=obj, size=ssize, offset=soff))
                # remaining per-export fields vary; resync using componentmap+netobjs
                ncomp = er.i32()
                er.p += ncomp * 12
                er.u32()                      # export flags
                nnet = er.i32(); er.p += nnet * 4
                er.p += 4                     # package guid part
                er.p += 16                    # guid remainder
                er.p += 4                     # package flags
            except Exception:
                break
        info['exports_read'] = len(exports)
        def resolve(i):
            if i < 0:
                j = -i - 1
                return imports[j]['name'] if j < len(imports) else '?'
            if i > 0:
                j = i - 1
                return exports[j]['name'] if j < len(exports) else '?'
            return 'None'
        for e in exports:
            e['class'] = resolve(e['cls'])
        return info, names, imports, exports


if __name__ == '__main__':
    info, names, imports, exports = read_header(sys.argv[1])
    print(json.dumps({k: v for k, v in info.items()}, indent=1))
    import collections
    c = collections.Counter(e['class'] for e in exports)
    print('top export classes:')
    for k, v in c.most_common(20):
        print(f'  {v:>6}  {k}')
