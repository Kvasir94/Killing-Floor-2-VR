#pragma once

#include "GameScript.h"
#include "WeaponAimStack.h"

namespace kf2vr::adapter {

// Enters only at an explicit weapon boundary. reject prevents a managed
// FireAmmunition call with an absent/stale ownership pose.
void BeginItemAim(GameScript& script, WeaponAimStack& stack, WeaponAimStack::Scope& scope,
                  void* bridge, void* pawn, void* object, void* function,
                  const void* locals, bool& reject);
// True also suppresses the legacy selected-weapon override for invalid or
// shadowed managed queries. Ordinary unregistered calls retain that fallback.
bool FinishItemAim(GameScript& script, const WeaponAimStack& stack, void* bridge,
                   void* pawn, void* object, void* function, const void* locals, void* result);
bool RouteItemTraceOrigin(GameScript& script, const WeaponAimStack& stack,
                         void* bridge, void* pawn, void* weapon, void* result);

} // namespace kf2vr::adapter
