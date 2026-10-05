#pragma once

#include "GameScript.h"
#include "ScriptField.h"

namespace kf2vr::adapter {

// KFWeapon.SpawnProjectile calls KFProjectile.Init before returning, and Init
// adds TossZ to the spawned velocity's world Z after the aim direction has been
// applied. A tracked laser marks the bore, so that toss reads as the whole shot
// missing high. Hand the finished projectile to script, which owns every policy
// question: whether this weapon is VR-managed, whether the shot came from the
// thrown-grenade firemode, and what the toss was worth.
//
// Per projectile, after the stock function has fully run. Nothing global is
// changed, so a multi-pellet spawn is handled one call at a time and there is
// no window in which another actor's projectile could see a modified class.
inline bool ClearProjectileToss(GameScript& script, void* bridge, void* weapon, void* projectile) {
    struct Parameters { void* weapon; void* projectile; } parameters{weapon,projectile};
    auto* function=script.FindFunction(bridge,L"ClearProjectileToss");
    ScriptField weaponField{},projectileField{};
    if (!function || !projectile ||
        !FindScriptField(function,script.Intern(L"W"),weaponField) ||
        !FindScriptField(function,script.Intern(L"P"),projectileField) ||
        weaponField.offset!=offsetof(Parameters,weapon) ||
        weaponField.size!=sizeof(parameters.weapon) ||
        projectileField.offset!=offsetof(Parameters,projectile) ||
        projectileField.size!=sizeof(parameters.projectile)) return false;
    return script.Invoke(bridge,function,&parameters);
}

} // namespace kf2vr::adapter
