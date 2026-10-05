"""
Extract the build machine's source-file paths embedded in KFGame.exe.

UE3's check()/checkSlow()/appErrorf() macros expand __FILE__ into the binary, so
a shipped Unreal build carries the absolute paths of the .cpp files it was
compiled from. That gives three things nothing else does:

  1. A census of which engine modules are actually linked into the executable.
  2. A per-file anchor: any function that references one of these strings is in
     that source file. With no engine RTTI and no PDB, this is the strongest
     naming signal the binary offers.
  3. The original depot layout, which tells us how Tripwire's fork is organised.

Read-only. Run:  python tools/re/srcmap.py [--json out.json]
"""
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pe import PE  # noqa: E402

TARGET = r"D:/SteamLibrary/steamapps/common/killingfloor2/Binaries/Win64/KFGame.exe"
SEP = chr(92)  # backslash, spelled out to survive shell quoting

PATH_RE = re.compile(
    (r'[A-Za-z]:' + re.escape(SEP) +
     r'[A-Za-z0-9_.\- ' + re.escape(SEP) + r']{4,200}'
     r'\.(?:cpp|h|inl|c)').encode('latin-1'))

SRC_RE = re.compile(r'Development' + re.escape(SEP) + r'Src' +
                    re.escape(SEP) + r'([^' + re.escape(SEP) + r']+)' +
                    re.escape(SEP), re.I)


def main():
    pe = PE(TARGET)

    # rva -> path, so each string is an addressable anchor
    hits = {}
    for m in PATH_RE.finditer(pe.data):
        rva = pe.off_to_rva(m.start())
        if rva is not None:
            hits[rva] = m.group().decode('latin-1')

    uniq = sorted(set(hits.values()))
    print(f"embedded source paths: {len(hits)} string instances, {len(uniq)} unique files")

    roots = collections.Counter()
    for u in uniq:
        i = u.lower().find('development' + SEP + 'src' + SEP)
        roots[u[:i + len('development' + SEP + 'src' + SEP)] if i >= 0
              else u.rsplit(SEP, 1)[0]] += 1
    print("\nbuild roots:")
    for k, v in roots.most_common(6):
        print(f"   {v:5}  {k}")

    mods = collections.Counter()
    for u in uniq:
        m = SRC_RE.search(u)
        if m:
            mods[m.group(1)] += 1
    print(f"\nengine modules linked into KFGame.exe ({len(mods)} modules):")
    for k, v in mods.most_common(40):
        print(f"   {k:<28} {v:4} files")

    # The files most worth reading first, by how often they are referenced --
    # a heavily-referenced file is one with many checks, i.e. a lot of code.
    by_file = collections.Counter(hits.values())
    print("\nmost-referenced source files (proxy for code volume):")
    for k, v in by_file.most_common(20):
        print(f"   {v:4}  {k.split('Src' + SEP)[-1] if 'Src' + SEP in k else k}")

    if '--json' in sys.argv:
        out = sys.argv[sys.argv.index('--json') + 1]
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, 'w', encoding='utf-8') as f:
            json.dump({
                'target': TARGET,
                'image_base': pe.image_base,
                'unique_files': uniq,
                'modules': dict(mods),
                'anchors': {hex(k): v for k, v in sorted(hits.items())},
            }, f, indent=1)
        print(f"\nwrote {out}")


if __name__ == '__main__':
    main()
