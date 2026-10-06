#include "EpicSession.h"
#include <iostream>
int wmain() {
 const auto result=kf2vr::adapter::epic::Consume(GetCommandLineW());
 if(result!=kf2vr::adapter::epic::Result::Accepted)return 2;
 wchar_t path[32768]{};
 if(!GetEnvironmentVariableW(L"KF2VR_LOG_PATH",path,32768))return 3;
 const int count=WideCharToMultiByte(CP_UTF8,0,path,-1,nullptr,0,nullptr,nullptr);
 if(count<=1)return 4;
 std::string text(static_cast<size_t>(count),'\0');
 WideCharToMultiByte(CP_UTF8,0,path,-1,text.data(),count,nullptr,nullptr);
 text.pop_back();std::cout<<text<<'\n';return 0;
}
