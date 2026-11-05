#pragma once
#include <climits>
#include <array>

namespace kf2vr::adapter {
// Cross-owner weapon actors may become relevant only after ClientGivenTo.
// An owner-allocated serial authorizes one first candidate; the later result
// must still match that actor and its stock inventory membership.
inline bool AcceptTransferredWeaponReceipt(int expectedSerial, int receivedSerial,
        const void* expectedWeapon, const void* receivedWeapon,
        const void* weapon, int serial) {
    const bool first = receivedSerial == 0 && !receivedWeapon;
    const bool repeat = receivedSerial == serial && receivedWeapon == weapon;
    return weapon && serial > 0 && serial < INT_MAX && expectedSerial == serial &&
        (!expectedWeapon || expectedWeapon == weapon) && (first || repeat);
}

struct TransferReceiptSlot {
    int expectedSerial{}, receivedSerial{};
    const void* expectedWeapon{};
    const void* receivedWeapon{};
};

// Select one exact request. Never let ambiguous serials or a weapon reserved
// by the other hand consume a second slot, regardless of delivery order.
inline int TransferredWeaponReceiptSlot(const std::array<TransferReceiptSlot,2>& slots,
                                       const void* weapon, int serial) {
    if (!weapon || serial <= 0 || serial == INT_MAX) return -1;
    const bool left = slots[0].expectedSerial == serial;
    const bool right = slots[1].expectedSerial == serial;
    if (left == right) return -1;
    const int index = left ? 0 : 1;
    const auto& slot = slots[index];
    const auto& other = slots[1-index];
    if (other.expectedSerial != 0 &&
        (other.expectedWeapon == weapon || other.receivedWeapon == weapon)) return -1;
    return AcceptTransferredWeaponReceipt(slot.expectedSerial,slot.receivedSerial,
        slot.expectedWeapon,slot.receivedWeapon,weapon,serial) ? index : -1;
}
}
