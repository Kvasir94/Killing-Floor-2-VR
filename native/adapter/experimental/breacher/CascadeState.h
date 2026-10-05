#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <stdexcept>

namespace kf2vr::breacher {
// Experimental CPU policy only. No tracked-input, engine, or shipping DLL dependency.
// The authoritative projectile supplies stable pawn-lifetime IDs (never bone IDs).
struct CascadeTuning {
    float baseDamage, damagePerEnemy, maxDamage;
    float baseRadius, radiusPerEnemy, maxRadius;
};
enum class ContactResult { Ignored, Hit, Exhausted };
struct CascadeHit {
    ContactResult result = ContactResult::Ignored;
    float damage = 0;
    float radius = 0;
};
class CascadeState {
public:
    static constexpr std::size_t capacity = 64; // safety bound, not a balance target
    explicit CascadeState(CascadeTuning tuning) : tuning_(tuning) {
        const auto nonnegative = [](float v) { return std::isfinite(v) && v >= 0; };
        if (!nonnegative(tuning.baseDamage) || !nonnegative(tuning.damagePerEnemy) ||
            !nonnegative(tuning.maxDamage) || !nonnegative(tuning.baseRadius) ||
            !nonnegative(tuning.radiusPerEnemy) || !nonnegative(tuning.maxRadius) ||
            tuning.maxDamage < tuning.baseDamage || tuning.maxRadius < tuning.baseRadius)
            throw std::invalid_argument("Invalid Cascade tuning");
    }
    // Call only after server collision/eligibility validation, ordered along the sweep.
    // Growth is earned by passing an enemy and benefits the NEXT distinct enemy.
    CascadeHit Contact(std::uint64_t pawnLifetimeId, bool livingEnemy) {
        if (!livingEnemy || pawnLifetimeId == 0 ||
            std::find(seen_.begin(), seen_.begin() + count_, pawnLifetimeId) != seen_.begin() + count_)
            return {};
        if (count_ == capacity) return {ContactResult::Exhausted};
        const CascadeHit hit{ContactResult::Hit, Damage(), Radius()};
        seen_[count_++] = pawnLifetimeId;
        return hit;
    }
    float Damage() const { return Grow(tuning_.baseDamage, tuning_.damagePerEnemy, tuning_.maxDamage); }
    float Radius() const { return Grow(tuning_.baseRadius, tuning_.radiusPerEnemy, tuning_.maxRadius); }
    std::size_t DistinctEnemies() const { return count_; }
private:
    float Grow(float base, float step, float limit) const {
        return static_cast<float>(std::min(static_cast<double>(limit),
            static_cast<double>(base) + static_cast<double>(step) * count_));
    }
    CascadeTuning tuning_;
    std::array<std::uint64_t, capacity> seen_{};
    std::size_t count_ = 0;
};
}
