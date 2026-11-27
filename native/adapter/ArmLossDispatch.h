#pragma once
#include "GameScript.h"
namespace kf2vr::adapter {
// Experimental arm loss (#210). Routes five stock script checks to the
// authority's VRArmLossMutator (and the stock injury notification to the
// local VRHandsBridge), so arm loss runs inside the stock decisions:
//   KFPawn_Monster.CanInjureHitZone       -> NativeCanInjureArm   (1: true)
//   KFPawnAnimInfo.CanDoAttackAnim        -> NativeAttackAllowed  (0: false)
//   KFPawn_Monster.MeleeImpactNotify      -> NativeImpactAllowed  (0: skip)
//   KFAIController_ZedHusk.CanDoFireball,
//   KFAIController_ZedHusk.CanDoFlamethrower -> NativeHuskGunAllowed (0: false)
//   KFPawn_Monster.HitZoneInjured (not on a dedicated server)
//                                         -> VRHandsBridge.NativeArmLossInjured
// Returns true when the stock body must be skipped; `result` then holds the
// answer. Every other call, and every call while no arm is lost or the
// mutator is absent, runs stock unchanged.
bool RouteArmLoss(GameScript& script,void* object,void* function,const void* locals,void* result,void* handsBridge);
}
