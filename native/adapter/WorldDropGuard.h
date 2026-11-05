#pragma once
#include "SecondaryReloadGuard.h"
#include "GameScript.h"
#include "ScriptField.h"
#include "WeaponIsolation.h"
#include "TransferredWeaponReceipt.h"
#include "SecondaryAmmoCorrection.h"
#include "ReloadGeneration.h"
#include <array>
#include <climits>

namespace kf2vr::adapter {
// The listen host's controlled pawn is not the remote weapon's owner. Resolve
// that owner's authority ledger through the same bound channel as dedicated.
// Call only on the established game/authority thread.
inline void* NetworkAuthorityLedger(GameScript& script,void* pawn) {
    if (!script.IsClass(pawn,L"KFPawn_Human") || script.Read<unsigned char>(pawn,L"Role")!=3 ||
        script.Read<int>(pawn,L"Health")<=0) return nullptr;
    auto* pc=script.Read<void*>(pawn,L"Controller");
    if (!script.IsClass(pc,L"KF2VRNetPlayerController") || script.Read<void*>(pc,L"Pawn")!=pawn) return nullptr;
    auto* channel=script.Read<void*>(pc,L"NetChannel");
    if (!script.IsClass(channel,L"KF2VRNetChannel") || script.Read<unsigned char>(channel,L"Role")!=3 ||
        script.Read<void*>(channel,L"Owner")!=pc || script.Read<void*>(channel,L"BoundPawn")!=pawn) return nullptr;
    auto* ledger=script.Read<void*>(channel,L"HeldInventory");
    return ledger && script.Read<void*>(ledger,L"Human")==pawn && script.Read<void*>(ledger,L"PC")==pc ? ledger : nullptr;
}

// Called only immediately before forwarding ServerSendToReload. Derived
// implementations may call Super, so count the exact KFWeapon declaration
// once; it is the stock body that starts the authority's primary reload.
inline void ObserveAuthorityReloadStart(GameScript& script,void* object,void* function) {
    if (GameScript::ObjectName(function)!=script.Intern(L"ServerSendToReload") ||
        !script.IsClass(object,L"KFWeapon") || script.Read<unsigned char>(object,L"Role")!=3) return;
    auto* type=GameScript::ObjectClass(object);
    const auto stock=script.Intern(L"KFWeapon");
    for (unsigned depth=0;type && depth<64 && GameScript::ObjectName(type)!=stock;++depth)
        type=GameScript::SuperStruct(type);
    if (!type || GameScript::ObjectName(type)!=stock ||
        secondaryReload::DirectChild(script,type,L"ServerSendToReload",L"Function")!=function) return;
    auto* pawn=script.Read<void*>(object,L"Instigator");
    auto* ledger=NetworkAuthorityLedger(script,pawn);
    if (!ledger || script.Read<void*>(object,L"Owner")!=pawn ||
        script.Read<void*>(object,L"InvManager")!=script.Read<void*>(pawn,L"InvManager")) return;
    void* runtime=nullptr;
    if (!ResolveInventoryItem(script,ledger,object,runtime) ||
        !script.IsClass(runtime,L"KF2VRNetItemRuntime") ||
        script.Read<void*>(runtime,L"Inventory")!=ledger || script.Read<void*>(runtime,L"Item")!=object ||
        script.Read<int>(runtime,L"NativeReady")!=1) return;
    ReloadGeneration generation{script.Read<int>(runtime,L"ReloadGeneration")};
    generation.Begin();
    script.Write(runtime,L"ReloadGeneration",generation.current);
}

// Pawn.Died has already accepted the death when it calls HolderDied/OwnerDied.
// Detach registered world items before stock pair restoration or inventory
// discard can destroy them. Polling on the next frame is too late.
inline void PublishDeathWorldDrops(GameScript& script,void* object,void* function,
                                   void* localBridge=nullptr) {
    const auto name=GameScript::ObjectName(function);
    void* pawn=nullptr;
    if (name==script.Intern(L"HolderDied") && script.IsClass(object,L"KFWeapon"))
        pawn=script.Read<void*>(object,L"Instigator");
    else if (name==script.Intern(L"OwnerDied") && script.IsClass(object,L"KFInventoryManager"))
        pawn=script.Read<void*>(object,L"Owner");
    if (!script.IsClass(pawn,L"KFPawn_Human") || script.Read<unsigned char>(pawn,L"Role")!=3 ||
        script.Read<int>(pawn,L"Health")>0) return;
    void* registry=nullptr;
    if (localBridge && script.Read<void*>(localBridge,L"Human")==pawn) {
        auto* hands=script.Read<void*>(localBridge,L"HandInventory");
        auto* drops=script.Read<void*>(hands,L"WorldDrops");
        registry=script.Read<void*>(drops,L"Registry");
    }
    if (!registry) {
        auto* pc=script.Read<void*>(pawn,L"Controller");
        if (!script.IsClass(pc,L"KF2VRNetPlayerController")) return;
        auto* channel=script.Read<void*>(pc,L"NetChannel");
        if (!script.IsClass(channel,L"KF2VRNetChannel") || script.Read<void*>(channel,L"BoundPawn")!=pawn ||
            script.Read<int>(channel,L"NativeWorldDropVersion")!=9) return;
        registry=script.Read<void*>(script.Read<void*>(channel,L"WorldDrops"),L"Registry");
    }
    if (!script.IsClass(registry,L"VRWorldDropRegistry")) return;
    if (auto* publish=script.FindFunction(registry,L"PublishDeathLoot")) script.Invoke(registry,publish,nullptr);
}

// Return marker on the same reliable weapon channel, after all earlier stock
// corrections. Owner receipts cannot unlock a newer action ahead of this.
inline bool ConsumeWeaponReceipt(GameScript& script,void* ledger,void* pawn,
                                  void* object,void* function,const void* locals) {
    if (GameScript::ObjectName(function)!=script.Intern(L"ClientForceAmmoUpdate") ||
        !script.IsClass(object,L"KFWeapon")) return false;
    int ammo=0,serial=0;
    if (!ReadScriptLocal(function,locals,script.Intern(L"NewAmmoCount"),ammo) || ammo>-255) return false;
    if (script.Read<unsigned char>(object,L"Role")==3) {
        script.DispatchRemote(object,function,locals);
        return true;
    }
    if (!ReadScriptLocal(function,locals,script.Intern(L"NewSpareAmmoCount"),serial) ||
        (ammo==-255 && (serial<=0 || serial==INT_MAX)) || !ledger || !pawn ||
        script.Read<unsigned char>(object,L"Role")==3 ||
        script.Read<void*>(ledger,L"Human")!=pawn ||
        script.Read<void*>(ledger,L"PC")!=script.Read<void*>(pawn,L"Controller") ||
        script.Read<void*>(script.Read<void*>(ledger,L"PC"),L"Pawn")!=pawn ||
        script.Read<void*>(object,L"Instigator")!=pawn ||
        script.Read<void*>(object,L"Owner")!=pawn ||
        script.Read<void*>(object,L"InvManager")!=script.Read<void*>(pawn,L"InvManager")) return true;
    if (ammo<=-256) {
        // Apply slot-one counts on the weapon channel, before its receipt and
        // any later ClientGiveSecondaryAmmo. Owner replies carry no ammo write.
        int loaded=0;
        void* runtime=nullptr;
        ScriptField loadedField{},reserveField{};
        if (!DecodeSecondaryAmmoCorrection(ammo,serial,loaded) ||
            !secondaryReload::StockPayment(script,object) ||
            !ResolveInventoryItem(script,ledger,object,runtime) || !runtime ||
            script.Read<void*>(runtime,L"Inventory")!=ledger ||
            script.Read<void*>(runtime,L"Item")!=object || script.Read<int>(runtime,L"NativeReady")!=1 ||
            !secondaryReload::Field(script,GameScript::ObjectClass(object),L"AmmoCount",L"IntProperty",sizeof(int),loadedField) ||
            !secondaryReload::Field(script,GameScript::ObjectClass(object),L"SpareAmmoCount",L"IntProperty",sizeof(int),reserveField))
            return true;
        auto* bytes=static_cast<std::byte*>(object);
        if (!GameScript::Accessible(bytes+loadedField.offset,2*sizeof(int)) ||
            !GameScript::Accessible(bytes+reserveField.offset,2*sizeof(int))) return true;
        std::memcpy(bytes+loadedField.offset+sizeof(int),&loaded,sizeof(loaded));
        std::memcpy(bytes+reserveField.offset+sizeof(int),&serial,sizeof(serial));
        return true;
    }
    // Capability 6 preserves two independent requests even when stock
    // ClientGivenTo precedes runtime registration or receipts arrive reversed.
    const std::array<TransferReceiptSlot,2> slots{{
        {script.Read<int>(ledger,L"ExpectedTransferSerial0"),script.Read<int>(ledger,L"ReceivedTransferSerial0"),
         script.Read<void*>(ledger,L"ExpectedTransferWeapon0"),script.Read<void*>(ledger,L"ReceivedTransferWeapon0")},
        {script.Read<int>(ledger,L"ExpectedTransferSerial1"),script.Read<int>(ledger,L"ReceivedTransferSerial1"),
         script.Read<void*>(ledger,L"ExpectedTransferWeapon1"),script.Read<void*>(ledger,L"ReceivedTransferWeapon1")}
    }};
    const int slot=TransferredWeaponReceiptSlot(slots,object,serial);
    if (slot>=0) {
        script.Write<void*>(ledger,slot==0 ? L"ReceivedTransferWeapon0" : L"ReceivedTransferWeapon1",object);
        script.Write<int>(ledger,slot==0 ? L"ReceivedTransferSerial0" : L"ReceivedTransferSerial1",serial);
    }
    void* runtime=nullptr;
    if (!ResolveInventoryItem(script,ledger,object,runtime) || !runtime ||
        script.Read<void*>(runtime,L"Inventory")!=ledger ||
        script.Read<void*>(runtime,L"Item")!=object || script.Read<int>(runtime,L"NativeReady")!=1) return true;
    if (serial>script.Read<int>(runtime,L"WeaponReceiptSerial"))
        script.Write<int>(runtime,L"WeaponReceiptSerial",serial);
    return true;
}

// Reserved on matching version-2 peers. The reliable weapon RPC orders stock
// fire/reload handlers before an owner-channel physical action. Never execute
// the stock body for this opcode: stock ignores FireMode and assigns ammo.
inline bool ConsumeWeaponBarrier(GameScript& script,void* ledger,void* pawn,
                                  void* object,void* function,const void* locals) {
    if (GameScript::ObjectName(function)!=script.Intern(L"SyncCurrentAmmoCount") ||
        !script.IsClass(object,L"KFWeapon")) return false;
    unsigned char mode=0;
    if (!ReadScriptLocal(function,locals,script.Intern(L"FireMode"),mode) || (mode!=255 && mode!=254)) return false;
    if (script.Read<unsigned char>(object,L"Role")<3) {
        script.DispatchRemote(object,function,locals);
        return true;
    }
    int serial=0;
    if (!ReadScriptLocal(function,locals,script.Intern(L"CurrentAmmoCount"),serial) ||
        serial<=0 || serial==INT_MAX || !ledger || !pawn ||
        script.Read<int>(pawn,L"Health")<=0 || script.Read<void*>(ledger,L"Human")!=pawn ||
        script.Read<void*>(ledger,L"PC")!=script.Read<void*>(pawn,L"Controller") ||
        script.Read<void*>(script.Read<void*>(ledger,L"PC"),L"Pawn")!=pawn ||
        script.Read<unsigned char>(object,L"Role")!=3 ||
        script.Read<void*>(object,L"Instigator")!=pawn ||
        script.Read<void*>(object,L"Owner")!=pawn ||
        script.Read<void*>(object,L"InvManager")!=script.Read<void*>(pawn,L"InvManager")) return true;
    void* runtime=nullptr;
    if (!ResolveInventoryItem(script,ledger,object,runtime) || !runtime ||
        script.Read<void*>(runtime,L"Inventory")!=ledger ||
        script.Read<void*>(runtime,L"Item")!=object || script.Read<int>(runtime,L"NativeReady")!=1) return true;
    if (mode==254) {
        // Retired shell-only opcode. New peers use acknowledged owner-channel
        // reserve loss behind the normal weapon barrier. Never run stock.
        return true;
    }
    // Capability 4 also orders an owned catch while the exact actor is dropped.
    // The script transaction validates the drop/contact before clearing fences.
    ReloadGeneration generation{script.Read<int>(runtime,L"ReloadGeneration"),
        script.Read<int>(runtime,L"WeaponBarrierReloadGeneration"),script.Read<int>(runtime,L"WeaponBarrierSerial")};
    if (generation.Mark(serial)) {
        if (script.IsClass(runtime,L"KF2VRNetItemRuntime"))
            script.Write<int>(runtime,L"WeaponBarrierReloadGeneration",generation.barrier);
        script.Write<int>(runtime,L"WeaponBarrierSerial",generation.serial);
    }
    return true;
}

// A dropped prop is still an exact owned inventory actor. Stock late fire
// and reload messages must not operate it until the held ledger recalls/catches it.
inline bool IsWorldDropAction(GameScript& script,GameScript::Name name) {
    static thread_local const auto blocked=std::array{
        script.Intern(L"FireAmmunition"),script.Intern(L"FireAmmo"),
        script.Intern(L"StartFire"),script.Intern(L"ServerStartFire"),
        script.Intern(L"BeginFire"),script.Intern(L"SendToFiringState"),
        script.Intern(L"ServerSyncWeaponFiring"),script.Intern(L"InitializeReload"),
        script.Intern(L"ServerSendToReload"),script.Intern(L"PerformReload"),
        script.Intern(L"ServerSyncReload"),script.Intern(L"SyncCurrentAmmoCount"),
        script.Intern(L"ServerSetAltAmmoCount"),script.Intern(L"SendToAltReload"),
        script.Intern(L"ServerSendToAltReload")};
    for (const auto candidate:blocked) if (name==candidate) return true;
    return false;
}
inline bool WorldDropSuppresses(GameScript& script,void* ledger,void* pawn,
                                void* object,void* function) {
    if (!IsWorldDropAction(script,GameScript::ObjectName(function)) || !ledger || !pawn ||
        !script.IsClass(object,L"KFWeapon") || script.Read<void*>(object,L"Instigator")!=pawn) return false;
    void* runtime=nullptr;
    if (!ResolveInventoryItem(script,ledger,object,runtime)) return true;
    if (!runtime) return false;
    if (script.Read<void*>(runtime,L"Inventory")!=ledger ||
        script.Read<void*>(runtime,L"Item")!=object || script.Read<int>(runtime,L"NativeReady")!=1) return true;
    if (script.Read<int>(runtime,L"WorldDropped")==1 || script.Read<int>(runtime,L"MechanismPending")==1 ||
        script.Read<int>(runtime,L"WorldTrickPending")!=0) return true;
    // Catching cannot erase a shot's remaining stock refire interval. Reloads
    // and physical cycling stay available while only offensive calls wait.
    const auto name=GameScript::ObjectName(function);
    const bool fire=name==script.Intern(L"FireAmmunition") || name==script.Intern(L"FireAmmo");
    const auto secondary=script.Read<int>(runtime,L"SecondaryMagazineFlags");
    const auto secondaryPending=script.Read<int>(runtime,L"SecondaryMagazinePending");
    if ((name==script.Intern(L"ServerSetAltAmmoCount") || name==script.Intern(L"SendToAltReload") ||
         name==script.Intern(L"ServerSendToAltReload")) &&
        (secondary || secondaryPending)) return true;
    if ((secondary || secondaryPending) && name==script.Intern(L"PerformReload") &&
        script.IsClass(object,L"KFWeap_AssaultRifle_FAMAS") &&
        function==secondaryReload::StockPayment(script,object)) return true;
    if (fire && script.Read<unsigned char>(object,L"CurrentFireMode")==1 &&
        ((secondary&2) || secondaryPending)) return true;
    return fire && script.Read<float>(runtime,L"WorldDropFireReadyAt")>
        script.Read<float>(script.Read<void*>(pawn,L"WorldInfo"),L"TimeSeconds");
}

// Before stock removal changes Owner/InvManager, retire the local identity.
// A same-frame removal/reacquisition must never recover an old drop transaction.
inline void NotifyWorldDropRemoval(GameScript& script,void* ledger,void* pawn,
                                   void* object,void* function,const void* locals) {
    if (!ledger || !pawn || GameScript::ObjectName(function)!=script.Intern(L"RemoveFromInventory") ||
        object!=script.Read<void*>(pawn,L"InvManager")) return;
    void* weapon=nullptr;
    if (!ReadScriptLocal(function,locals,script.Intern(L"ItemToRemove"),weapon) ||
        !script.IsClass(weapon,L"KFWeapon")) return;
    auto* notify=script.FindFunction(ledger,L"NotifyRemoved");
    ScriptField parameter{};
    if (!FindScriptField(notify,script.Intern(L"W"),parameter) || parameter.offset!=0 ||
        parameter.size!=sizeof(weapon)) return;
    struct Parameters { void* weapon; } args{weapon};
    script.Invoke(ledger,notify,&args);
}
}
