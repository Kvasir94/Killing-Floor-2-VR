#include "EpicSession.h"
#include <iostream>
using namespace kf2vr::adapter::epic;
int main() {
 int failures=0; Marker marker;
 auto check=[&](bool ok){if(!ok)++failures;};
 const std::wstring valid=L"-kf2vr-epic-session=01234567-89ab-cdef-0123-456789abcdef:123:456";
 check(Parse(L"KFGame.exe -kf2vr-probe",marker)==Result::NotRequested);
 check(Parse(L"KFGame.exe "+valid,marker)==Result::Accepted);
 check(marker.pid==123&&marker.created==456);
 check(Parse(valid+L" "+valid,marker)==Result::Refused);
 check(Parse(L"prefix"+valid,marker)==Result::Refused);
 check(Parse(valid+L":789",marker)==Result::Refused);
 check(Parse(L"-kf2vr-epic-session=bad:123:456",marker)==Result::Refused);
 check(Parse(L"-kf2vr-epic-session=01234567-89ab-cdef-0123-456789abcdef:4294967296:456",marker)==Result::Refused);
 std::uint64_t number=0;check(!Number(L"18446744073709551616",number));
 check(!Number(L"-1",number));check(!Number(L"0",number));
 std::wstring path;check(!Root("relative/path",path));check(!Root("C:\\missing\nfolder",path));
 std::cout<<"Epic session checks failed: "<<failures<<'\n';return failures?1:0;
}
