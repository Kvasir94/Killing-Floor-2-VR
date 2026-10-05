"""Read-only, hash-pinned render-boundary evidence from the shipped PE.

Run with python -B tools/re/render_map.py --out reverse/out/render-map.json.
The byte scanner only supplies candidates: references included in the report
must also decode on a Capstone instruction boundary from a .pdata entry start.
This is static evidence, not a validated callable engine ABI or runtime trace.
"""
import argparse
import hashlib
import json
import re
import struct
from pathlib import Path

from capstone import Cs, CS_ARCH_X86, CS_MODE_64
from capstone.x86_const import X86_OP_IMM, X86_OP_MEM, X86_REG_RIP

from pe import PE, function_at, runtime_functions
from xref import XrefIndex


TARGET = Path('D:/SteamLibrary/steamapps/common/killingfloor2/Binaries/Win64/KFGame.exe')
EXPECTED_SHA256 = '77AB9C2CF43AEAA3038274FFF3822064815A3EA02A1B3C81870CDC12A885C994'
TERMS = re.compile(r'D3D11|DXGI|SceneView|ViewFamily|LocalPlayer|Viewport|RenderThread|RenderingThread|BeginRendering|Present|CalcScene|DrawWorld|DrawScene|GameEngine::Tick|LaunchEngineLoop|SceneRendering|UnGame\.cpp', re.I)
SEEDS = {
    0x6746A0: 'ULocalPlayer::CalcSceneView candidate; SDK signature and viewport call agree',
    0x676350: 'UGameViewportClient::Draw candidate',
    0x8D5DF0: 'scene-view constructor candidate',
    0x8D6180: 'scene-view constructor used by CalcSceneView candidate',
    0x8D6530: 'scene-view-family constructor candidate',
    0x8FEA50: 'renderer construction and scene-view copying candidate',
    0x903380: 'scene-family submission candidate; constructs FDrawSceneCommand',
    0x9075B0: 'FDrawSceneCommand executor; calls 0x913ce0',
    0x913CE0: 'render dispatch and renderer destruction; must not replay pointer',
    0xCB19D0: 'D3D11 viewport construction; creates DXGI swapchain',
    0xCC9BD0: 'persistent RHI D3D11 device/context creation candidate',
    0xCD11D0: 'temporary adapter capability-test device creation',
    0xCD74A0: 'TwD3d1xInfoInit capability-test device creation',
}


def strings(pe):
    result = {}
    for sec in pe.sections:
        if sec.executable or not sec.readable:
            continue
        blob = pe.data[sec.raw_ptr:sec.raw_ptr + sec.raw_size]
        for pattern, encoding in ((rb'[\x20-\x7e]{5,}\x00', 'ascii'),
                                  (rb'(?:[\x20-\x7e]\x00){5,}\x00\x00', 'utf-16-le')):
            for match in re.finditer(pattern, blob):
                value = match.group().decode(encoding).rstrip('\0')
                result[sec.vaddr + match.start()] = value
    return result


def build(path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest().upper()
    if digest != EXPECTED_SHA256:
        raise ValueError(f'Unsupported binary hash {digest}; expected {EXPECTED_SHA256}')
    pe = PE(str(path))
    fns = runtime_functions(pe)
    idx = XrefIndex(pe)
    text = strings(pe)
    anchors = {rva: value for rva, value in text.items() if TERMS.search(value)}
    for dll, _, symbols in pe.delay_imports():
        if dll.lower() in ('d3d11.dll', 'dxgi.dll'):
            for name, rva in symbols:
                anchors[rva] = f'{dll}!{name} [delay IAT slot]'
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    md.detail = True
    decoded = {}

    def decode(begin, end):
        if begin not in decoded:
            decoded[begin] = list(md.disasm(pe.read(begin, end - begin), begin))
        return decoded[begin]

    selected = {}
    rejected = 0
    unverified = []
    for target, value in anchors.items():
        for site, _ in idx.to(target):
            fn = function_at(fns, site)
            if not fn:
                rejected += 1
                unverified.append({'site_rva': hex(site), 'target_rva': hex(target),
                                   'text': value, 'reason': 'no .pdata range; may be valid leaf code'})
                continue
            begin, end, _ = fn
            instruction = next((ins for ins in decode(begin, end) if ins.address == site), None)
            if instruction is None or not any(
                op.type == X86_OP_MEM and op.mem.base == X86_REG_RIP and
                instruction.address + instruction.size + op.mem.disp == target
                for op in instruction.operands
            ):
                rejected += 1
                unverified.append({'site_rva': hex(site), 'target_rva': hex(target),
                                   'text': value, 'reason': 'instruction-boundary validation failed'})
                continue
            entry = selected.setdefault(begin, {'begin_rva': hex(begin), 'end_rva': hex(end),
                                               'anchors': [], 'strings': [], 'direct_calls': []})
            entry['anchors'].append({'site_rva': hex(site), 'target_rva': hex(target), 'text': value})
    for rva, label in SEEDS.items():
        begin, end, _ = function_at(fns, rva)
        entry = selected.setdefault(begin, {'begin_rva': hex(begin), 'end_rva': hex(end),
                                           'anchors': [], 'strings': [], 'direct_calls': []})
        entry['candidate_label'] = label
    import_calls = []
    import_thunks = {0xF7B1ED: 'D3D11CreateDevice', 0xF7B278: 'CreateDXGIFactory1'}
    for sec in pe.sections:
        if not sec.executable:
            continue
        blob = pe.data[sec.raw_ptr:sec.raw_ptr + sec.raw_size]
        for match in re.finditer(b'\xe8', blob):
            offset = match.start()
            if offset + 5 > len(blob):
                continue
            site = sec.vaddr + offset
            target = site + 5 + struct.unpack_from('<i', blob, offset + 1)[0]
            if target not in import_thunks:
                continue
            fn = function_at(fns, site)
            if fn and any(ins.address == site and ins.mnemonic == 'call' and
                          any(op.type == X86_OP_IMM and op.imm == target for op in ins.operands)
                          for ins in decode(fn[0], fn[1])):
                import_calls.append({'site_rva': hex(site), 'return_rva': hex(site + 5),
                                     'thunk_rva': hex(target), 'symbol': import_thunks[target],
                                     'containing_unwind_begin_rva': hex(fn[0])})
    for begin, entry in selected.items():
        seen = set()
        for ins in decode(begin, int(entry['end_rva'], 16)):
            for op in ins.operands:
                if op.type == X86_OP_MEM and op.mem.base == X86_REG_RIP:
                    target = ins.address + ins.size + op.mem.disp
                    if target in text and target not in seen:
                        seen.add(target)
                        entry['strings'].append({'site_rva': hex(ins.address), 'target_rva': hex(target), 'text': text[target]})
                elif ins.mnemonic == 'call' and op.type == X86_OP_IMM:
                    entry['direct_calls'].append({'site_rva': hex(ins.address), 'target_rva': hex(op.imm)})
    return {'schema': 'kf2vr/render-map/1', 'target': str(path), 'sha256': digest,
            'image_base': hex(pe.image_base), 'evidence': 'offline instruction-boundary-validated candidates; no callable ABI claim',
            'range_caution': '.pdata ranges can be fragments of a function, and leaf functions may be absent',
            'delay_import_calls': import_calls,
            'rejected_unverified_scanner_hits': rejected,
            'unverified_scanner_hits': unverified,
            'functions': sorted(selected.values(), key=lambda item: int(item['begin_rva'], 16))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', type=Path, default=TARGET)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    report = build(args.target)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f"Wrote {len(report['functions'])} function candidates to {args.out}; "
          f"rejected {report['rejected_unverified_scanner_hits']} scanner hits")


if __name__ == '__main__':
    main()
