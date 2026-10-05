#include "../DamagePopupArguments.h"
#include "VmCallbackFilter.h"
#include <cstdio>
#include <stdexcept>
#include <string_view>

using Filter=kf2vr::adapter::VmCallbackFilter;
using Callback=Filter::Callback;

static void Check(bool condition,const char* message) {
    if (!condition) throw std::runtime_error(message);
}

int main() {
    try {
        Filter filter;
        unsigned internCalls=0;
        // Deliberately scramble numeric order so sorted lookup must preserve
        // callback identity. Retain high bits to exercise the full FName value.
        const auto nameFor=[](std::size_t index) {
            return std::uint64_t{0x123400000000ULL}+(Filter::CallbackNames.size()-index)*4+1;
        };
        const auto intern=[&](const wchar_t* text) {
            ++internCalls;
            for (std::size_t i=0;i<Filter::CallbackNames.size();++i)
                if (std::wstring_view(text)==Filter::CallbackNames[i]) return nameFor(i);
            throw std::runtime_error("unexpected name interning");
        };
        const std::uint64_t positionName=0x987600000003ULL;
        Check(filter.Lookup(positionName,positionName,intern)==Callback::SetPosition,
            "pinned SetPosition must remain eligible before cache initialization");
        Check(internCalls==0,"pinned SetPosition must not initialize unrelated callback names");
        Check(filter.Lookup(0,positionName,intern)==Callback::Unrelated,
            "an unrelated FName must pass through");
        Check(internCalls==Filter::CallbackNames.size(),"initialize each callback identity once");
        for (std::size_t i=0;i<Filter::CallbackNames.size();++i) {
            Check(filter.Lookup(nameFor(i),positionName,intern)==static_cast<Callback>(i),
                "every literal callback must round-trip after numeric sorting");
            Check(filter.Lookup(nameFor(i)+1,positionName,intern)==Callback::Unrelated,
                "numeric gaps must not select a neighboring callback");
            Check(filter.Lookup(nameFor(i)+(std::uint64_t{1}<<32),positionName,intern)==Callback::Unrelated,
                "comparison must retain the full 64-bit FName");
        }
        Check(internCalls==Filter::CallbackNames.size(),"warm lookup must not repeat string interning");
        Check(filter.Lookup(positionName+1,positionName+1,intern)==Callback::SetPosition,
            "the live pinned SetPosition name must be supplied on every lookup");
        Check(filter.Lookup(positionName,positionName+1,intern)==Callback::Unrelated,
            "do not retain an earlier pinned SetPosition name");
        Check(Filter::Groups(Callback::SetPosition)==0 && Filter::Groups(Callback::Unrelated)==0,
            "position and unrelated callbacks must skip all weapon helper groups");
        Check(Filter::Groups(Callback::ScoreDamage)==0,
            "damage accounting must not enter weapon or perk scopes");
        Check(Filter::Groups(Callback::PlayWeaponAnimation)==0,
            "reload audio animation callback must not enter aim, recoil, perk or effect scopes");
        Check(Filter::Groups(Callback::FireAmmunition)==(Filter::BeginAim|Filter::Handling|Filter::Perk),
            "a shot must enter the aim, handling and perk scopes");
        Check(Filter::Groups(Callback::TakeDamage)==Filter::Perk && Filter::Groups(Callback::UpdateGroundSpeed)==Filter::Perk,
            "a hit and a speed update must enter only the perk scope");
        Check(Filter::Groups(Callback::SetSprinting)==Filter::Sprint,
            "the negative sprint guard must remain eligible");
        Check(Filter::Groups(Callback::ClearAllPendingFire)==Filter::PendingFire,
            "pending fire cancellation must remain eligible without a current pose");
        Check(Filter::Groups(Callback::SetFlashLocation)==Filter::Effects,
            "array-dispatched effect receipts must remain eligible");
        Check(Filter::Groups(Callback::GetWeaponStartTraceLocation)==Filter::FinishAim,
            "explicit-item and no-item trace fallback must run after the original body");
        {
            using namespace kf2vr::adapter;
            std::array<std::byte,64> buffer{};
            void* victim=reinterpret_cast<void*>(std::uintptr_t{0x12340});
            void* kind=reinterpret_cast<void*>(std::uintptr_t{0x56780});
            const DamagePopupArgumentField v{0,sizeof(void*)},a{8,sizeof(std::int32_t)},packed{12,sizeof(void*)},aligned{16,sizeof(void*)};
            for (auto k:{packed,aligned}) {
                Check(WriteDamagePopupArguments(buffer,v,a,k,victim,37,kind),"accept reflected packed and aligned pointer layouts including offset zero");
                void* decodedVictim=nullptr;void* decodedKind=nullptr;std::int32_t decodedAmount=0;
                std::memcpy(&decodedVictim,buffer.data()+v.offset,sizeof(decodedVictim));
                std::memcpy(&decodedAmount,buffer.data()+a.offset,sizeof(decodedAmount));
                std::memcpy(&decodedKind,buffer.data()+k.offset,sizeof(decodedKind));
                Check(decodedVictim==victim && decodedKind==kind && decodedAmount==37,"write arguments at reflected offsets");
            }
            const auto before=buffer;
            Check(!WriteDamagePopupArguments(buffer,v,a,{8,sizeof(void*)},victim,37,kind),"reject overlapping argument fields");
            Check(!WriteDamagePopupArguments(buffer,v,a,{63,sizeof(void*)},victim,37,kind),"reject an argument extending beyond the buffer");
            Check(!WriteDamagePopupArguments(buffer,v,{8,2},packed,victim,37,kind),"reject mismatched reflected integer width");
            Check(!WriteDamagePopupArguments(buffer,v,a,{0xffffffffu,sizeof(void*)},victim,37,kind),"reject overflow-range offsets");
            Check(buffer==before,"metadata rejection leaves the parameter buffer unchanged");
        }
        std::puts("PASS: numeric callback round-trip, cached lookup, pinned identity, and overlapping helper groups.");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr,"FAIL: %s\n",error.what());
        return 1;
    }
}
