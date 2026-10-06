#include "kf2vr/adapter/GameBuild.h"
#include <iostream>
using namespace kf2vr::adapter::build;
int main() {
    int failures=0;
    auto check=[&](bool ok) { if (!ok) ++failures; };
    check(Identify(SteamHash)==Store::Steam);
    check(Identify(EpicHash)==Store::Epic);
    check(Identify("1.0.8767.0")==Store::Unknown);
    check(Identify(std::string_view(SteamHash.data(),63))==Store::Unknown);
    check(Translate(Store::Unknown,functions[0].steam)==0);
    check(Translate(Store::Epic,0xdeadbeef)==0);
    for (const auto& r:functions) {
        check(Translate(Store::Steam,r.steam)==r.steam);
        check(Translate(Store::Epic,r.steam)==r.epic);
        check(Translate(Store::Epic,r.steam+r.size-1)==r.epic+r.size-1);
    }
    for (const auto& r:globals) check(Translate(Store::Epic,r.steam)==r.epic);
    check(Select(EpicHash));
    check(Rva(functions[0].steam)==functions[0].epic);
    check(!Select("unknown"));
    check(selected==Store::Unknown);
    check(Select(SteamHash));
    std::cout << "Build profile failures: " << failures << '\n';
    return failures ? 1 : 0;
}
