"""
Identify a function by the strings it references.

With no symbols, the fastest way to work out what a function is remains reading
its log messages, assert text and __FILE__ anchors. This resolves a function's
bounds from .pdata, scans its body for RIP-relative operands, and prints every
target that decodes as a readable ANSI or UTF-16 string.

Usage:
    python tools/re/fnstrings.py 0xcd74a0
    python tools/re/fnstrings.py 0xcc9ee3 --containing   # resolve fn from an
                                                         # address inside it
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pe import PE, runtime_functions, function_at  # noqa: E402

TARGET = r"D:/SteamLibrary/steamapps/common/killingfloor2/Binaries/Win64/KFGame.exe"


def readable(s, minlen=4):
    return len(s) >= minlen and all(32 <= ord(c) < 127 or c in '\r\n\t' for c in s)


def wide_at(pe, rva, limit=200):
    b = pe.read(rva, limit * 2)
    if not b:
        return ''
    out = []
    for i in range(0, len(b) - 1, 2):
        ch = b[i] | (b[i + 1] << 8)
        if ch == 0:
            break
        if ch > 0x7E and ch != 0x2019:
            return ''
        out.append(chr(ch))
    return ''.join(out)


def scan(pe, begin, end):
    """RIP-relative targets referenced inside [begin, end)."""
    data = pe.read(begin, end - begin)
    if data is None:
        return []
    hits = []
    i = 0
    n = len(data)
    while i < n - 6:
        b = data[i]
        if 0x48 <= b <= 0x4F and data[i + 1] in (0x8D, 0x8B):
            modrm = data[i + 2]
            if (modrm >> 6) == 0 and (modrm & 7) == 5:
                disp = struct.unpack_from('<i', data, i + 3)[0]
                site = begin + i
                hits.append((site, site + 7 + disp, 'lea' if data[i + 1] == 0x8D else 'mov'))
                i += 7
                continue
        i += 1
    return hits


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    addr = int(sys.argv[1], 0)

    pe = PE(TARGET)
    fns = runtime_functions(pe)
    f = function_at(fns, addr)
    if not f:
        sys.exit(f'{hex(addr)} has no .pdata entry')
    begin, end, _ = f
    print(f"function {hex(begin)}..{hex(end)}  ({end - begin} bytes)  "
          f"VA {hex(pe.va(begin))}")

    seen = set()
    for site, tgt, kind in scan(pe, begin, end):
        if tgt in seen:
            continue
        sec = pe.sec_for_rva(tgt)
        if not sec or sec.name not in ('.rdata', '_RDATA', '.data'):
            continue
        a = pe.cstr(tgt, 200)
        w = wide_at(pe, tgt)
        if readable(a):
            seen.add(tgt)
            print(f"   {hex(site)} {kind} -> {hex(tgt)}  {a[:110]!r}")
        elif readable(w):
            seen.add(tgt)
            print(f"   {hex(site)} {kind} -> {hex(tgt)}  L{w[:110]!r}")


if __name__ == '__main__':
    main()
