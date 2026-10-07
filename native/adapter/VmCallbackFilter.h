#pragma once
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

namespace kf2vr::adapter {
// This only rejects names for which every VR dispatcher is a no-op. Eligible
// calls still run the original live object, ownership, pose and memory checks.
// Add a name here whenever a VR dispatcher gains a handler for it: a name
// missing from this union silently skips that dispatcher.
class VmCallbackFilter {
public:
    // These numeric identities describe dispatch only. They never cache an
    // object, class, ownership decision, pose or reflected function pointer.
    enum class Callback : std::uint8_t {
        AddSpread, AdjustDamage, ApplyAutoTarget, ApplyForceLookAtPawn,
        ApplyTargetAdhesion, ApplyTargetFriction, AttachWeaponTo, CheckTargetLock, ClearAllPendingFire,
        ClearFlashCount, ClearFlashLocation, ClearPendingFire, ClientPlayCameraAnim, ClientWeaponSet,
        DetachWeapon, EnableIronSightsDoF, FireAmmunition, FiringModeUpdated,
        FlashCountUpdated, FlashLocationUpdated, GetAdjustedAim, GetAdjustedAimFor,
        GetBackBlastLocationAndRotation, GetBaseAimRotation, GetMeleeAimRotation,
        GetMeleeStartTraceLocation, GetMuzzleLoc, GetPendingFireLength,
        GetWeaponFiringMode, GetWeaponStartTraceLocation, HandleRecoil,
        IncrementFlashCount, IsPendingFire, LandingShake, MeleeAttackDestructibles,
        MeleeAttackImpact, NativeHandsUpdate, NotifyBeginState, NotifyEndState,
        PendingFire, PlayCameraAnim, PlayCameraShake, PlayTakeHitEffects,
        ProcessViewRotation, RenderDisplay, SetCurrentWeapon, SetFiringMode,
        SetFlashLocation, SetPendingFire, SetSprinting, ShakeView, SpawnProjectile,
        Timer_CheckForAIWarning, UpdateCamera, UpdateHealTarget, UpdateWalkBob,
        ViewShake, WeaponFired, WeaponStoppedFiring,
        ClientPlayBlockEffects, ClientPlayParryEffects, IsGrappleBlocked,
        TakeDamage, UpdateGroundSpeed, PlayWeaponAnimation,
        CalcWeaponFire, NativePortalShotsUpdate, HitWall, NativeMagazineFeedEvent, ScoreDamage,
        ClientSetRotation, ClientSetLocation, AddCameraLensEffect, SetPosition, Unrelated
    };
    static constexpr std::array<const wchar_t*,73> CallbackNames{
        L"AddSpread", L"AdjustDamage", L"ApplyAutoTarget", L"ApplyForceLookAtPawn",
        L"ApplyTargetAdhesion", L"ApplyTargetFriction", L"AttachWeaponTo", L"CheckTargetLock", L"ClearAllPendingFire",
        L"ClearFlashCount", L"ClearFlashLocation", L"ClearPendingFire", L"ClientPlayCameraAnim", L"ClientWeaponSet",
        L"DetachWeapon", L"EnableIronSightsDoF", L"FireAmmunition", L"FiringModeUpdated",
        L"FlashCountUpdated", L"FlashLocationUpdated", L"GetAdjustedAim", L"GetAdjustedAimFor",
        L"GetBackBlastLocationAndRotation", L"GetBaseAimRotation", L"GetMeleeAimRotation",
        L"GetMeleeStartTraceLocation", L"GetMuzzleLoc", L"GetPendingFireLength",
        L"GetWeaponFiringMode", L"GetWeaponStartTraceLocation", L"HandleRecoil",
        L"IncrementFlashCount", L"IsPendingFire", L"LandingShake", L"MeleeAttackDestructibles",
        L"MeleeAttackImpact", L"NativeHandsUpdate", L"NotifyBeginState", L"NotifyEndState",
        L"PendingFire", L"PlayCameraAnim", L"PlayCameraShake", L"PlayTakeHitEffects",
        L"ProcessViewRotation", L"RenderDisplay", L"SetCurrentWeapon", L"SetFiringMode",
        L"SetFlashLocation", L"SetPendingFire", L"SetSprinting", L"ShakeView", L"SpawnProjectile",
        L"Timer_CheckForAIWarning", L"UpdateCamera", L"UpdateHealTarget", L"UpdateWalkBob",
        L"ViewShake", L"WeaponFired", L"WeaponStoppedFiring",
        L"ClientPlayBlockEffects", L"ClientPlayParryEffects", L"IsGrappleBlocked",
        L"TakeDamage", L"UpdateGroundSpeed", L"PlayWeaponAnimation",
        L"CalcWeaponFire", L"NativePortalShotsUpdate", L"HitWall", L"NativeMagazineFeedEvent", L"ScoreDamage",
        L"ClientSetRotation", L"ClientSetLocation", L"AddCameraLensEffect"
    };
    static_assert(CallbackNames.size()==static_cast<std::size_t>(Callback::SetPosition));

    enum Group : std::uint16_t {
        PendingFire=1u<<0, Lifecycle=1u<<1, Sprint=1u<<2, Melee=1u<<3,
        BeginAim=1u<<4, Handling=1u<<5, Effects=1u<<6, FinishAim=1u<<7, Perk=1u<<8
    };
    // Union of each helper's name predicates, before its live validation.
    // The source regression checks each group against those helper bodies.
    static constexpr std::uint16_t Groups(Callback callback) {
        switch(callback) {
        case Callback::GetPendingFireLength:
        case Callback::PendingFire:
        case Callback::IsPendingFire:
        case Callback::SetPendingFire:
        case Callback::ClearPendingFire:
        case Callback::ClearAllPendingFire: return PendingFire;
        case Callback::AttachWeaponTo:
        case Callback::DetachWeapon:
        case Callback::NotifyBeginState:
        case Callback::NotifyEndState:
        case Callback::SetCurrentWeapon:
        case Callback::ClientWeaponSet: return Lifecycle;
        case Callback::SetSprinting: return Sprint;
        case Callback::GetMeleeAimRotation:
        case Callback::GetMeleeStartTraceLocation:
        case Callback::MeleeAttackImpact:
        case Callback::MeleeAttackDestructibles:
        case Callback::ClientPlayBlockEffects:
        case Callback::ClientPlayParryEffects:
        case Callback::IsGrappleBlocked: return Melee;
        case Callback::FireAmmunition: return BeginAim | Handling | Perk;
        case Callback::TakeDamage:
        case Callback::UpdateGroundSpeed: return Perk;
        case Callback::GetAdjustedAim: return BeginAim | FinishAim;
        case Callback::GetAdjustedAimFor:
        case Callback::UpdateHealTarget:
        case Callback::Timer_CheckForAIWarning: return BeginAim;
        case Callback::AddSpread:
        case Callback::HandleRecoil:
        case Callback::ProcessViewRotation: return Handling;
        case Callback::AdjustDamage:
        case Callback::PlayTakeHitEffects:
        case Callback::WeaponFired:
        case Callback::WeaponStoppedFiring:
        case Callback::GetWeaponFiringMode:
        case Callback::SetFiringMode:
        case Callback::FiringModeUpdated:
        case Callback::IncrementFlashCount:
        case Callback::ClearFlashCount:
        case Callback::FlashCountUpdated:
        case Callback::SetFlashLocation:
        case Callback::ClearFlashLocation:
        case Callback::FlashLocationUpdated: return Effects;
        case Callback::GetBaseAimRotation:
        case Callback::GetWeaponStartTraceLocation:
        case Callback::GetMuzzleLoc: return FinishAim;
        default: return 0;
        }
    }

    template<class Intern>
    Callback Lookup(std::uint64_t name, std::uint64_t positionName, Intern intern) {
        // SetPosition retains its pinned engine FName identity.
        if (name==positionName) return Callback::SetPosition;
        if (!initialized_) {
            for (std::size_t i=0;i<CallbackNames.size();++i)
                names_[i]={intern(CallbackNames[i]),static_cast<Callback>(i)};
            std::sort(names_.begin(),names_.end(),[](const Entry& left,const Entry& right) {
                return left.name<right.name;
            });
            initialized_=true;
        }
        const auto found=std::lower_bound(names_.begin(),names_.end(),name,
            [](const Entry& entry,std::uint64_t wanted) { return entry.name<wanted; });
        return found!=names_.end() && found->name==name ? found->callback : Callback::Unrelated;
    }
private:
    struct Entry { std::uint64_t name; Callback callback; };
    std::array<Entry,CallbackNames.size()> names_{};
    bool initialized_=false;
};
}
