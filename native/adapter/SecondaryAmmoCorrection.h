#pragma once
#include <climits>

namespace kf2vr::adapter {
// Negative loaded count distinguishes slot-one corrections from stock primary
// updates and the -255 receipt marker. Reserve remains an ordinary integer.
inline bool DecodeSecondaryAmmoCorrection(int encoded,int reserve,int& loaded) {
    if (encoded>-256 || encoded==INT_MIN || reserve<0) return false;
    const int decoded=-256-encoded;
    if (decoded>INT_MAX-reserve) return false;
    loaded=decoded;
    return true;
}
}
