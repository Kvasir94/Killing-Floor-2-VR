# Engine-independent VR core: poses, calibration, comfort, input state.
#
# Hard rule: this target links nothing game-specific, nothing Windows-specific
# and nothing XR-runtime-specific. It is the part of the project that can be
# reasoned about and tested without a headset, a GPU or a copy of KF2, and it
# stops being that the moment a dependency creeps in.
add_library(kf2vr_core STATIC
  src/InputState.cpp
)

target_include_directories(kf2vr_core PUBLIC include)
target_compile_features(kf2vr_core PUBLIC cxx_std_20)
