"""Verify and record the pinned editor's FBX interval branches, without executing it."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from capstone import Cs, CS_ARCH_X86, CS_MODE_64
from pe import PE
from disasm import annotate

PINNED_SHA256 = "b937aadaa06f728354044461cb8490ef2c20b17245535cf88d3f23cd81ddb85c"
DEFAULT_EDITOR = Path("D:/SteamLibrary/steamapps/common/killingfloor2/Binaries/Win64/KFEditor.exe")

# Exact instructions supporting the conclusions; not signatures for other SDKs.
EVIDENCE = [
    (0x147F8C4, "mov", "r9d, 1", "viewer enables morph tracks"),
    (0x1379D46, "mov", "dword ptr [rcx + 0x30], r15d", "argument 4 stored in importer options"),
    (0x1378300, "cmp", "dword ptr [rax + 0x30], 0", "morph interval gate"),
    (0x1378304, "je", "0x13784b1", "disabled gate skips extra interval collection"),
    (0x1378371, "mov", "edx, 2", "blend-shape deformer type for count"),
    (0x1378379, "call", "0x1aa0d20", "geometry deformer count"),
    (0x1378397, "lea", "r8d, [r9 + 2]", "blend-shape deformer type for lookup"),
    (0x13783A0, "call", "0x1aa0e40", "geometry deformer lookup"),
    (0x13781D3, "call", "0x1a37550", "sets evaluator current stack before each take"),
    (0x13782EC, "xor", "r8d, r8d", "interval stack argument is null"),
    (0x13782F6, "call", "0x1a2a7d0", "node interval query"),
    (0x1A2A7F2, "movabs", "rax, 0x7fffffffffffffff", "interval start sentinel"),
    (0x1A2A7FF, "movabs", "rax, 0x8000000000000001", "interval end sentinel"),
    (0x1A2A810, "jne", "0x1a2a856", "explicit stack bypasses scene stack lookup"),
    (0x1A2A839, "xor", "r8d, r8d", "null stack selects stack index zero"),
    (0x1A2A83F, "call", "0x1a5c8c0", "get first scene source object of stack class"),
    (0x1A3114B, "call", "0x1a30d10", "interval recursion visits descendant nodes"),
    (0x13794EB, "cmp", "rax, rcx", "compare sample start with end"),
    (0x13794EE, "jg", "0x13799f0", "skip skeleton sampling only for start greater than end"),
    (0x13794F9, "movabs", "rax, 0xac0e8d7b0", "FBX ticks per second (46186158000)"),
    (0x1A80A19, "cmp", "ebx, 1", "BakeLayers tests layer count"),
    (0x1A80A1C, "je", "0x1a81650", "single-layer stack exits without baking"),
]

RANGES = [(0x147F8BA, 0x23), (0x1379D34, 0x16), (0x13781CC, 0x13),
          (0x1378292, 0x78), (0x1378359, 0x4C), (0x1A2A7D0, 0xD4),
          (0x1A310D3, 0xA5), (0x13794D9, 0x53), (0x1A809EC, 0x39)]


def audit(editor: Path) -> dict:
    sha256 = hashlib.sha256(editor.read_bytes()).hexdigest()
    if sha256 != PINNED_SHA256:
        raise ValueError(f"Editor does not match the pinned SDK: {sha256}")
    pe = PE(str(editor))
    decoder = Cs(CS_ARCH_X86, CS_MODE_64)
    checks = []
    for rva, mnemonic, operands, meaning in EVIDENCE:
        instruction = next(decoder.disasm(pe.read(rva, 16), rva))
        actual = (instruction.mnemonic, instruction.op_str)
        if actual != (mnemonic, operands):
            raise ValueError(f"Unexpected instruction at {rva:#x}: {actual}")
        checks.append(dict(rva=hex(rva), bytes=instruction.bytes.hex(),
                           instruction=f"{mnemonic} {operands}", meaning=meaning))
    listing = []
    for start, length in RANGES:
        listing.append([f"{i.address:#010x} {i.mnemonic} {i.op_str}{annotate(pe, i)}"
                        for i in decoder.disasm(pe.read(start, length), start)])
    return dict(editor=str(editor.resolve()), sha256=sha256, verified_instructions=checks,
                disassembly=listing, scope="Read-only static evidence; editor code was never loaded or executed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = audit(args.editor)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"Verified {len(result['verified_instructions'])} instructions against pinned editor {result['sha256']}")


if __name__ == "__main__":
    main()
