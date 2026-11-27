"""Read every Zed melee attack's parry/interrupt flags from the cooked packages.

KFPawnAnimInfo.Attacks (struct AttackAnimInfo) lives in ZED_*_ANIM.upk, not in
script. KF2 packages ship uncompressed, so this scans each package for the
tagged-property headers of the struct's fields in file order: a `Tag`
NameProperty starts an attack, and the BoolProperty tags that follow belong to
it. A bool that equals the struct default is not serialized, so a missing flag
means false (the struct has no defaults).

  python tools/re/zed_attack_flags.py [--json out.json] [KF2 install dir]
"""
import glob, json, os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'ue3'))
from upkg import read_header  # noqa: E402

INSTALL = r"D:\SteamLibrary\steamapps\common\killingfloor2"
BOOLS = ['bIsInterruptible', 'bCannotBeParried', 'bUseRootMotion', 'bPlayUpperBodyOnly',
         'bOnlyWhileSprinting', 'bOnlyWhileInSpecializedMode', 'bOnlyWhileNotInSpecializedMode']


def scan(path):
    info, names, imports, exports = read_header(path)
    idx = {n: i for i, n in enumerate(names)}
    need = ['Tag', 'NameProperty', 'BoolProperty', 'bCannotBeParried']
    if any(n not in idx for n in need):
        return []
    buf = open(path, 'rb').read()
    name = lambda n: struct.pack('<ii', idx[n], 0)
    events = []
    # Tag: name(8) type NameProperty(8) size=8 index=0, then the value FName.
    head = name('Tag') + name('NameProperty') + struct.pack('<ii', 8, 0)
    p = buf.find(head)
    while p >= 0:
        v, num = struct.unpack_from('<ii', buf, p + len(head))
        if 0 <= v < len(names):
            events.append((p, 'Tag', names[v] + (f'_{num - 1}' if num > 0 else '')))
        p = buf.find(head, p + 1)
    for b in BOOLS:
        if b not in idx:
            continue
        head = name(b) + name('BoolProperty') + struct.pack('<ii', 0, 0)
        p = buf.find(head)
        while p >= 0:
            events.append((p, b, bool(buf[p + len(head)])))
            p = buf.find(head, p + 1)
    events.sort()
    attacks, cur = [], None
    for _, key, value in events:
        if key == 'Tag':
            cur = {'Tag': value}
            attacks.append(cur)
        elif cur is not None:
            cur[key] = value
    return attacks


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    out_json = sys.argv[sys.argv.index('--json') + 1] if '--json' in sys.argv else None
    if out_json in args:
        args.remove(out_json)
    root = args[0] if args else INSTALL
    result = {}
    for path in sorted(glob.glob(os.path.join(root, 'KFGame', 'BrewedPC', 'Packages', 'ZEDs', '**', '*_ANIM.upk'), recursive=True)):
        attacks = scan(path)
        if not attacks:
            continue
        key = os.path.basename(path)
        result[key] = attacks
        print(f'\n{key}  ({len(attacks)} attacks)')
        for a in attacks:
            print(f"  {a['Tag']:30} interruptible={int(a.get('bIsInterruptible', False))} "
                  f"cannotParry={int(a.get('bCannotBeParried', False))}"
                  f"{' specialMode' if a.get('bOnlyWhileInSpecializedMode') else ''}")
    if out_json:
        json.dump(result, open(out_json, 'w', encoding='utf-8'), indent=1)


if __name__ == '__main__':
    main()
