#pragma once
#include "GameScript.h"
namespace kf2vr::adapter {
class WeaponBlockScope {
    GameScript* script_{};
    void* game_{};
    void* zed_{};
    void* helper_{};
    int serial_{};
    int first_{};
    int delayedIndex_{-1};
    bool suppressed_{};
    bool ownsDepth_{};
    unsigned thrownContext_{~0u};
    bool ownsThrownContext_{},ownsThrownDamage_{},blocksThrownArmor_{};
public:
    WeaponBlockScope(GameScript&,void* object,void* function,const void* locals);
    ~WeaponBlockScope();
    WeaponBlockScope(const WeaponBlockScope&)=delete;
    WeaponBlockScope& operator=(const WeaponBlockScope&)=delete;
    bool Suppressed() const { return suppressed_; }
};
}
