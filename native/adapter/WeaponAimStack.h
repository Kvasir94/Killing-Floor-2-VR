#pragma once

#include "kf2vr/adapter/VerifiedLayout.h"

namespace kf2vr::adapter {

struct WeaponAimPose {
    void* weapon{};
    bool managed=false, ready=false;
    pinned::NativeVector3 origin{};
    pinned::NativeRotator base{}, recoil{};
};

// Only synchronous call frames retain these borrowed references. A nested
// weapon shadows its caller, including an unmanaged weapon inside a VR shot.
class WeaponAimStack {
public:
    class Scope {
    public:
        explicit Scope(WeaponAimStack& stack) : stack_(stack) {}
        Scope(const Scope&)=delete;
        Scope& operator=(const Scope&)=delete;
        ~Scope() {
            if (!active_) return;
            if (buffer_) *buffer_=saved_;
            stack_.top_=parent_;
        }
        void Enter(WeaponAimPose pose, pinned::NativeRotator* buffer) {
            if (active_) return;
            parent_=stack_.top_;
            pose_=pose;
            buffer_=buffer;
            blocksLegacy_=pose.managed || (parent_ && parent_->blocksLegacy_);
            if (buffer_) {
                saved_=*buffer_;
                baseline_=parent_ && parent_->buffer_==buffer_ ? parent_->baseline_ : saved_;
                *buffer_=pose.managed ? (pose.ready ? pose.recoil : pinned::NativeRotator{}) : baseline_;
            }
            stack_.top_=this;
            active_=true;
        }
    private:
        friend class WeaponAimStack;
        WeaponAimStack& stack_;
        Scope* parent_{};
        WeaponAimPose pose_{};
        pinned::NativeRotator* buffer_{};
        pinned::NativeRotator saved_{}, baseline_{};
        bool active_=false, blocksLegacy_=false;
    };
    const WeaponAimPose* Current() const { return top_ ? &top_->pose_ : nullptr; }
    bool BlocksLegacy() const { return top_ && top_->blocksLegacy_; }
private:
    Scope* top_{};
};

} // namespace kf2vr::adapter
