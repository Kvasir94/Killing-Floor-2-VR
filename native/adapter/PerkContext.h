#pragma once

#include "GameScript.h"

namespace kf2vr::adapter {

// Stock perk evaluation points that read one "current, aimed" weapon. Script
// (VRPerkContext) points Pawn.Weapon at the acting item and raises its sights
// flag for a braced shot for exactly the duration of the stock call.
enum class PerkEntry { None, Fire, Damage, Movement };

struct PerkCall {
    PerkEntry entry{PerkEntry::None};
    void* pawn{};      // the VR player's pawn whose perk is evaluated
    void* argument{};  // Fire: the weapon; Damage: the damage causer
};

// Classifies FireAmmunition on a KFWeapon, TakeDamage on a KFPawn_Monster
// (by its instigating controller's pawn) and UpdateGroundSpeed on a human.
PerkCall ClassifyPerkCall(GameScript& script, void* object, void* function, const void* locals);

// Damage and movement are authority work. Solo and a dedicated server are
// the only authorities this mod runs as; online clients bracket shots only.
bool PawnHasAuthority(GameScript& script, void* pawn);

// Calls provider.NativePerkFire/Damage/Movement on entry and NativePerkEnd on
// exit. The provider is VRHandsBridge (solo, and a client's own shots) or
// the server's KF2VRNetHeldInventory ledger.
class PerkScope {
public:
    explicit PerkScope(GameScript& script) : script_(script) {}
    ~PerkScope();
    PerkScope(const PerkScope&)=delete;
    PerkScope& operator=(const PerkScope&)=delete;
    void Enter(void* provider, const PerkCall& call);
private:
    GameScript& script_;
    void* provider_{};
};

// Client adapter entry: the local player's shots anywhere, and its hits and
// movement where this process is the authority (solo).
void EnterLocalPerk(GameScript& script, PerkScope& scope, void* bridge, void* pawn,
                    void* object, void* function, const void* locals);

} // namespace kf2vr::adapter
