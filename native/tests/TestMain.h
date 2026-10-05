// Minimal test harness. No dependency, because a golden-test suite that is
// hard to run does not get run.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "kf2vr/Math.h"

namespace kf2test {

inline int g_failures = 0;
inline int g_checks   = 0;

inline void Fail(const char* what, const char* file, int line) {
    ++g_failures;
    std::printf("\n    FAIL %s:%d  %s\n", file, line, what);
}

inline bool Near(float a, float b, float eps) { return std::fabs(a - b) <= eps; }

inline bool NearVec(const kf2vr::Vec3& a, const kf2vr::Vec3& b, float eps) {
    return Near(a.x, b.x, eps) && Near(a.y, b.y, eps) && Near(a.z, b.z, eps);
}

// Quaternions double-cover rotations: q and -q are the same rotation.
inline bool NearQuat(const kf2vr::Quat& a, const kf2vr::Quat& b, float eps) {
    const bool same = Near(a.x, b.x, eps) && Near(a.y, b.y, eps) &&
                      Near(a.z, b.z, eps) && Near(a.w, b.w, eps);
    const bool neg  = Near(a.x, -b.x, eps) && Near(a.y, -b.y, eps) &&
                      Near(a.z, -b.z, eps) && Near(a.w, -b.w, eps);
    return same || neg;
}

// Deterministic PRNG, so a property-test failure reproduces exactly.
class Rng {
public:
    explicit Rng(std::uint64_t seed) : s_(seed ? seed : 0x9E3779B97F4A7C15ull) {}
    std::uint64_t Next() {
        s_ ^= s_ << 13; s_ ^= s_ >> 7; s_ ^= s_ << 17;
        return s_;
    }
    float Unit() { return static_cast<float>(Next() >> 11) / 9007199254740992.0f; }
    float Range(float lo, float hi) { return lo + Unit() * (hi - lo); }
    kf2vr::Vec3 Vec(float r = 2.f) { return {Range(-r, r), Range(-r, r), Range(-r, r)}; }
    kf2vr::Quat Rot() {
        // The +1e-4 on x keeps a degenerate all-zero axis from producing a
        // zero quaternion on the (astronomically unlikely) unlucky draw.
        return kf2vr::Quat::FromAxisAngle(
            kf2vr::Vec3{Range(-1, 1) + 1e-4f, Range(-1, 1), Range(-1, 1)},
            Range(-3.14159f, 3.14159f));
    }
private:
    std::uint64_t s_;
};

struct Case { const char* name; void (*fn)(); };
inline std::vector<Case>& Registry() { static std::vector<Case> r; return r; }

}  // namespace kf2test

#define CHECK(cond)                                                        \
    do {                                                                   \
        ++kf2test::g_checks;                                               \
        if (!(cond)) kf2test::Fail(#cond, __FILE__, __LINE__);             \
    } while (0)

#define CHECK_NEAR(a, b, eps)                                              \
    do {                                                                   \
        ++kf2test::g_checks;                                               \
        if (!kf2test::Near((a), (b), (eps)))                               \
            kf2test::Fail(#a " ~= " #b, __FILE__, __LINE__);               \
    } while (0)

#define CHECK_VEC(a, b, eps)                                               \
    do {                                                                   \
        ++kf2test::g_checks;                                               \
        if (!kf2test::NearVec((a), (b), (eps)))                            \
            kf2test::Fail(#a " ~= " #b, __FILE__, __LINE__);               \
    } while (0)

#define CHECK_QUAT(a, b, eps)                                              \
    do {                                                                   \
        ++kf2test::g_checks;                                               \
        if (!kf2test::NearQuat((a), (b), (eps)))                           \
            kf2test::Fail(#a " ~= " #b, __FILE__, __LINE__);               \
    } while (0)

// Self-registering test case.
#define TEST(name)                                                         \
    void name();                                                           \
    struct Reg_##name {                                                    \
        Reg_##name() { kf2test::Registry().push_back({#name, name}); }     \
    } reg_##name;                                                          \
    void name()
