#pragma once

namespace kf2vr::adapter {
// A menu frame owns two world views and one UI-only viewport. Always restore
// the stock movie/viewport flags, including partial setup and render failures.
struct MenuRenderSink {
    virtual ~MenuRenderSink()=default;
    virtual bool BeginWorld()=0;
    virtual bool WorldEye(unsigned eye)=0;
    virtual bool BeginImage()=0;
    virtual bool Image()=0;
    virtual bool Restore() noexcept=0;
};
inline bool RenderMenuLayers(MenuRenderSink& sink,bool includeWorld=true) {
    struct RestoreScope {
        MenuRenderSink& sink;
        bool restored=false;
        ~RestoreScope() { if (!restored) sink.Restore(); }
        bool Finish() { restored=true; return sink.Restore(); }
    } scope{sink};
    const bool rendered=sink.BeginWorld() && (!includeWorld || (sink.WorldEye(0) && sink.WorldEye(1)))
        && sink.BeginImage() && sink.Image();
    return scope.Finish() && rendered;
}
}
