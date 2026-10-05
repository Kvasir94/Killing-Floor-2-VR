#include "kf2vr/adapter/LocalWorldGate.h"
#include <array>
#include <cstdio>
#include <cstring>
#include <map>
#include <stdexcept>
#include <vector>

namespace p = kf2vr::adapter::pinned;
static void Check(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
struct Memory {
    std::map<std::uintptr_t, std::vector<std::byte>> ranges;
    int reads = 0, failAt = -1;
    template<class T> void Set(std::uintptr_t address, const T& value) {
        auto& bytes = ranges[address]; bytes.resize(sizeof(value));
        std::memcpy(bytes.data(), &value, sizeof(value));
    }
    bool Read(std::uintptr_t address, void* target, std::size_t bytes) {
        if (reads++ == failAt) return false;
        const auto found = ranges.find(address);
        if (found == ranges.end() || found->second.size() != bytes) return false;
        std::memcpy(target, found->second.data(), bytes);
        return true;
    }
};
int main() {
    try {
        constexpr std::uintptr_t base = 0x140000000, world = 0x1000, level = 0x2000;
        constexpr std::uintptr_t actors = 0x3000, info = 0x4000, player = 0x5000, controller = 0x6000;
        Memory fixture;
        fixture.Set(base + p::kWorldPointerRva, world);
        fixture.Set(world + p::kWorldPersistentLevel, level);
        fixture.Set(level + p::kLevelActorData, actors);
        fixture.Set(level + p::kLevelActorCount, std::int32_t{1});
        fixture.Set(level + p::kLevelActorCapacity, std::int32_t{4});
        fixture.Set(actors, info);
        fixture.Set(info + p::kWorldInfoNetMode, std::uint8_t{0});
        fixture.Set(world + p::kWorldNetDriver, std::uintptr_t{0});
        fixture.Set(player + p::kLocalPlayerController, controller);
        fixture.Set(controller + p::kActorWorldInfo, info);
        p::LocalWorldSnapshot snapshot;
        auto check = [&](Memory& memory, std::uintptr_t imageBase = 0x140000000) {
            return p::CheckStandaloneWorld(imageBase, player,
                [&](std::uintptr_t address, void* target, std::size_t bytes) {
                    return memory.Read(address, target, bytes);
                }, snapshot);
        };
        Check(check(fixture), "matching standalone world");
        Check(snapshot.controller == controller && snapshot.worldInfo == info, "identity captured");
        const auto expectedReads = fixture.reads;
        for (int fail = 0; fail < expectedReads; ++fail) {
            auto bad = fixture; bad.reads = 0; bad.failAt = fail;
            Check(!check(bad), "every unreadable link fails closed");
        }
        for (std::uint8_t mode : std::array<std::uint8_t, 5>{1,2,3,4,255}) {
            auto bad = fixture; bad.Set(info + p::kWorldInfoNetMode, mode);
            Check(!check(bad) && snapshot.status == p::LocalWorldStatus::NetworkMode, "non-standalone mode rejected");
        }
        auto bad = fixture;
        bad.Set(world + p::kWorldNetDriver, std::uintptr_t{0x7000});
        Check(!check(bad) && snapshot.status == p::LocalWorldStatus::NetworkDriver, "transport before netmode transition rejected");
        bad = fixture; bad.Set(controller + p::kActorWorldInfo, std::uintptr_t{0x8000});
        Check(!check(bad) && snapshot.status == p::LocalWorldStatus::ControllerWorldMismatch, "stale controller rejected");
        bad = fixture; bad.Set(level + p::kLevelActorCount, std::int32_t{0});
        Check(!check(bad) && snapshot.status == p::LocalWorldStatus::InvalidActorArray, "empty actor array rejected");
        bad = fixture; bad.Set(level + p::kLevelActorCapacity, std::int32_t{0});
        Check(!check(bad), "invalid array capacity rejected");
        bad = fixture; bad.reads = 0;
        Check(!check(bad, (std::numeric_limits<std::uintptr_t>::max)()), "base overflow rejected");
        Check(bad.reads == 0, "overflow makes no memory read");
        Check(check(fixture), "valid state can resume after rejected state");
        auto client = fixture;
        client.Set(info + p::kWorldInfoNetMode, std::uint8_t{3});
        client.Set(world + p::kWorldNetDriver, std::uintptr_t{0x7000});
        Check(!check(client), "network opt-in does not alter standalone check");
        Check(p::IsAdmittedNetworkClient(snapshot,true,true,1), "opt-in owning mod client admitted");
        Check(!p::IsAdmittedNetworkClient(snapshot,false,true,1), "ordinary launch rejects network");
        Check(!p::IsAdmittedNetworkClient(snapshot,true,false,1), "unknown controller rejected");
        Check(!p::IsAdmittedNetworkClient(snapshot,true,true,0), "incomplete handshake rejected");
        Check(!p::IsAdmittedNetworkClient(snapshot,true,true,2), "invalid handshake marker rejected");
        snapshot.netMode=1;
        Check(!p::IsAdmittedNetworkClient(snapshot,true,true,1), "dedicated server cannot own XR");
        snapshot.netMode=3; snapshot.netDriver=0;
        Check(!p::IsAdmittedNetworkClient(snapshot,true,true,1), "torn transport rejected");
        client.Set(controller + p::kActorWorldInfo, std::uintptr_t{0x8000});
        Check(!check(client) && !p::IsAdmittedNetworkClient(snapshot,true,true,1), "stale controller cannot reuse handshake");
        std::puts("Local world gate checks passed");
    } catch (const std::exception& exception) {
        std::fprintf(stderr, "FAIL: %s\n", exception.what()); return 1;
    }
    return 0;
}
