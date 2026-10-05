"""Record selected portal cvar/command registrations from an owned Portal 2 DLL.

Read-only, binary-hashed evidence; immediate references are candidates, never
callable ABI declarations. No DLL is executed or changed.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32


def inspect(path, names):
    data = path.read_bytes()
    pe = pefile.PE(data=data, fast_load=True)
    if pe.FILE_HEADER.Machine != 0x14C:
        raise ValueError('Expected the owned x86 Portal 2 reference DLL')
    base = pe.OPTIONAL_HEADER.ImageBase
    text = next(s for s in pe.sections if s.Name.rstrip(b'\0') == b'.text')
    code = text.get_data()
    dis = Cs(CS_ARCH_X86, CS_MODE_32)
    records = []
    for name in names:
        needle = name.encode() + b'\0'
        start = 0
        while (offset := data.find(needle, start)) >= 0:
            start = offset + 1
            if offset and data[offset-1] not in (0, 10, 13):
                continue
            rva = pe.get_rva_from_offset(offset)
            address = base + rva
            pointers = []
            pos = 0
            while (hit := code.find(struct.pack('<I', address), pos)) >= 0:
                pos = hit + 1
                if hit == 0 or code[hit-1] not in (0x68, *range(0xB8, 0xC0)):
                    continue
                ref = text.VirtualAddress + hit-1
                insns = list(dis.disasm(code[hit-1:hit+65], base+ref))[:12]
                record = {'rva': hex(ref), 'instruction_window': [
                    f'{i.address-base:#x}: {i.mnemonic} {i.op_str}' for i in insns]}
                # Exact observed registration pattern in the owned server:
                # push flags; push default string; push name; mov ecx, object.
                if hit >= 11 and code[hit-11] == 0x68 and code[hit-6] == 0x68 and code[hit+4] == 0xB9:
                    default_va = struct.unpack_from('<I', code, hit-5)[0]
                    if base <= default_va < base + pe.OPTIONAL_HEADER.SizeOfImage:
                        value = pe.get_string_at_rva(default_va-base)
                        if value and len(value) < 80 and all(32 <= c < 127 for c in value):
                            record['default_string_candidate'] = value.decode()
                            record['default_string_rva'] = hex(default_va-base)
                pointers.append(record)
            records.append({'name': name, 'string_rva': hex(rva), 'immediate_candidates': pointers})
    return {'schema': 'kf2vr/portal2-reference/1', 'binary': str(path.resolve()),
            'sha256': hashlib.sha256(data).hexdigest(), 'image_base': hex(base), 'records': records}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--names', nargs='+', default=[
        'portals_resizeall', 'portal_placement_never_fail', 'portal_placement_debug',
        'portal_player_interaction', 'sv_portal_placement_never_bump', 'portalgun_fire_delay',
        'portalgun_held_button_fire_fire_delay', 'portal2_portal_width', 'Portals_ResizeAll',
        'portal_new_player_trace', 'sv_player_funnel_into_portals', 'portal_teleportation_debug',
        'portal_surface_shader', 'r_portal_stencil_depth', 'r_portal_use_dlights',
        'r_portal_use_pvs_optimization', 'r_portal_use_complex_frustums'])
    args = parser.parse_args()
    result = inspect(args.binary, args.names)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2))
    print(json.dumps({'sha256': result['sha256'], 'found': [r['name'] for r in result['records']],
                      'output': str(args.output)}))
