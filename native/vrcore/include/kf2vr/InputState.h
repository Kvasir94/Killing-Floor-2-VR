// Button edge/hold state machine with explicit invalidation.
//
// Two rules from the research pack drive the whole design:
//
//   "Clear transient actions on lost tracking, dashboard focus, menu changes,
//    weapon changes, death, and reconnect."
//   "...recover without duplicate clicks."
//
// Those pull in opposite directions. Cancelling a held trigger is easy;
// cancelling it without emitting a phantom press when the user is still
// physically holding the button is the part that goes wrong. This class
// handles it by latching a suppression flag that only clears on a real
// physical release.
#pragma once

#include <cstdint>

namespace kf2vr {

enum class CancelReason : std::uint8_t {
    None = 0,
    TrackingLost,
    FocusLost,      // dashboard, alt-tab, headset removed
    MenuOpened,
    WeaponChanged,
    PawnDied,
    Disconnected,
    Travel,
};

class ButtonState {
public:
    // Feed the raw physical button once per frame with a REAL-time timestamp.
    // Real time, deliberately: a hold gesture measured in ZedTime-dilated game
    // seconds would stretch with the dilation. Fire cadence and ammo stay on
    // game time, in the script layer, where the server can arbitrate them.
    void Update(bool rawDown, double realTimeSeconds) {
        const bool wasEffective = effectiveDown_;

        if (suppressedUntilRelease_) {
            if (!rawDown) suppressedUntilRelease_ = false;  // the real release clears it
            effectiveDown_ = false;
        } else {
            effectiveDown_ = rawDown;
        }

        pressed_  = effectiveDown_ && !wasEffective;
        released_ = !effectiveDown_ && wasEffective;

        if (pressed_) downSince_ = realTimeSeconds;
        now_ = realTimeSeconds;
    }

    // Rising edge this frame.
    bool Pressed() const { return pressed_; }

    // Falling edge this frame. A cancel produces one of these, so consumers
    // that release on the falling edge stay balanced.
    bool Released() const { return released_; }

    bool Down() const { return effectiveDown_; }

    double HeldSeconds() const { return effectiveDown_ ? now_ - downSince_ : 0.0; }

    bool HeldFor(double seconds) const { return effectiveDown_ && HeldSeconds() >= seconds; }

    // Drop the action now. If the button was down this synthesises a release
    // on this frame, then suppresses the input until the user physically lets
    // go -- so returning from the dashboard still holding the trigger does not
    // fire a shot, and does not require a second click to re-arm either.
    void Cancel(CancelReason reason) {
        released_              = effectiveDown_;
        effectiveDown_         = false;
        pressed_               = false;
        suppressedUntilRelease_ = true;
        lastCancel_            = reason;
        ++cancelCount_;
    }

    bool Suppressed() const { return suppressedUntilRelease_; }
    CancelReason LastCancelReason() const { return lastCancel_; }
    unsigned CancelCount() const { return cancelCount_; }

private:
    bool         effectiveDown_          = false;
    bool         pressed_                = false;
    bool         released_               = false;
    bool         suppressedUntilRelease_ = false;
    double       downSince_              = 0.0;
    double       now_                    = 0.0;
    CancelReason lastCancel_             = CancelReason::None;
    unsigned     cancelCount_            = 0;
};

// The full set of transient VR actions, cancelled as a unit.
struct ActionSet {
    ButtonState triggerRight;
    ButtonState triggerLeft;
    ButtonState gripRight;
    ButtonState gripLeft;
    ButtonState bash;
    ButtonState reload;

    void CancelAll(CancelReason reason) {
        triggerRight.Cancel(reason);
        triggerLeft.Cancel(reason);
        gripRight.Cancel(reason);
        gripLeft.Cancel(reason);
        bash.Cancel(reason);
        reload.Cancel(reason);
    }
};

const char* ToString(CancelReason r);

}  // namespace kf2vr
