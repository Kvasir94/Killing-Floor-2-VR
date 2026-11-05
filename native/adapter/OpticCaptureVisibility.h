#pragma once
#include "GameScript.h"
#include "ScriptField.h"
#include "OpticProbeBindings.h"
#include "include/kf2vr/adapter/GameBuild.h"
#include <MinHook.h>
#include <intrin.h>
#include <array>
#include <atomic>
#include <cstring>

namespace kf2vr::adapter {
// Steam 77ab9c2c...885c994: TW2DDPG component table172de70, slot2d8 ->
//315440 -> probe constructor30ed00/table172a140 -> Render691de0. Render
// initializes its own TSet, calls GRI+758 at691fb5, passes that same set to
// FSceneView at69215d, and destroys it at6922da. Never change scene proxies.
class OpticCaptureVisibility {
public:
    static constexpr std::uintptr_t CreateRva=0x315440,RenderRva=0x691de0;
    static constexpr std::size_t MaxComponents=64,MaxOptics=3;
    using Identity=OpticProbeIdentity;
    struct Snapshot {
        std::array<void*,MaxComponents> components{};
        std::array<Identity,MaxOptics> optics{};
        void* gri{};
        std::size_t count=0,opticsCount=0;
    };

    bool Install(std::uintptr_t base,bool(*gameThread)()) {
        base_=base;gameThread_=gameThread;script_.Initialise(base);
        if (build::selected!=build::Store::Steam || !Validate()) return false;
        instance_=this;
        auto* create=reinterpret_cast<void*>(base_+CreateRva);
        auto* render=reinterpret_cast<void*>(base_+RenderRva);
        if (MH_CreateHook(create,reinterpret_cast<void*>(&HookCreate),reinterpret_cast<void**>(&create_))!=MH_OK)
            return false;
        if (MH_CreateHook(render,reinterpret_cast<void*>(&HookRender),reinterpret_cast<void**>(&render_))!=MH_OK) {
            MH_RemoveHook(create);return false;
        }
        if (MH_EnableHook(create)!=MH_OK || MH_EnableHook(render)!=MH_OK) {
            MH_DisableHook(create);MH_DisableHook(render);
            MH_RemoveHook(create);MH_RemoveHook(render);return false;
        }
        enabled_.store(true,std::memory_order_release);return true;
    }
    bool Enabled() const { return enabled_.load(std::memory_order_acquire); }

    // Only the admitted game-thread world submission calls this, after final
    // hand placement. UObject references are inspected here, never by Render.
    Snapshot Collect(GameScript& script,void* root,void* pawn,void* pc) {
        Snapshot out{};
        if (!Enabled() || !gameThread_ || !gameThread_() || !root || !pawn || !pc ||
            script.Read<void*>(root,L"RootBridge") || script.Read<void*>(root,L"PC")!=pc ||
            script.Read<void*>(root,L"Human")!=pawn || script.Read<void*>(pc,L"Pawn")!=pawn ||
            script.Read<int>(pawn,L"Health")<=0) return out;
        auto* world=script.Read<void*>(pawn,L"WorldInfo");
        out.gri=script.Read<void*>(world,L"GRI");
        if (!out.gri || !BindGri(out.gri)) return {};
        AddPresenter(script,out,root,root,pawn);
        auto* registry=script.Read<void*>(root,L"HeldInventory");
        if (registry && script.Read<void*>(registry,L"Human")==pawn &&
            script.Read<void*>(registry,L"PC")==pc) {
            for (const auto* name:{L"LeftItem",L"RightItem",L"LeftSupport",L"RightSupport"}) {
                auto* runtime=script.Read<void*>(registry,name);
                auto* presenter=script.Read<void*>(runtime,L"Presenter");
                auto* weapon=script.Read<void*>(runtime,L"Item");
                if (!presenter || script.Read<void*>(presenter,L"RootBridge")!=root ||
                    script.Read<void*>(presenter,L"PresentedItem")!=runtime ||
                    script.Read<void*>(weapon,L"Instigator")!=pawn ||
                    script.Read<void*>(weapon,L"Owner")!=pawn) continue;
                AddPresenter(script,out,presenter,root,pawn);
                AddWeapon(script,out,weapon);
            }
        }
        auto* active=script.Read<void*>(root,L"ActiveWeapon");
        if (active && script.Read<void*>(active,L"Instigator")==pawn &&
            script.Read<void*>(active,L"Owner")==pawn) AddWeapon(script,out,active);
        AddFixed(script,out,pawn,L"FirstPersonAttachments",3); // KFGame/Globals.uci
        // An overflow drops this submission's optional exclusions altogether.
        if (out.count>MaxComponents || !out.opticsCount) return {};
        return out;
    }

    // Enqueue immediately around the engine submission, like ForegroundDepth.
    // No primitive-pointer snapshot survives the submitted renderer's Pop.
    void Push(const Snapshot& snapshot) {
        if (submissionDepth_<submissions_.size()) submissions_[submissionDepth_]=snapshot;
        ++submissionDepth_;
    }
    void Pop() {
        if (!submissionDepth_) return;
        --submissionDepth_;
        if (submissionDepth_<submissions_.size()) submissions_[submissionDepth_]={};
    }
    // Game-side stop/travel. Already queued draws retain only their scoped
    // native command values; restoring stock GRI dispatch is safe for them.
    // The two entry detours, like the adapter's other detours, live until exit.
    void ResetGame() {
        if (!gameThread_ || !gameThread_()) return;
        AcquireSRWLockExclusive(&recordsLock_);
        bindings_.Clear();
        ReleaseSRWLockExclusive(&recordsLock_);
        for (std::size_t i=0;i<slotsUsed_;++i) RestoreSlot(slots_[i],HiddenHook(i));
    }

private:
    using Create=void*(*)(void*);
    using Render=void(*)(void*,void*);
    using Hidden=void(*)(void*,void*);
    using Insert=int*(*)(void*,int*,void*,int*);
    struct Slot { void** address{};Hidden original{}; };
    static inline OpticCaptureVisibility* instance_=nullptr;
    static thread_local std::array<Snapshot,8> submissions_;
    static inline thread_local std::size_t submissionDepth_=0;
    static inline thread_local const Snapshot* active_=nullptr;
    std::uintptr_t base_=0;
    GameScript script_;
    bool(*gameThread_)()=nullptr;
    std::atomic<bool> enabled_{false};
    Create create_=nullptr;Render render_=nullptr;
    OpticProbeBindings<> bindings_;
    SRWLOCK recordsLock_=SRWLOCK_INIT;
    std::array<Slot,8> slots_{};std::size_t slotsUsed_=0;

    bool Bytes(std::uintptr_t rva,const unsigned char* expected,std::size_t size) const {
        auto* address=reinterpret_cast<void*>(base_+rva);
        MEMORY_BASIC_INFORMATION region{};
        return GameScript::Accessible(address,size) && VirtualQuery(address,&region,sizeof(region)) &&
            (region.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY)) &&
            std::memcmp(address,expected,size)==0;
    }
    bool Validate() const {
        constexpr unsigned char create[]{0x48,0x8b,0xc4,0x57,0x41,0x54,0x41,0x55,0x41,0x56,0x41,0x57,0x48,0x81,0xec,0x10};
        constexpr unsigned char render[]{0x48,0x8b,0xc4,0x55,0x56,0x57,0x41,0x54,0x41,0x55,0x41,0x56,0x41,0x57,0x48,0x8d};
        constexpr unsigned char dispatch[]{0xff,0x90,0x58,0x07,0x00,0x00};
        constexpr unsigned char insert[]{0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7c,0x24,0x20,0x41};
        return base_ && Bytes(CreateRva,create,sizeof(create)) && Bytes(RenderRva,render,sizeof(render)) &&
            Bytes(0x691fb5,dispatch,sizeof(dispatch)) && Bytes(0x35f500,insert,sizeof(insert)) &&
            GameScript::At<std::uintptr_t>(reinterpret_cast<void*>(base_+0x172de70),0x2d8)==base_+CreateRva &&
            GameScript::At<std::uintptr_t>(reinterpret_cast<void*>(base_+0x172a140),8)==base_+RenderRva;
    }
    static void* HookCreate(void* component) {
        auto& self=*instance_;
        auto* probe=self.create_(component);
        // Reused native addresses must invalidate the old identity even for a
        // foreign capture. Keep other probes of this component: queued older
        // submissions can still render them after the next probe is created.
        AcquireSRWLockExclusive(&self.recordsLock_);
        self.bindings_.Register(probe,{});
        ReleaseSRWLockExclusive(&self.recordsLock_);
        if (!self.Enabled() || !self.gameThread_ || !self.gameThread_()) return probe;
        if (!probe || GameScript::At<std::uintptr_t>(component,0)!=self.base_+0x172de70 ||
            GameScript::At<std::uintptr_t>(probe,0)!=self.base_+0x172a140) return probe;
        auto& script=self.script_;
        auto* owner=script.Read<void*>(component,L"Owner");
        auto* scope=script.Read<void*>(owner,L"M14Scope");
        auto* target=script.Read<void*>(scope,L"Target");
        if (!owner || !script.IsClass(owner,L"VRHandsBridge") || !scope || !target ||
            script.Read<void*>(scope,L"Capture")!=component || script.Read<void*>(scope,L"Presenter")!=owner ||
            script.Read<void*>(component,L"TextureTarget")!=target ||
            GameScript::At<void*>(probe,8)!=owner || GameScript::At<void*>(probe,0x20)!=target) return probe;
        AcquireSRWLockExclusive(&self.recordsLock_);
        self.bindings_.Register(probe,{component,owner,target});
        ReleaseSRWLockExclusive(&self.recordsLock_);
        return probe;
    }
    static void HookRender(void* probe,void* renderer) {
        auto& self=*instance_;
        struct Restore {
            const Snapshot* prior=active_;
            ~Restore() { active_=prior; }
        } restore;
        active_=nullptr;
        // Probe is a live native render resource. These are pointer comparisons;
        // no owner/target/component UObject is dereferenced on this thread.
        if (self.Enabled() && submissionDepth_ && submissionDepth_<=submissions_.size() &&
            GameScript::At<std::uintptr_t>(probe,0)==self.base_+0x172a140) {
            Identity created{};
            AcquireSRWLockShared(&self.recordsLock_);
            created=self.bindings_.Find(probe);
            ReleaseSRWLockShared(&self.recordsLock_);
            const auto& snapshot=submissions_[submissionDepth_-1];
            for (std::size_t i=0;i<snapshot.opticsCount;++i) {
                const auto& id=snapshot.optics[i];
                if (created.Valid() && created==id &&
                    GameScript::At<void*>(probe,8)==id.owner &&
                    GameScript::At<void*>(probe,0x20)==id.target) { active_=&snapshot;break; }
            }
        }
        self.render_(probe,renderer);
    }
    template<std::size_t Index> static void HookHidden(void* gri,void* set) {
        // Separate wrappers retain the original per-table dispatch without
        // reading the GRI's UObject/vtable on the rendering thread.
        const auto caller=reinterpret_cast<std::uintptr_t>(_ReturnAddress());
        auto& self=*instance_;
        self.slots_[Index].original(gri,set);
        if (!self.Enabled() || !active_ || active_->gri!=gri || caller!=self.base_+0x691fbb) return;
        const auto insert=reinterpret_cast<Insert>(self.base_+0x35f500);
        for (std::size_t i=0;i<active_->count;++i) {
            int index=-1;insert(set,&index,active_->components[i],nullptr);
        }
    }
    static Hidden HiddenHook(std::size_t index) {
        constexpr std::array<Hidden,8> hooks{&HookHidden<0>,&HookHidden<1>,&HookHidden<2>,&HookHidden<3>,
            &HookHidden<4>,&HookHidden<5>,&HookHidden<6>,&HookHidden<7>};
        return hooks[index];
    }
    bool BindGri(void* gri) {
        if (!script_.IsClass(gri,L"GameReplicationInfo")) return false;
        auto* table=GameScript::At<void**>(gri,0);
        if (!GameScript::Accessible(table,0x760)) return false;
        auto** address=table+0x758/sizeof(void*);
        std::size_t i=0;
        for (;i<slotsUsed_;++i) if (slots_[i].address==address) break;
        if (i==slotsUsed_) {
            if (i==slots_.size()) return false;
            auto* original=*address;
            MEMORY_BASIC_INFORMATION region{};
            if (!original || !VirtualQuery(original,&region,sizeof(region)) ||
                !(region.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY))) return false;
            slots_[i]={address,reinterpret_cast<Hidden>(original)};++slotsUsed_;
        }
        auto* hook=reinterpret_cast<void*>(HiddenHook(i));
        if (*address==hook) return true;
        if (*address!=reinterpret_cast<void*>(slots_[i].original)) return false;
        DWORD old=0;
        if (!VirtualProtect(address,sizeof(void*),PAGE_READWRITE,&old)) return false;
        const auto previous=InterlockedCompareExchangePointer(address,hook,reinterpret_cast<void*>(slots_[i].original));
        DWORD ignored=0;VirtualProtect(address,sizeof(void*),old,&ignored);
        return previous==reinterpret_cast<void*>(slots_[i].original) || previous==hook;
    }
    static void RestoreSlot(const Slot& slot,Hidden hook) {
        if (!slot.address || !GameScript::Accessible(slot.address,sizeof(void*))) return;
        DWORD old=0;
        if (!VirtualProtect(slot.address,sizeof(void*),PAGE_READWRITE,&old)) return;
        InterlockedCompareExchangePointer(slot.address,reinterpret_cast<void*>(slot.original),reinterpret_cast<void*>(hook));
        DWORD ignored=0;VirtualProtect(slot.address,sizeof(void*),old,&ignored);
    }
    static void Add(GameScript& script,Snapshot& out,void* component) {
        if (!component || out.count>MaxComponents || !script.IsClass(component,L"PrimitiveComponent")) return;
        for (std::size_t i=0;i<out.count;++i) if (out.components[i]==component) return;
        if (out.count==MaxComponents) { ++out.count;return; }
        out.components[out.count++]=component;
    }
    static void AddFixed(GameScript& script,Snapshot& out,void* object,const wchar_t* field,std::size_t count) {
        ScriptField reflected{};
        if (!object || !FindScriptField(GameScript::ObjectClass(object),script.Intern(field),reflected) ||
            reflected.size!=sizeof(void*)) return;
        auto* data=static_cast<std::byte*>(object)+reflected.offset;
        if (!GameScript::Accessible(data,count*sizeof(void*))) return;
        for (std::size_t i=0;i<count;++i) Add(script,out,GameScript::At<void*>(data,i*sizeof(void*)));
    }
    static void AddWeapon(GameScript& script,Snapshot& out,void* weapon) {
        Add(script,out,script.Read<void*>(weapon,L"MySkelMesh"));
        // Actor.AllComponents includes attached FP particles and secondary
        // meshes. Admit only components whose exact actor owner is this local
        // held inventory weapon; never the pawn's world/third-person meshes.
        struct Array { void* data;int count,capacity; };
        const auto all=script.Read<Array>(weapon,L"AllComponents");
        if (all.count<0 || all.count>128 || all.capacity<all.count || all.capacity>4096 ||
            (all.count && !GameScript::Accessible(all.data,all.count*sizeof(void*)))) return;
        for (int i=0;i<all.count;++i) {
            auto* component=GameScript::At<void*>(all.data,i*sizeof(void*));
            if (script.Read<void*>(component,L"Owner")==weapon) Add(script,out,component);
        }
    }
    static void AddOwnedHands(GameScript& script,Snapshot& out,void* presenter) {
        auto* mesh=script.Read<void*>(presenter,L"FloatingHandsMesh");
        if (!mesh) return;
        // The same Actor.AllComponents layout as AddWeapon. Reload/bow/recovery
        // hands and the melee ghost attach directly to their VRHandsBridge;
        // their exact owner and floating-hand asset exclude world actors,
        // weapon rigs and the private gun meshes used to sample animations.
        struct Array { void* data;int count,capacity; };
        const auto all=script.Read<Array>(presenter,L"AllComponents");
        if (all.count<0 || all.count>128 || all.capacity<all.count || all.capacity>4096 ||
            (all.count && !GameScript::Accessible(all.data,all.count*sizeof(void*)))) return;
        for (int i=0;i<all.count;++i) {
            auto* component=GameScript::At<void*>(all.data,i*sizeof(void*));
            if (component && script.IsClass(component,L"KFSkeletalMeshComponent") &&
                script.Read<void*>(component,L"Owner")==presenter &&
                script.Read<void*>(component,L"SkeletalMesh")==mesh) Add(script,out,component);
        }
    }
    void AddPresenter(GameScript& script,Snapshot& out,void* presenter,void* root,void* pawn) {
        if (!presenter || script.Read<void*>(presenter,L"Human")!=pawn ||
            (presenter!=root && script.Read<void*>(presenter,L"RootBridge")!=root)) return;
        Add(script,out,script.Read<void*>(presenter,L"Arms"));
        AddFixed(script,out,presenter,L"AttachedHands",2);
        AddOwnedHands(script,out,presenter);
        auto* scope=script.Read<void*>(presenter,L"M14Scope");
        auto* component=script.Read<void*>(scope,L"Capture");
        auto* target=script.Read<void*>(scope,L"Target");
        if (!component || !target || script.Read<void*>(scope,L"Presenter")!=presenter ||
            GameScript::At<std::uintptr_t>(component,0)!=base_+0x172de70 ||
            script.Read<void*>(component,L"Owner")!=presenter ||
            script.Read<void*>(component,L"TextureTarget")!=target) return;
        // SetView requests a deferred reattach. The exact native probe may be
        // created after Collect; bind the current script identity now and
        // resolve its opaque creation record only when that probe renders.
        for (std::size_t i=0;i<out.opticsCount;++i) if (out.optics[i].component==component) return;
        if (out.opticsCount<MaxOptics) out.optics[out.opticsCount++]={component,presenter,target};
    }
};
inline thread_local std::array<OpticCaptureVisibility::Snapshot,8> OpticCaptureVisibility::submissions_{};
}
