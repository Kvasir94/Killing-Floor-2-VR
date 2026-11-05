#pragma once
#include <array>
#include <cstddef>

namespace kf2vr::adapter {
struct OpticProbeIdentity {
    void* component{};
    void* owner{};
    void* target{};
    bool Valid() const { return component && owner && target; }
    bool operator==(const OpticProbeIdentity&) const = default;
};

// Opaque keys only. The caller owns synchronization and resource lifetimes.
// Several probes of one capture can coexist while older frames are queued.
template<std::size_t Capacity=32>
class OpticProbeBindings {
    static_assert(Capacity>0);
    struct Entry { void* probe{};OpticProbeIdentity identity{}; };
    std::array<Entry,Capacity> entries_{};
    std::size_t next_=0;
public:
    void Register(void* probe,const OpticProbeIdentity& identity) {
        if (!probe) return;
        for (auto& entry:entries_) if (entry.probe==probe) entry={};
        // A foreign creation still invalidates a reused native address. It
        // cannot consume capacity or erase other queued probes of a capture.
        if (!identity.Valid()) return;
        entries_[next_]={probe,identity};
        next_=(next_+1)%Capacity;
    }
    OpticProbeIdentity Find(void* probe) const {
        if (probe) for (const auto& entry:entries_)
            if (entry.probe==probe) return entry.identity;
        return {};
    }
    bool Matches(void* probe,const OpticProbeIdentity& identity) const {
        return identity.Valid() && Find(probe)==identity;
    }
    void Clear() { entries_={};next_=0; }
};
}
