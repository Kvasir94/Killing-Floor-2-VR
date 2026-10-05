"""Hash-pinned, read-only evidence for KF2's single-view lighting branch.

This verifies instruction boundaries and existing data flow, not a callable
engine ABI or a safe multiview patch. It never starts or modifies the game.
"""
import argparse
import hashlib
import json
from pathlib import Path
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
from pe import PE, runtime_functions, function_at

TARGET = Path('D:/SteamLibrary/steamapps/common/killingfloor2/Binaries/Win64/KFGame.exe')
EXPECTED = '77ab9c2cf43aeaa3038274fff3822064815a3ea02a1b3c81870cdc12a885c994'


def audit(target):
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    if digest != EXPECTED:
        raise ValueError('Executable differs from pinned multiview evidence')
    pe = PE(str(target))
    functions = runtime_functions(pe)
    decoder = Cs(CS_ARCH_X86, CS_MODE_64)
    decoded = {}
    for start in (0x911620, 0x322430, 0x90f900):
        boundary = function_at(functions, start)
        if not boundary or boundary[0] != start:
            raise ValueError(f'Unexpected function boundary: {start:x}')
        decoded[start] = {i.address: i for i in decoder.disasm(pe.read(start, boundary[1]-start), start)}
    instructions = {address: i for group in decoded.values() for address, i in group.items()}

    def code(address, expected):
        return address in instructions and instructions[address].bytes == bytes.fromhex(expected)

    def branch(address, mnemonic, target):
        i = instructions.get(address)
        return i is not None and i.mnemonic == mnemonic and i.op_str == hex(target)

    checks = {
        'lighting_dpg_requires_one': code(0x91169f, '41 83 fc 01') and branch(0x9116a3, 'jne', 0x9116d2),
        'lighting_view_count_must_equal_one': code(0x9116b3, '44 39 63 74') and branch(0x9116b7, 'jne', 0x9116d2),
        'single_view_path_selected': branch(0x9116c8, 'call', 0x322430) and branch(0x9116cd, 'jmp', 0x9117c8),
        'fallback_calls_other_light_path': branch(0x911724, 'call', 0x8ca3e0),
        'special_path_loads_first_view': code(0x32245d, '4c 8b e1') and code(0x322486, '4d 8b 6c 24 6c'),
        'base_pass_loads_indexed_view': code(0x90fa31, '4c 8b 7f 6c') and code(0x90fa35, '4d 03 fe'),
        'base_pass_advances_view_stride': code(0x90fbd0, 'ff c3') and code(0x90fbd2, '49 81 c6 80 13 00 00'),
        'base_pass_loops_to_view_count': code(0x90fbd9, '8b 47 74') and code(0x90fbdc, '3b d8') and
            branch(0x90fbde, 'jl', 0x90f9a1),
    }
    return dict(scope='static-multiview-barrier; no patch, performance or image claim',
                sha256=digest, checks=checks, all_checks_pass=all(checks.values()))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', type=Path, default=TARGET)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    report = audit(args.target)
    text = json.dumps(report, indent=2)+'\n'
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text)
    print(text, end='')
    raise SystemExit(0 if report['all_checks_pass'] else 1)
