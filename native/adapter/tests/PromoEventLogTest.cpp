#include "PromoEventLog.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <cstdlib>
void Check(bool value) { if (!value) { std::cerr<<"promo file check failed\n"; std::exit(1); } }
int main(int argc,char** argv) {
    Check(argc==2);
    const std::filesystem::path path(argv[1]);
    SetEnvironmentVariableW(L"KF2VR_PROMO_LOG_PATH",path.wstring().c_str());
    SetEnvironmentVariableW(L"KF2VR_PROMO_ROLE",L"driver");
    SetEnvironmentVariableW(L"KF2VR_PROMO_SESSION",L"private-name-and-chat");
    { kf2vr::adapter::promo::Log refused; Check(!refused.Start()); }
    SetEnvironmentVariableW(L"KF2VR_PROMO_SESSION",L"01234567-89ab-cdef-0123-456789abcdef");
    {
        kf2vr::adapter::promo::Log log;
        Check(log.Start());
        log.Marker(3,1920,1080,42);
    }
    std::ifstream input(path); std::string line; unsigned rows=0;
    while (std::getline(input,line)) {
        ++rows;
        Check(line.starts_with("{\"schema\":\"kf2vr/promo-events/1\""));
        Check(line.find("\"qpc_ticks\":")!=std::string::npos);
        Check(line.find("\"event_id\":")!=std::string::npos);
        Check(line.find("private-name-and-chat")==std::string::npos);
        Check(line.find(path.string())==std::string::npos);
    }
    Check(rows==3);
    std::cout<<"promo per-session file and privacy checks passed\n";
}
