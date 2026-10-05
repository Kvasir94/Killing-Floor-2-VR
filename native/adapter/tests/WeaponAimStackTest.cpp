#include "WeaponAimStack.h"
#include <cstdio>

using namespace kf2vr::adapter;
namespace {
int checks=0, failures=0;
void Check(bool value, const char* message) {
    ++checks;
    if (!value) { ++failures; std::printf("FAIL: %s\n",message); }
}
bool Same(pinned::NativeRotator a, pinned::NativeRotator b) {
    return a.pitch==b.pitch && a.yaw==b.yaw && a.roll==b.roll;
}
void EarlyReturn(WeaponAimStack& stack, WeaponAimPose pose, pinned::NativeRotator& buffer) {
    WeaponAimStack::Scope scope(stack);
    scope.Enter(pose,&buffer);
}
}

int main() {
    int weaponA=0, weaponB=0, tool=0;
    const pinned::NativeRotator stock{901,902,903};
    pinned::NativeRotator shared=stock;
    WeaponAimPose a{&weaponA,true,true,{10,20,30},{100,200,300},{11,22,33}};
    WeaponAimPose b{&weaponB,true,true,{-40,50,60},{400,500,600},{44,55,66}};
    WeaponAimPose unmanaged{&tool};
    WeaponAimStack stack;
    Check(!stack.Current() && !stack.BlocksLegacy(),"no context between calls");
    {
        WeaponAimStack::Scope outer(stack);
        outer.Enter(a,&shared);
        Check(stack.Current()->weapon==&weaponA && Same(shared,a.recoil),"A publishes only A recoil");
        Check(stack.Current()->origin.x==10 && stack.BlocksLegacy(),"A blocks selected-weapon origin");
        {
            WeaponAimStack::Scope inner(stack);
            inner.Enter(b,&shared);
            Check(stack.Current()->weapon==&weaponB && Same(shared,b.recoil),"B shadows A");
            {
                WeaponAimStack::Scope stockCall(stack);
                stockCall.Enter(unmanaged,&shared);
                Check(!stack.Current()->managed && Same(shared,stock),"nested tool sees original stock buffer");
                Check(stack.BlocksLegacy(),"nested tool cannot inherit selected gun pose");
                {
                    WeaponAimStack::Scope backToA(stack);
                    backToA.Enter(a,&shared);
                    Check(Same(shared,a.recoil),"managed call inside tool restores its own context");
                }
                Check(Same(shared,stock),"tool buffer restored after managed call");
            }
            Check(stack.Current()->weapon==&weaponB && Same(shared,b.recoil),"tool exit restores B exactly");
            shared={700,800,900}; // stock callees may change the temporary output
        }
        Check(stack.Current()->weapon==&weaponA && Same(shared,a.recoil),"B exit restores A even after mutation");
        auto invalid=b; invalid.ready=false;
        {
            WeaponAimStack::Scope lostTracking(stack);
            lostTracking.Enter(invalid,&shared);
            Check(!stack.Current()->ready && Same(shared,{}),"invalid B cannot borrow A recoil");
            Check(stack.BlocksLegacy(),"invalid B cannot borrow selected pose");
        }
        Check(Same(shared,a.recoil),"invalid call restores A");
        WeaponAimStack independent;
        pinned::NativeRotator other=stock;
        EarlyReturn(independent,b,other);
        Check(!independent.Current() && Same(other,stock) && stack.Current()->weapon==&weaponA,
              "independent stacks do not share state");
    }
    Check(!stack.Current() && Same(shared,stock),"outer exit restores original controller");
    EarlyReturn(stack,b,shared);
    Check(!stack.Current() && Same(shared,stock),"early return clears context");
    {
        WeaponAimStack::Scope topTool(stack);
        topTool.Enter(unmanaged,&shared);
        Check(!stack.BlocksLegacy() && Same(shared,stock),"ordinary unmanaged call keeps legacy fallback");
    }
    {
        WeaponAimStack::Scope noBuffer(stack);
        noBuffer.Enter(a,nullptr);
        Check(stack.Current()->weapon==&weaponA,"missing buffer still scopes identity");
    }
    Check(!stack.Current() && Same(shared,stock),"missing buffer scope cleans up");
    std::printf("weapon aim: %d checks, %d failures\n",checks,failures);
    return failures?1:0;
}
