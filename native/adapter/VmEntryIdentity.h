#pragma once
#include <windows.h>
#include <cstdint>
#include <cstring>

namespace kf2vr::adapter {
// Only for the pinned ProcessInternal entry: the engine owns this live stack
// and function for the duration of the call. Never use for arbitrary reflected
// fields, retained pointers, or writes. Do not cache identity across callbacks.
// A leaf SEH boundary avoids two VirtualQuery system calls on every VM entry.
// Catch access violations only; guard-page and other engine exceptions retain
// their normal handlers. Candidate callbacks still pass the existing checks.
__declspec(noinline) inline bool ReadVmEntryIdentity(const void* stack,void*& function,std::uint64_t& name) {
    function=nullptr;name=0;
    if (!stack) return false;
    void* node=nullptr;
    std::uint64_t identity=0;
    __try {
        std::memcpy(&node,static_cast<const char*>(stack)+0x14,sizeof(node));
        if (!node) return false;
        std::memcpy(&identity,static_cast<const char*>(node)+0x48,sizeof(identity));
    } __except(GetExceptionCode()==EXCEPTION_ACCESS_VIOLATION ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
        return false;
    }
    function=node;name=identity;
    return true;
}
}
