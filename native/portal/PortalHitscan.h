#pragma once

#include <atomic>
#include <cstdint>
#include "../adapter/GameScript.h"


namespace kf2vr::portal {

// Reuses the adapter's existing ProcessInternal hook. It never hooks global
// collision traces, changes stock weapon classes, or calls damage itself.
class PortalHitscan {
public:
    using LogFn=void(*)(const char*,...);
    void Initialise(std::uintptr_t gameBase,LogFn log);
    void Refresh(void* localPlayer,void* gun);
    bool Effects(void* object,void* frame);
    bool ProjectileWall(void* object,void* frame);
    bool Route(void* object,void* frame,void* result);
    void Reset();
    std::uint64_t RoutedCalls() const { return routedCalls_; }
private:
    bool LocalPawn(void*& pawn);
    bool Alive(void* object,const wchar_t* type);
    adapter::GameScript script_;
    std::uintptr_t base_{};
    std::atomic<std::uint32_t> thread_{};
    void* localPlayer_{};
    void* pawn_{};
    void* gun_{};
    void* bridge_{};
    void* stockFunction_{};
    LogFn log_{};
    unsigned depth_{};
    unsigned report_{};
    std::uint64_t routedCalls_{};
};

} // namespace kf2vr::portal
