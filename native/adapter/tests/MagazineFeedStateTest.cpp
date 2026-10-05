#include "MagazineFeedState.h"
#include "EmptyMagazineState.h"
#include <cstdio>
#include <limits>

using State=kf2vr::adapter::MagazineFeedState;
using Event=State::Event;
int checks=0,failures=0;
void Check(bool pass,const char* label) { ++checks; if(!pass) { ++failures; std::printf("FAIL %s\n",label); } }

int main() {
    // The production policy is called with real stock snapshots. It has no
    // reserve, credit, capacity or writable ammo argument: ownership stays stock.
    for(int initial=0; initial<=16; ++initial) {
        State state;
        int stock=initial, reserve=23, spent=0;
        Check(state.Apply(Event::Observe,stock),"initialize from stock");
        Check(state.Chamber(stock)==(initial>0),"initial live/empty chamber");
        const int total=stock+reserve;
        Check(state.Apply(Event::Eject,stock) && state.Out(),"eject changes presence only");
        Check(stock+reserve==total,"ejection preserves all owned rounds");
        Check(state.DisplayAmmo(stock)==(initial>0?1:0),"magazine-out HUD shows the chamber only");
        // Refused StartFire and duplicate trigger intent have no ammo decrease.
        for(int press=0; press<3; ++press) state.Apply(Event::Observe,stock);
        Check(state.Chamber(stock)==(initial>0),"refused shot cannot clear or recreate the chamber");
        if(state.Chamber(stock)) { --stock; ++spent; }
        state.Apply(Event::Observe,stock);
        Check(!state.Chamber(stock),"one confirmed shot empties magazine-out chamber");
        Check(stock+reserve+spent==total && spent==(initial>0?1:0),"exactly one shot conserved");
        for(int press=0; press<8; ++press) {
            state.Apply(Event::Eject,stock);
            state.Apply(Event::Observe,stock);
            state.Apply(Event::Rack,stock);
            if(state.Chamber(stock)) { --stock; ++spent; }
        }
        Check(spent==(initial>0?1:0) && stock+reserve+spent==total,
              "repeated eject, dry press and rack with magazine out cannot feed or duplicate");
        State transferred=state;
        State other;
        other.Apply(Event::Observe,7);
        Check(transferred.flags==state.flags && transferred.lastAmmo==state.lastAmmo,
              "stow and hand transfer retain exact actor metadata");
        transferred.Apply(Event::Observe,stock);
        Check(!transferred.Chamber(stock) && other.Chamber(7),"independent weapons keep independent chambers");
        transferred.Apply(Event::Seat,stock);
        Check(!transferred.Out() && !transferred.Chamber(stock),"reinsertion without feed cannot chamber");
        for(int repeat=0; repeat<4; ++repeat) transferred.Apply(Event::Seat,stock);
        Check(stock+reserve+spent==total && !transferred.Chamber(stock),"duplicate seat events create no rounds or chamber");
        transferred.Apply(Event::Rack,stock);
        Check(transferred.Chamber(stock)==(stock>0),"rack feeds only from a seated nonempty stock load");
        for(int repeat=0; repeat<4; ++repeat) transferred.Apply(Event::Rack,stock);
        Check(stock+reserve+spent==total,"repeated rack changes availability only");
    }
    {
        State state;
        // Golden stock snapshots: four loaded, two reserve; chamber fired;
        // stock reload credits two, leaving five loaded and no reserve.
        state.Apply(Event::Observe,4);
        state.Apply(Event::Eject,4);
        state.Apply(Event::Observe,3);
        state.Apply(Event::Seat,5);
        Check(!state.Out() && !state.Chamber(5) && state.lastAmmo==5,
              "partial reload after chamber shot retains five, requires rack");
        state.Apply(Event::Observe,5);
        Check(!state.Chamber(5),"observing credited rounds is not chambering");
        state.Apply(Event::Rack,5);
        Check(state.Chamber(5) && state.DisplayAmmo(5)==5,"physical rack unlocks the conserved five-round load");
    }
    {
        State state;
        state.Apply(Event::Observe,4);
        state.Apply(Event::Eject,4);
        state.Apply(Event::Seat,6);
        Check(state.Chamber(6),"ordinary partial top-up retains its unfired chamber");
        state.Apply(Event::Eject,6);
        state.Apply(Event::Observe,5);
        state.Apply(Event::Observe,6); // Replication correction, not a physical feed.
        Check(!state.Chamber(6),"upward correction cannot rearm a spent magazine-out chamber");
    }
    {
        State state;
        state.Apply(Event::Observe,0);
        state.Apply(Event::Eject,0);
        state.Apply(Event::Seat,15);
        Check(!state.Chamber(15) && state.DisplayAmmo(15)==15,"empty reload shows stock capacity but still needs rack");
        state.Apply(Event::EmptyChamber,15);
        state.Apply(Event::Observe,15);
        Check(!state.Chamber(15),"interrupted pending lock cannot become a chamber on observation");
        state.Apply(Event::Rack,15);
        state.Apply(Event::Eject,15);
        Check(state.DisplayAmmo(15)==1,"full magazine removal still exposes only one chamber round");
    }
    {
        State unknown;
        Check(!unknown.Apply(Event::Seat,15) && unknown.flags==0,
              "unknown seat cannot infer an existing chamber from total rounds");
        Check(!unknown.Apply(Event::Rack,15) && unknown.flags==0,
              "unknown rack cannot bypass policy initialization");
    }
    {
        State state;
        state.Apply(Event::Observe,1);
        state.Apply(Event::Observe,0);
        state.Apply(Event::Observe,15);
        Check(state.Chamber(15),"ordinary button reload outside physical feed retains stock auto-chamber behavior");
        state.Apply(Event::Reset,15);
        Check(state.flags==0 && state.lastAmmo==15,"turning physical reload off relinquishes availability metadata only");
        state.Apply(Event::Observe,15);
        Check(state.Chamber(15),"stock mode returns with no retained physical gate");
    }
    {
        State left, right;
        left.Apply(Event::Observe,5); left.Apply(Event::Eject,5);
        right.Apply(Event::Observe,9);
        left.Apply(Event::Observe,4);
        Check(!left.Chamber(4) && right.Chamber(9),"opposite gun firing cannot rearm the empty chamber");
        left.Apply(Event::Reset,4); // Stock accepts the existing two-gun reload fallback.
        Check(left.flags==0 && left.lastAmmo==4 && right.lastAmmo==9,
              "two-gun fallback relinquishes only exact item availability, no ammo transfer");
        left.Apply(Event::Observe,15);
        Check(left.Chamber(15) && right.Chamber(9),"button reload feeding remains independent per gun");
    }
    {
        State state;
        state.Apply(Event::Observe,5);
        state.Apply(Event::Eject,5);
        const State before=state;
        Check(!state.Apply(Event::Observe,-1),"invalid negative stock snapshot refused");
        Check(!state.Apply(static_cast<Event>(99),5),"invalid transition refused");
        Check(state.flags==before.flags && state.lastAmmo==before.lastAmmo,"rejected updates leave state intact");
        state.Apply(Event::Observe,std::numeric_limits<int>::max());
        Check(state.Out() && state.DisplayAmmo(std::numeric_limits<int>::max())==1,
              "large stock corrections do not expose retained magazine rounds");
    }
    {
        State state;
        state.Apply(Event::Observe,7); state.Apply(Event::Eject,7);
        state.Apply(Event::Shot,7); // Ammo-saving perk confirmed the shot without decreasing stock.
        Check(!state.Chamber(7) && state.DisplayAmmo(7)==0 && state.lastAmmo==7,
              "ammo-saving shot empties chamber without changing stock totals");
        Check((state.flags & State::ShotConfirmed)!=0,"confirmed shot requests stock RPC flush");
        state.Apply(Event::Observe,7); state.Apply(Event::Eject,7);
        Check(!state.Chamber(7),"unchanged stock snapshots cannot feed a second perk shot");
        state.Apply(Event::ShotFlushed,7);
        Check((state.flags & State::ShotConfirmed)==0 && !state.Chamber(7),
              "completed RPC flush clears its marker without feeding");
        const int flags=state.flags;
        state.Apply(Event::ShotFlushed,7);
        Check(state.flags==flags && state.lastAmmo==7,"duplicate flush is idempotent");
        state.Apply(Event::Seat,7);
        Check(!state.Chamber(7),"perk shot still requires a rack after seating");
        state.Apply(Event::Rack,7);
        Check(state.Chamber(7) && state.lastAmmo==7,"rack restores feed without creating perk ammunition");
        state.Apply(Event::Shot,7);
        Check((state.flags & State::ShotConfirmed)==0,"seated ordinary shot creates no magazine-out flush");
    }
    {
        using Empty=kf2vr::adapter::EmptyMagazineState;
        using E=Empty::Event;
        for (int action=0; action<=3; ++action) {
            Empty weapon;
            int stock=0, reserve=0;
            Check(weapon.Apply(E::Eject,stock,action) && (weapon.flags&Empty::Removed),
                  "zero-reserve empty ejection is admitted");
            Check(stock==0 && reserve==0,"empty ejection creates no ammunition");
            const auto removed=weapon.flags;
            Check(weapon.Apply(E::Eject,stock,action) && weapon.flags==removed,
                  "duplicate empty ejection preserves presence metadata");
            Check(!weapon.Apply(E::Seat,stock,action) && weapon.flags==removed,
                  "missing reserve cannot produce a seated loaded magazine");
            Empty stowed=weapon, other;
            Check(stowed.flags==removed && other.flags==0,
                  "stow and switching retain state only on the exact weapon");
            reserve=12; // A stock pickup changes reserve, not load/presence.
            Check(stowed.flags==removed && stock==0,"later ammo pickup cannot reinsert the magazine");
            stock=12; reserve=0; // Only stock PerformReload pays this transition.
            Check(stowed.Apply(E::Seat,stock,action) && !(stowed.flags&Empty::Removed),
                  "stock-credited later reload seats the replacement");
            Check(bool(stowed.flags&Empty::NeedsAction)==(action!=2),
                  "closed, open and notch actions remain gated; no-action loads are ready");
            Empty redrawn=stowed;
            Check(redrawn.flags==stowed.flags,"interrupted action survives redraw");
            if (action!=2) Check(redrawn.Apply(E::Action,stock,action) && redrawn.flags==0,
                                 "resumed action completes without another ammo credit");
            Check(stock==12 && reserve==0,"seat and action metadata never change stock totals");
            Empty loaded;
            Check(!loaded.Apply(E::Eject,stock,action) && loaded.flags==0,
                  "empty-only policy cannot infer a chamber on loaded removal");
        }
        Empty open;
        open.Apply(E::Eject,0,1);
        Check(open.Apply(E::Action,0,1) && (open.flags&Empty::Cocked),
              "open bolt may cock without a magazine or reserve");
        const auto cocked=open.flags;
        open.Apply(E::Eject,0,1);
        Check(open.flags==cocked,"duplicate ejection does not uncock an open bolt");
        Check(open.Apply(E::Seat,9,1) && open.flags==0,
              "cock-before-seat open bolt needs no invented chamber or second rack");
        Empty closed;
        closed.Apply(E::Eject,0,0);
        const auto flags=closed.flags;
        Check(!closed.Apply(E::Action,0,0) && closed.flags==flags,
              "closed bolt cannot feed from an absent magazine");
        Check(!closed.Apply(E::Eject,-1,0) && !closed.Apply(E::Seat,7,4)
              && !closed.Apply(static_cast<E>(7),0,0) && closed.flags==flags,
              "invalid empty-policy snapshots and actions leave state intact");
        Check(closed.Apply(E::Reset,0,0) && closed.flags==0,
              "explicit stock-mode fallback clears metadata only");
    }
    std::printf("Magazine feed checks=%d failures=%d\n",checks,failures);
    return failures?1:0;
}
