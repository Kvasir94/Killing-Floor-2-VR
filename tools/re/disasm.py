"""
Disassemble a range of KFGame.exe, with RIP-relative targets resolved to the
string or global they actually point at.

Capstone alone prints `lea rcx, [rip + 0x1234]`, which is useless without doing
the arithmetic by hand every time. This resolves the target RVA and, when it
lands on a readable string, prints it inline. That turns a wall of assembly into
something you can read for intent.

Usage:
    python tools/re/disasm.py 0xe2066 0x84
    python tools/re/disasm.py 0xe2066 0x84 --calls      # only call/jmp targets
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pe import PE  # noqa: E402

try:
    from capstone import Cs, CS_ARCH_X86, CS_MODE_64
except ImportError:
    sys.exit("capstone not installed:  python -m pip install capstone")

TARGET = r"D:/SteamLibrary/steamapps/common/killingfloor2/Binaries/Win64/KFGame.exe"


def printable(s: str) -> bool:
    return bool(s) and all(32 <= ord(c) < 127 for c in s)


def annotate(pe: PE, insn) -> str:
    """Resolve a RIP-relative or direct branch target to something readable."""
    note = ''
    if 'rip' in insn.op_str:
        # capstone gives the displacement; target = end of instruction + disp
        i = insn.op_str.find('rip')
        j = insn.op_str.find(']', i)
        expr = insn.op_str[i + 3:j].replace(' ', '')
        try:
            disp = int(expr, 16) if expr.startswith(('0x', '-0x')) else int(expr or '0', 0)
        except ValueError:
            return note
        tgt = insn.address + insn.size + disp
        sec = pe.sec_for_rva(tgt)
        note = f'   ; -> {hex(tgt)} [{sec.name if sec else "?"}]'
        s = pe.cstr(tgt, 64)
        if printable(s) and len(s) >= 2:
            note += f' {s!r}'
        else:
            w = pe.read(tgt, 64)
            if w:
                try:
                    ws = w.decode('utf-16-le', 'ignore').split('\x00')[0]
                    if printable(ws) and len(ws) >= 3:
                        note += f' L{ws!r}'
                except Exception:
                    pass
    elif insn.mnemonic in ('call', 'jmp') and insn.op_str.startswith('0x'):
        note = f'   ; target {insn.op_str}'
    return note


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    rva = int(sys.argv[1], 0)
    length = int(sys.argv[2], 0)
    only_calls = '--calls' in sys.argv

    pe = PE(TARGET)
    data = pe.read(rva, length)
    if data is None:
        sys.exit(f'{hex(rva)} is not in an initialised section')

    md = Cs(CS_ARCH_X86, CS_MODE_64)
    md.detail = False
    for insn in md.disasm(data, rva):
        if only_calls and insn.mnemonic not in ('call', 'jmp'):
            continue
        print(f'  {insn.address:#010x}  {insn.mnemonic:<7} {insn.op_str:<40}'
              f'{annotate(pe, insn)}')


if __name__ == '__main__':
    main()
