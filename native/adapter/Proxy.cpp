#include <windows.h>
#include <unknwn.h>

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
    return reinterpret_cast<Function>(GetProcAddress(systemInput,name));
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
