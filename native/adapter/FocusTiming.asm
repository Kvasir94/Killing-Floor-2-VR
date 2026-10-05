; Pinned KFGame.exe 8767, UWorld::Tick interior RVA 582AD8.
; Entry is a JMP: engine RSP is 16-byte aligned; R15=world, R12=WorldInfo,
; XMM0=clamped simulation delta, [RBP+77h]=the shared tick delta local.
; Preserve every volatile register and flags around the non-throwing callback.
; The original 10-byte MOVSS is replayed by MinHook's trampoline.
EXTERN FocusAdjustSimulation:PROC
EXTERN FocusSimulationTrampoline:QWORD
PUBLIC FocusSimulationDetour
.code
FocusSimulationDetour PROC
    pushfq
    push rax
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    sub rsp, 80h
    movdqu [rsp+20h], xmm0
    movdqu [rsp+30h], xmm1
    movdqu [rsp+40h], xmm2
    movdqu [rsp+50h], xmm3
    movdqu [rsp+60h], xmm4
    movdqu [rsp+70h], xmm5
    mov rcx, r15
    mov rdx, r12
    movaps xmm2, xmm0
    call FocusAdjustSimulation
    movss DWORD PTR [rbp+77h], xmm0
    movdqu xmm0, [rsp+20h]
    movss xmm1, DWORD PTR [rbp+77h]
    movss xmm0, xmm1
    movdqu xmm1, [rsp+30h]
    movdqu xmm2, [rsp+40h]
    movdqu xmm3, [rsp+50h]
    movdqu xmm4, [rsp+60h]
    movdqu xmm5, [rsp+70h]
    add rsp, 80h
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    popfq
    jmp QWORD PTR [FocusSimulationTrampoline]
FocusSimulationDetour ENDP
END
