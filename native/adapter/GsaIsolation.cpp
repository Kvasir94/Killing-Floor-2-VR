#include "GsaIsolation.h"
#include "kf2vr/adapter/GameBuild.h"

namespace kf2vr::adapter::gsa {
namespace {
// GSA startup (Steam 0xdb42d0, Epic 0xdbeed0): GFSDK_GSA_InitializeSDK, option
// registration, GFSDK_GSA_LoadConfigFile. Its only caller (0xdb3b60) applies the
// XML through 0xd66f60 when it returns nonzero.
constexpr std::uintptr_t StartupRva=0xdb42d0;

void* originalStartup=nullptr;
Log log=nullptr;

int HookStartup() {
    if(log) log("GsaIsolation revision=1 skipped GeForce Experience settings; session INIs are authoritative");
    return 0;
}
} // namespace

std::vector<EngineHook> PrepareIsolation(std::uintptr_t gameBase,Log logFunction) {
    log=logFunction;
    return {{reinterpret_cast<void*>(gameBase+build::Rva(StartupRva)),reinterpret_cast<void*>(&HookStartup),&originalStartup}};
}

} // namespace kf2vr::adapter::gsa
