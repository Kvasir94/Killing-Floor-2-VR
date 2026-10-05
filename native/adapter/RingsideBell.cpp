#include "RingsideBell.h"

#include <windows.h>
#include <mmsystem.h>

namespace kf2vr::adapter {
namespace {

HMODULE AdapterModule() {
    HMODULE module=nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCWSTR>(&AdapterModule),&module);
    return module;
}

}

void PlayRingsideBell(int cueMask) {
    const wchar_t* cue=(cueMask&kBellReady)?L"ringside_bell_ready":(cueMask&kBellDing)?L"ringside_bell_ding":nullptr;
    if (cue) PlaySoundW(cue,AdapterModule(),SND_RESOURCE|SND_ASYNC|SND_NODEFAULT);
}

}
