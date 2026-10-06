#pragma once
#include <algorithm>
#include <cstdint>
#include <unordered_map>

namespace kf2vr::adapter::promo {
enum class Headshot { Unknown, SameTick, TimestampAdvanced };
struct Key {
    std::uintptr_t address{};
    std::uint64_t name{};
    bool operator==(const Key&) const = default;
};
struct Hash {
    std::size_t operator()(const Key& k) const {
        return std::hash<std::uintptr_t>{}(k.address) ^ (std::hash<std::uint64_t>{}(k.name)<<1);
    }
};
struct Hit {
    std::uint32_t victim{}, damage{};
    bool kill{};
};
// Post-score accounting, not a prediction from requested damage. Each engine
// actor lifetime gets one kill; nested/super scoring and postmortem callbacks
// cannot inflate it. Keys never leave this process or enter the output file.
class State {
public:
    explicit State(std::size_t capacity=8192) : capacity_(capacity) {}
    void World(Key world) {
        if (world==world_) return;
        world_=world; victims_.clear(); ++epoch_;
    }
    void BeginTravel() { world_={}; victims_.clear(); }
    Hit Score(Key key, int requested, int before, int after) {
        if (!key.address || requested<=0 || before<=0 || after>=before) return {};
        auto found=victims_.find(key);
        if (found==victims_.end()) {
            if (victims_.size()>=capacity_) { ++dropped_; return {}; }
            found=victims_.emplace(key, Victim{++nextVictim_,false}).first;
        }
        if (found->second.dead) return {};
        const auto loss=std::min<std::int64_t>(requested,static_cast<std::int64_t>(before)-after);
        const bool killed=after<=0;
        found->second.dead=killed;
        if (killed) ++kills_;
        return {found->second.id,static_cast<std::uint32_t>(std::min<std::int64_t>(loss,before)),killed};
    }
    std::uint32_t Epoch() const { return epoch_; }
    std::uint64_t Kills() const { return kills_; }
    std::uint64_t Dropped() const { return dropped_; }
private:
    struct Victim { std::uint32_t id; bool dead; };
    Key world_{};
    std::unordered_map<Key,Victim,Hash> victims_;
    std::size_t capacity_;
    std::uint32_t epoch_{},nextVictim_{};
    std::uint64_t kills_{},dropped_{};
};
inline Headshot HeadshotEvidence(float previous, float current, float gameTime, bool havePrevious) {
    if (!(current>0) || current!=gameTime) return Headshot::Unknown;
    // The stock timestamp advancing during this exact TakeDamage scope is
    // stronger evidence than a timestamp left by another hit in the same tick.
    return havePrevious && current>previous ? Headshot::TimestampAdvanced : Headshot::SameTick;
}
} // namespace kf2vr::adapter::promo
