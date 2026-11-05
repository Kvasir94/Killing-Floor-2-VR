#undef NDEBUG
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "../localtest/Bridge.h"
#include <cassert>
#include <fstream>
#include <map>
#include <iostream>
#include <cstring>

// Execute the production bridge/channel with reflected fields but no game,
// headset, process handles or live session. Deliberately omit the nested VM
// poll during PrepareLocalTestTravel, as happens after the controller gate.
struct Object {
    std::map<std::wstring,int> ints;
    std::map<std::wstring,void*> pointers;
    std::map<std::wstring,std::wstring> strings;
};
struct Script {
    int dispatches{};
    bool IsClass(void*,const wchar_t*) { return true; }
    template<class T> T Read(void* address,const wchar_t* field) {
        auto& o=*static_cast<Object*>(address);
        if constexpr(std::is_pointer_v<T>) return static_cast<T>(o.pointers[field]);
        else if constexpr(std::is_integral_v<T>) return static_cast<T>(o.ints[field]);
        else {
            const auto& s=o.strings[field];
            return T{s.c_str(),static_cast<int>(s.size()+1),static_cast<int>(s.size()+1)};
        }
    }
    void Write(void* address,const wchar_t* field,int value) { static_cast<Object*>(address)->ints[field]=value; }
    const wchar_t* FindFunction(void*,const wchar_t* name) { return name; }
    bool Invoke(void* address,const wchar_t* name,void*) {
        auto& o=*static_cast<Object*>(address);
        if (std::wstring_view(name)==L"PrepareLocalTestTravel") o.ints[L"NativeTestWorldClosed"]=1;
        else if (std::wstring_view(name)==L"DisableLocalTest") o.ints[L"NativeTestEnabled"]=0;
        else if (std::wstring_view(name)==L"SubmitTestAction") {
            ++dispatches;
            o.strings[L"LastTestReceipt"]=L"ok\tstatus";
        }
        return true;
    }
};
static std::string Contents(const std::filesystem::path& path) {
    std::ifstream f(path); return {std::istreambuf_iterator<char>(f),{}};
}
static std::uint64_t clockOffset=0;
int main() {
    using namespace kf2vr::localtest;
    const auto tick=std::to_string(GetTickCount64());
    const auto pid=std::to_string(GetCurrentProcessId());
    std::string session(32,'0');
    session.replace(0,pid.size(),pid); session.replace(16,tick.size(),tick);
    wchar_t temp[MAX_PATH]{}; GetTempPathW(MAX_PATH,temp);
    const auto root=std::filesystem::path(temp)/L"KF2VRLocalTest"/session;
    assert(!std::filesystem::exists(root));
    Object world,nextWorld,old,next,wrong;
    auto init=[&](Object& o,Object& w) {
        o.pointers[L"WorldInfo"]=&w; o.ints[L"NativeTestEnabled"]=1;
        o.strings[L"SessionID"]=std::wstring(session.begin(),session.end());
    };
    init(old,world); init(next,nextWorld); init(wrong,nextWorld);
    Script script;
    {
        Bridge bridge([]() -> std::uint64_t { return GetTickCount64()+clockOffset; });
        bridge.Poll(script,&old);
        assert(std::filesystem::exists(root/L"ready.tsv"));
        assert(Contents(root/L"ready.tsv").find("duration=game_session")!=std::string::npos);
        const std::string stale(32,'a'),fresh(32,'b'),original(32,'c');
        const auto wire=[&](const std::string& id) { return session+"\t"+id+"\tstatus\t0\t-\t0"; };
        { std::ofstream f(root/(original+".request")); f<<wire(original); }
        Sleep(510); bridge.Poll(script,&old);
        assert(script.dispatches==1);
        { std::ofstream f(root/(stale+".request")); f<<wire(stale); }
        // A pre-travel queued request must never execute on the destination.
        Sleep(20);
        // Advance the production channel's monotonic clock beyond 30 minutes
        // before travel; both resumption and fresh commands must remain valid.
        clockOffset=7ULL*24*60*60*1000;
        bridge.BeginTravel(script,&world);
        assert(old.ints[L"NativeTestWorldClosed"]==1);
        assert(!std::filesystem::exists(root/L"ready.tsv"));
        wrong.strings[L"SessionID"]=std::wstring(32,L'f');
        bridge.Poll(script,&wrong);
        assert(!std::filesystem::exists(root/L"ready.tsv"));
        nextWorld.ints[L"NetMode"]=3; bridge.Poll(script,&next);
        assert(!std::filesystem::exists(root/L"ready.tsv"));
        nextWorld.ints[L"NetMode"]=0;
        bridge.Poll(script,&next);
        assert(std::filesystem::exists(root/L"ready.tsv"));
        Sleep(510); bridge.Poll(script,&next);
        assert(script.dispatches==1);
        assert(Contents(root/(stale+".receipt")).find("expired_request")!=std::string::npos);
        { std::ofstream f(root/(original+".request")); f<<wire(original); }
        Sleep(510); bridge.Poll(script,&next);
        assert(script.dispatches==1); // Pre-travel ID returns its cached result.
        { std::ofstream f(root/(fresh+".request")); f<<wire(fresh); }
        Sleep(510); bridge.Poll(script,&next);
        assert(script.dispatches==2);
        { std::ofstream f(root/(fresh+".request")); f<<wire(fresh); }
        Sleep(510); bridge.Poll(script,&next);
        assert(script.dispatches==2); // Duplicate does not dispatch again.
        next.ints[L"NativeTestEnabled"]=0; bridge.Poll(script,&next);
        assert(!std::filesystem::exists(root/L"ready.tsv"));
        next.ints[L"NativeTestEnabled"]=1;
        bridge.BeginTravel(script,&nextWorld); bridge.Poll(script,&old);
        assert(!std::filesystem::exists(root/L"ready.tsv"));
    }
    // Process/session shutdown cannot attach to an old on-disk identity.
    { Bridge restarted; old.ints[L"NativeTestWorldClosed"]=0; restarted.Poll(script,&old);
      assert(old.ints[L"NativeTestEnabled"]==0); }
    // Only the generated test directory, verified above to be absent at start.
    std::filesystem::remove_all(root);
    std::cout<<"local bridge: missed actor callback, travel, identity, standalone, stale requests, dedup, disable and restart passed\n";
}
