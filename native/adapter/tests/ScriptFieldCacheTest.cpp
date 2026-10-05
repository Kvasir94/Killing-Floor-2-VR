#include "ScriptField.h"
#include <vector>
#include <chrono>
#include <cstdio>
using namespace kf2vr::adapter;
using Node=std::array<std::byte,0x100>;
template<class T> void Put(Node& node,std::size_t offset,T value) { std::memcpy(node.data()+offset,&value,sizeof(value)); }
void Field(Node& n,GameScript::Name name,int offset,int size) { Put(n,0x48,name);Put(n,0x8c,offset);Put(n,0x6c,size); }
int main() {
    int failures=0,checks=0;
    const auto check=[&](bool ok,const char* label) { ++checks;if(!ok) { ++failures;std::printf("FAIL %s\n",label); } };
    Node root{},base{},newField{};std::vector<Node> fields(512);
    Put(root,0x48,GameScript::Name{71});Put(base,0x48,GameScript::Name{72});Put(root,0x78,base.data());Put(base,0x80,fields[0].data());
    for(std::size_t i=0;i<fields.size();++i) {
        Field(fields[i],100+i,static_cast<int>(i*4),4);
        if(i+1<fields.size()) Put(fields[i],0x60,fields[i+1].data());
    }
    ScriptFieldCache cache;ScriptField found{};const auto target=GameScript::Name{611};
    check(cache.Find(root.data(),target,found) && found.offset==2044,"inherited long-list discovery");
    check(cache.Find(root.data(),target,found) && cache.hits==1,"warm cached discovery");
    Put(fields.back(),0x8c,2000);
    check(cache.Find(root.data(),target,found) && found.offset==2000 && cache.invalidations==1,"descriptor changes revalidated");
    Put(base,0x48,GameScript::Name{73});
    check(cache.Find(root.data(),target,found) && cache.invalidations==2,"ancestor identity changes invalidate");
    Field(newField,target,0,4);Put(base,0x80,newField.data());
    check(cache.Find(root.data(),target,found) && found.offset==0,"replacement metadata and zero offset");
    Put(newField,0x6c,0);
    check(!cache.Find(root.data(),target,found) && found.offset==0 && found.size==0,"invalid size cannot be reused");
    Field(newField,target,0,4);Put(root,0x78,static_cast<void*>(nullptr));
    check(!cache.Find(root.data(),target,found),"removed ancestor cannot retain a hit");
    check(!cache.Find(root.data(),900,found),"missing field not cached");
    Field(newField,900,12,4);Put(root,0x80,newField.data());
    check(cache.Find(root.data(),900,found) && found.offset==12,"later field discovery after miss");
    auto* page=VirtualAlloc(nullptr,4096,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
    if(!page) return 2;
    Node protectedField{};Field(protectedField,901,20,4);std::memcpy(page,protectedField.data(),protectedField.size());Put(root,0x80,page);
    check(cache.Find(root.data(),901,found),"readable property primed");
    DWORD old=0;VirtualProtect(page,4096,PAGE_READWRITE|PAGE_GUARD,&old);
    check(!cache.Find(root.data(),901,found),"guarded cached metadata rejected without access");
    MEMORY_BASIC_INFORMATION region{};VirtualQuery(page,&region,sizeof(region));
    check((region.Protect&PAGE_GUARD)!=0,"guard state preserved");
    VirtualProtect(page,4096,PAGE_READWRITE,&old);VirtualFree(page,0,MEM_RELEASE);
    check(!cache.Find(root.data(),901,found),"decommitted metadata rejected");
    ScriptFieldCache bounded;Node capacityRoot{};std::vector<Node> capacityFields(65);
    Put(capacityRoot,0x80,capacityFields[0].data());
    bool allDiscovered=true;
    for(std::size_t i=0;i<capacityFields.size();++i) {
        Field(capacityFields[i],1000+i,static_cast<int>(i*4),4);
        if(i+1<capacityFields.size()) Put(capacityFields[i],0x60,capacityFields[i+1].data());
    }
    for(std::size_t i=0;i<capacityFields.size();++i)
        allDiscovered=bounded.Find(capacityRoot.data(),1000+i,found) && found.offset==i*4 && allDiscovered;
    check(allDiscovered,"cache capacity does not limit field discovery");
    const auto capacityMisses=bounded.misses;
    check(bounded.Find(capacityRoot.data(),1000,found) && found.offset==0 && bounded.misses==capacityMisses+1,
        "evicted metadata rediscovered correctly");
    check(bounded.Find(capacityRoot.data(),1064,found) && found.offset==256 && bounded.hits==1,
        "recent metadata retained after eviction");
    ScriptFieldCache deep;std::vector<Node> ancestors(17);Node deepField{};
    Field(deepField,2000,40,4);
    for(std::size_t i=0;i+1<ancestors.size();++i) Put(ancestors[i],0x78,ancestors[i+1].data());
    Put(ancestors.back(),0x80,deepField.data());
    check(deep.Find(ancestors[0].data(),2000,found) && found.offset==40,"deep hierarchy still discovered");
    check(deep.Find(ancestors[0].data(),2000,found) && deep.hits==0 && deep.misses==2,"deep hierarchy bypasses bounded cache");
    Node cyclicType{},cyclicProperty{};Put(cyclicType,0x78,cyclicType.data());
    check(!deep.Find(cyclicType.data(),3000,found),"cyclic ancestry terminates");
    Put(cyclicType,0x78,static_cast<void*>(nullptr));Put(cyclicType,0x80,cyclicProperty.data());
    Put(cyclicProperty,0x60,cyclicProperty.data());
    check(!deep.Find(cyclicType.data(),3000,found),"cyclic property chain terminates");
    scriptFieldCacheEnabled=true;CurrentScriptFields().Clear();
    check(FindScriptField(capacityRoot.data(),1064,found) && FindScriptField(capacityRoot.data(),1064,found) &&
        CurrentScriptFields().hits==1,"enabled public wrapper uses metadata cache");
    scriptFieldCacheEnabled=false;
    check(FindScriptField(capacityRoot.data(),1064,found) && CurrentScriptFields().hits==1,
        "rollback public wrapper uses original traversal");
    Put(root,0x80,fields[0].data());cache.Clear();
    const auto bench=[&](bool cached) {
        const auto start=std::chrono::steady_clock::now();
        for(int i=0;i<200;++i) { if(cached) cache.Find(root.data(),target,found);else FindScriptFieldUncached(root.data(),target,found); }
        return std::chrono::duration<double,std::micro>(std::chrono::steady_clock::now()-start).count()/200;
    };
    const double cold=bench(false),warm=bench(true);
    std::printf("Synthetic 512-property lookup: uncached=%.3fus cached=%.3fus (not an FPS benchmark)\n",cold,warm);
    std::printf("%d checks, %d failures\n",checks,failures);return failures?1:0;
}
