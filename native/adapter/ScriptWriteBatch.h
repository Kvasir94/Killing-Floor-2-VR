#pragma once
#include "GameScript.h"
#include <algorithm>
#include <array>
#include <limits>
#include <type_traits>

namespace kf2vr::adapter {
struct ScriptWriteBatchCounts {
    std::uint64_t commits=0,rangeQueries=0,writes=0,failures=0;
};
inline ScriptWriteBatchCounts& HandWriteCounts() {
    thread_local ScriptWriteBatchCounts counts;
    return counts;
}

// One game-thread update of one borrowed object. Values are staged, then the
// current class and the complete destination span are checked before writing.
// No engine call/allocation occurs between span validation and the memcpy loop.
// Nothing is cached across updates; UObject/field-offset lifetime assumptions
// are the same as GameScript::Write. Never retain this object across a callback.
class ScriptWriteBatch {
    struct WriteValue {
        std::uint32_t offset,size;
        std::array<std::byte,16> value;
    };
    GameScript& script_;
    void* object_;
    void* type_;
    bool enabled_,invalid_=false,finished_=false;
    // Only staged entries are read. Avoid clearing unused storage, including
    // on the default unbatched path.
    std::array<WriteValue,96> values_;
    std::size_t count_=0;
public:
    ScriptWriteBatch(GameScript& script,void* object,bool enabled):script_(script),object_(object),
        type_(enabled?GameScript::ObjectClass(object):nullptr),enabled_(enabled) {}
    ScriptWriteBatch(const ScriptWriteBatch&)=delete;
    ScriptWriteBatch& operator=(const ScriptWriteBatch&)=delete;

    template<class T> bool Stage(GameScript::Name name,const T& value) {
        static_assert(std::is_trivially_copyable_v<T> && sizeof(T)<=16);
        if (!enabled_ || finished_ || invalid_ || !object_ || !type_ || count_==values_.size()) {
            invalid_=true;return false;
        }
        const auto offset=script_.FieldOffset(type_,name);
        if (!offset || offset>=0x10000 || sizeof(T)>0x10000-offset) {
            invalid_=true;return false;
        }
        auto& entry=values_[count_++];entry.offset=offset;entry.size=sizeof(T);
        std::memcpy(entry.value.data(),&value,sizeof(T));
        return true;
    }
    template<class T> bool Write(const wchar_t* field,const T& value) {
        if (!enabled_) return script_.Write(object_,field,value);
        return Stage(script_.Intern(field),value);
    }
    bool Commit() {
        if (!enabled_) return true;
        auto& counts=HandWriteCounts();
        const auto refuse=[&] { finished_=true;++counts.failures;return false; };
        if (finished_ || invalid_ || !object_ || !type_ || GameScript::ObjectClass(object_)!=type_)
            return refuse();
        if (!count_) { finished_=true;return true; }
        std::uint32_t first=0x10000,last=0;
        for (std::size_t i=0;i<count_;++i) {
            const auto& v=values_[i];first=(std::min)(first,v.offset);last=(std::max)(last,v.offset+v.size);
        }
        const auto base=reinterpret_cast<std::uintptr_t>(object_);
        if (base>(std::numeric_limits<std::uintptr_t>::max)()-last) return refuse();
        const auto end=base+last;
        for (auto cursor=base+first;cursor<end;) {
            MEMORY_BASIC_INFORMATION region{};++counts.rangeQueries;
            if (!VirtualQuery(reinterpret_cast<const void*>(cursor),&region,sizeof(region)) ||
                region.State!=MEM_COMMIT || (region.Protect&(PAGE_GUARD|PAGE_NOACCESS)) ||
                !(region.Protect&(PAGE_READWRITE|PAGE_WRITECOPY|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY)))
                return refuse();
            const auto address=reinterpret_cast<std::uintptr_t>(region.BaseAddress);
            if (address>(std::numeric_limits<std::uintptr_t>::max)()-region.RegionSize) return refuse();
            const auto next=address+region.RegionSize;
            if (next<=cursor) return refuse();
            cursor=next;
        }
        // All destinations are checked first. Preserve repeated writes/order;
        // no script observer can see intermediate values on this owner thread.
        for (std::size_t i=0;i<count_;++i) {
            const auto& v=values_[i];
            std::memcpy(reinterpret_cast<void*>(base+v.offset),v.value.data(),v.size);
        }
        finished_=true;++counts.commits;counts.writes+=count_;return true;
    }
};
}
