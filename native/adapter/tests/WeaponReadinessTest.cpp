#include "WeaponReadiness.h"
#include <cstdio>
#include <initializer_list>
#include <cstdint>
#include <initializer_list>

using namespace kf2vr::adapter;
int checks=0,failures=0;
void Check(bool value,const char* message) {
    ++checks;
    if (!value) { ++failures; std::printf("FAIL %s\n",message); }
}

int main() {
    // The same gate precedes base, derived and delayed refire callbacks. A
    // no-chamber energy load must stay blocked after a positive stock ammo
    // correction until its own seat event retires the removed magazine.
    for (int ammo : {0,1,15,100}) {
        WeaponReadiness gun;
        gun.feedModeMask=3;
        gun.empty.Apply(EmptyMagazineState::Event::Eject,0,2);
        for (int callback=0;callback<8;++callback) {
            Check(gun.BlocksShot(0,ammo,true) && gun.BlocksShot(1,ammo,true),
                  "derived custom shots cannot fire through a removed no-chamber load");
            Check(gun.empty.flags==EmptyMagazineState::Removed,
                  "repeated shot checks cannot seat or pay the removed load");
        }
        gun.empty.Apply(EmptyMagazineState::Event::Seat,ammo,2);
        Check(!gun.BlocksShot(0,ammo,true) && !gun.BlocksShot(1,ammo,true),
              "the physical seat restores stock fire eligibility without inventing an action");
    }
    {
        WeaponReadiness gun;
        gun.finishProfileToken=4;
        gun.finishModeMask=3;
        // A different reload owner may reset magazine metadata, while the
        // paid finishing obligation still belongs to this exact weapon.
        for (int callback=0;callback<8;++callback)
            Check(gun.BlocksShot(0,30,true) && gun.BlocksShot(1,30,true),
                  "paid finish blocks both same-ammo modes without a feed tracker");
        gun.finishModeMask=1;
        Check(!gun.BlocksShot(1,30,true),"separate secondary ammunition retains stock eligibility");
        gun.finishProfileToken=0;
        Check(!gun.BlocksShot(0,30,true),"completed action retires its gate once");
        gun.cylinderClosePending=true;
        Check(gun.BlocksShot(0,6,true) && !gun.BlocksShot(1,6,true),
              "M32 cylinder close blocks only its primary round");
        gun.secondaryBlocked=true;
        Check(gun.BlocksShot(1,6,true),"FAMAS secondary seat/action blocks secondary fire");
        for (int mode : {-1,2,3,4,5,6,31,255})
            Check(!gun.BlocksShot(mode,6,true),"reload, bash and equipment are outside the round gate");
    }
    {
        WeaponReadiness gun;
        gun.feedModeMask=1;
        gun.feed.Apply(MagazineFeedState::Event::Observe,8);
        gun.feed.Apply(MagazineFeedState::Event::Eject,8);
        Check(!gun.BlocksShot(0,8,true) && gun.BlocksShot(0,8,false),
              "only realistic rules allow the retained chamber shot");
        gun.feed.Apply(MagazineFeedState::Event::Shot,8); // ammo-saving perk
        Check(gun.BlocksShot(0,8,true),"the second callback cannot reuse a perk-preserved chamber");
        Check(!gun.BlocksShot(1,8,true),"separate secondary remains available with primary removed");
        gun.feed.Apply(MagazineFeedState::Event::Seat,15);
        Check(gun.BlocksShot(0,15,true),"positive stock reload payment cannot finish the rack");
        gun.feed.Apply(MagazineFeedState::Event::Rack,15);
        Check(!gun.BlocksShot(0,15,true),"explicit rack restores the funded feed");
    }
    {
        // Deterministic interruption chains exercise the production feed and
        // readiness policies together. The RNG chooses only interruptions;
        // it neither implements a second reload model nor alters ammunition.
        std::uint32_t seed=0x4b463256;
        const auto next=[&] { seed=seed*1664525u+1013904223u; return seed; };
        for (int sequence=0;sequence<1024;++sequence) {
            const int stock=1+int(next()%100);
            WeaponReadiness gun,other;
            gun.feedModeMask=1;
            other.feedModeMask=1;
            gun.feed.Apply(MagazineFeedState::Event::Observe,stock);
            other.feed.Apply(MagazineFeedState::Event::Observe,7);
            gun.feed.Apply(MagazineFeedState::Event::Eject,stock);
            gun.feed.Apply(MagazineFeedState::Event::Shot,stock); // stock perk saves the round
            for (int interruption=0;interruption<32;++interruption) {
                switch(next()%5) {
                case 0: gun.feed.Apply(MagazineFeedState::Event::Observe,stock); break;
                case 1: gun.feed.Apply(MagazineFeedState::Event::Eject,stock); break;
                case 2: gun.feed.Apply(MagazineFeedState::Event::ShotFlushed,stock); break;
                case 3: { const auto stowed=gun; gun=stowed; break; }
                default: gun.BlocksShot(1,stock,true); break; // separate-ammo attempt
                }
                Check(gun.BlocksShot(0,stock,(next()&1)!=0),
                      "arbitrary refire/flush/stow/alternate chains cannot recreate the spent chamber");
                Check(gun.feed.lastAmmo==stock && other.feed.Chamber(7) && other.feed.lastAmmo==7,
                      "interruption metadata neither pays ammo nor changes the opposite weapon");
            }
            gun.feed.Apply(MagazineFeedState::Event::Seat,stock);
            Check(gun.BlocksShot(0,stock,true),"every interrupted chain preserves the seat-to-rack obligation");
            gun.feed.Apply(MagazineFeedState::Event::Rack,stock);
            Check(!gun.BlocksShot(0,stock,true),"every interrupted chain remains recoverable by the real rack");
        }
    }
    std::printf("Weapon readiness checks=%d failures=%d\n",checks,failures);
    return failures ? 1 : 0;
}
