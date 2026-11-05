#pragma once
#include "LoadingPlate.h"

namespace kf2vr::adapter {

// The branded loading plate: the game's own installed splash artwork
// (KFGame\Splash\PC\Splash.bmp beside the running executable's install, never
// a shipped copy) framed by a VIRTUAL REALITY header and a LOADING label. One
// static image; no animation or simulated progress. Returns an empty image
// when the splash is missing or GDI fails, so the caller keeps the generated
// plate.
LoadingPlateImage BrandedLoadingPlate(const wchar_t* gameExecutable,std::uint32_t width,std::uint32_t height);

} // namespace kf2vr::adapter
