"""
RIP-relative cross-reference scanner for KFGame.exe.

With no engine RTTI, no exported engine symbols and no PDB, the only way to
attribute code is to follow what it touches. On x64 almost every reference to a
string, a global or an import is RIP-relative, so scanning .text for those
instruction forms and resolving their targets yields a usable xref index without
a full disassembler.

Recognised forms (all with REX.W, mod=00, rm=101):

    48 8D /r disp32      lea  reg, [rip+disp32]     -- string/global address
    48 8B /r disp32      mov  reg, [rip+disp32]     -- load global
    48 89 /r disp32      mov  [rip+disp32], reg     -- store global  (a store to
                                                       a global is how you find
                                                       who *initialises* it)
    FF 15    disp32      call [rip+disp32]          -- indirect/IAT call
    FF 25    disp32      jmp  [rip+disp32]          -- tail/IAT thunk

This is a scanner, not a disassembler: it does not track instruction boundaries,
so a byte sequence inside an unrelated instruction's operand can look like a
match. Treat single hits as leads and clusters as evidence. Everything it
reports is cheap to confirm in Ghidra.

Usage:
    python tools/re/xref.py --to 0x1646518            # who references this RVA
    python tools/re/xref.py --range 0x1646000 0x1647000
    python tools/re/xref.py --build reverse/out/xref.json
"""
import json
import os
import struct
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pe import PE  # noqa: E402

TARGET = r"D:/SteamLibrary/steamapps/common/killingfloor2/Binaries/Win64/KFGame.exe"


class XrefIndex:
    """target RVA -> [(site RVA, kind), ...]"""

    KINDS = {
        (0x8D,): 'lea',
        (0x8B,): 'mov_load',
        (0x89,): 'mov_store',
    }

    def __init__(self, pe: PE):
        self.pe = pe
        self.by_target = defaultdict(list)
        self._scan()

    def _scan(self):
        pe = self.pe
        for sec in pe.sections:
            if not sec.executable:
                continue
            base = sec.raw_ptr
            data = pe.data[base:base + sec.raw_size]
            secrva = sec.vaddr
            n = len(data)
            i = 0
            while i < n - 7:
                b = data[i]
                # REX.W prefix, 0x48-0x4F with the W bit set
                if 0x48 <= b <= 0x4F:
                    op = data[i + 1]
                    kind = self.KINDS.get((op,))
                    if kind:
                        modrm = data[i + 2]
                        if (modrm >> 6) == 0 and (modrm & 7) == 5:
                            disp = struct.unpack_from('<i', data, i + 3)[0]
                            site = secrva + i
                            tgt = site + 7 + disp
                            self.by_target[tgt].append((site, kind))
                            i += 7
                            continue
                elif b == 0xFF:
                    op = data[i + 1]
                    if op in (0x15, 0x25):
                        disp = struct.unpack_from('<i', data, i + 2)[0]
                        site = secrva + i
                        tgt = site + 6 + disp
                        self.by_target[tgt].append(
                            (site, 'call_ind' if op == 0x15 else 'jmp_ind'))
                        i += 6
                        continue
                i += 1

    def to(self, rva):
        return sorted(self.by_target.get(rva, []))

    def in_range(self, lo, hi):
        out = []
        for t, sites in self.by_target.items():
            if lo <= t < hi:
                out.extend((t, s, k) for s, k in sites)
        return sorted(out)


def describe(pe, rva):
    s = pe.sec_for_rva(rva)
    return s.name if s else '?'


def main():
    pe = PE(TARGET)
    idx = XrefIndex(pe)
    total = sum(len(v) for v in idx.by_target.values())
    print(f"indexed {total} rip-relative refs to {len(idx.by_target)} targets", file=sys.stderr)

    if '--to' in sys.argv:
        rva = int(sys.argv[sys.argv.index('--to') + 1], 0)
        hits = idx.to(rva)
        print(f"{len(hits)} refs to {hex(rva)} ({describe(pe, rva)}) "
              f"str={pe.cstr(rva, 80)!r}")
        for site, kind in hits:
            print(f"   {hex(site)}  {kind:<9} VA {hex(pe.va(site))}")

    elif '--range' in sys.argv:
        i = sys.argv.index('--range')
        lo, hi = int(sys.argv[i + 1], 0), int(sys.argv[i + 2], 0)
        hits = idx.in_range(lo, hi)
        print(f"{len(hits)} refs into {hex(lo)}-{hex(hi)}")
        # Cluster by referencing site: a function that touches many of these
        # strings is almost certainly the one that registers them.
        buckets = defaultdict(list)
        for t, s, k in hits:
            buckets[s >> 12].append((t, s, k))
        for page, items in sorted(buckets.items(), key=lambda kv: -len(kv[1]))[:15]:
            print(f"\n  .text page {hex(page << 12)} -- {len(items)} refs")
            for t, s, k in sorted(items)[:24]:
                print(f"     site {hex(s)} {k:<9} -> {hex(t)}  {pe.cstr(t, 40)!r}")

    elif '--build' in sys.argv:
        out = sys.argv[sys.argv.index('--build') + 1]
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, 'w', encoding='utf-8') as f:
            json.dump({hex(t): [[hex(s), k] for s, k in v]
                       for t, v in idx.by_target.items()}, f)
        print(f"wrote {out}")


if __name__ == '__main__':
    main()
