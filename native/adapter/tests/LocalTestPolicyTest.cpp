#include "../localtest/CommandPolicy.h"
#include <cassert>
#include <stdexcept>
#include <iostream>

int main() {
    using namespace kf2vr::localtest;
    const std::string session(32,'a');
    auto wire=[&](char id,std::string op="give-all",std::string arg="-",unsigned count=0) {
        return session+"\t"+std::string(32,id)+"\t"+op+"\t7\t"+arg+"\t"+std::to_string(count);
    };
    Request request;
    assert(Parse(wire('b'),request));
    assert(!Parse(wire('b',"exec","EnableCheats"),request));
    assert(!Parse(wire('b',"give-one","../anything",1),request));
    assert(!Parse(wire('b',"give-one","Shotty;Quit",1),request));
    assert(!Parse(wire('b',"spawn-zeds","scrake",7),request));
    assert(!Parse(wire('b',"spawn-zeds","boss",1),request));
    assert(Parse(wire('b',"spawn-zeds","scrake",6),request));
    Policy policy; unsigned effects=0;
    auto execute=[&](const Request&) { ++effects; return "ok\tgranted=132\tcheats=unchanged"; };
    assert(policy.Apply(wire('b'),0,execute)=="error\twrong_session");
    assert(!policy.Enable(session,false,true));
    assert(!policy.Enable(session,true,false));
    assert(policy.Enable(session,true,true));
    const auto first=policy.Apply(wire('b'),0,execute);
    assert(effects==1 && first.starts_with("ok\t"));
    assert(policy.Apply(wire('b'),1,execute)==first && effects==1);
    assert(policy.Apply(wire('b',"status"),600,execute)=="error\tid_conflict" && effects==1);
    assert(policy.Apply(wire('c'),100,execute)=="error\trate_limited" && effects==1);
    assert(policy.Apply(wire('c'),1000,execute)=="error\trate_limited" && effects==1);
    assert(policy.Apply(wire('d'),500,execute)==first && effects==2);
    auto wrong=wire('e'); wrong[0]='f';
    assert(policy.Apply(wrong,1000,execute)=="error\twrong_session" && effects==2);
    assert(policy.Apply(wire('e'),1000,[](const Request&)->std::string {throw std::runtime_error("effect uncertain");})=="error\tindeterminate_do_not_retry");
    assert(policy.Apply(wire('e'),1500,execute)=="error\tindeterminate_do_not_retry" && effects==2);
    assert(policy.Apply(wire('f',"disable"),1001,[](const Request&) {return "ok\tdisabled";})=="ok\tdisabled");
    assert(!policy.Enabled());
    assert(policy.Apply(wire('f',"disable"),2000,execute)=="ok\tdisabled" && effects==2);
    assert(policy.Apply(wire('0'),2000,execute)=="error\tcontrols_off");
    assert(!policy.Enable(session,true,true));
    Policy asynchronous;
    assert(asynchronous.Enable(session,true,true));
    assert(asynchronous.Apply(wire('1'),0,[](const Request&) { return "pending\tqueued=132"; }).starts_with("pending\t"));
    assert(asynchronous.Complete(std::string(32,'1'),"ok\tgranted=132"));
    assert(!asynchronous.Complete(std::string(32,'1'),"error\tchanged_result"));
    assert(asynchronous.Apply(wire('1'),500,execute)=="ok\tgranted=132" && effects==2);
    std::cout << "local test policy: allowlist, bounds, opt-in, session, dedup, conflict, rate, uncertain effect, disable passed\n";
}
