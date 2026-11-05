// Editor-only map save bridge. ABI and hash match the existing asset bridges.
#include <windows.h>
#include <bcrypt.h>
#include <MinHook.h>
#include <intrin.h>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>

namespace {
constexpr char kSdkHash[]="b937aadaa06f728354044461cb8490ef2c20b17245535cf88d3f23cd81ddb85c";
using FindObject=void*(*)(void*,void*,const wchar_t*,int);
using SavePackage=int(*)(void*,void*,std::uint64_t,const wchar_t*,void*,void*,int,int,std::uint32_t);
FindObject originalFind=nullptr;
std::uintptr_t editorBase=0;
std::wstring outputPath;
bool saving=false;
using BuildCancelled=int(*)(void*);
BuildCancelled originalBuildCancelled=nullptr;
using GetTransientPackage=void*(*)();
GetTransientPackage originalTransientPackage=nullptr;
void* MapWorldPackage() {
    // UWorld's new-world factory uses Transient for commandlets at this exact
    // call site, whereas its adjacent normal-editor branch creates a package.
    // Authoring a persistent map needs that ordinary package ownership. Do not
    // change GIsUCC or redirect any other transient-object allocation.
    if(reinterpret_cast<std::uintptr_t>(_ReturnAddress())==editorBase+0x8b6143) {
        using CreatePackage=void*(*)(void*,const wchar_t*,int);
        return reinterpret_cast<CreatePackage>(editorBase+0xda8f0)(nullptr,nullptr,0);
    }
    return originalTransientPackage();
}
int HeadlessBuildCancelled(void* engine) {
    // The editor's cancellation accessor reads the GUI progress object's
    // +0x2f4 flag. Commandlets have no such object; our synchronous authoring
    // BSP and path builds have no GUI cancel button. Initialize restricts
    // this hook to the pinned unattended mapper; preserve any real GUI state.
    if(!(*reinterpret_cast<void**>(editorBase+0x3f34eb0)))return 0;
    return originalBuildCancelled(engine);
}

std::wstring Environment(const wchar_t* key) {
    DWORD size=GetEnvironmentVariableW(key,nullptr,0);
    if(!size||size>32768)return {};
    std::wstring value(size,L'\0');
    DWORD count=GetEnvironmentVariableW(key,value.data(),size);
    if(!count||count>=size)return {};
    value.resize(count);return value;
}
std::string HashFile(const wchar_t* path) {
    HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)return {};
    BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;std::string result;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0&&
       BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0)>=0) {
        std::array<UCHAR,65536> buffer{};DWORD count=0;bool ok=true;
        for(;;) {
            if(!ReadFile(file,buffer.data(),static_cast<DWORD>(buffer.size()),&count,nullptr)){ok=false;break;}
            if(!count)break;
            if(BCryptHashData(hash,buffer.data(),count,0)<0){ok=false;break;}
        }
        std::array<UCHAR,32> digest{};
        if(ok&&BCryptFinishHash(hash,digest.data(),static_cast<ULONG>(digest.size()),0)>=0) {
            constexpr char hex[]="0123456789abcdef";
            for(auto byte:digest){result+=hex[byte>>4];result+=hex[byte&15];}
        }
    }
    if(hash)BCryptDestroyHash(hash);
    if(algorithm)BCryptCloseAlgorithmProvider(algorithm,0);
    CloseHandle(file);return result;
}
void* CurrentWorld() {
    void* worldClass=originalFind(nullptr,nullptr,L"Engine.World",0);
    void* world=*reinterpret_cast<void**>(editorBase+0x3f09e48);
    return worldClass&&world&&*reinterpret_cast<void**>(static_cast<char*>(world)+0x50)==worldClass?world:nullptr;
}
void* FindWithSave(void* cls,void* outer,const wchar_t* name,int exact) {
    if(name&&wcscmp(name,L"KF2VRRange.PrepareCollision")==0) {
        void* world=CurrentWorld();
        if(!world||saving)return nullptr;
        // MAP REBUILD invalidates model components, then requests viewport
        // redraw. A commandlet has no viewport tick to refresh them. Use the
        // same UWorld update called by the editor's new-world initialization;
        // it builds model components and updates all level actor components.
        using UpdateComponents=void(*)(void*,int);
        reinterpret_cast<UpdateComponents>(editorBase+0x8cb5a0)(world,0);
        // UWorld::Tick (0x61105d..0x6110d3) refreshes this derived BSP-present
        // cache from Levels[].Model.Nodes.Num(). Headless map authoring has no
        // viewport tick; MultiLineCheck at 0x5df2d8 otherwise skips valid BSP.
        // Mirror only that cache calculation, without advancing game time.
        auto worldBytes=static_cast<char*>(world);
        int hasBsp=0;
        auto levels=*reinterpret_cast<void***>(worldBytes+0x70);
        int count=*reinterpret_cast<int*>(worldBytes+0x78);
        for(int i=0;i<count;++i) {
            auto level=static_cast<char*>(levels[i]);
            auto model=level?*reinterpret_cast<char**>(level+0xe0):nullptr;
            if(model&&*reinterpret_cast<int*>(model+0x70)!=0) { hasBsp=1;break; }
        }
        *reinterpret_cast<int*>(worldBytes+0x3a8)=hasBsp;
        return world;
    }
    if(name&&wcscmp(name,L"KF2VRRange.BuildPaths")==0) {
        void* world=CurrentWorld();
        if(!world||saving)return nullptr;
        saving=true;
        // Pinned editor BUILDPATHS call at 0xe232ff passes review/selection
        // flags and a cancel callback. The orchestrator at 0x6e3a50 explicitly
        // accepts null callbacks at 0x6e3aaf and dispatches the normal path
        // stages through WorldInfo, without the GUI build-progress wrapper.
        using BuildPaths=void(*)(int,int,void*);
        reinterpret_cast<BuildPaths>(editorBase+0x6e3a50)(0,0,nullptr);
        saving=false;
        return CurrentWorld();
    }
    if(!name||wcscmp(name,L"KF2VRRange.SaveRequest")!=0)return originalFind(cls,outer,name,exact);
    if(saving)return nullptr;
    saving=true;
    void* worldClass=originalFind(nullptr,nullptr,L"Engine.World",0);
    // The pinned MAP IMPORT implementation at 0x12016b0 resolves its target
    // through this singleton (loads at 0x1201a23/0x1201a2f), then reads its
    // Outer at +0x40 and name at +0x48 before StaticImportObject at 0x1201adb.
    // FindObject by PersistentLevel.TheWorld can select the superseded
    // commandlet bootstrap world after importing a map with the same name.
    void* world=*reinterpret_cast<void**>(editorBase+0x3f09e48);
    if(!worldClass||!world||*reinterpret_cast<void**>(static_cast<char*>(world)+0x50)!=worldClass)
        world=nullptr;
    void* package=world?*reinterpret_cast<void**>(static_cast<char*>(world)+0x40):nullptr;
    void* packageClass=*reinterpret_cast<void**>(editorBase+0x3c47d78);
    void* feedback=*reinterpret_cast<void**>(editorBase+0x3c33ff8);
    int saved=0;
    if(package&&feedback&&*reinterpret_cast<void**>(static_cast<char*>(package)+0x50)==packageClass) {
        saved=reinterpret_cast<SavePackage>(editorBase+0x2ffb0)(package,world,0,outputPath.c_str(),feedback,nullptr,0,1,0);
    }
    std::ofstream(std::filesystem::path(outputPath+L".bridge-result"))<<"save_result="<<saved<<'\n';
    saving=false;return saved?world:nullptr;
}
DWORD WINAPI Initialize(void*) {
    try {
        std::array<wchar_t,32768> executable{};
        DWORD size=GetModuleFileNameW(nullptr,executable.data(),static_cast<DWORD>(executable.size()));
        if(!size||size>=executable.size()||
           _wcsicmp(std::filesystem::path(executable.data()).filename().c_str(),L"KFEditor.exe")!=0||
           !wcsstr(GetCommandLineW(),L"RangeMapTools.VRRangeMapCommandlet")||
           !wcsstr(GetCommandLineW(),L"-unattended")||HashFile(executable.data())!=kSdkHash)return 1;
        auto workspace=Environment(L"KF2VR_RANGE_WORKSPACE"),requested=Environment(L"KF2VR_RANGE_OUTPUT");
        if(workspace.empty()||requested.empty())return 2;
        auto allowed=std::filesystem::canonical(std::filesystem::path(workspace)/L"build"/L"range-runs");
        auto output=std::filesystem::weakly_canonical(requested);
        auto prefix=allowed.wstring()+L"\\";outputPath=output.wstring();
        if(output.filename()!=L"KF-VRRange.kfm"||outputPath.size()<=prefix.size()||
           _wcsnicmp(outputPath.c_str(),prefix.c_str(),prefix.size())!=0||std::filesystem::exists(output))return 3;
        editorBase=reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
        if(MH_Initialize()!=MH_OK||MH_CreateHook(reinterpret_cast<void*>(editorBase+0xf4660),&FindWithSave,
             reinterpret_cast<void**>(&originalFind))!=MH_OK||
           MH_CreateHook(reinterpret_cast<void*>(editorBase+0x131c310),&HeadlessBuildCancelled,
             reinterpret_cast<void**>(&originalBuildCancelled))!=MH_OK||
           MH_CreateHook(reinterpret_cast<void*>(editorBase+0xe01c0),&MapWorldPackage,
             reinterpret_cast<void**>(&originalTransientPackage))!=MH_OK||MH_EnableHook(MH_ALL_HOOKS)!=MH_OK)return 4;
        std::ofstream(std::filesystem::path(outputPath+L".bridge-ready"))<<"pinned_range_save_ready\n";
        return 0;
    }catch(...){return 5;}
}
}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID) {
    if(reason==DLL_PROCESS_ATTACH){DisableThreadLibraryCalls(instance);HANDLE thread=CreateThread(nullptr,0,Initialize,nullptr,0,nullptr);if(thread)CloseHandle(thread);}
    return TRUE;
}


