#include <windows.h>
#include <bcrypt.h>
#include <array>
#include <atomic>
#include <cstdio>
#include <memory>
#include <string>
#include <share.h>
#include <MinHook.h>
#include "GameScript.h"
#include "ScriptField.h"
#include "WeaponIsolation.h"
#include "PerkContext.h"

// Deliberately separate from the rendering/XR adapter. No local player, camera,
// shared pawn effects scope, or client executable address is used here.
namespace {
using kf2vr::adapter::GameScript;
using ProcessInternal=void(*)(void*,void*,void*);
ProcessInternal originalProcess=nullptr;
std::unique_ptr<GameScript> script;
std::atomic<DWORD> authorityThread{0};
FILE* logFile=nullptr;
constexpr auto serverHash="2ea16bb5e37d2330a30f82f6d4cf50919c008ac8c96a8917b3b9ba010dfbce71";

bool HashFile(const wchar_t* path,std::string& result) {
    HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE) return false;
    BCRYPT_ALG_HANDLE algorithm=nullptr; BCRYPT_HASH_HANDLE hash=nullptr;
    bool success=false;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0 &&
       BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0)>=0) {
        std::array<unsigned char,65536> data{}; DWORD count=0; bool ok=true;
        for(;;) {
            if(!ReadFile(file,data.data(),static_cast<DWORD>(data.size()),&count,nullptr)) { ok=false;break; }
            if(!count) break;
            if(BCryptHashData(hash,data.data(),count,0)<0) { ok=false;break; }
        }
        std::array<unsigned char,32> digest{};
        if(ok && BCryptFinishHash(hash,digest.data(),static_cast<ULONG>(digest.size()),0)>=0) {
            char hex[65]{};
            for(unsigned i=0;i<32;++i) std::snprintf(hex+i*2,3,"%02x",digest[i]);
            result=hex;success=true;
        }
    }
    if(hash) BCryptDestroyHash(hash);
    if(algorithm) BCryptCloseAlgorithmProvider(algorithm,0);
    CloseHandle(file);return success;
}

bool DedicatedChannel(void* channel) {
    if(!script->IsClass(channel,L"KF2VRNetChannel") || script->Read<unsigned char>(channel,L"Role")!=3) return false;
    auto* world=script->Read<void*>(channel,L"WorldInfo");
    auto* owner=script->Read<void*>(channel,L"Owner");
    return world && script->Read<unsigned char>(world,L"NetMode")==1 &&
        script->IsClass(owner,L"KF2VRNetPlayerController") &&
        script->Read<void*>(owner,L"NetChannel")==channel;
}

void* LedgerForPawn(void* pawn) {
    if(!pawn || script->Read<int>(pawn,L"Health")<=0) return nullptr;
    auto* pc=script->Read<void*>(pawn,L"Controller");
    if(!script->IsClass(pc,L"KF2VRNetPlayerController") || script->Read<void*>(pc,L"Pawn")!=pawn) return nullptr;
    auto* channel=script->Read<void*>(pc,L"NetChannel");
    if(!DedicatedChannel(channel) || script->Read<int>(channel,L"NativeAuthorityReady")!=1 ||
        script->Read<void*>(channel,L"BoundPawn")!=pawn) return nullptr;
    auto* inventory=script->Read<void*>(channel,L"HeldInventory");
    return inventory && script->Read<void*>(inventory,L"Human")==pawn &&
        script->Read<void*>(inventory,L"PC")==pc ? inventory : nullptr;
}

void HookProcess(void* object,void* stack,void* result) {
    auto* function=GameScript::At<void*>(stack,0x14);
    const auto name=GameScript::ObjectName(function);
    // Interned names and reflection caches are game-thread data. Before that
    // thread is established, only a separate thread-local lookup is touched.
    static thread_local GameScript lookup(reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr)),{0xc3b70,0xc8f40});
    if(name==lookup.Intern(L"NativeAuthorityUpdate") && lookup.IsClass(object,L"KF2VRNetChannel") &&
       lookup.FindFunction(object,L"NativeAuthorityUpdate")==function) {
        DWORD unset=0;
        authorityThread.compare_exchange_strong(unset,GetCurrentThreadId());
        if(authorityThread.load()==GetCurrentThreadId() && DedicatedChannel(object)) {
            originalProcess(object,stack,result);
            script->Write(object,L"NativeAuthorityReady",1);
            return;
        }
    }
    if(authorityThread.load()!=GetCurrentThreadId()) { originalProcess(object,stack,result);return; }
    const bool removal=name==script->Intern(L"RemoveFromInventory");
    bool pending=false;
    for(const auto* entry:{L"GetPendingFireLength",L"PendingFire",L"IsPendingFire",L"SetPendingFire",L"ClearPendingFire",L"ClearAllPendingFire"})
        pending=pending || name==script->Intern(entry);
    if(pending || removal) {
        auto* pawn=script->Read<void*>(object,L"Instigator");
        auto* ledger=LedgerForPawn(pawn);
        auto* locals=GameScript::At<void*>(stack,0x2c);
        if(ledger && removal && object==script->Read<void*>(pawn,L"InvManager")) {
            void* weapon=nullptr;
            if(kf2vr::adapter::ReadScriptLocal(function,locals,script->Intern(L"ItemToRemove"),weapon) &&
               script->IsClass(weapon,L"KFWeapon")) {
                struct Parameters { void* weapon; } args{weapon};
                auto* notify=script->FindFunction(ledger,L"NotifyRemoved");
                kf2vr::adapter::ScriptField parameter{};
                if(kf2vr::adapter::FindScriptField(notify,script->Intern(L"W"),parameter) &&
                   parameter.offset==0 && parameter.size==sizeof(args.weapon)) script->Invoke(ledger,notify,&args);
            }
        }
        if(ledger && pending && kf2vr::adapter::RouteInventoryPendingFire(*script,ledger,pawn,object,function,locals,result)) return;
    }
    // Stock perks evaluate a shot, a Zed hit and movement speed against one
    // current, aimed weapon. The VR player's ledger brackets exactly those
    // calls with the acting item and its grip (KF2VRNetHeldInventory).
    kf2vr::adapter::PerkScope perkScope(*script);
    if(name==script->Intern(L"FireAmmunition") || name==script->Intern(L"TakeDamage") ||
       name==script->Intern(L"UpdateGroundSpeed")) {
        const auto call=kf2vr::adapter::ClassifyPerkCall(*script,object,function,GameScript::At<void*>(stack,0x2c));
        if(call.entry!=kf2vr::adapter::PerkEntry::None && kf2vr::adapter::PawnHasAuthority(*script,call.pawn))
            perkScope.Enter(LedgerForPawn(call.pawn),call);
    }
    originalProcess(object,stack,result);
}
} // namespace

DWORD WINAPI AdapterMain(void*) {
    if(!wcsstr(GetCommandLineW(),L"-kf2vr-server-adapter")) return 0;
    wchar_t logPath[32768]{},path[32768]{};
    if(GetEnvironmentVariableW(L"KF2VR_SERVER_LOG_PATH",logPath,32768)) logFile=_wfsopen(logPath,L"wb",_SH_DENYWR);
    if(!logFile) return 1;
    std::setvbuf(logFile,nullptr,_IONBF,0);
    GetModuleFileNameW(nullptr,path,32768);
    std::string hash;
    if(!HashFile(path,hash) || hash!=serverHash) { std::fprintf(logFile,"server_adapter hash_refused\n");return 2; }
    kf2vr::adapter::guardedScriptReads=wcsstr(GetCommandLineW(),L"-kf2vr-checked-reads")==nullptr;
    const auto base=reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
    const std::array<unsigned char,13> entry{0x40,0x53,0x55,0x56,0x57,0x41,0x56,0x48,0x81,0xec,0x90,0x00,0x00};
    if(!GameScript::Accessible(reinterpret_cast<void*>(base+0x7b590),entry.size()) ||
       std::memcmp(reinterpret_cast<void*>(base+0x7b590),entry.data(),entry.size())!=0) return 3;
    // Ledger callbacks are plain UObject ProcessEvent. On this server its
    // virtual slot is 0x210; client 0x218 is ProcessDelegate here and is unsafe.
    script=std::make_unique<GameScript>(base,GameScript::ReflectionProfile{0xc3b70,0xc8f40,0x210,0x7b200});
    if(MH_Initialize()!=MH_OK || MH_CreateHook(reinterpret_cast<void*>(base+0x7b590),
       reinterpret_cast<void*>(&HookProcess),reinterpret_cast<void**>(&originalProcess))!=MH_OK ||
       MH_EnableHook(reinterpret_cast<void*>(base+0x7b590))!=MH_OK) {
        std::fprintf(logFile,"server_adapter hook_refused\n");return 4;
    }
    std::fprintf(logFile,"server_adapter ready=1 sha256=%s process_internal=7b590 guardedReads=%d\n",hash.c_str(),
        kf2vr::adapter::guardedScriptReads);
    return 0;
}
