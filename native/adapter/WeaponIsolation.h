#pragma once

#include "GameScript.h"

namespace kf2vr::adapter {

// Resolve through script-owned inventory references; saves/restores native
// query ingress for nested calls. Success with null state means unmanaged.
bool ResolveInventoryItem(GameScript& script, void* inventory, void* weapon, void*& state);

// Called only from the local, game-thread ProcessInternal dispatch. False
// means ordinary stock execution; true means a registered item's VM call was
// completed here. No item actor is created, equipped or selected by this code.
bool RouteItemPendingFire(GameScript& script, void* bridge, void* pawn,
                          void* object, void* function, const void* locals, void* result);

// Server callers resolve the ledger through the exact weapon owner's channel.
// The caller must establish authority/thread/lifetime before using this core.
bool RouteInventoryPendingFire(GameScript& script, void* inventory, void* pawn,
                               void* object, void* function, const void* locals, void* result);

} // namespace kf2vr::adapter
