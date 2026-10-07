#include "Dlss.h"
namespace kf2vr::adapter {
struct DlssUpscaler::Impl {};
DlssUpscaler::DlssUpscaler() : impl_(std::make_unique<Impl>()) {}
DlssUpscaler::~DlssUpscaler()=default;
void DlssUpscaler::Configure(DlssMode mode,std::wstring,std::wstring) {
    mode_=mode;if(mode!=DlssMode::Off) Fail("DLSS support not compiled");
}
void DlssUpscaler::Fail(const std::string& why) { failure_=why;failed_.store(true,std::memory_order_release); }
void DlssUpscaler::Reset() noexcept {}
void DlssUpscaler::Shutdown() noexcept {}
bool DlssUpscaler::Evaluate(ID3D11Device*,ID3D11DeviceContext*,unsigned,ID3D11Texture2D*,ID3D11Texture2D*,ID3D11Texture2D*,const DlssEyeInput&,std::string& error) {
    error="DLSS support not compiled";return false;
}
}
