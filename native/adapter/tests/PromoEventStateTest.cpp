#include "PromoEventState.h"
#include <cstdlib>
#include <iostream>
#include <limits>
using namespace kf2vr::adapter::promo;
void Check(bool value) { if (!value) { std::cerr<<"promo state check failed\n"; std::exit(1); } }
int main() {
    State state(2); state.World({1,1});
    auto hit=state.Score({10,1},20,100,80);
    Check(hit.victim==1 && hit.damage==20 && !hit.kill);
    hit=state.Score({10,1},200,80,-120);
    Check(hit.victim==1 && hit.damage==80 && hit.kill && state.Kills()==1);
    Check(!state.Score({10,1},200,80,-120).victim && state.Kills()==1);
    Check(!state.Score({10,1},20,0,-20).victim);
    Check(!state.Score({11,1},20,80,80).victim);
    Check(!state.Score({11,1},20,80,90).victim);
    hit=state.Score({10,2},30,30,0); // recycled address, new engine name
    Check(hit.victim==2 && hit.kill && state.Kills()==2);
    Check(!state.Score({12,1},30,30,0).victim && state.Dropped()==1);
    state.World({2,1});
    Check(state.Epoch()==2 && state.Score({10,1},30,30,0).kill);
    Check(state.Kills()==3); // session totals survive travel
    state.BeginTravel(); state.World({2,1}); // reused world and actor addresses
    Check(state.Epoch()==3 && state.Score({10,1},30,30,0).kill && state.Kills()==4);
    Check(HeadshotEvidence(4,5,5,true)==Headshot::TimestampAdvanced);
    Check(HeadshotEvidence(5,5,5,true)==Headshot::SameTick);
    Check(HeadshotEvidence(4,5,5,false)==Headshot::SameTick);
    Check(HeadshotEvidence(4,5,6,true)==Headshot::Unknown);
    Check(HeadshotEvidence(0,0,0,true)==Headshot::Unknown);
    Check(HeadshotEvidence(0,std::numeric_limits<float>::quiet_NaN(),5,true)==Headshot::Unknown);
    std::cout<<"promo accounting and evidence checks passed\n";
}
