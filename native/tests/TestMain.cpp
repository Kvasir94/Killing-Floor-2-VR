#include <cstdio>

#include "TestMain.h"

int main() {
    std::printf("kf2vr golden tests\n");

    int failedCases = 0;
    for (const auto& c : kf2test::Registry()) {
        const int before = kf2test::g_failures;
        std::printf("  %-52s", c.name);
        c.fn();
        const bool ok = kf2test::g_failures == before;
        if (!ok) ++failedCases;
        std::printf("%s\n", ok ? "ok" : "FAILED");
    }

    std::printf("\n%d checks, %zu cases, %d failing cases, %d failed checks\n",
                kf2test::g_checks, kf2test::Registry().size(), failedCases,
                kf2test::g_failures);
    return kf2test::g_failures == 0 ? 0 : 1;
}
