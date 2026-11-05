#include "FlexInstall.h"
#include "FlexApi.h"
#include "FlexAbi.h"
#include "kf2vr/adapter/GameBuild.h"

#include <windows.h>
#include <delayimp.h>

#include <cstring>
#include <cstdlib>
#include <string>
#include <utility>

namespace kf2vr::flex {
namespace {
namespace build=kf2vr::adapter::build;

// KFGame natives, Steam RVAs translated per store by GameBuild.h.
constexpr std::uintptr_t HardwareSupportedRva=0x656720; // CUDA device, SM>=3.0, >=2000 MB
constexpr std::uintptr_t HardwareLevelRva=0x657960;     // caps PhysXLevel by compute capability
constexpr std::uintptr_t InitializeRva=0x6561d0;        // creates the CUDA context manager, then flexInit
constexpr std::uintptr_t AcquireContextRva=0x64c960;    // per physics tick: CUDA context valid and acquired
constexpr std::uintptr_t InitializedFlagRva=0x221ad20;
// Native graphics-settings apply used by the options menu and by NVIDIA GSA at
// startup. GSA's GFXSettings.KFGame.xml carries its own "Flex" value (0 unless
// set through GeForce Experience) and resets PhysXLevel before the first map.
constexpr std::uintptr_t ApplyNativeSettingsRva=0xde2810;
constexpr std::uintptr_t EngineRva=0x22174c8;
constexpr std::size_t EnginePhysXLevel=0x7ec;

std::uintptr_t base=0;
void* originalSupported=nullptr;
void* originalLevel=nullptr;
void* originalInitialize=nullptr;
void* originalAcquire=nullptr;
void* originalApplySettings=nullptr;
InstallLog installLog=nullptr;

struct ImportSlot {
    ULONGLONG* address;
    void* function;
    ULONGLONG original;
    DWORD protection=0;
};
std::vector<ImportSlot> importSlots;
std::size_t changedImports=0;

[[noreturn]] void RollbackFailed(InstallLog log,const char* reason) {
    log("FlexPortable fatal: cannot restore stock FleX (%s); refusing mixed backends",reason);
    RaiseFailFastException(nullptr,nullptr,0);
    std::abort();
}

int HookSupported() { return 1; }
int HookLevel() { return 2; }
int HookAcquire() { return 1; }
// The launcher owns PhysXLevel (-Flex writes the session KFEngine.ini). Keep
// the level PhysX initialization accepted across settings applies.
void HookApplySettings(void* self,void* settings) {
    auto* engine=*reinterpret_cast<std::uint8_t**>(base+build::Rva(EngineRva));
    const int kept=engine?*reinterpret_cast<int*>(engine+EnginePhysXLevel):0;
    reinterpret_cast<void(*)(void*,void*)>(originalApplySettings)(self,settings);
    engine=*reinterpret_cast<std::uint8_t**>(base+build::Rva(EngineRva));
    if(!engine) return;
    auto* level=reinterpret_cast<int*>(engine+EnginePhysXLevel);
    if(*level!=kept) {
        if(installLog) installLog("FlexPortable kept PhysXLevel=%d over a settings apply that set %d",kept,*level);
        *level=kept;
    }
}
int HookInitialize() {
    auto* initialized=reinterpret_cast<int*>(base+build::Rva(InitializedFlagRva));
    if(*initialized) return 1;
    int count=0;
    const Export* exports=Exports(count);
    for(int i=0;i<count;++i) if(std::strcmp(exports[i].name,"flexInit")==0) {
        const auto init=reinterpret_cast<int(__cdecl*)(int,ErrorCallback,int)>(exports[i].function);
        if(init(Version,nullptr,0)!=0) return 0;
        *initialized=1;
        return 1;
    }
    return 0;
}

bool SameName(const char* a,const char* b) { return _stricmp(a,b)==0; }

// Writes the portable exports into KFGame's delay-load import slots for the
// two FleX DLLs. Refuses unless every imported name has a replacement and
// neither DLL is already loaded, so FleX is never half-switched.
bool PatchDelayImports(InstallLog log) {
    if(GetModuleHandleW(L"flexRelease_x64.dll") || GetModuleHandleW(L"flexExtRelease_x64.dll")) {
        log("FlexPortable refused: NVIDIA FleX is already loaded");
        return false;
    }
    const auto* image=reinterpret_cast<const unsigned char*>(base);
    const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(image);
    const auto* nt=reinterpret_cast<const IMAGE_NT_HEADERS64*>(image+dos->e_lfanew);
    const auto& directory=nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT];
    if(!directory.VirtualAddress) { log("FlexPortable refused: no delay imports"); return false; }
    int count=0;
    const Export* exports=Exports(count);
    std::vector<ImportSlot> slots;
    int dlls=0;
    for(const auto* d=reinterpret_cast<const ImgDelayDescr*>(image+directory.VirtualAddress);d->rvaDLLName;++d) {
        const char* dll=reinterpret_cast<const char*>(image+d->rvaDLLName);
        if(!SameName(dll,"flexRelease_x64.dll") && !SameName(dll,"flexExtRelease_x64.dll")) continue;
        ++dlls;
        auto* iat=reinterpret_cast<ULONGLONG*>(base+d->rvaIAT);
        const auto* names=reinterpret_cast<const ULONGLONG*>(image+d->rvaINT);
        for(int i=0;names[i];++i) {
            if(IMAGE_SNAP_BY_ORDINAL64(names[i])) { log("FlexPortable refused: %s imports by ordinal",dll); return false; }
            const auto* byName=reinterpret_cast<const IMAGE_IMPORT_BY_NAME*>(image+static_cast<DWORD>(names[i]));
            void* replacement=nullptr;
            for(int e=0;e<count && !replacement;++e)
                if(SameName(exports[e].dll,dll) && std::strcmp(exports[e].name,byName->Name)==0) replacement=exports[e].function;
            if(!replacement) { log("FlexPortable refused: no replacement for %s!%s",dll,byName->Name); return false; }
            slots.push_back({iat+i,replacement,iat[i]});
        }
    }
    if(dlls!=2) { log("FlexPortable refused: expected both FleX delay imports, found %d",dlls); return false; }
    // Retain all originals before the first write, including across later
    // MinHook failures. No allocation is needed once patching has begun.
    importSlots=std::move(slots);
    for(auto& slot:importSlots) {
        if(!VirtualProtect(slot.address,sizeof(*slot.address),PAGE_READWRITE,&slot.protection)) {
            log("FlexPortable refused: import slot not writable");
            RollbackPortableFlex(log);
            return false;
        }
        *slot.address=reinterpret_cast<ULONGLONG>(slot.function);
        ++changedImports;
        DWORD ignored=0;
        if(!VirtualProtect(slot.address,sizeof(*slot.address),slot.protection,&ignored)) {
            log("FlexPortable refused: import protection could not be restored");
            RollbackPortableFlex(log);
            return false;
        }
    }
    log("FlexPortable routed %d FleX imports to the portable solver",static_cast<int>(importSlots.size()));
    return true;
}
} // namespace

void RollbackPortableFlex(InstallLog log,bool engineHooksRemoved) {
    if(changedImports && !engineHooksRemoved) RollbackFailed(log,"engine detours remain installed");
    const auto restored=changedImports;
    while(changedImports) {
        const auto& slot=importSlots[changedImports-1];
        DWORD ignored=0;
        if(!VirtualProtect(slot.address,sizeof(*slot.address),PAGE_READWRITE,&ignored))
            RollbackFailed(log,"import slot not writable");
        *slot.address=slot.original;
        if(!VirtualProtect(slot.address,sizeof(*slot.address),slot.protection,&ignored))
            RollbackFailed(log,"import protection could not be restored");
        --changedImports;
    }
    importSlots.clear();
    if(restored) log("FlexPortable restored %d stock FleX imports",static_cast<int>(restored));
}

std::vector<EngineHook> PreparePortableFlex(std::uintptr_t gameBase,InstallLog log) {
    wchar_t value[32]{};
    const auto length=GetEnvironmentVariableW(L"KF2VR_FLEX_BACKEND",value,32);
    const std::wstring backend=length && length<32?value:L"portable";
    if(backend==L"nvidia") { log("FlexPortable revision=1 backend=nvidia; stock FleX and its CUDA gate kept"); return {}; }
    if(backend!=L"portable") log("FlexPortable unknown KF2VR_FLEX_BACKEND; using portable");
    base=gameBase;
    installLog=log;
    SetLog(log);
    if(!PatchDelayImports(log)) return {};
    log("FlexPortable revision=1 backend=portable; PhysXLevel decides gibs/fluids on any GPU");
    return {
        {reinterpret_cast<void*>(gameBase+build::Rva(HardwareSupportedRva)),reinterpret_cast<void*>(&HookSupported),&originalSupported},
        {reinterpret_cast<void*>(gameBase+build::Rva(HardwareLevelRva)),reinterpret_cast<void*>(&HookLevel),&originalLevel},
        {reinterpret_cast<void*>(gameBase+build::Rva(InitializeRva)),reinterpret_cast<void*>(&HookInitialize),&originalInitialize},
        {reinterpret_cast<void*>(gameBase+build::Rva(AcquireContextRva)),reinterpret_cast<void*>(&HookAcquire),&originalAcquire},
        {reinterpret_cast<void*>(gameBase+build::Rva(ApplyNativeSettingsRva)),reinterpret_cast<void*>(&HookApplySettings),&originalApplySettings},
    };
}

} // namespace kf2vr::flex
