#pragma once

#include "GameScript.h"
#include <array>

namespace kf2vr::adapter {

// Function parameters may start at offset zero. GameScript::FieldOffset's
// historical zero sentinel is suitable for object fields, not VM locals.
struct ScriptField {
    std::uint32_t offset{};
    std::uint32_t size{};
};

inline bool FindScriptFieldUncached(void* type, GameScript::Name name, ScriptField& field) {
    field={};
    for (unsigned depth=0;type && depth<64;++depth,type=GameScript::SuperStruct(type)) {
        auto* child=GameScript::Children(type);
        for (unsigned count=0;child && count<4096;++count,child=GameScript::NextField(child)) {
            if (GameScript::ObjectName(child)!=name) continue;
            const auto offset=GameScript::At<std::int32_t>(child,0x8c);
            const auto size=GameScript::At<std::int32_t>(child,0x6c);
            if (offset<0 || offset>=0x10000 || size<=0 || size>=0x10000 || offset+size>0x10000)
                return false;
            field={static_cast<std::uint32_t>(offset),static_cast<std::uint32_t>(size)};
            return true;
        }
    }
    return false;
}

// Loaded UClass/UFunction property lists are immutable in the pinned shipping
// engine (same lifetime assumption as GameScript::FieldOffset). Cache only
// successful metadata discovery, never live object values, ownership or memory
// permissions. Every hit validates root/ancestor headers and the descriptor.
// Changed identities, class links, offsets, sizes or inaccessible pages miss.
// Startup enables this for the pinned engine; the comparison/rollback flag
// -kf2vr-no-metadata-cache selects the original traversal.
inline bool scriptFieldCacheEnabled=false;
class ScriptFieldCache {
    struct Header {
        GameScript::Name name{};void* super{};void* children{};
        bool operator==(const Header&) const = default;
    };
    struct Ancestor { void* type{};Header header{}; };
    struct Entry {
        void* root{};GameScript::Name name{};void* property{};ScriptField field{};
        std::array<Ancestor,16> path{};std::size_t depth=0;
    };
    std::array<Entry,64> entries_{};
    std::size_t next_=0;
    template<class T> static T Copy(const void* object,std::size_t offset) {
        T value{};std::memcpy(&value,static_cast<const std::byte*>(object)+offset,sizeof(T));return value;
    }
    static bool ReadHeader(void* type,Header& out) {
        if(!GameScript::Accessible(type,0x88)) return false;
        out={Copy<GameScript::Name>(type,0x48),Copy<void*>(type,0x78),Copy<void*>(type,0x80)};return true;
    }
    static bool ReadDescriptor(void* property,GameScript::Name name,ScriptField& out) {
        if(!GameScript::Accessible(property,0x90) || Copy<GameScript::Name>(property,0x48)!=name) return false;
        const auto offset=Copy<std::int32_t>(property,0x8c),size=Copy<std::int32_t>(property,0x6c);
        if(offset<0 || offset>=0x10000 || size<=0 || size>=0x10000 || offset+size>0x10000) return false;
        out={static_cast<std::uint32_t>(offset),static_cast<std::uint32_t>(size)};return true;
    }
public:
    std::uint64_t hits=0,misses=0,invalidations=0;
    void Clear() { entries_={};next_=0; }
    bool Find(void* root,GameScript::Name name,ScriptField& field) {
        field={};
        if(!root) return false;
        for(auto& entry:entries_) if(entry.root==root && entry.name==name) {
            bool valid=true;
            for(std::size_t i=0;i<entry.depth && valid;++i) {
                Header current{};
                valid=ReadHeader(entry.path[i].type,current) && current==entry.path[i].header;
            }
            ScriptField current{};
            valid=valid && ReadDescriptor(entry.property,name,current) &&
                current.offset==entry.field.offset && current.size==entry.field.size;
            if(valid) { ++hits;field=current;return true; }
            ++invalidations;entry.root=nullptr;break;
        }
        ++misses;
        Entry candidate{};candidate.root=root;candidate.name=name;
        auto* type=root;
        for(unsigned depth=0;type && depth<64;++depth) {
            Header header{};
            if(!ReadHeader(type,header)) return false;
            if(depth<candidate.path.size()) candidate.path[depth]={type,header};
            auto* child=header.children;
            for(unsigned count=0;child && count<4096;++count,child=GameScript::NextField(child)) {
                if(GameScript::ObjectName(child)!=name) continue;
                if(!ReadDescriptor(child,name,field)) return false;
                candidate.property=child;candidate.field=field;candidate.depth=depth+1;
                if(candidate.depth<=candidate.path.size()) {
                    entries_[next_]=candidate;next_=(next_+1)%entries_.size();
                }
                return true;
            }
            type=header.super;
        }
        return false;
    }
};
inline ScriptFieldCache& CurrentScriptFields() { thread_local ScriptFieldCache cache;return cache; }
inline bool FindScriptField(void* type,GameScript::Name name,ScriptField& field) {
    return scriptFieldCacheEnabled ? CurrentScriptFields().Find(type,name,field) : FindScriptFieldUncached(type,name,field);
}

template<class T>
bool ReadScriptLocal(void* function, const void* locals, GameScript::Name name, T& value) {
    ScriptField field{};
    if (!locals || !FindScriptField(function,name,field) || field.size!=sizeof(T)) return false;
    auto* source=static_cast<const std::byte*>(locals)+field.offset;
    if (!GameScript::Accessible(source,sizeof(T))) return false;
    std::memcpy(&value,source,sizeof(T));
    return true;
}

} // namespace kf2vr::adapter
