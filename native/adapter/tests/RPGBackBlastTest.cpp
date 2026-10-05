#include "RPGBackBlast.h"
#include <array>
#include <cstdio>

using namespace kf2vr::adapter;
namespace {
using Node=std::array<std::byte,0x100>;
template<class T> void Put(Node& node, std::size_t offset, T value) {
    std::memcpy(node.data()+offset,&value,sizeof(value));
}
int failures=0;
void Check(bool ok,const char* message) {
    if (!ok) { ++failures; std::printf("FAIL: %s\n",message); }
}
}
int main() {
    Node function{},locationProperty{},rotationProperty{},unrelated{},frame{},first{},second{},locals{};
    Put(function,0x80,locationProperty.data()); Put(locationProperty,0x60,rotationProperty.data());
    Put(locationProperty,0x48,GameScript::Name{11}); Put(locationProperty,0x6c,12);
    Put(rotationProperty,0x48,GameScript::Name{12}); Put(rotationProperty,0x6c,12);
    kf2vr::Vec3 callerLocation{1,2,3}; pinned::NativeRotator callerRotation{4,5,6};
    Put(frame,0x2c,locals.data()); Put(frame,0x3c,first.data());
    // Deliberately reverse the references: the caller's chain order need not
    // match function property order, and neither destination is VM locals.
    Put(first,0,rotationProperty.data()); Put(first,8,&callerRotation); Put(first,16,second.data());
    Put(second,0,locationProperty.data()); Put(second,8,&callerLocation);
    auto* location=RPGOutParameter(function.data(),frame.data(),11,sizeof(callerLocation));
    auto* rotation=RPGOutParameter(function.data(),frame.data(),12,sizeof(callerRotation));
    Check(location==&callerLocation && rotation==&callerRotation,"resolves actual caller references by property identity");
    const kf2vr::Vec3 exhaust{-72,0,11};
    if (location) std::memcpy(location,&exhaust,sizeof(exhaust));
    Check(callerLocation.x==-72 && locals[0]==std::byte{},"writes caller location without changing VM locals");
    Check(!RPGOutParameter(function.data(),frame.data(),11,8),"incorrect reflected width is rejected");
    Check(!RPGOutParameter(function.data(),frame.data(),99,12),"missing property is rejected");
    // A different function's identically named property is not this out arg.
    Put(unrelated,0x48,GameScript::Name{11}); Put(unrelated,0x6c,12); Put(second,0,unrelated.data());
    Check(!RPGOutParameter(function.data(),frame.data(),11,12),"foreign property cannot redirect output");
    Put(second,0,locationProperty.data()); Put(second,8,static_cast<void*>(nullptr));
    Check(!RPGOutParameter(function.data(),frame.data(),11,12),"null destination is rejected");
    Put(second,0,unrelated.data()); Put(second,16,first.data());
    Check(!RPGOutParameter(function.data(),frame.data(),11,12),"cyclic out-parameter chain terminates");
    Check(!RPGOutParameter(function.data(),nullptr,11,12),"missing frame is rejected");
    std::printf("RPG backblast reference checks: %d failures\n",failures);
    return failures ? 1 : 0;
}
