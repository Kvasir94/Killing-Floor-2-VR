#include "ScriptWriteBatch.h"
#include <cstdio>
using namespace kf2vr::adapter;
using Node=std::array<std::byte,256>;
template<class T> void Put(void* p,std::size_t offset,T value) { std::memcpy(static_cast<char*>(p)+offset,&value,sizeof(value)); }
template<class T> T Read(void* p,std::size_t offset) { T v{};std::memcpy(&v,static_cast<char*>(p)+offset,sizeof(v));return v; }
int checks=0,failures=0;
void Check(bool okay,const char* name) { ++checks;if(!okay){++failures;std::printf("FAIL %s\n",name);} }
int main() {
    SYSTEM_INFO info{};GetSystemInfo(&info);const auto page=info.dwPageSize;
    auto* object=static_cast<char*>(VirtualAlloc(nullptr,page*3,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE));
    if(!object)return 2;
    Node type{},otherType{},first{},second{},crossing{},vectorField{},crossingVector{};
    Put(object,0x50,type.data());Put(type.data(),0x80,first.data());
    const auto field=[&](Node& node,std::uint64_t name,int offset,void* next,int size=4) {
        Put(node.data(),0x48,name);Put(node.data(),0x8c,offset);Put(node.data(),0x6c,size);Put(node.data(),0x60,next);
    };
    field(first,11,0x100,second.data());field(second,12,page+0x100,crossing.data());
    field(crossing,13,page-2,vectorField.data());
    field(vectorField,14,0x200,crossingVector.data(),12);
    field(crossingVector,15,page-6,nullptr,12);
    GameScript script;
    {
        ScriptWriteBatch batch(script,object,true);
        Check(batch.Stage(11,73) && batch.Stage(12,94),"fields resolve on one object");
        Check(Read<int>(object,0x100)==0,"staging does not write");
        Check(batch.Commit() && Read<int>(object,0x100)==73 && Read<int>(object,page+0x100)==94,"commit writes all fields");
        Check(HandWriteCounts().rangeQueries==1,"same memory region queried once for sparse fields");
        Check(!batch.Commit(),"batch cannot replay writes");
    }
    {
        ScriptWriteBatch batch(script,object,true);batch.Stage(11,101);batch.Stage(11,102);
        Check(batch.Commit() && Read<int>(object,0x100)==102,"repeated writes preserve order");
    }
    {
        const std::array<float,3> position{1.25f,-2.5f,99.f};
        Put(object,0x1fc,0x12345678);Put(object,0x20c,0x23456789);
        ScriptWriteBatch batch(script,object,true);
        Check(batch.Stage(14,position) && batch.Commit() && Read<std::array<float,3>>(object,0x200)==position &&
            Read<int>(object,0x1fc)==0x12345678 && Read<int>(object,0x20c)==0x23456789,
            "12-byte pose values preserve all components and adjacent memory");
    }
    {
        ScriptWriteBatch batch(script,object,true);batch.Stage(11,123);
        Check(!batch.Stage(999,1) && !batch.Commit() && Read<int>(object,0x100)==102,"missing field prevents partial update");
    }
    {
        ScriptWriteBatch batch(script,object,true);batch.Stage(11,123);Put(object,0x50,otherType.data());
        Check(!batch.Commit() && Read<int>(object,0x100)==102,"changed object class rejects update");Put(object,0x50,type.data());
    }
    DWORD old=0;
    for (DWORD protection:{DWORD(PAGE_NOACCESS),DWORD(PAGE_READONLY),DWORD(PAGE_READWRITE|PAGE_GUARD)}) {
        ScriptWriteBatch batch(script,object,true);batch.Stage(11,123);batch.Stage(12,321);
        VirtualProtect(object+page,page,protection,&old);
        Check(!batch.Commit() && Read<int>(object,0x100)==102,"protected later field never causes partial earlier writes");
        MEMORY_BASIC_INFORMATION region{};VirtualQuery(object+page,&region,sizeof(region));
        Check(region.Protect==protection,"validation does not consume guard pages");
        VirtualProtect(object+page,page,PAGE_READWRITE,&old);
    }
    {
        ScriptWriteBatch batch(script,object,true);batch.Stage(13,123);
        VirtualProtect(object+page,page,PAGE_NOACCESS,&old);
        Check(!batch.Commit(),"field crossing inaccessible page rejected");VirtualProtect(object+page,page,PAGE_READWRITE,&old);
    }
    {
        const std::array<float,3> position{1.f,2.f,3.f};
        ScriptWriteBatch batch(script,object,true);batch.Stage(11,123);batch.Stage(15,position);
        VirtualProtect(object+page,page,PAGE_NOACCESS,&old);
        Check(!batch.Commit() && Read<int>(object,0x100)==102,"pose crossing inaccessible page rejects the entire update");
        VirtualProtect(object+page,page,PAGE_READWRITE,&old);
    }
    {
        ScriptWriteBatch batch(script,object,true);bool okay=true;
        for(unsigned i=0;i<96;++i)okay=okay && batch.Stage(11,123);
        Check(okay && !batch.Stage(11,124) && !batch.Commit() && Read<int>(object,0x100)==102,"bounded overflow rejects whole update");
    }
    {
        ScriptWriteBatch batch(script,object,true);batch.Stage(11,999);
    }
    Check(Read<int>(object,0x100)==102,"destruction cannot implicitly commit");
    {
        ScriptWriteBatch batch(script,nullptr,true);Check(!batch.Stage(11,123) && !batch.Commit(),"null object rejected");
    }
    {
        ScriptWriteBatch batch(script,object,true);Check(batch.Commit(),"empty valid update is harmless");
    }
    VirtualFree(object,0,MEM_RELEASE);
    std::printf("Script write batch checks=%d failures=%d\n",checks,failures);return failures?1:0;
}
