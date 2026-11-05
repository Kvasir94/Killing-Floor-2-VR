#pragma once
#include "MagazineFeedState.h"
#include "EmptyMagazineState.h"

namespace kf2vr::adapter {
// Persistent per-item obligations gate every stock FireAmmunition body,
// including weapons that implement their own shot without calling KFWeapon.
// This policy only observes stock ammunition; it never pays or consumes it.
struct WeaponReadiness {
    int feedModeMask=0, finishProfileToken=0, finishModeMask=0;
    bool secondaryBlocked=false, cylinderClosePending=false;
    EmptyMagazineState empty;
    MagazineFeedState feed;

    bool BlocksShot(int mode, int stockAmmo, bool realistic) {
        // Reload, bash, grenade and equipment modes keep their stock policy.
        if (mode<0 || mode>1) return false;
        if ((mode==1 && secondaryBlocked) || (mode==0 && cylinderClosePending)) return true;
        if (finishProfileToken>0 && (finishModeMask&(1<<mode))) return true;
        if (!(feedModeMask&(1<<mode))) return false;
        if (empty.BlocksFire()) return true;
        if (!(feed.flags&MagazineFeedState::Ready)) return false;
        return feed.Apply(MagazineFeedState::Event::Observe,stockAmmo) && feed.BlocksFire(stockAmmo,realistic);
    }
};
}
