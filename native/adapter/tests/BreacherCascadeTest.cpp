#include "../experimental/breacher/CascadeState.h"
#include <cstdio>
#include <limits>
#include <stdexcept>
using namespace kf2vr::breacher;
static void Check(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}
int main() {
    try {
        // Test values exercise boundaries; they are not proposed weapon balance.
        CascadeState shot({10, 5, 20, 1, 1, 3});
        Check(shot.Contact(0, true).result == ContactResult::Ignored, "invalid ID");
        Check(shot.Contact(9, false).result == ContactResult::Ignored, "corpse/friendly/ineligible");
        auto first = shot.Contact(9, true);
        Check(first.result == ContactResult::Hit && first.damage == 10 && first.radius == 1, "first target base");
        Check(shot.Contact(9, true).result == ContactResult::Ignored, "same pawn other bone duplicate");
        auto second = shot.Contact(10, true);
        Check(second.damage == 15 && second.radius == 2, "second distinct target gains");
        Check(shot.Contact(9, true).damage == 0 && shot.DistinctEnemies() == 2, "reentry cannot farm");
        Check(shot.Contact(11, true).damage == 20, "damage cap");
        for (std::uint64_t id = 12; shot.DistinctEnemies() < CascadeState::capacity; ++id)
            Check(shot.Contact(id, true).result == ContactResult::Hit, "saturated growth still tracks distinct pawns");
        Check(shot.Damage() == 20 && shot.Radius() == 3, "growth remains capped");
        Check(shot.Contact(1000, true).result == ContactResult::Exhausted, "capacity terminates without forgetting enemies");
        Check(shot.Contact(9, true).result == ContactResult::Ignored, "duplicates remain ignored at capacity");
        CascadeState next({10, 0, 10, 1, 0, 1});
        Check(next.Contact(9, true).damage == 10 && next.Radius() == 1, "new projectile independent and zero gains valid");
        CascadeTuning invalid[] = {
            {-1, 1, 20, 1, 1, 3}, {10, -1, 20, 1, 1, 3}, {10, 1, 9, 1, 1, 3},
            {10, 1, 20, -1, 1, 3}, {10, 1, 20, 1, -1, 3}, {10, 1, 20, 2, 1, 1},
            {10, std::numeric_limits<float>::infinity(), 20, 1, 1, 3},
            {10, 1, 20, std::numeric_limits<float>::quiet_NaN(), 1, 3}};
        for (const auto& tuning : invalid) {
            bool rejected = false;
            try { CascadeState bad(tuning); } catch (const std::invalid_argument&) { rejected = true; }
            Check(rejected, "invalid tuning rejected");
        }
        const auto large = std::numeric_limits<float>::max();
        CascadeState bounded({large, large, large, large, large, large});
        bounded.Contact(1, true);
        Check(std::isfinite(bounded.Damage()) && std::isfinite(bounded.Radius()), "growth avoids float overflow");
        std::puts("Breacher Cascade state checks passed");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}
