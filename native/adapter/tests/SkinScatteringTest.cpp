#include <cmath>
#include <cstdint>
#include <cstdio>
#include "SkinScattering.h"
using kf2vr::adapter::SkinScattering;
namespace {
int checks=0, failures=0;
void Test(bool value,const char* label) { ++checks; if(!value) { ++failures; std::printf("FAIL %s\n",label); } }
bool Near(float a,float b) { return std::fabs(a-b)<=1e-6f*(1.0f+std::fabs(b)); }
}
int main() {
    SkinScattering pass;
    // Two eyes side by side filling the buffer: half the width each, full height.
    const std::int32_t pair[2][4]{{0,0,2016,2240},{2016,0,2016,2240}};
    Test(pass.Begin(pair,2,4032,2240) && pass.Active(),"pair accepted");
    Test(Near(pass.Next(),0.5f),"horizontal step is the eye's share of the width");
    Test(Near(pass.Next(),1.0f),"vertical step is the eye's share of the height");
    Test(Near(pass.Next(),0.5f) && Near(pass.Next(),1.0f) && pass.Uploads()==4,"uploads alternate");
    pass.End();
    Test(!pass.Active(),"ended");
    // A buffer that kept an older, larger size: the eye's share shrinks on both axes.
    Test(pass.Begin(pair,2,5376,2688) && Near(pass.Next(),2016.0f/5376.0f) && Near(pass.Next(),2240.0f/2688.0f),
         "larger buffer");
    Test(pass.Uploads()==2,"begin restarts the upload count");
    // Left stock: one view, unequal eyes, a view outside the buffer, bad sizes.
    Test(!pass.Begin(pair,1,4032,2240) && !pass.Active(),"single view is stock");
    const std::int32_t unequal[2][4]{{0,0,2016,2240},{2016,0,2000,2240}};
    Test(!pass.Begin(unequal,2,4032,2240),"unequal eyes are stock");
    const std::int32_t outside[2][4]{{0,0,2016,2240},{2100,0,2016,2240}};
    Test(!pass.Begin(outside,2,4032,2240),"view outside the buffer is stock");
    const std::int32_t empty[2][4]{{0,0,0,2240},{2016,0,0,2240}};
    Test(!pass.Begin(empty,2,4032,2240) && !pass.Begin(pair,2,0,2240) && !pass.Begin(nullptr,2,4032,2240),"degenerate input is stock");
    // The game's own values at scale 1; only the step is scaled.
    float values[2]{};
    SkinScattering::Parameters(0.9f,1.0f,values);
    Test(Near(values[0],0.9f/6.0f) && values[1]==0.9f,"stock parameters at scale 1");
    SkinScattering::Parameters(0.9f,0.5f,values);
    Test(Near(values[0],0.9f/12.0f) && values[1]==0.9f,"step scaled, depth falloff kept");
    std::printf("SkinScattering checks=%d failures=%d\n",checks,failures);
    return failures ? 1 : 0;
}
