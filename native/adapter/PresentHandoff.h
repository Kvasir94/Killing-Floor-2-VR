#pragma once
#include <atomic>
#include <cstdint>

namespace kf2vr::adapter {
// Loading movies may Present the game's swapchain on a temporary thread. They
// never own XR. Keep only atomic receipts here; mutable rendering state remains
// on the original owner, which must discard its old frame before continuing.
class PresentHandoff {
public:
    enum class OwnerAction { Continue, Wait, Discard, UnsafeOverlap };
    void BeginForeign() noexcept {
        foreign_.fetch_add(1);
        requested_.fetch_add(1);
        if (ownerWork_.load()) overlap_.store(true);
    }
    void EndForeign() noexcept { foreign_.fetch_sub(1); }
    bool BeginOwner() noexcept {
        ownerWork_.fetch_add(1);
        if (!foreign_.load()) return true;
        ownerWork_.fetch_sub(1);
        return false;
    }
    void EndOwner() noexcept { ownerWork_.fetch_sub(1); }
    OwnerAction Action(std::uint64_t& ticket,bool loadingMovieActive=false) const noexcept {
        if (overlap_.load()) return OwnerAction::UnsafeOverlap;
        if (loadingMovieActive || foreign_.load()) return OwnerAction::Wait;
        ticket=requested_.load();
        return ticket==completed_ ? OwnerAction::Continue : OwnerAction::Discard;
    }
    // Owner only; acknowledge exactly the discarded generation. A later movie
    // Present cannot be lost if it arrives during recovery.
    void Complete(std::uint64_t ticket) noexcept { completed_=ticket; }
private:
    std::atomic<unsigned> foreign_{0},ownerWork_{0};
    std::atomic<std::uint64_t> requested_{0};
    std::atomic<bool> overlap_{false};
    std::uint64_t completed_=0; // Owner thread only.
};
class PresentOwnerScope {
public:
    explicit PresentOwnerScope(PresentHandoff& handoff) noexcept
        : handoff_(handoff),entered_(handoff.BeginOwner()) {}
    ~PresentOwnerScope() { if (entered_) handoff_.EndOwner(); }
    explicit operator bool() const noexcept { return entered_; }
private:
    PresentHandoff& handoff_;
    bool entered_;
};
} // namespace kf2vr::adapter
