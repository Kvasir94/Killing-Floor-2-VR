"""
Dump the tagged properties of objects in a KF2 UE3 package (FileVersion 871).

    python tools/ue3/upk_props.py <package.upk> [path-substring] [--class Name]

Prints each matching export's path, class and its serialized properties
(bools, ints, floats, names, object paths, vectors, rotators, arrays of object
references). Struct payloads it does not decode are shown as hex. Used for
docs/re/shell-eject-emitters.md (#201).

KF2 export entries are 68 bytes when they carry no components or net objects
(upkg.py's header walk skips 24 bytes after the net-object list where KF2 has
16, so this tool re-reads the export table itself). Property data starts after
a 4-byte net index, plus 4 more for component/subobject exports; the start is
chosen by which offset yields a valid first property tag.
"""
import struct
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import upkg  # noqa: E402

PROP_TYPES = {'BoolProperty', 'IntProperty', 'FloatProperty', 'ObjectProperty', 'ComponentProperty',
              'ClassProperty', 'ByteProperty', 'NameProperty', 'StrProperty', 'ArrayProperty',
              'StructProperty', 'DelegateProperty', 'InterfaceProperty'}


def read_exports(path):
    info, names, imports, _ = upkg.read_header(path)
    data = open(path, 'rb').read()
    r = upkg.Reader(data)
    r.p = info['export_offset']
    exports = []
    for _ in range(info['export_count']):
        cls = r.i32(); r.i32(); outer = r.i32(); name = r.fname(names); r.i32(); r.u64()
        size = r.i32(); off = r.i32()
        ncomp = r.i32(); r.p += ncomp * 12
        r.u32()
        nnet = r.i32(); r.p += nnet * 4
        r.p += 16
        exports.append(dict(cls=cls, outer=outer, name=name, size=size, off=off))
    return info, names, imports, exports, data


def main():
    args = [a for a in sys.argv[1:]]
    want_class = None
    if '--class' in args:
        i = args.index('--class'); want_class = args[i + 1]; del args[i:i + 2]
    path = args[0]
    want = args[1].lower() if len(args) > 1 else ''
    info, names, imports, exports, data = read_exports(path)

    def ref(i):
        if i < 0:
            j = -i - 1
            return imports[j]['name'] if j < len(imports) else '?'
        parts = []
        while 0 < i <= len(exports):
            parts.append(exports[i - 1]['name']); i = exports[i - 1]['outer']
        return '.'.join(reversed(parts)) if parts else 'None'

    def name_at(p):
        idx = struct.unpack_from('<i', data, p)[0]
        return names[idx] if 0 <= idx < len(names) else None

    def props(e):
        start = None
        for skip in (4, 8, 12):
            p = e['off'] + skip
            if p + 24 > len(data):
                continue
            first = name_at(p)
            if first == 'None' or (first and name_at(p + 8) in PROP_TYPES):
                start = p; break
        if start is None:
            return [('<undecoded>', '', '')]
        r = upkg.Reader(data); r.p = start
        out = []
        for _ in range(400):
            n = r.fname(names)
            if n == 'None':
                break
            t = r.fname(names); sz = r.i32(); r.i32()
            if t == 'StructProperty':
                sn = r.fname(names); raw = data[r.p:r.p + sz]; r.p += sz
                if sn == 'Vector' and sz == 12: v = struct.unpack('<3f', raw)
                elif sn == 'Rotator' and sz == 12: v = struct.unpack('<3i', raw)
                elif sn == 'Color' and sz == 4: v = tuple(raw)
                else: v = raw.hex()
                out.append((n, sn, v)); continue
            if t == 'BoolProperty': v = bool(data[r.p]); r.p += 1
            elif t == 'IntProperty': v = r.i32()
            elif t == 'FloatProperty': v = struct.unpack_from('<f', data, r.p)[0]; r.p += 4
            elif t in ('ObjectProperty', 'ComponentProperty', 'ClassProperty'): v = ref(r.i32())
            elif t == 'NameProperty': v = r.fname(names)
            elif t == 'ByteProperty':
                enum = r.fname(names)
                if sz == 8: v = (enum, r.fname(names))
                else: v = (enum, data[r.p]); r.p += 1
            elif t == 'ArrayProperty':
                cnt = r.i32(); raw = data[r.p:r.p + sz - 4]; r.p += sz - 4
                v = [ref(x) for x in struct.unpack_from('<%di' % cnt, raw)] if len(raw) == 4 * cnt else raw.hex()
            else: v = data[r.p:r.p + sz].hex(); r.p += sz
            out.append((n, t, v))
        return out

    for i, e in enumerate(exports):
        full = ref(i + 1)
        cls = ref(e['cls']) if e['cls'] else 'Class'
        if want and want not in full.lower():
            continue
        if want_class and cls != want_class:
            continue
        print(full, cls)
        try:
            for p in props(e):
                print('   ', p)
        except Exception as ex:  # a struct this reader does not size
            print('    <stopped:', ex, '>')


if __name__ == '__main__':
    main()
