"""Read-only candidate mapping of pinned Steam native functions to Epic KF2.

Outputs offline analysis, never a support allowlist. Full normalized matches
retain structure/field offsets but mask relocated branches and global addresses.
Live ABI/lifetime and online authentication still require separate acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
from pe import PE
from capstone import Cs, CS_ARCH_X86, CS_MODE_64, CS_GRP_JUMP, CS_GRP_CALL
from capstone.x86 import X86_OP_MEM, X86_REG_RIP

FUNCTIONS = {
    "CalcSceneView": 0x6746a0, "ViewportDraw": 0x676350,
    "SubmitSceneFamily": 0x903380, "RendererConstruct": 0x8fea50,
    "SceneViewConstruct": 0x8d6180, "SceneViewCopyConstruct": 0x8ff130,
    "SceneViewInitialize": 0x8e9760, "SceneViewDestruct": 0x8d91b0,
    "PlayerControllerTick": 0x582000, "ActorSetRotation": 0x6f43c0,
    "WorldTick": 0x582550, "GetMousePosition": 0xd179c0,
    "GfxInputKey": 0xc2ad00, "GfxInputAxis": 0xc2a3d0,
    "GfxGetFocusMovie": 0xc22f40, "RenderAllocate": 0xe3f0,
    "RenderCommit": 0x102d0, "WeaponViewRotation": 0xe000c0,
    "ResizeRhi": 0xd1ef30, "CanvasDraw": 0xd350a0,
    "PhysicalFireStartLoc": 0x47e3c0, "ProcessInternal": 0x7aed0,
    "ConstructName": 0xc4990, "FindFunction": 0xc9de0,
    "PortalRender": 0x693430, "PortalClip": 0x68c850,
    "InputGlobals": 0x4bd7b0, "PositionName": 0xd67810, "PortalProbeConstruct": 0x695880,
}
PINS = ["77AB9C2CF43AEAA3038274FFF3822064815A3EA02A1B3C81870CDC12A885C994",
        "80CE504F73DBC76C06E3888ABAA5B69DF6AE6E7C23C39ABB778D3C47B508DB9A"]


def ranges(pe):
    rva, size = pe._dir(3)
    return {start: end for start, end, unwind in struct.iter_unpack('<III', pe.read(rva, size))}


def normalized(pe, start, end):
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    md.detail = True
    raw = pe.read(start, end-start)
    result = bytearray(raw)
    mask = bytearray(len(raw))
    references = []
    decoded = 0
    for ins in md.disasm(raw, start):
        offset = ins.address-start
        decoded += ins.size
        if ins.group(CS_GRP_JUMP) or ins.group(CS_GRP_CALL):
            if ins.imm_size and not start <= ins.operands[0].imm < end:
                begin = offset + ins.imm_offset
                result[begin:begin+ins.imm_size] = bytes(ins.imm_size)
                mask[begin:begin+ins.imm_size] = b'\x01' * ins.imm_size
                references.append((offset, "branch", ins.operands[0].imm))
        for operand in ins.operands:
            if operand.type == X86_OP_MEM and operand.mem.base == X86_REG_RIP:
                begin = offset + ins.disp_offset
                result[begin:begin+ins.disp_size] = bytes(ins.disp_size)
                mask[begin:begin+ins.disp_size] = b'\x01' * ins.disp_size
                references.append((offset, "global", ins.address+ins.size+operand.mem.disp))
    return bytes(result), bytes(mask), references, decoded == len(raw)


def analyze(steam, epic):
    srange, erange = ranges(steam), ranges(epic)
    # Leaf allocator has no unwind entry; its complete body ends in RET.
    srange[0xe3f0] = 0xe473
    erange[0xf7c0] = 0xf843
    outputs = []
    mappings = {}
    for name, start in FUNCTIONS.items():
        end = srange.get(start)
        if end is None:
            outputs.append(dict(name=name, steam_rva=hex(start), status="no-function-boundary"))
            continue
        norm, mask, refs, complete = normalized(steam, start, end)
        prefix = min(len(norm), 160)
        expression = b''.join(b'.' if mask[i] else re.escape(norm[i:i+1]) for i in range(prefix))
        candidates = []
        candidate_refs = []
        for sec in epic.sections:
            if not sec.executable:
                continue
            data = epic.data[sec.raw_ptr:sec.raw_ptr+sec.raw_size]
            for match in re.finditer(expression, data, re.DOTALL):
                target = sec.vaddr+match.start()
                if target in erange:
                    en, em, erefs, ec = normalized(epic, target, erange[target])
                    equal = norm == en and mask == em and complete and ec
                    candidates.append(dict(rva=hex(target), size=erange[target]-target,
                                           full_normalized_match=equal))
                    if equal:
                        candidate_refs.append(erefs)
        if len(candidates) == 1 and len(candidate_refs) == 1:
            for left, right in zip(refs, candidate_refs[0]):
                if left[:2] == right[:2]:
                    mappings.setdefault(hex(left[2]), set()).add(hex(right[2]))
        outputs.append(dict(name=name, steam_rva=hex(start), steam_size=end-start,
                            decoded_complete=complete, candidates=candidates))
    return dict(schema="kf2vr/offline-store-map/1", native_support_enabled=False,
                functions=outputs, reference_candidates={k:sorted(v) for k,v in mappings.items()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("steam", type=Path)
    parser.add_argument("epic", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binaries = [PE(str(args.steam)), PE(str(args.epic))]
    hashes = [hashlib.sha256(pe.data).hexdigest().upper() for pe in binaries]
    if hashes != PINS:
        parser.error("Expected the exact pinned Steam and Epic binaries; refusing a different build")
    result = analyze(*binaries)
    result["sha256"] = dict(zip(("steam", "epic"), hashes))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    for row in result["functions"]:
        print(row["name"], row.get("candidates", row.get("status")))


if __name__ == "__main__":
    main()
