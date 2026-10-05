"""Minimal UE4 .pak index reader (no decompression) - enumerates entries."""
import struct, sys, os, hashlib

MAGIC = 0x5A6F12E1

def read_fstring(f):
    n = struct.unpack('<i', f.read(4))[0]
    if n == 0: return ''
    if n < 0:  # UTF-16
        b = f.read(-n * 2)
        return b.decode('utf-16-le').rstrip('\x00')
    b = f.read(n)
    return b.decode('utf-8', 'replace').rstrip('\x00')

def find_footer(path):
    size = os.path.getsize(path)
    with open(path, 'rb') as f:
        # scan last 4KB backwards for magic
        tail = 8192
        f.seek(size - tail)
        buf = f.read(tail)
    for off in range(len(buf) - 4, -1, -1):
        if struct.unpack_from('<I', buf, off)[0] == MAGIC:
            return size - tail + off
    return None

def main(path):
    pos = find_footer(path)
    if pos is None:
        print('magic not found'); return
    with open(path, 'rb') as f:
        f.seek(pos)
        magic, version = struct.unpack('<Ii', f.read(8))
        index_offset, index_size = struct.unpack('<qq', f.read(16))
        index_hash = f.read(20)
        print(f'magic=0x{magic:X} version={version} index_offset={index_offset} index_size={index_size}', file=sys.stderr)
        f.seek(index_offset)
        idx = f.read(index_size)

    p = 0
    def s_fstring():
        nonlocal p
        n = struct.unpack_from('<i', idx, p)[0]; p += 4
        if n < 0:
            b = idx[p:p - n * 2]; p += -n * 2
            return b.decode('utf-16-le').rstrip('\x00')
        b = idx[p:p + n]; p += n
        return b.decode('utf-8', 'replace').rstrip('\x00')

    mount = s_fstring()
    count = struct.unpack_from('<i', idx, p)[0]; p += 4
    print(f'mount={mount} count={count}', file=sys.stderr)
    out = []
    for i in range(count):
        name = s_fstring()
        offset, size, usize = struct.unpack_from('<qqq', idx, p); p += 24
        cmethod = struct.unpack_from('<I', idx, p)[0]; p += 4
        if version <= 1:
            p += 8  # timestamp
        p += 20  # hash
        if version >= 3 and cmethod != 0:
            nblocks = struct.unpack_from('<i', idx, p)[0]; p += 4
            p += nblocks * 16
        if version >= 3:
            p += 1   # bEncrypted
            p += 4   # compression block size
        out.append((name, size, usize, cmethod))
    for name, size, usize, cm in out:
        print(f'{usize}\t{size}\t{cm}\t{mount}{name}')

if __name__ == '__main__':
    main(sys.argv[1])
