#include "TransferredWeaponReceipt.h"
#include <cstdio>
#include <climits>

int main() {
    int a=0,b=0,failures=0;
    auto check=[&](bool ok,const char* label) {
        if(!ok) { ++failures; std::printf("FAIL: %s\n",label); }
    };
    using kf2vr::adapter::AcceptTransferredWeaponReceipt;
    check(AcceptTransferredWeaponReceipt(12,0,nullptr,nullptr,&a,12),"serial-only expectation accepts first candidate");
    check(AcceptTransferredWeaponReceipt(12,12,nullptr,&a,&a,12),"duplicate same receipt is idempotent");
    check(!AcceptTransferredWeaponReceipt(12,12,nullptr,&a,&b,12),"different candidate cannot replace first actor");
    check(!AcceptTransferredWeaponReceipt(12,12,nullptr,nullptr,&b,12),"destroyed first candidate cannot be replaced");
    check(!AcceptTransferredWeaponReceipt(12,0,nullptr,&a,&a,12),"actor without its receipt serial is inconsistent");
    check(AcceptTransferredWeaponReceipt(12,0,&a,nullptr,&a,12),"known actor matches expectation");
    check(!AcceptTransferredWeaponReceipt(12,0,&a,nullptr,&b,12),"known actor constraint is retained");
    check(!AcceptTransferredWeaponReceipt(12,0,nullptr,nullptr,&a,11),"older receipt cannot satisfy request");
    check(!AcceptTransferredWeaponReceipt(12,0,nullptr,nullptr,&a,13),"newer unrelated receipt cannot satisfy request");
    check(!AcceptTransferredWeaponReceipt(0,0,nullptr,nullptr,&a,12),"no active expectation rejects receipt");
    check(!AcceptTransferredWeaponReceipt(12,11,nullptr,&a,&a,12),"inconsistent received lifetime rejects receipt");
    check(!AcceptTransferredWeaponReceipt(12,0,nullptr,nullptr,nullptr,12),"missing actor rejects receipt");
    check(!AcceptTransferredWeaponReceipt(0,0,nullptr,nullptr,&a,0),"zero token rejects receipt");
    check(!AcceptTransferredWeaponReceipt(-1,0,nullptr,nullptr,&a,-1),"negative token rejects receipt");
    check(!AcceptTransferredWeaponReceipt(INT_MAX,0,nullptr,nullptr,&a,INT_MAX),"exhausted serial rejects receipt");
    using kf2vr::adapter::TransferReceiptSlot;
    using kf2vr::adapter::TransferredWeaponReceiptSlot;
    std::array<TransferReceiptSlot,2> slots{{{12,0,nullptr,nullptr},{13,0,nullptr,nullptr}}};
    check(TransferredWeaponReceiptSlot(slots,&b,13)==1,"second hand may receive first");
    slots[1].receivedSerial=13; slots[1].receivedWeapon=&b;
    check(TransferredWeaponReceiptSlot(slots,&a,12)==0,"older receipt still reaches first hand");
    check(TransferredWeaponReceiptSlot(slots,&b,12)==-1,"second hand actor cannot bind first hand");
    slots[0].receivedSerial=12; slots[0].receivedWeapon=&a;
    check(TransferredWeaponReceiptSlot(slots,&a,12)==0,"first receipt remains idempotent with both occupied");
    check(TransferredWeaponReceiptSlot(slots,&b,13)==1,"second receipt remains idempotent with both occupied");
    check(TransferredWeaponReceiptSlot(slots,&a,13)==-1,"wrong actor cannot consume second serial");
    check(TransferredWeaponReceiptSlot(slots,&a,14)==-1,"future receipt cannot consume either slot");
    slots[0]={};
    check(TransferredWeaponReceiptSlot(slots,&a,12)==-1,"forgotten serial cannot revive a cleared slot");
    check(TransferredWeaponReceiptSlot(slots,&b,13)==1,"clearing one hand retains the other receipt");
    slots[0]={14,0,&a,nullptr};
    check(TransferredWeaponReceiptSlot(slots,&b,14)==-1,"reused slot retains its new actor constraint");
    check(TransferredWeaponReceiptSlot(slots,&a,14)==0,"reused slot accepts new serial and actor");
    slots[0].expectedSerial=13;
    check(TransferredWeaponReceiptSlot(slots,&b,13)==-1,"ambiguous duplicate serial fails closed");
    slots={};
    check(TransferredWeaponReceiptSlot(slots,&a,12)==-1,"teardown rejects old receipts");
    check(TransferredWeaponReceiptSlot(slots,&b,13)==-1,"teardown clears both lifetimes");
    std::printf("Transferred weapon receipt failures=%d\n",failures);
    return failures ? 1 : 0;
}
