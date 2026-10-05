#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <new>
#include <type_traits>
#include <utility>
#include <windows.h>

namespace kf2vr::adapter {
// UE3's render-command queue (GRenderCommandBuffer), as compiled into the
// hash-pinned KFGame.exe. Evidence: tools/re/audit_render_thread.py.
//   0x903380 enqueues with: AllocationContext ctor 0xe3f0(context, ring 0x21f8f38,
//   size), a FSkipRenderCommand (vtable 0x166bc30, size at +8) when the tail is
//   too short, placement construction, then commit 0x102d0.
//   The rendering thread (0x2a3810) calls vtable slot 1 (Execute, returns the
//   command size), then slot 0 with flags 0 (in-place destructor), then
//   FinishRead, which rounds the size up to the ring alignment.
//   0x21f8da0 (GIsThreadedRendering) is zero under -onethread, where the engine
//   executes its own commands inline; Enqueue does the same.
// The ring has a single producer, the game thread. A call made on the thread
// that drains the ring runs inline instead, as the engine's own commands do.
class RenderCommandQueue {
public:
    static constexpr std::uintptr_t ThreadedRenderingRva=0x21f8da0;
    static constexpr std::uintptr_t RingRva=0x21f8f38;
    static constexpr std::uintptr_t AllocateRva=0xe3f0;
    static constexpr std::uintptr_t CommitRva=0x102d0;
    static constexpr std::uintptr_t SkipCommandVtableRva=0x166bc30;

    void Initialise(std::uintptr_t base) noexcept { base_=base; }
    bool Threaded() const noexcept {
        return base_ && *reinterpret_cast<const volatile std::int32_t*>(base_+ThreadedRenderingRva)!=0;
    }
    // The thread that last executed one of these commands: the game thread
    // under -onethread, UE3's rendering thread otherwise.
    DWORD ExecutingThread() const noexcept { return executing_.load(std::memory_order_acquire); }
    // The thread that drained a queued command; zero until one has run.
    DWORD DrainingThread() const noexcept { return draining_.load(std::memory_order_acquire); }

    template<class F> void Enqueue(F&& function) {
        using Command=Payload<std::decay_t<F>>;
        if (!Threaded() || GetCurrentThreadId()==draining_.load(std::memory_order_acquire)) {
            executing_.store(GetCurrentThreadId(),std::memory_order_release);
            function(); return;
        }
        static_assert(alignof(Command)<=8,"ring allocations are only pointer-aligned");
        Allocation context{};
        Allocate(context,sizeof(Command));
        if (static_cast<std::uint32_t>(context.end-context.start)<sizeof(Command)) {
            if (context.start) {
                *reinterpret_cast<std::uintptr_t*>(context.start)=base_+SkipCommandVtableRva;
                *reinterpret_cast<std::uint32_t*>(context.start+8)=static_cast<std::uint32_t>(context.end-context.start);
            }
            Commit(context);
            Allocate(context,sizeof(Command));
        }
        if (context.start) new (context.start) Command(std::forward<F>(function),*this);
        Commit(context);
    }
private:
    // FRenderCommand: slot 0 scalar deleting destructor, slot 1 Execute,
    // slot 2 DescribeCommand. The engine never frees ring memory through slot 0.
    struct CommandBase {
        virtual ~CommandBase()=default;
        virtual std::uint32_t Execute() noexcept=0;
        virtual const wchar_t* DescribeCommand() noexcept { return L"KF2VRRenderCommand"; }
    };
    template<class F> struct Payload final : CommandBase {
        F function;
        RenderCommandQueue& queue;
        Payload(F&& f,RenderCommandQueue& q) : function(std::move(f)),queue(q) {}
        Payload(const F& f,RenderCommandQueue& q) : function(f),queue(q) {}
        std::uint32_t Execute() noexcept override {
            const DWORD thread=GetCurrentThreadId();
            queue.draining_.store(thread,std::memory_order_release);
            queue.executing_.store(thread,std::memory_order_release);
            function();
            return sizeof(Payload);
        }
    };
    struct Allocation {
        void* ring=nullptr;
        std::byte* start=nullptr;
        std::byte* end=nullptr;
        std::byte reserved[0x28]{};
    };
    void Allocate(Allocation& context,std::size_t size) const {
        using AllocateFn=Allocation*(*)(Allocation*,void*,std::uint32_t);
        reinterpret_cast<AllocateFn>(base_+AllocateRva)(&context,reinterpret_cast<void*>(base_+RingRva),
            static_cast<std::uint32_t>(size));
    }
    void Commit(Allocation& context) const {
        using CommitFn=void(*)(Allocation*);
        reinterpret_cast<CommitFn>(base_+CommitRva)(&context);
    }
    std::uintptr_t base_=0;
    std::atomic<DWORD> executing_{0},draining_{0};
};
} // namespace kf2vr::adapter
