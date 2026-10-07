#pragma once
namespace kf2vr::adapter {
// No-chamber removal metadata: unlike MagazineFeedState this never represents
// a chamber or permits a magazine-out shot. Stock owns every round.
struct EmptyMagazineState {
    enum Flag { Removed=1, NeedsAction=2, Cocked=4 };
    enum class Event { Eject, Seat, Action, Reset };
    int flags=0;
    bool BlocksFire() const { return (flags&(Removed|NeedsAction))!=0; }
    bool Apply(Event event, int stockAmmo, int actionKind) {
        if (stockAmmo<0 || actionKind<0 || actionKind>3 ||
            static_cast<int>(event)<0 || static_cast<int>(event)>3) return false;
        if (event==Event::Reset) { flags=0; return true; }
        if (event==Event::Eject) {
            // Exact catalog open bolts may remove a loaded magazine too.
            // A loaded idle open bolt is cocked; an interrupted, unworked
            // empty reload must retain NeedsAction instead of inventing it.
            if (stockAmmo!=0 && actionKind!=1) return false;
            if (!(flags&Removed)) {
                if (stockAmmo>0) {
                    flags|=Removed;
                    if (!(flags&NeedsAction)) flags|=Cocked;
                } else flags=Removed|(actionKind==2?0:NeedsAction);
            }
            return true;
        }
        if (event==Event::Seat) {
            if (!(flags&Removed) || stockAmmo==0) return false;
            flags&=~Removed;
            if (actionKind==2 || (actionKind==1 && (flags&Cocked))) flags=0;
            return true;
        }
        if (flags&Removed) {
            if (actionKind!=1) return false;
            flags|=Cocked; // Open bolt reaches its sear before ammunition seats.
            return true;
        }
        if (!(flags&NeedsAction) || stockAmmo==0) return false;
        flags=0;
        return true;
    }
};
}
