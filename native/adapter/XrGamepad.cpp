#include "XrGamepad.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <utility>

namespace kf2vr::adapter {
namespace {
struct ExclusiveLock {
    explicit ExclusiveLock(SRWLOCK& lock) : lock_(lock) { AcquireSRWLockExclusive(&lock_); }
    ~ExclusiveLock() { ReleaseSRWLockExclusive(&lock_); }
    SRWLOCK& lock_;
};

// Missing input never counts as a physical release. Initial connection,
// focus/tracking loss, inactivity and timeout all require a real release.
constexpr float kStickDeadzone = .12f;

struct HoldGate {
    bool suppressed = true, digitalDown = false;
    void Cancel() { suppressed = true; digitalDown = false; }
    bool Button(bool active, bool down) {
        if (!active) { Cancel(); return false; }
        if (!down) { suppressed = false; return false; }
        return !suppressed;
    }
    float Axis(bool active, float value, float releaseThreshold = .1f) {
        if (!active || !std::isfinite(value)) { Cancel(); return 0.f; }
        value = std::clamp(value, 0.f, 1.f);
        if (value <= releaseThreshold) { suppressed = false; return 0.f; }
        return suppressed ? 0.f : value;
    }
    bool Squeeze(bool active, float value, float pressThreshold = .75f, float releaseThreshold = .25f) {
        if (!active || !std::isfinite(value)) { Cancel(); return false; }
        if (value <= releaseThreshold) { suppressed = false; digitalDown = false; return false; }
        if (suppressed) return false;
        if (value >= pressThreshold) digitalDown = true;
        return digitalDown; // Schmitt thresholds avoid repeated presses from squeeze jitter.
    }
    std::pair<float,float> Stick(bool active, float x, float y) {
        if (!active || !std::isfinite(x) || !std::isfinite(y)) { Cancel(); return {}; }
        x = std::clamp(x, -1.f, 1.f);
        y = std::clamp(y, -1.f, 1.f);
        const float magnitude = std::sqrt(x*x + y*y);
        if (magnitude <= kStickDeadzone) { suppressed = false; return {}; }
        if (suppressed) return {};
        if (magnitude > 1.f) { x /= magnitude; y /= magnitude; }
        return {x,y};
    }
    // Only X is published for turning, so its deadzone is axial and rescaled:
    // turn speed ramps up from zero at the edge instead of starting at 12%.
    float Yaw(bool active, float x, float y) {
        const float value = Stick(active, x, y).first;
        const float amount = std::abs(value);
        return amount <= kStickDeadzone ? 0.f :
            std::copysign((amount - kStickDeadzone) / (1.f - kStickDeadzone), value);
    }
};
SHORT Thumb(float axis) { return static_cast<SHORT>(std::lround(std::clamp(axis,-1.f,1.f) * 32767.f)); }
BYTE Trigger(float axis) { return static_cast<BYTE>(std::lround(std::clamp(axis,0.f,1.f) * 255.f)); }
bool SamePad(const XINPUT_GAMEPAD& a, const XINPUT_GAMEPAD& b) {
    return a.wButtons == b.wButtons && a.bLeftTrigger == b.bLeftTrigger && a.bRightTrigger == b.bRightTrigger &&
        a.sThumbLX == b.sThumbLX && a.sThumbLY == b.sThumbLY && a.sThumbRX == b.sThumbRX && a.sThumbRY == b.sThumbRY;
}
constexpr WORD kButtons = XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_B | XINPUT_GAMEPAD_X | XINPUT_GAMEPAD_Y |
    XINPUT_GAMEPAD_LEFT_SHOULDER | XINPUT_GAMEPAD_RIGHT_SHOULDER | XINPUT_GAMEPAD_LEFT_THUMB |
    XINPUT_GAMEPAD_RIGHT_THUMB | XINPUT_GAMEPAD_START;
} // namespace

HandWeaponButtons MapHandWeaponButtons(const xr::FrameState& frame, int validHandMask) {
    HandWeaponButtons buttons;
    const bool leftValid = (validHandMask & 1) != 0;
    const bool rightValid = (validHandMask & 2) != 0;
    const auto& left = frame.handLeft;
    const auto& right = frame.handRight;
    const bool leftPrimaryActive = leftValid && left.primaryActive;
    const bool rightPrimaryActive = rightValid && right.primaryActive;
    const bool torchActive = leftPrimaryActive && rightValid && right.gripActive && std::isfinite(right.gripAxis);
    if (leftPrimaryActive) buttons.activeMask |= 1;
    if (leftValid && left.secondaryActive) buttons.activeMask |= 2;
    if (torchActive) buttons.activeMask |= 4;
    if (rightPrimaryActive) buttons.activeMask |= 8;
    // Unmodified X/A reload; right-grip + X retains the flashlight-only chord.
    // A always reloads independently of that chord and the other hand's state.
    if (leftPrimaryActive && left.primaryPressed)
        buttons.pressedMask |= torchActive && right.gripAxis > .65f ? 4 : 1;
    if ((buttons.activeMask & 2) && left.secondaryPressed) buttons.pressedMask |= 2;
    if (rightPrimaryActive && right.primaryPressed) buttons.pressedMask |= 8;
    return buttons;
}

void RemoveScriptWeaponActions(XINPUT_GAMEPAD& pad) {
    pad.bLeftTrigger = pad.bRightTrigger = 0;
    pad.wButtons &= ~(XINPUT_GAMEPAD_X | XINPUT_GAMEPAD_Y |
        XINPUT_GAMEPAD_LEFT_SHOULDER | XINPUT_GAMEPAD_RIGHT_SHOULDER);
}

struct XrGamepad::Impl {
    SRWLOCK lock = SRWLOCK_INIT;
    XINPUT_STATE state{};
    std::array<HoldGate, 2> trigger, grip, stick, primary, secondary, stickClick, menu;
    ULONGLONG receivedTick = 0;
    unsigned timeoutMs = 250;
    double lastRealTime = 0;
    bool haveTimestamp = false, haveFrame = false;

    void Publish(const XINPUT_GAMEPAD& next) {
        if (!SamePad(state.Gamepad, next)) {
            ++state.dwPacketNumber; // XInput packet numbers advance only on changed state.
            state.Gamepad = next;
        }
    }
    void Cancel() {
        for (auto* group : {&trigger, &grip, &stick, &primary, &secondary, &stickClick, &menu})
            for (auto& control : *group) control.Cancel();
        Publish({});
        haveFrame = false;
    }
    void ExpireIfStale() {
        if (haveFrame && GetTickCount64() - receivedTick > timeoutMs) Cancel();
    }
    template<typename GripFrame, typename AimFrame>
    void MapHand(std::size_t index, const xr::HandState<GripFrame,AimFrame>& hand, XINPUT_GAMEPAD& pad) {
        const bool available = hand.poseValid;
        const auto button = [&](bool down, WORD bit) { if (down) pad.wButtons |= bit; };
        // Explicit provisional mapping follows stock KF2 DefaultInput.ini:
        // Left stick = movement/sprint-crouch; right stick X = yaw, click = bash.
        // Right stick Y stays zero; this bridge never introduces artificial pitch.
        if (index == 0) {
            // Physical left trigger = stock use (pad B), never ironsights.
            // Separate press/release thresholds prevent interact key repeats
            // from trigger jitter; lost input still requires a real release.
            button(trigger[index].Squeeze(available && hand.triggerActive, hand.triggerAxis, .55f, .1f), XINPUT_GAMEPAD_B);
            const auto movement = stick[index].Stick(available && hand.stickActive, hand.stickX, hand.stickY);
            pad.sThumbLX = Thumb(movement.first);
            pad.sThumbLY = Thumb(movement.second);
        } else {
            pad.bRightTrigger = Trigger(trigger[index].Axis(available && hand.triggerActive, hand.triggerAxis)); // stock fire
            pad.sThumbRX = Thumb(stick[index].Yaw(available && hand.stickActive, hand.stickX, hand.stickY));
        }
        // Physical lower buttons X/A = reload; Y = weapon cycle; B = jump.
        // Other profiles supply equivalent primary/secondary face actions.
        button(primary[index].Button(available && hand.primaryActive, hand.primaryPressed), XINPUT_GAMEPAD_X);
        button(secondary[index].Button(available && hand.secondaryActive, hand.secondaryPressed), index == 0 ? XINPUT_GAMEPAD_Y : XINPUT_GAMEPAD_A);
        button(stickClick[index].Button(available && hand.stickClickActive, hand.stickPressed), index == 0 ? XINPUT_GAMEPAD_LEFT_THUMB : XINPUT_GAMEPAD_RIGHT_THUMB);
        button(menu[index].Button(available && hand.menuActive, hand.menuPressed), XINPUT_GAMEPAD_START);
        // Grips are deliberate squeeze buttons in this provisional stock-pad
        // map: left grenade, right alternate fire. Never infer a pose gesture.
        button(grip[index].Squeeze(available && hand.gripActive, hand.gripAxis),
            index == 0 ? XINPUT_GAMEPAD_LEFT_SHOULDER : XINPUT_GAMEPAD_RIGHT_SHOULDER);
    }
};

XrGamepad::XrGamepad(unsigned staleTimeoutMilliseconds) : impl_(std::make_unique<Impl>()) {
    impl_->timeoutMs = std::clamp(staleTimeoutMilliseconds, 10u, 1000u);
}
XrGamepad::~XrGamepad() = default;
void XrGamepad::SetFrame(const xr::FrameState& frame, double realTimeSeconds) {
    auto& p = *impl_;
    ExclusiveLock guard(p.lock);
    p.ExpireIfStale();
    const bool monotonic = std::isfinite(realTimeSeconds) && (!p.haveTimestamp || realTimeSeconds >= p.lastRealTime);
    if (!monotonic) { p.Cancel(); p.haveTimestamp = false; return; }
    p.lastRealTime = realTimeSeconds;
    p.haveTimestamp = true;
    if (frame.state != xr::SessionState::Focused || !frame.actionsSynced || !frame.headPoseValid || !frame.viewsValid) {
        p.Cancel();
        return;
    }
    XINPUT_GAMEPAD next{};
    p.MapHand(0, frame.handLeft, next);
    p.MapHand(1, frame.handRight, next);
    p.Publish(next);
    p.receivedTick = GetTickCount64();
    p.haveFrame = true;
}
DWORD XrGamepad::GetState(DWORD deviceIndex, XINPUT_STATE* state) {
    if (!state) return ERROR_BAD_ARGUMENTS;
    *state = {};
    if (deviceIndex != 0) return ERROR_DEVICE_NOT_CONNECTED;
    auto& p = *impl_;
    ExclusiveLock guard(p.lock);
    p.ExpireIfStale();
    *state = p.state;
    return ERROR_SUCCESS;
}
DWORD XrGamepad::GetCapabilities(DWORD deviceIndex, DWORD flags, XINPUT_CAPABILITIES* capabilities) const {
    if (!capabilities) return ERROR_BAD_ARGUMENTS;
    *capabilities = {};
    if (deviceIndex != 0) return ERROR_DEVICE_NOT_CONNECTED;
    if (flags != 0 && flags != XINPUT_FLAG_GAMEPAD) return ERROR_BAD_ARGUMENTS;
    capabilities->Type = XINPUT_DEVTYPE_GAMEPAD;
    capabilities->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
    capabilities->Gamepad.wButtons = kButtons;
    capabilities->Gamepad.bRightTrigger = 255;
    capabilities->Gamepad.sThumbLX = capabilities->Gamepad.sThumbLY = capabilities->Gamepad.sThumbRX = 32767;
    // No advertised right-Y, D-pad, back button or rumble until implemented.
    return ERROR_SUCCESS;
}
void XrGamepad::Cancel() {
    ExclusiveLock guard(impl_->lock);
    impl_->Cancel();
}
} // namespace kf2vr::adapter

