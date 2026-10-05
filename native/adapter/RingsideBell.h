#pragma once

// Boxing-glove ringside bell (script VRBoxingGloves). A recorded CC0 bell
// embedded as WAVE resources (assets/RingsideBell.rc), played on the default
// Windows audio device for the local player only.
namespace kf2vr::adapter {

enum RingsideBellCue : int {
    kBellDing=1,   // the gloves start charging
    kBellReady=2,  // ding-ding-ding: fully charged
};

// Plays the loudest requested cue in the mask; later cues cut earlier ones off.
void PlayRingsideBell(int cueMask);

}
