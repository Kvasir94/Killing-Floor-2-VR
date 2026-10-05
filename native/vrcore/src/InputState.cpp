#include "kf2vr/InputState.h"

namespace kf2vr {

const char* ToString(CancelReason r) {
    switch (r) {
        case CancelReason::None:         return "none";
        case CancelReason::TrackingLost: return "tracking_lost";
        case CancelReason::FocusLost:    return "focus_lost";
        case CancelReason::MenuOpened:   return "menu_opened";
        case CancelReason::WeaponChanged:return "weapon_changed";
        case CancelReason::PawnDied:     return "pawn_died";
        case CancelReason::Disconnected: return "disconnected";
        case CancelReason::Travel:       return "travel";
    }
    return "unknown";
}

}  // namespace kf2vr
