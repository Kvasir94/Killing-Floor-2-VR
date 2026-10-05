#include "PresentHandoff.h"
#include <cstdio>
#include <stdexcept>

using kf2vr::adapter::PresentHandoff;
using kf2vr::adapter::PresentOwnerScope;
using Action=PresentHandoff::OwnerAction;
static void Check(bool value,const char* message) {
    if (!value) throw std::runtime_error(message);
}
int main() {
    try {
        PresentHandoff handoff;
        std::uint64_t ticket=0;
        Check(handoff.Action(ticket)==Action::Continue,"ordinary owner needs no recovery");
        Check(handoff.Action(ticket,true)==Action::Wait,"engine loading movie blocks XR before first movie Present");
        handoff.BeginForeign();
        Check(handoff.Action(ticket)==Action::Wait,"movie in flight cannot recover XR");
        { PresentOwnerScope blocked(handoff); Check(!blocked,"owner cannot enter XR during movie Present"); }
        handoff.EndForeign();
        Check(handoff.Action(ticket,true)==Action::Wait,"gap between loading movie Presents is not movie completion");
        Check(handoff.Action(ticket)==Action::Discard,"finished movie invalidates pre-load frame even without script travel");
        const auto first=ticket;
        handoff.Complete(ticket);
        Check(handoff.Action(ticket)==Action::Continue,"one recovery permits fresh owner frame");

        // Multiple loading frames coalesce, and a later receipt cannot be
        // accidentally cleared by acknowledging an earlier recovery ticket.
        handoff.BeginForeign(); handoff.EndForeign();
        Check(handoff.Action(ticket)==Action::Discard,"second load requires recovery");
        const auto earlier=ticket;
        handoff.BeginForeign(); handoff.BeginForeign();
        handoff.EndForeign();
        Check(handoff.Action(ticket)==Action::Wait,"all movie Presents must return");
        handoff.EndForeign(); handoff.Complete(earlier);
        Check(handoff.Action(ticket)==Action::Discard && ticket>earlier && earlier>first,
            "late handoff receipt survives old acknowledgment");
        handoff.Complete(ticket);
        Check(handoff.Action(ticket)==Action::Continue,"latest receipt acknowledged exactly once");

        // A completed eye atlas/pending XR frame must be cancelled, not reused.
        bool pending=true,atlasReady=true;
        unsigned cancelledFrames=0;
        handoff.BeginForeign(); handoff.EndForeign();
        if (handoff.Action(ticket)==Action::Discard) {
            PresentOwnerScope owner(handoff);
            Check(bool(owner),"native-only recovery can run after movie completes");
            if (pending) { ++cancelledFrames; pending=false; }
            atlasReady=false; handoff.Complete(ticket);
        }
        Check(!pending && !atlasReady && cancelledFrames==1,"pre-load frame balanced without stale atlas submission");
        Check(handoff.Action(ticket)==Action::Continue,"discard does not repeat next frame");

        // The real failure alternated movie Presents with world/menu draws.
        // World initialization can finish while the delayed-stop movie still
        // owns presentation: none of those gaps may start another XR frame.
        PresentHandoff loading;
        for (int i=0;i<650;++i) {
            loading.BeginForeign(); loading.EndForeign();
            Check(loading.Action(ticket,true)==Action::Wait,
                "repeated world draws during loading cannot resume XR between movie frames");
        }
        Check(loading.Action(ticket,false)==Action::Discard,
            "actual engine movie completion permits one deferred recovery");
        loading.Complete(ticket);
        Check(loading.Action(ticket,false)==Action::Continue,
            "normal rendering resumes after the movie lifetime ends");

        PresentHandoff unsafe;
        {
            PresentOwnerScope nativeSubmit(unsafe);
            Check(bool(nativeSubmit),"owner enters native XR submission");
            unsafe.BeginForeign(); unsafe.EndForeign();
        }
        Check(unsafe.Action(ticket)==Action::UnsafeOverlap,"actual overlap with native XR work remains fatal");
        unsafe.Complete(ticket);
        Check(unsafe.Action(ticket)==Action::UnsafeOverlap,"acknowledgment cannot hide unsafe overlap");
        std::puts("Present handoff policy passed (no XR or game launched)");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr,"Present handoff test failed: %s\n",error.what()); return 1;
    }
}
