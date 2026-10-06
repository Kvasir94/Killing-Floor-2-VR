#include <windows.h>
#include <unknwn.h>
#include <cstring>

// Every export resolves only the system copy. No engine work happens under
// loader lock; a worker may run only after DLL initialization has returned.
extern DWORD WINAPI AdapterMain(void*);
namespace {
INIT_ONCE once=INIT_ONCE_STATIC_INIT;
HMODULE systemInput=nullptr;
BOOL CALLBACK LoadSystem(PINIT_ONCE,void*,void**) {
    wchar_t path[MAX_PATH]{};
    const UINT count=GetSystemDirectoryW(path,MAX_PATH);
    if (!count || count+13>=MAX_PATH) return FALSE;
    if (wcscat_s(path,L"\\dinput8.dll")!=0) return FALSE;
    systemInput=LoadLibraryExW(path,nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
    return systemInput!=nullptr;
}
template<class Function> Function Resolve(const char* name) {
    if (!InitOnceExecuteOnce(&once,LoadSystem,nullptr,nullptr)) return nullptr;
    // An overlay can intercept GetProcAddress("DirectInput8Create") and return
    // its wrapper even for the system HMODULE. When its saved original is this
    // proxy, resolving through that API again recurses overlay -> proxy -> overlay.
    // Forward to the actual export of the explicitly loaded System32 image.
    // Do not patch code, remove hooks, or change the overlay/authentication DLLs.
    const auto* base=reinterpret_cast<const unsigned char*>(systemInput);
    const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if(dos->e_magic!=IMAGE_DOS_SIGNATURE || dos->e_lfanew<=0 || dos->e_lfanew>4096)return nullptr;
    const auto* nt=reinterpret_cast<const IMAGE_NT_HEADERS64*>(base+dos->e_lfanew);
    if(nt->Signature!=IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC)return nullptr;
    const auto size=nt->OptionalHeader.SizeOfImage;
    const auto inside=[size](DWORD rva,std::size_t count){return rva<size && count<=size-rva;};
    const auto directory=nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if(!directory.VirtualAddress || !inside(directory.VirtualAddress,directory.Size) || directory.Size<sizeof(IMAGE_EXPORT_DIRECTORY))return nullptr;
    const auto* exports=reinterpret_cast<const IMAGE_EXPORT_DIRECTORY*>(base+directory.VirtualAddress);
    if(!inside(exports->AddressOfNames,std::size_t(exports->NumberOfNames)*sizeof(DWORD)) ||
       !inside(exports->AddressOfNameOrdinals,std::size_t(exports->NumberOfNames)*sizeof(WORD)) ||
       !inside(exports->AddressOfFunctions,std::size_t(exports->NumberOfFunctions)*sizeof(DWORD)))return nullptr;
    const auto* names=reinterpret_cast<const DWORD*>(base+exports->AddressOfNames);
    const auto* ordinals=reinterpret_cast<const WORD*>(base+exports->AddressOfNameOrdinals);
    const auto* functions=reinterpret_cast<const DWORD*>(base+exports->AddressOfFunctions);
    const auto length=std::strlen(name)+1;
    for(DWORD i=0;i<exports->NumberOfNames;++i) {
        if(!inside(names[i],length) || std::memcmp(base+names[i],name,length)!=0)continue;
        if(ordinals[i]>=exports->NumberOfFunctions)return nullptr;
        const auto rva=functions[ordinals[i]];
        if(!rva || !inside(rva,1))return nullptr;
        // A forwarder string is not callable. Do not reenter an intercepted API.
        if(rva>=directory.VirtualAddress && rva-directory.VirtualAddress<directory.Size)return nullptr;
        return reinterpret_cast<Function>(const_cast<unsigned char*>(base+rva));
    }
    return nullptr;
}
}
extern "C" HRESULT WINAPI ProxyDirectInput8Create(HINSTANCE instance,DWORD version,REFIID iid,void** out,LPUNKNOWN outer) {
    using F=HRESULT(WINAPI*)(HINSTANCE,DWORD,REFIID,void**,LPUNKNOWN);
    const auto fn=Resolve<F>("DirectInput8Create"); return fn?fn(instance,version,iid,out,outer):E_FAIL;
}
extern "C" HRESULT WINAPI ProxyDllCanUnloadNow() {
    // The installed hooks live until process exit; unloading their module is
    // never safe even when the real DirectInput DLL has no clients.
    return S_FALSE;
}
extern "C" HRESULT WINAPI ProxyDllGetClassObject(REFCLSID clsid,REFIID iid,void** out) {
    using F=HRESULT(WINAPI*)(REFCLSID,REFIID,void**);
    const auto fn=Resolve<F>("DllGetClassObject"); return fn?fn(clsid,iid,out):E_FAIL;
}
extern "C" HRESULT WINAPI ProxyDllRegisterServer() {
    using F=HRESULT(WINAPI*)(); const auto fn=Resolve<F>("DllRegisterServer"); return fn?fn():E_FAIL;
}
extern "C" HRESULT WINAPI ProxyDllUnregisterServer() {
    using F=HRESULT(WINAPI*)(); const auto fn=Resolve<F>("DllUnregisterServer"); return fn?fn():E_FAIL;
}
extern "C" const void* WINAPI ProxyGetdfDIJoystick() {
    using F=const void*(WINAPI*)(); const auto fn=Resolve<F>("GetdfDIJoystick"); return fn?fn():nullptr;
}
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,void*) {
    if (reason==DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        // Merely installing the proxy is not permission to patch the process.
#ifdef KF2VR_SERVER_ADAPTER
        const bool requested=wcsstr(GetCommandLineW(),L"-kf2vr-server-adapter")!=nullptr;
#else
        const bool requested=wcsstr(GetCommandLineW(),L"-kf2vr-probe")!=nullptr;
#endif
        if (requested) {
            HANDLE worker=CreateThread(nullptr,0,AdapterMain,module,0,nullptr);
            if (worker) CloseHandle(worker);
        }
    }
    return TRUE;
}
