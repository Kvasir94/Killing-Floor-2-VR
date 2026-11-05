#pragma once
#include <cstdint>

namespace kf2vr::adapter {
// Availability metadata only. Stock owns every round and all reload counters.
// No event returns an ammo credit or changes the observed stock total.
struct MagazineFeedState {
    enum Flag : int { Ready=1, MagazineOut=2, ChamberLoaded=4, NeedsRack=8, ShotConfirmed=16,
                     UnlockedEmpty=32 };
    enum class Event : int { Observe, Eject, Seat, Rack, Reset, EmptyChamber, Shot, ShotFlushed };
    int flags=0, lastAmmo=0;
    bool Out() const { return (flags & (Ready|MagazineOut))==(Ready|MagazineOut); }
    bool Chamber(int stockAmmo) const { return stockAmmo>0 && (flags & (Ready|ChamberLoaded))==(Ready|ChamberLoaded); }
    // Realistic ammo off keeps stock round rules: nothing fires while the
    // magazine is out, chambered or not. An unracked seat still waits either way.
    bool BlocksFire(int stockAmmo, bool realistic=true) const {
        if (!(flags&Ready)) return false;
        if (Out() && !realistic) return true;
        return (Out() || (flags&NeedsRack)) && !Chamber(stockAmmo);
    }
    int DisplayAmmo(int stockAmmo) const { return Out() ? (Chamber(stockAmmo)?1:0) : stockAmmo; }
    bool Apply(Event event,int stockAmmo) {
        if(stockAmmo<0 || static_cast<int>(event)<0 || static_cast<int>(event)>7) return false;
        if(event==Event::Reset) { flags=0; lastAmmo=stockAmmo; return true; }
        if(!(flags&Ready)) {
            if(event!=Event::Observe && event!=Event::Eject) return false;
            flags=Ready|(stockAmmo>0?ChamberLoaded:0);
        }
        // A decrease confirms actual consumption, not merely trigger intent.
        // Replicated corrections fail closed while the magazine is out.
        if(stockAmmo==0 || (stockAmmo<lastAmmo && Out())) flags&=~ChamberLoaded;
        // Unaudited/button reloads retain ordinary stock automatic feeding.
        if(stockAmmo>lastAmmo && !Out() && !(flags&NeedsRack)) {
            flags|=ChamberLoaded; flags&=~UnlockedEmpty;
        }
        lastAmmo=stockAmmo;
        switch(event) {
        case Event::Eject: flags|=MagazineOut; break;
        case Event::Seat:
            flags&=~MagazineOut;
            if(!(flags&ChamberLoaded)) flags|=NeedsRack;
            break; // Seating cannot chamber.
        case Event::Rack:
            // Without a magazine follower, releasing the action closes it;
            // an empty chamber alone cannot engage the last-round catch.
            if(Out()) flags|=UnlockedEmpty;
            else {
                flags&=~UnlockedEmpty;
                if(stockAmmo>0) { flags|=ChamberLoaded; flags&=~NeedsRack; }
            }
            break;
        case Event::EmptyChamber:
            flags&=~ChamberLoaded; flags|=NeedsRack;
            // Losing the hand at the rear stop must not invent a follower
            // catch when the magazine is absent.
            if(Out()) flags|=UnlockedEmpty;
            break;
        case Event::Shot:
            // Perk/infinite-ammo shots still empty the physical chamber while
            // stock retains its declared ammo-saving behavior.
            if(Out()) { flags&=~ChamberLoaded; flags|=ShotConfirmed|UnlockedEmpty; }
            break;
        case Event::ShotFlushed: flags&=~ShotConfirmed; break;
        default: break;
        }
        return true;
    }
};
}
