#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <type_traits>

namespace kf2vr::adapter::pinned {

// Exact pinned-build evidence: native GetWorldInfo 0x7e29d0;
// GetCurrentNetMode 0x889f80 -> 0x7e1940; controller Tick 0x582000;
// local-player CalcSceneView 0x6746a0. See docs/re/04-head-aim-and-world-gate.md.
inline constexpr std::uintptr_t kWorldPointerRva = 0x221c080;
inline constexpr std::size_t kWorldPersistentLevel = 0x80;
inline constexpr std::size_t kWorldNetDriver = 0x120;
inline constexpr std::size_t kLevelActorData = 0x60;
inline constexpr std::size_t kLevelActorCount = 0x68;
inline constexpr std::size_t kLevelActorCapacity = 0x6c;
inline constexpr std::size_t kWorldInfoNetMode = 0x664;
inline constexpr std::size_t kLocalPlayerController = 0x68;
inline constexpr std::size_t kActorWorldInfo = 0x11c;
inline constexpr std::size_t kActorRotation = 0x8c;

enum class LocalWorldStatus {
    Unreadable,
    InvalidActorArray,
    ControllerWorldMismatch,
    NetworkMode,
    NetworkDriver,
    Standalone
};

struct LocalWorldSnapshot {
    std::uintptr_t world{}, level{}, worldInfo{}, controller{}, netDriver{};
    std::uint8_t netMode = 4; // SDK ENetMode_MAX / no world
    LocalWorldStatus status = LocalWorldStatus::Unreadable;
};

// The caller supplies current reflected package/handshake state. An ordinary
// network world remains rejected unless this launch explicitly opts in.
inline bool IsAdmittedNetworkClient(const LocalWorldSnapshot& world, bool requested,
                                    bool expectedController, int handshakeReady) {
    return requested && expectedController && handshakeReady==1 &&
        world.status==LocalWorldStatus::NetworkMode && world.netMode==3 &&
        world.world && world.worldInfo && world.controller && world.netDriver;
}

// The reader validates and copies a requested range; it returns bool and has
// signature (uintptr_t source, void* destination, size_t bytes). This helper
// does not dereference process memory, invoke the engine, or perform writes.
// The caller owns the executable hash gate and executes this on the game
// thread, immediately before each operation that requires standalone mode.
// A successful result is a current-world restriction, not prevention of travel
// or an anti-cheat approval. Recheck after travel; never cache a true result.
template<class Reader>
bool CheckStandaloneWorld(std::uintptr_t gameBase, std::uintptr_t localPlayer,
                          Reader&& reader, LocalWorldSnapshot& out,
                          std::uintptr_t worldPointerRva=kWorldPointerRva) {
    LocalWorldSnapshot value;
    auto read = [&](std::uintptr_t object, std::size_t offset, auto& target) {
        using T = std::remove_reference_t<decltype(target)>;
        static_assert(std::is_trivially_copyable_v<T>);
        constexpr auto maximum = (std::numeric_limits<std::uintptr_t>::max)();
        if (!object || offset > maximum - object || sizeof(T) > maximum - (object + offset))
            return false;
        return reader(object + offset, static_cast<void*>(&target), sizeof(T));
    };
    auto finish = [&](LocalWorldStatus status) {
        value.status = status;
        out = value;
        return status == LocalWorldStatus::Standalone;
    };
    std::uintptr_t actors = 0, controllerWorld = 0;
    std::int32_t count = 0, capacity = 0;
    if (!read(gameBase, worldPointerRva, value.world) ||
        !read(value.world, kWorldPersistentLevel, value.level) ||
        !read(value.level, kLevelActorData, actors) ||
        !read(value.level, kLevelActorCount, count) ||
        !read(value.level, kLevelActorCapacity, capacity))
        return finish(LocalWorldStatus::Unreadable);
    if (!actors || count < 1 || capacity < count || capacity > 1048576)
        return finish(LocalWorldStatus::InvalidActorArray);
    if (!read(actors, 0, value.worldInfo) ||
        !read(value.worldInfo, kWorldInfoNetMode, value.netMode) ||
        !read(value.world, kWorldNetDriver, value.netDriver) ||
        !read(localPlayer, kLocalPlayerController, value.controller) ||
        !read(value.controller, kActorWorldInfo, controllerWorld))
        return finish(LocalWorldStatus::Unreadable);
    if (controllerWorld != value.worldInfo)
        return finish(LocalWorldStatus::ControllerWorldMismatch);
    if (value.netMode != 0) return finish(LocalWorldStatus::NetworkMode);
    if (value.netDriver != 0) return finish(LocalWorldStatus::NetworkDriver);
    return finish(LocalWorldStatus::Standalone);
}

} // namespace kf2vr::adapter::pinned
