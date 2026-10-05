#include "ScriptField.h"
#include <array>
#include <cstdio>

using namespace kf2vr::adapter;
namespace {
int failures=0,checks=0;
void Check(bool ok, const char* message) {
    ++checks;
    if (!ok) { ++failures; std::printf("FAIL: %s\n",message); }
}
using Node=std::array<std::byte,0x100>;
template<class T> void Put(Node& node, std::size_t offset, T value) {
    std::memcpy(node.data()+offset,&value,sizeof(value));
}
void Field(Node& node, GameScript::Name name, int offset, int size) {
    Put(node,0x48,name); Put(node,0x8c,offset); Put(node,0x6c,size);
}
}

int main() {
    // Long names exceed std::wstring's inline storage. All three lookup
    // forms must share a hash/equality policy while the cache owns its key.
    // wstring_view cannot implicitly become an owning wstring, so find(view)
    // also requires the heterogeneous overload used by warm Intern calls.
    std::unordered_map<std::wstring,GameScript::Name,GameScript::NameHash,GameScript::NameEqual> names;
    const wchar_t literal[]=L"GetWeaponStartTraceLocation";
    std::wstring owned=literal;
    const std::wstring padded=owned+L"UnusedSuffix";
    const std::wstring_view view(padded.data(),owned.size());
    const GameScript::NameHash hash;
    const GameScript::NameEqual equal;
    Check(hash(literal)==hash(owned) && hash(owned)==hash(view),"script name hashes agree for array, string and bounded view");
    Check(equal(literal,owned) && equal(owned,view) && equal(view,literal),"script name equality agrees across borrowed and owned inputs");
    names.emplace(owned,73);
    owned[0]=L'x'; // The cached name must remain valid independently.
    const auto* storedKey=names.begin()->first.data();
    bool hits=true;
    const std::wstring query=literal;
    for (int i=0;i<1000;++i) {
        const auto arrayHit=names.find(literal), stringHit=names.find(query), viewHit=names.find(view);
        hits=hits && arrayHit!=names.end() && stringHit!=names.end() && viewHit!=names.end() &&
            arrayHit->second==73 && stringHit->second==73 && viewHit->second==73;
    }
    Check(hits && names.size()==1 && names.begin()->first.data()==storedKey,
          "warm heterogeneous name lookups retain one independently owned key");
    Check(names.find(std::wstring_view(owned))==names.end() && names.find(std::wstring_view(padded))==names.end(),
          "name lookup preserves exact case and bounded-view length");

    Node function{},weapon{},mode{},base{},inherited{},locals{};
    Field(weapon,11,0,8); Field(mode,12,8,4); Field(inherited,13,16,4);
    Put(function,0x80,weapon.data()); Put(weapon,0x60,mode.data());
    Put(function,0x78,base.data()); Put(base,0x80,inherited.data());
    void* const expected=weapon.data();
    Put(locals,0,expected); Put(locals,8,6); Put(locals,16,41);
    void* item=nullptr; int fireMode=-1, inheritedValue=0;
    Check(ReadScriptLocal(function.data(),locals.data(),11,item) && item==expected,
          "first object parameter at zero is readable");
    Check(ReadScriptLocal(function.data(),locals.data(),12,fireMode) && fireMode==6,
          "mode following object has its reflected offset");
    Check(ReadScriptLocal(function.data(),locals.data(),13,inheritedValue) && inheritedValue==41,
          "inherited property resolves");
    ScriptField field{123,4};
    Check(!FindScriptField(function.data(),99,field) && field.offset==0 && field.size==0,
          "missing field is distinct from a parameter at zero");
    Check(!ReadScriptLocal(function.data(),locals.data(),11,fireMode) && fireMode==6,
          "width mismatch does not overwrite the destination");
    Check(!ReadScriptLocal(function.data(),nullptr,11,item),"null locals rejected");
    Put(weapon,0x8c,-1);
    Check(!ReadScriptLocal(function.data(),locals.data(),11,item),"negative offset rejected");
    Put(weapon,0x8c,0); Put(weapon,0x6c,0);
    Check(!ReadScriptLocal(function.data(),locals.data(),11,item),"zero-sized property rejected");
    Put(weapon,0x8c,0xffff); Put(weapon,0x6c,8);
    Check(!FindScriptField(function.data(),11,field),"property past layout bound rejected");
    Put(mode,0x60,mode.data());
    Check(!FindScriptField(function.data(),99,field),"cyclic field chain terminates");
    Put(base,0x78,base.data());
    Check(!FindScriptField(function.data(),99,field),"cyclic superclass chain terminates");

    // Guarded and checked reads must agree on every rejection, and neither
    // may consume a guard page. Page 0 readable, 1 variable, 2 reserved only.
    constexpr std::size_t page=4096;
    auto* pages=static_cast<std::byte*>(VirtualAlloc(nullptr,page*3,MEM_RESERVE,PAGE_NOACCESS));
    if (!pages || !VirtualAlloc(pages,page*2,MEM_COMMIT,PAGE_READWRITE)) return 2;
    Put(*reinterpret_cast<Node*>(pages),0x10,1234);
    for (const bool guarded:{true,false}) {
        guardedScriptReads=guarded;
        const auto faults=guardedReadFaults;
        Check(GameScript::At<int>(pages,0x10)==1234,"committed field read");
        Check(GameScript::Accessible(pages+page-4,8),"range across two readable pages accepted");
        Check(GameScript::At<int>(pages,page*2)==0 && !GameScript::Accessible(pages+page*2,4),
              "reserved but uncommitted page rejected");
        Check(!GameScript::Accessible(pages+page-4,page+8),"range ending in an uncommitted page rejected");
        Check(GameScript::At<std::uint64_t>(nullptr,0x48)==0 && GameScript::At<void*>(reinterpret_cast<void*>(0x20),0x48)==nullptr,
              "null-page offsets rejected");
        DWORD old=0;
        VirtualProtect(pages+page,page,PAGE_NOACCESS,&old);
        Check(GameScript::At<int>(pages+page,0)==0 && !GameScript::Accessible(pages+page-4,8),"no-access page rejected");
        VirtualProtect(pages+page,page,PAGE_READWRITE|PAGE_GUARD,&old);
        Check(GameScript::At<int>(pages+page,0)==0 && !GameScript::Accessible(pages+page,4),"guard page rejected");
        MEMORY_BASIC_INFORMATION region{};VirtualQuery(pages+page,&region,sizeof(region));
        Check((region.Protect&PAGE_GUARD)!=0,"guard page preserved after rejected reads");
        VirtualProtect(pages+page,page,PAGE_READWRITE,&old);
        Check(guarded ? guardedReadFaults>faults : guardedReadFaults==faults,"faults counted only on the guarded path");
    }
    guardedScriptReads=true;
    VirtualFree(pages,0,MEM_RELEASE);
    std::printf("script fields: %d checks, %d failures\n",checks,failures);
    return failures?1:0;
}
