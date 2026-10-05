"""Hash-pinned offline queue/dispatch evidence; never hooks or starts KF2."""
import argparse
import hashlib
import json
from pathlib import Path
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
from capstone.x86_const import X86_OP_IMM, X86_OP_MEM, X86_REG_RIP
from pe import PE, runtime_functions, function_at

EXPECTED = '77ab9c2cf43aeaa3038274fff3822064815a3ea02a1b3c81870cdc12a885c994'
TARGET = Path('D:/SteamLibrary/steamapps/common/killingfloor2/Binaries/Win64/KFGame.exe')


def audit(target):
    digest=hashlib.sha256(target.read_bytes()).hexdigest()
    if digest != EXPECTED:
        raise ValueError('Executable hash differs from the pinned render evidence')
    pe=PE(str(target));functions=runtime_functions(pe)
    decoder=Cs(CS_ARCH_X86,CS_MODE_64);decoder.detail=True
    output={}
    for address,label in [(0x903380,'submit'),(0x9075b0,'execute'),(0x913ce0,'render_and_destroy'),
                          (0x2a48c0,'start_render_thread')]:
        boundary=function_at(functions,address)
        if not boundary or boundary[0]!=address:
            raise ValueError(f'Unexpected function boundary: {address:x}')
        begin,end,_=boundary
        instructions=[];calls=[];references=[]
        for instruction in decoder.disasm(pe.read(begin,end-begin),begin):
            instructions.append(f'{instruction.address:08x}: {instruction.mnemonic} {instruction.op_str}')
            for op in instruction.operands:
                if instruction.mnemonic=='call' and op.type==X86_OP_IMM:
                    calls.append(op.imm)
                if op.type==X86_OP_MEM and op.mem.base==X86_REG_RIP:
                    references.append(instruction.address+instruction.size+op.mem.disp)
        output[label]=dict(begin=begin,end=end,calls=calls,references=references,instructions=instructions)
    def window(address,size):
        return [f'{i.mnemonic} {i.op_str}' for i in decoder.disasm(pe.read(address,size),address)]
    # Leaf helpers have no unwind entry; decode the exact bytes the adapter calls.
    allocate=window(0xe3f0,0x83);finish_read=window(0x1e310,0x1e)
    loop=window(0x2a3860,0x3c);skip_execute=window(0xa970a0,4)
    execute_call='call qword ptr [rax + 8]'
    after_execute=loop[loop.index(execute_call)+1:] if execute_call in loop else []
    checks={
        'submit_reads_threaded_global':0x21f8da0 in output['submit']['references'],
        'submit_references_command_queue':0x21f8f38 in output['submit']['references'],
        'submit_references_draw_command_vtable':0x18df2b0 in output['submit']['references'],
        'submit_constructs_renderer':0x8fea50 in output['submit']['calls'],
        'submit_has_synchronous_dispatch':0x913ce0 in output['submit']['calls'],
        'command_executes_same_dispatch':0x913ce0 in output['execute']['calls'],
        'dispatch_calls_renderer':0x90ef10 in output['render_and_destroy']['calls'],
        'dispatch_destroys_renderer':0x900f40 in output['render_and_destroy']['calls'],
        'dispatch_frees_renderer':0x04f240 in output['render_and_destroy']['calls'],
        # Enqueue ABI used by native/adapter/RenderCommand.h.
        'submit_allocates_ring_space':0xe3f0 in output['submit']['calls'],
        'submit_commits_ring_space':0x102d0 in output['submit']['calls'],
        'submit_writes_skip_command':0x166bc30 in output['submit']['references'],
        'allocate_marks_ring_writing':'mov dword ptr [rdx + 0x18], 1' in allocate,
        'render_loop_executes_slot1':execute_call in loop,
        'render_loop_destroys_slot0_in_place':'xor edx, edx' in after_execute and 'call qword ptr [r8]' in after_execute,
        'render_loop_finishes_read':'call 0x1e310' in loop,
        'finish_read_aligns_size':'and rdx, rax' in finish_read,
        'skip_command_returns_stored_size':skip_execute[:1]==['mov eax, dword ptr [rcx + 8]'],
    }
    return dict(scope='static-disassembly-only',sha256=digest,checks=checks,functions=output,
                all_checks_pass=all(checks.values()))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    report=audit(TARGET)
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='functions'},indent=2))
    raise SystemExit(0 if report['all_checks_pass'] else 1)
