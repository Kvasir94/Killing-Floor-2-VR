#pragma once
#include "GameScript.h"
#include "WeaponBlockSurface.h"
namespace kf2vr::adapter {
bool ReadWeaponImpactBody(GameScript&,void* prop,weaponblock::RigidBodyState&);
}
