#pragma once

#include <windows.h>
#include "include/kf2vr/adapter/GameBuild.h"
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace kf2vr::adapter {

// Reflected reads and probes use a leaf SEH boundary instead of one VirtualQuery
// system call per field; that query was the leading leaf in the 2026-09-17
// frame drilldown (world tick, controller tick and scene setup). A successful
// read is a plain load. Access violations and in-page errors reject the read.
// A guard page is re-armed before rejecting, so probing never consumes another
// thread's stack guard or an allocator sentinel. `-kf2vr-checked-reads`
// restores the VirtualQuery walk for A/B comparison.
inline bool guardedScriptReads=true;
inline std::uint64_t guardedReadFaults=0; // Diagnostic count; racy increments are acceptable.
inline int GuardedReadFilter(const EXCEPTION_POINTERS* info) noexcept {
    const auto* record=info->ExceptionRecord;
    switch (record->ExceptionCode) {
    case EXCEPTION_ACCESS_VIOLATION:
    case EXCEPTION_IN_PAGE_ERROR:
        ++guardedReadFaults;
        return EXCEPTION_EXECUTE_HANDLER;
    case STATUS_GUARD_PAGE_VIOLATION:
        if (record->NumberParameters>=2) {
            auto* address=reinterpret_cast<void*>(record->ExceptionInformation[1]);
            MEMORY_BASIC_INFORMATION region{};
            DWORD old=0;
            if (VirtualQuery(address,&region,sizeof(region)) && region.State==MEM_COMMIT)
                VirtualProtect(address,1,region.Protect|PAGE_GUARD,&old);
        }
        ++guardedReadFaults;
        return EXCEPTION_EXECUTE_HANDLER;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}
// Null-page offsets and kernel addresses never reach the exception path.
inline bool PlausibleUserRange(std::uintptr_t start,std::size_t size) noexcept {
    constexpr std::uintptr_t lowest=0x10000,highest=0x7ffffffeffff;
    return start>=lowest && start<=highest && size<=highest-start+1;
}
__declspec(noinline) inline bool GuardedCopy(void* out,const void* source,std::size_t size) noexcept {
    if (!PlausibleUserRange(reinterpret_cast<std::uintptr_t>(source),size)) return false;
    __try { std::memcpy(out,source,size); }
    __except(GuardedReadFilter(GetExceptionInformation())) { return false; }
    return true;
}
// Touches one byte per page, including the last byte of the range.
__declspec(noinline) inline bool GuardedProbe(const void* pointer,std::size_t size) noexcept {
    const auto start=reinterpret_cast<std::uintptr_t>(pointer);
    if (!size) return true;
    if (!PlausibleUserRange(start,size)) return false;
    constexpr std::uintptr_t page=0x1000;
    const auto last=start+size-1;
    __try {
        for (auto cursor=start;;) {
            (void)*reinterpret_cast<const volatile std::byte*>(cursor);
            const auto next=(cursor|(page-1))+1;
            if (next>last) break;
            cursor=next;
        }
        (void)*reinterpret_cast<const volatile std::byte*>(last);
    } __except(GuardedReadFilter(GetExceptionInformation())) { return false; }
    return true;
}

// Pinned KF2 reflection, not a generated/general UE3 SDK. See the read-only
// weapon-reflection and weapon-call-function exports. Game-thread use only.
class GameScript {
public:
    using Name=std::uint64_t;
    struct NameHash {
        using is_transparent=void;
        std::size_t operator()(std::wstring_view text) const noexcept {
            return std::hash<std::wstring_view>{}(text);
        }
    };
    struct NameEqual {
        using is_transparent=void;
        bool operator()(std::wstring_view left, std::wstring_view right) const noexcept {
            return left==right;
        }
    };
    // Profiles are supplied only after the owning executable's hash gate.
    struct ReflectionProfile {
        std::uintptr_t constructName=0xc4990;
        std::uintptr_t findFunction=0xc9de0;
        std::size_t processEventSlot=0x218;
        // Optional exact target for a narrow adapter invoking plain UObjects.
        // Zero retains the client's existing virtual dispatch behavior.
        std::uintptr_t processEventTarget=0;
    };
    explicit GameScript(std::uintptr_t base=0) : base_(base) {}
    GameScript(std::uintptr_t base, ReflectionProfile profile) : base_(base), explicitProfile_(true), profile_(profile) {}
    void Initialise(std::uintptr_t base) { base_=base; }
    static bool Accessible(const void* p,std::size_t size) {
        auto cursor=reinterpret_cast<std::uintptr_t>(p);
        if (!cursor || cursor+size<cursor) return false;
        if (guardedScriptReads) return GuardedProbe(p,size);
        const auto end=cursor+size;
        while (cursor<end) {
            MEMORY_BASIC_INFORMATION region{};
            if (!VirtualQuery(reinterpret_cast<void*>(cursor),&region,sizeof(region)) ||
                region.State!=MEM_COMMIT || (region.Protect&(PAGE_GUARD|PAGE_NOACCESS))) return false;
            const auto next=reinterpret_cast<std::uintptr_t>(region.BaseAddress)+region.RegionSize;
            if (next<=cursor) return false;
            cursor=next;
        }
        return true;
    }
    template<class T> static T At(const void* object,std::size_t offset) {
        T value{};
        if (!object) return value;
        auto* address=static_cast<const std::byte*>(object)+offset;
        if (guardedScriptReads) {
            if (!GuardedCopy(&value,address,sizeof(T))) value=T{};
        } else if (Accessible(address,sizeof(T))) std::memcpy(&value,address,sizeof(T));
        return value;
    }
    Name Intern(const wchar_t* text) {
        // VM hooks ask for the same names on every call. Search without an
        // owning temporary; only a cache miss allocates its persistent key.
        const auto found=names_.find(std::wstring_view(text));
        if (found!=names_.end()) return found->second;
        Name value=0;
        using ConstructName=Name*(*)(Name*,const wchar_t*,std::int32_t);
        reinterpret_cast<ConstructName>(base_+(explicitProfile_ ? profile_.constructName : build::Rva(profile_.constructName)))(&value,text,1);
        names_.emplace(text,value);
        return value;
    }
    static Name ObjectName(const void* object) { return At<Name>(object,0x48); }
    static void* ObjectClass(const void* object) { return At<void*>(object,0x50); }
    static void* SuperStruct(const void* object) { return At<void*>(object,0x78); }
    static void* Children(const void* object) { return At<void*>(object,0x80); }
    static void* NextField(const void* object) { return At<void*>(object,0x60); }
    bool IsClass(const void* object,const wchar_t* name) {
        const Name wanted=Intern(name);
        void* type=ObjectClass(object);
        for (unsigned depth=0;type && depth<64;++depth,type=SuperStruct(type))
            if (ObjectName(type)==wanted) return true;
        return false;
    }
    std::uint32_t FieldOffset(void* type,Name name) {
        const auto typeKey=reinterpret_cast<std::uintptr_t>(type);
        const auto found=offsets_.find(typeKey);
        if (found!=offsets_.end()) {
            const auto field=found->second.find(name);
            if (field!=found->second.end()) return field->second;
        }
        std::uint32_t offset=0;
        for (unsigned depth=0;type && depth<64;++depth,type=SuperStruct(type)) {
            auto* child=Children(type);
            for (unsigned count=0;child && count<4096;++count,child=NextField(child)) {
                if (ObjectName(child)!=name) continue;
                const auto candidate=At<std::int32_t>(child,0x8c);
                const auto elementSize=At<std::int32_t>(child,0x6c);
                if (candidate>=0 && candidate<0x10000 && elementSize>0 && elementSize<0x10000)
                    offset=static_cast<std::uint32_t>(candidate);
                break;
            }
            if (offset) break;
        }
        offsets_[typeKey][name]=offset;
        return offset;
    }
    template<class T> T Read(void* object,const wchar_t* field) {
        if (!object) return {};
        const auto offset=FieldOffset(ObjectClass(object),Intern(field));
        return offset ? At<T>(object,offset) : T{};
    }
    template<class T> bool Write(void* object,const wchar_t* field,const T& value) {
        if (!object) return false;
        const auto offset=FieldOffset(ObjectClass(object),Intern(field));
        auto* address=static_cast<std::byte*>(object)+offset;
        if (!offset || !Accessible(address,sizeof(T))) return false;
        std::memcpy(address,&value,sizeof(T));
        return true;
    }
    void* FindFunction(void* object,const wchar_t* function) {
        using Find=void*(*)(void*,Name,std::int32_t);
        if (!Accessible(object,0x58)) return nullptr;
        return reinterpret_cast<Find>(base_+(explicitProfile_ ? profile_.findFunction : build::Rva(profile_.findFunction)))(object,Intern(function),0);
    }
    bool Invoke(void* object,void* function,void* parameters) {
        if (!Accessible(object,0x58) || !Accessible(function,0xf8) ||
            At<std::uint16_t>(function,0xd4)!=0) return false;
        auto* table=At<void*>(object,0);
        if (!Accessible(table,profile_.processEventSlot+sizeof(void*))) return false;
        using Event=void(*)(void*,void*,void*,void*);
        auto event=At<Event>(table,profile_.processEventSlot);
        if (!event || (profile_.processEventTarget &&
            reinterpret_cast<std::uintptr_t>(event)!=base_+profile_.processEventTarget)) return false;
        event(object,function,parameters,nullptr);
        return true;
    }
private:
    std::uintptr_t base_{};
    bool explicitProfile_=false;
    ReflectionProfile profile_{};
    std::unordered_map<std::wstring,Name,NameHash,NameEqual> names_;
    std::unordered_map<std::uintptr_t,std::unordered_map<Name,std::uint32_t>> offsets_;
};
} // namespace kf2vr::adapter
