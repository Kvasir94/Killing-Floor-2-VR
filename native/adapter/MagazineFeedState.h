#pragma once
#include <cstdint>

namespace kf2vr::adapter {
// Availability metadata only. Stock owns every round and all reload counters.
// No event returns an ammo credit or changes the observed stock total.
struct MagazineFeedState {
    enum Flag : int { Ready=1, MagazineOut=2, ChamberLoaded=4, NeedsRack=8, ShotConfirmed=16 };
    enum class Event : int { Observe, Eject, Seat, Rack, Reset, EmptyChamber, Shot, ShotFlushed };
    int flags=0, lastAmmo=0;
    bool Out() const { return (flags & (Ready|MagazineOut))==(Ready|MagazineOut); }
    bool Chamber(int stockAmmo) const { return stockAmmo>0 && (flags & (Ready|ChamberLoaded))==(Ready|ChamberLoaded); }
    bool BlocksFire(int stockAmmo) const {
        return (flags&Ready) && (Out() || (flags&NeedsRack)) && !Chamber(stockAmmo);
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
        if(stockAmmo>lastAmmo && !Out() && !(flags&NeedsRack)) flags|=ChamberLoaded;
        lastAmmo=stockAmmo;
        switch(event) {
        case Event::Eject: flags|=MagazineOut; break;
        case Event::Seat:
            flags&=~MagazineOut;
            if(!(flags&ChamberLoaded)) flags|=NeedsRack;
            break; // Seating cannot chamber.
        case Event::Rack:
            if(!Out() && stockAmmo>0) { flags|=ChamberLoaded; flags&=~NeedsRack; }
            break;
        case Event::EmptyChamber: flags&=~ChamberLoaded; flags|=NeedsRack; break;
        case Event::Shot:
            // Perk/infinite-ammo shots still empty the physical chamber while
            // stock retains its declared ammo-saving behavior.
            if(Out()) { flags&=~ChamberLoaded; flags|=ShotConfirmed; }
            break;
        case Event::ShotFlushed: flags&=~ShotConfirmed; break;
        default: break;
        }
        return true;
    }
};
}
