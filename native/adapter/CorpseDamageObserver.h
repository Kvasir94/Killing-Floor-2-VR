#pragma once

#include "GameScript.h"
#include <array>
#include <optional>

namespace kf2vr::adapter {

// Observe only the stock KFPawn.Dying.TakeDamage body on the authority.
// This reports an actual corpse damage call; it does not intercept a shot,
// change stock damage, or provide missing server-side corpse collision.
void ObserveCorpseDamage(GameScript& script, void* victim, void* function, const void* locals);

// True only when the optional script consumed this exact Husk contact. The
// projectile may have been destroyed; the caller must not run its stock body.
bool RouteHeldHuskContact(GameScript& script,void* projectile,void* function,const void* locals);

struct SwipeCallFrame {
    SwipeCallFrame(void* object,void* called,const void* parameters,SwipeCallFrame* parent)
        : helper(object),function(called),locals(parameters),previous(parent),damagedCount(0) {}
    void* helper;
    void* function;
    const void* locals;
    SwipeCallFrame* previous;
    // Only entries below damagedCount are read; insertion initializes each.
    std::array<void*,16> damagedBodies;
    std::size_t damagedCount;
};

// Tracks only synchronous stock swipe frames; the optional metadata patch is
// the real physics hit returned by a validated body-occlusion callback.
class SwipeDispatchScope {
public:
    SwipeDispatchScope(GameScript& script,void* object,void* function,void* locals);
    ~SwipeDispatchScope();
    SwipeDispatchScope(const SwipeDispatchScope&)=delete;
    SwipeDispatchScope& operator=(const SwipeDispatchScope&)=delete;
private:
    std::optional<SwipeCallFrame> frame_;
    void* patched_{};
    std::size_t patchSize_{};
    // GuardedCopy fills every byte read or restored, before patched_ is set.
    std::array<std::byte,256> original_;
};

bool RouteHeldSwipeContact(GameScript& script,void* helper,void* function,const void* locals);

// Exact stock bone-radius execution marks nested damage as radial even though
// Pawn.TakeRadiusDamageOnBones does not set KFPawn.bTakingRadiusDamage.
class RadiusDamageScope {
public:
    RadiusDamageScope(GameScript& script,void* pawn,void* function);
    ~RadiusDamageScope();
    RadiusDamageScope(const RadiusDamageScope&)=delete;
    RadiusDamageScope& operator=(const RadiusDamageScope&)=delete;
private:
    bool previous_{};
};

// Carry real live-pawn HitInfo through the stock ReduceDamage -> NetDamage
// call, which otherwise omits it. No credit is issued here. Script maintains
// a bounded nesting stack; this synchronous scope always pairs begin/end.
class LiveDamageScope {
public:
    LiveDamageScope(GameScript& script,void* victim,void* function,const void* locals);
    ~LiveDamageScope();
    LiveDamageScope(const LiveDamageScope&)=delete;
    LiveDamageScope& operator=(const LiveDamageScope&)=delete;
private:
    GameScript& script_;
    void* mutator_{};
    void* victim_{};
    void* world_{};
};

} // namespace kf2vr::adapter
