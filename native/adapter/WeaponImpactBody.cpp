#include "WeaponImpactBody.h"
#include <bcrypt.h>
#include <array>
#include <cmath>

namespace kf2vr::adapter {
namespace {
// KF2's shipped PhysX3.3.4. The exported metadata constructor gives a read-only
// snapshot through the actual actor's public virtual getters. No body storage
// offsets are used: BodyInstance and BodyData are reflected script properties.
constexpr std::array<unsigned char,32> expectedHash={
    0x80,0xc5,0x3d,0xb9,0xed,0x98,0xfe,0xaa,0x9d,0xde,0x72,0xa0,0x28,0xfd,0x2c,0x53,
    0x66,0x71,0x82,0xb9,0xd2,0xb6,0xbb,0xe2,0x4c,0xdb,0xcd,0x98,0x75,0x56,0xc8,0x68};
bool HashMatches(HMODULE module){
    std::array<wchar_t,32768> path{};
    if(!GetModuleFileNameW(module,path.data(),static_cast<DWORD>(path.size())))return false;
    HANDLE file=CreateFileW(path.data(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)return false;
    BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;bool ok=false;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0
        &&BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0)>=0){
        std::array<unsigned char,65536> bytes{};DWORD count=0;ok=true;
        while(true){
            if(!ReadFile(file,bytes.data(),static_cast<DWORD>(bytes.size()),&count,nullptr)){ok=false;break;}
            if(!count)break;
            if(BCryptHashData(hash,bytes.data(),count,0)<0){ok=false;break;}
        }
        std::array<unsigned char,32> digest{};
        ok=ok&&BCryptFinishHash(hash,digest.data(),static_cast<ULONG>(digest.size()),0)>=0&&digest==expectedHash;
    }
    if(hash)BCryptDestroyHash(hash);
    if(algorithm)BCryptCloseAlgorithmProvider(algorithm,0);
    CloseHandle(file);return ok;
}
struct PhysicsApi {
    HMODULE module{};std::uintptr_t begin{},end{};
    using Values=void*(*)(void*,const void*);
    Values values{};
    PhysicsApi(){
        module=GetModuleHandleW(L"PhysX3_x64.dll");if(!module||!HashMatches(module))return;
        begin=reinterpret_cast<std::uintptr_t>(module);
        const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(module);
        const auto* nt=reinterpret_cast<const IMAGE_NT_HEADERS64*>(begin+dos->e_lfanew);
        end=begin+nt->OptionalHeader.SizeOfImage;
        values=reinterpret_cast<Values>(GetProcAddress(module,"??0PxRigidBodyGeneratedValues@physx@@QEAA@PEBVPxRigidBody@1@@Z"));
        if(reinterpret_cast<std::uintptr_t>(values)!=begin+0xa2c60)values=nullptr;
    }
    void* Method(void* object,std::size_t offset)const{
        void* table=nullptr;void* fn=nullptr;
        if(!GuardedCopy(&table,object,sizeof(table))
            ||!GuardedCopy(&fn,static_cast<std::byte*>(table)+offset,sizeof(fn)))return nullptr;
        const auto address=reinterpret_cast<std::uintptr_t>(fn);
        return address>=begin&&address<end?fn:nullptr;
    }
};
// Engine GetBodyMass/GetUnrealWorldTM on the pinned KFGame call getScene@30,
// lockRead@308 and unlockRead@310 around these same public actor getters.
// GetUnrealWorldVelocity verifies concrete dynamic type5; static type6 has no
// finite dynamic response. These are validated PhysX ABI values, not UObject
// layout guesses. Exception handling keeps the scene lock paired on failure.
bool Snapshot(const PhysicsApi& api,void* actor,std::byte* output){
    using Scene=void*(*)(void*);using Lock=void(*)(void*,const char*,unsigned);using Unlock=void(*)(void*);
    unsigned short type=0;
    if(!GuardedCopy(&type,static_cast<std::byte*>(actor)+8,sizeof(type))||type!=5)return false;
    auto getScene=reinterpret_cast<Scene>(api.Method(actor,0x30));if(!getScene)return false;
    void* scene=nullptr;bool locked=false;bool ok=false;
    __try {
        scene=getScene(actor);if(!scene)return false;
        auto lock=reinterpret_cast<Lock>(api.Method(scene,0x308));
        auto unlock=reinterpret_cast<Unlock>(api.Method(scene,0x310));
        if(!lock||!unlock)return false;
        __try {lock(scene,"KF2VR weapon impact",0);locked=true;api.values(output,actor);ok=true;}
        __finally {if(locked)unlock(scene);}
    } __except(GuardedReadFilter(GetExceptionInformation())) {ok=false;}
    return ok;
}
template<class T>T Read(const std::byte* bytes,std::size_t offset){T value{};std::memcpy(&value,bytes+offset,sizeof(value));return value;}
weaponblock::Vec Rotate(weaponblock::Quat q,weaponblock::Vec v){
    const auto cross=[](weaponblock::Vec a,weaponblock::Vec b){return weaponblock::Vec{a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};};
    const weaponblock::Vec u{q.x,q.y,q.z};const auto uv=cross(u,v),uuv=cross(u,uv);
    return {v.x+2*(q.w*uv.x+uuv.x),v.y+2*(q.w*uv.y+uuv.y),v.z+2*(q.w*uv.z+uuv.z)};
}
}
bool ReadWeaponImpactBody(GameScript& script,void* prop,weaponblock::RigidBodyState& out){
    out={};
    static const PhysicsApi api;if(!api.values)return false;
    auto* mesh=script.Read<void*>(prop,L"MyMeshComp");auto* body=script.Read<void*>(mesh,L"BodyInstance");
    if(!script.IsClass(body,L"RB_BodyInstance"))return false;
    auto* actor=script.Read<void*>(body,L"BodyData");if(!actor)return false;
    alignas(16) std::array<std::byte,0xb0> values{};
    if(!Snapshot(api,actor,values.data()))return false;
    using weaponblock::Vec;using weaponblock::Quat;
    // Named GeneratedInfo constructor@a49b0 confirms every field identity;
    // Values@a2c60 writes these offsets. PxTransform is quaternion then position.
    const auto q=Read<Quat>(values.data(),0x28),localQ=Read<Quat>(values.data(),0x48);
    const auto position=Read<Vec>(values.data(),0x38),local=Read<Vec>(values.data(),0x58);
    const auto offset=Rotate(q,local);
    out.center={(position.x+offset.x)*50,(position.y+offset.y)*50,(position.z+offset.z)*50};
    out.inertiaQ={q.w*localQ.x+q.x*localQ.w+q.y*localQ.z-q.z*localQ.y,
        q.w*localQ.y-q.x*localQ.z+q.y*localQ.w+q.z*localQ.x,
        q.w*localQ.z+q.x*localQ.y-q.y*localQ.x+q.z*localQ.w,
        q.w*localQ.w-q.x*localQ.x-q.y*localQ.y-q.z*localQ.z};
    out.inverseMass=Read<float>(values.data(),0x68);
    out.inverseInertia=Read<Vec>(values.data(),0x78);
    out.inverseInertia={out.inverseInertia.x/2500,out.inverseInertia.y/2500,out.inverseInertia.z/2500};
    out.linear=Read<Vec>(values.data(),0x84);out.linear={out.linear.x*50,out.linear.y*50,out.linear.z*50};
    out.angular=Read<Vec>(values.data(),0x90);
    // Engine converters6576f0/6579c0 multiply lengths by50;65ff10 leaves
    // angular velocity unchanged. Inverse inertia therefore divides by50^2.
    return true;
}
}
