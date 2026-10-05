"""Read-only evidence tying the stock DepthPrepass setting to its draw gate."""
import hashlib
import json
import struct
from pathlib import Path
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
from pe import PE, runtime_functions, function_at

TARGET=Path('D:/SteamLibrary/steamapps/common/killingfloor2/Binaries/Win64/KFGame.exe')
EXPECTED='77ab9c2cf43aeaa3038274fff3822064815a3ea02a1b3c81870cdc12a885c994'


def audit():
    digest=hashlib.sha256(TARGET.read_bytes()).hexdigest()
    if digest!=EXPECTED: raise ValueError('Unsupported executable')
    pe=PE(str(TARGET)); decoder=Cs(CS_ARCH_X86,CS_MODE_64)
    functions=runtime_functions(pe)
    instructions={}
    for address in (0x8fea50,0x913440):
        begin,end,_=function_at(functions,address)
        if begin!=address: raise ValueError('Unexpected unwind boundary')
        for ins in decoder.disasm(pe.read(begin,end-begin),begin): instructions[ins.address]=ins
    copy=bytes.fromhex('83 3d 58 a2 8f 01 00 75 0d 8b 0d e8 be 5d 01 41 89 8f ec 00 00 00')
    checks={
        'table_names_depth_prepass':struct.unpack('<Q',pe.read(0x1eda1a4,8))[0]==pe.image_base+0x171ec98 and
            pe.read(0x171ec98,26)==('DepthPrepass\0').encode('utf-16-le'),
        'table_points_to_live_setting':struct.unpack('<Q',pe.read(0x1eda1ac,8))[0]==pe.image_base+0x1edafb0,
        'constructor_copy_and_override':pe.read(0x8ff0b9,len(copy))==copy and all(
            address in instructions for address in (0x8ff0b9,0x8ff0c0,0x8ff0c2,0x8ff0c8)),
        'prepass_draw_gate':instructions[0x9135f4].bytes==bytes.fromhex('83 bf ec 00 00 00 00') and
            instructions[0x9135fb].mnemonic=='je' and instructions[0x9135fb].op_str=='0x91369f',
        'foreground_prepass_call':instructions[0x91366c].mnemonic=='call' and instructions[0x91366c].op_str=='0x9117f0',
        'normal_prepass_call':any(i.mnemonic=='call' and i.op_str=='0x9117f0'
            for a,i in instructions.items() if 0x91368f<=a<0x91369f),
    }
    return dict(scope='static-setting-to-render-gate; no performance or image claim',sha256=digest,
                checks=checks,all_checks_pass=all(checks.values()))


if __name__=='__main__':
    report=audit()
    print(json.dumps(report,indent=2))
    raise SystemExit(0 if report['all_checks_pass'] else 1)
