#undef NDEBUG
#include "../localtest/CommandPolicy.h"
#include "../localtest/DiagnosticInput.h"
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
    assert(FreshRequest(100,100));
    assert(FreshRequest(100,100+60ULL*10000000));
    assert(!FreshRequest(100,101+60ULL*10000000));
    assert(!FreshRequest(101,100));
    assert(!FreshRequest(100,200,150));
    assert(!FreshRequest(150,200,150));
    assert(FreshRequest(151,200,150));
    assert(Parse(wire('b'),request));
    assert(!Parse(wire('b',"exec","EnableCheats"),request));
    assert(Parse(wire('b',"console","set Engine.GameInfo GameSpeed 0.5"),request));
    assert(Parse(wire('b',"console","exec \"../test commands.txt\""),request));
    assert(Parse(wire('b',"console",std::string(384,'x')),request));
    assert(!Parse(wire('b',"console",std::string(385,'x')),request));
    for (auto text : {"", "   ", "god\tquit", "god\nquit", "god\rquit"})
        assert(!Parse(wire('b',"console",text),request));
    assert(!Parse(wire('b',"console","god",1),request));
    assert(!Parse(wire('b',"give-one","../anything",1),request));
    assert(!Parse(wire('b',"give-one","Shotty;Quit",1),request));
    assert(!Parse(wire('b',"spawn-zeds","scrake",7),request));
    assert(!Parse(wire('b',"spawn-zeds","boss",1),request));
    assert(Parse(wire('b',"spawn-zeds","scrake",6),request));
    assert(Parse(wire('b',"diagnostic","case-deadbolt-left-manual"),request));
    assert(Parse(wire('b',"diagnostic","case-ripcord-right-automatic"),request));
    assert(!Parse(wire('b',"diagnostic","case-other-right-manual"),request));
    assert(!Parse(wire('b',"diagnostic","case-deadbolt-left-manual",1),request));
    DiagnosticInput input;
    assert(!input.Fresh(0) && input.Triggers(0)==0 && input.Buttons(0)==0);
    input.Update(true,2,8,1000);
    assert(input.Fresh(1250) && input.Triggers(1250)==2 && input.Buttons(1250)==8);
    assert(!input.Fresh(999) && !input.Fresh(1251) && input.Triggers(1251)==0 && input.Buttons(1251)==0);
    input.Update(false,3,9,1300);
    assert(input.Triggers(1300)==0 && input.Buttons(1300)==0);
    input.Update(true,4,8,1400);
    assert(!input.Fresh(1400));
    input.Update(true,2,2,1500);
    assert(!input.Fresh(1500));
    input.Update(true,1,1,1600); input.Clear();
    assert(input.Triggers(1600)==0 && input.Buttons(1600)==0);
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
    Policy console;
    assert(console.Enable(session,true,true));
    unsigned commands=0;
    auto dispatch=[&](const Request& r) { ++commands; assert(r.argument=="god"); return "ok\tconsole_dispatched=1"; };
    const auto command=wire('a',"console","god");
    assert(console.Apply(command,0,dispatch).starts_with("ok\t"));
    assert(console.Apply(command,1000,dispatch).starts_with("ok\t") && commands==1);
    assert(console.Apply(wire('a',"console","ghost"),2000,dispatch)=="error\tid_conflict" && commands==1);
    assert(asynchronous.Enable(session,true,true));
    assert(asynchronous.Apply(wire('1'),0,[](const Request&) { return "pending\tqueued=132"; }).starts_with("pending\t"));
    assert(asynchronous.Complete(std::string(32,'1'),"ok\tgranted=132"));
    assert(!asynchronous.Complete(std::string(32,'1'),"error\tchanged_result"));
    assert(asynchronous.Apply(wire('1'),500,execute)=="ok\tgranted=132" && effects==2);
    Policy travel;
    assert(!travel.Suspend() && !travel.Resume(session,true,true));
    assert(travel.Enable(session,true,true));
    assert(travel.Apply(wire('2'),1000,execute)==first && effects==3);
    assert(travel.Suspend() && travel.Suspended() && !travel.Enabled());
    assert(!travel.Suspend());
    assert(travel.Apply(wire('3'),1500,execute)=="error\tcontrols_off" && effects==3);
    assert(travel.Apply(wire('2'),1500,execute)==first && effects==3);
    assert(!travel.Resume(std::string(32,'f'),true,true));
    assert(!travel.Resume(session,false,true));
    assert(!travel.Resume(session,true,false));
    assert(travel.Resume(session,true,true) && travel.Enabled());
    assert(!travel.Resume(session,true,true));
    assert(travel.Apply(wire('2'),1600,execute)==first && effects==3);
    assert(travel.Apply(wire('2',"status"),1600,execute)=="error\tid_conflict");
    // Travel does not reset the rate limit or let a closed session revive.
    assert(travel.Apply(wire('3'),1200,execute)=="error\trate_limited" && effects==3);
    // A fresh action remains valid after days in the same opted-in process.
    assert(travel.Apply(wire('5'),7ULL*24*60*60*1000,execute)==first && effects==4);
    assert(travel.Suspend()); travel.Close();
    assert(!travel.Suspended() && !travel.Resume(session,true,true));
    assert(travel.Apply(wire('4'),2000,execute)=="error\tcontrols_off" && effects==4);
    std::cout << "local test policy: allowlist, bounds, opt-in, session, dedup, conflict, rate, uncertain effect, disable, travel suspension and request freshness passed\n";
}
