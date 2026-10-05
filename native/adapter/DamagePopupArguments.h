#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>

namespace kf2vr::adapter {
struct DamagePopupArgumentField { std::uint32_t offset{},size{}; };
// UnrealScript parameter packing is reflected, not necessarily C++ packing.
inline bool WriteDamagePopupArguments(std::span<std::byte> buffer,
    DamagePopupArgumentField v, DamagePopupArgumentField a, DamagePopupArgumentField k,
    void* victim,std::int32_t amount,void* kind) {
    const auto bounded=[&](DamagePopupArgumentField f) { return f.offset<=buffer.size() && f.size<=buffer.size()-f.offset; };
    const auto overlaps=[](DamagePopupArgumentField x,DamagePopupArgumentField y) { return x.offset<y.offset+y.size && y.offset<x.offset+x.size; };
    if (v.size!=sizeof(victim) || a.size!=sizeof(amount) || k.size!=sizeof(kind) ||
        !bounded(v) || !bounded(a) || !bounded(k) || overlaps(v,a) || overlaps(v,k) || overlaps(a,k)) return false;
    std::memcpy(buffer.data()+v.offset,&victim,sizeof(victim));
    std::memcpy(buffer.data()+a.offset,&amount,sizeof(amount));
    std::memcpy(buffer.data()+k.offset,&kind,sizeof(kind));
    return true;
}
} // namespace kf2vr::adapter
