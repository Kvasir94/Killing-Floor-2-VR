#pragma once
#include <windows.h>
#include <share.h>
#include <array>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <mutex>
#include "GameScript.h"
#include "ScriptField.h"
#include "PromoEventState.h"

namespace kf2vr::adapter::promo {
// This file has a fixed output vocabulary. Engine strings, actor names,
// account IDs, paths, addresses and chat never enter its JSON serializer.
class Log {
public:
    ~Log() { if (file_) std::fclose(file_); }
    bool Enabled() const { return file_!=nullptr && !failed_.load(std::memory_order_relaxed); }
    void BeginTravel() noexcept try {
        if (Enabled()) { std::lock_guard guard(mutex_); state_.BeginTravel(); localController_=nullptr; localPlayer_=-1; }
    } catch (...) { failed_=true; }
    bool Start() noexcept try {
        wchar_t path[32768]{},session[64]{},role[16]{};
        const auto count=GetEnvironmentVariableW(L"KF2VR_PROMO_LOG_PATH",path,32768);
        if (!count || count>=32768 || GetEnvironmentVariableW(L"KF2VR_PROMO_SESSION",session,64)!=36 ||
            !GetEnvironmentVariableW(L"KF2VR_PROMO_ROLE",role,16)) return false;
        for (unsigned i=0;i<36;++i) {
            const bool dash=i==8 || i==13 || i==18 || i==23;
            if ((dash && session[i]!=L'-') || (!dash && !((session[i]>=L'0' && session[i]<=L'9') ||
                (session[i]>=L'a' && session[i]<=L'f')))) return false;
            session_[i]=static_cast<char>(session[i]);
        }
        if (wcscmp(role,L"driver")==0) role_="driver";
        else if (wcscmp(role,L"server")==0) role_="server";
        else return false;
        LARGE_INTEGER frequency{};
        if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart<=0) return false;
        frequency_=frequency.QuadPart;
        file_=_wfsopen(path,L"wb",_SH_DENYWR);
        if (!file_) return false;
        std::setvbuf(file_,nullptr,_IOFBF,65536);
        start_=Clock(); lastFlush_=start_;
        Anchor("session_start");
        return true;
    } catch (...) { failed_=true; return false; }
    static std::uint64_t Clock() { LARGE_INTEGER now{}; QueryPerformanceCounter(&now); return now.QuadPart; }
    template<class T> static bool Read(GameScript& script, void* object,const wchar_t* name,T& value) {
        if (!object) return false;
        const auto offset=script.FieldOffset(GameScript::ObjectClass(object),script.Intern(name));
        if (!offset || !GameScript::Accessible(static_cast<std::byte*>(object)+offset,sizeof(T))) return false;
        value=GameScript::At<T>(object,offset); return true;
    }
    // A scope snapshots the stock headshot timestamp before the most-derived
    // TakeDamage body. ScoreDamage runs inside it; super calls do not add scopes.
    class DamageScope {
    public:
        DamageScope(Log& log,GameScript& script,void* victim,void* function) : log_(log) {
            try {
            if (!log.Enabled() || !victim || !script.IsClass(victim,L"KFPawn_Monster") ||
                script.FindFunction(victim,L"TakeDamage")!=function || log.depth_>=log.damage_.size()) return;
            auto& entry=log.damage_[log.depth_]; entry.victim=victim;
            entry.known=Read(script,victim,L"LastHeadShotReceivedTime",entry.previous);
            ++log.depth_; entered_=true;
            } catch (...) { log.failed_=true; }
        }
        ~DamageScope() { if (entered_) --log_.depth_; }
    private:
        Log& log_; bool entered_{};
    };
    class PhysicalScope {
    public:
        PhysicalScope(Log& log,GameScript& script,void* object,GameScript::Name name) : log_(log) {
            try {
            if (!log.Enabled() || name!=script.Intern(L"ProcessScaledHit") ||
                !script.IsClass(object,L"VRMeleeScale")) return;
            ++log_.physicalDepth_; entered_=true;
            } catch (...) { log.failed_=true; }
        }
        ~PhysicalScope() { if (entered_) --log_.physicalDepth_; }
    private:
        Log& log_; bool entered_{};
    };
    static int Player(GameScript& script,void* controller) {
        if (!script.IsClass(controller,L"KFPlayerController")) return -1;
        void* pri=nullptr; int id=-1;
        if (!Read(script,controller,L"PlayerReplicationInfo",pri) || !Read(script,pri,L"PlayerID",id) ||
            id<0 || id>65535) return -1;
        return id;
    }
    void LocalPlayer(GameScript& script,void* controller) noexcept try {
        if (!Enabled() || (controller==localController_ && localPlayer_>=0)) return;
        const int id=Player(script,controller);
        if (id<0) return;
        localController_=controller; localPlayer_=id;
        std::lock_guard guard(mutex_);
        Emit(Clock(),"\"event\":\"local_player\",\"player_id\":%d",id);
    } catch (...) { failed_=true; }
    // Called only after the exact most-derived stock score callback. This is
    // authority accounting in Solo or on the host, never client hit requests.
    void Score(GameScript& script,void* game,void* function,const void* locals,void* localController=nullptr) noexcept try {
        if (!Enabled() || !script.IsClass(game,L"KFGameInfo") ||
            script.FindFunction(game,L"ScoreDamage")!=function) return;
        void* world=nullptr; unsigned char mode=255;
        if (!Read(script,game,L"WorldInfo",world) || !Read(script,world,L"NetMode",mode) ||
            (mode!=0 && mode!=1)) return;
        int amount=0,before=0,after=0; void* controller=nullptr; void* victim=nullptr; void* kind=nullptr;
        if (!ReadScriptLocal(function,locals,script.Intern(L"DamageAmount"),amount) ||
            !ReadScriptLocal(function,locals,script.Intern(L"HealthBeforeDamage"),before) ||
            !ReadScriptLocal(function,locals,script.Intern(L"InstigatedBy"),controller) ||
            !ReadScriptLocal(function,locals,script.Intern(L"DamagedPawn"),victim) ||
            !ReadScriptLocal(function,locals,script.Intern(L"DamageType"),kind) ||
            !script.IsClass(victim,L"KFPawn_Monster") || !Read(script,victim,L"Health",after) ||
            (mode==0 && controller!=localController)) return;
        const int player=Player(script,controller); if (player<0) return;
        float headTime=0,gameTime=-1; Headshot head=Headshot::Unknown;
        if (Read(script,victim,L"LastHeadShotReceivedTime",headTime) && Read(script,world,L"TimeSeconds",gameTime)) {
            const Context* context=nullptr;
            for (unsigned i=depth_;i>0;--i) if (damage_[i-1].victim==victim) { context=&damage_[i-1]; break; }
            head=HeadshotEvidence(context?context->previous:0,headTime,gameTime,context && context->known);
        }
        int remaining=-1,wave=-1; void* gri=nullptr;
        if (Read(script,world,L"GRI",gri)) {
            Read(script,gri,L"AIRemaining",remaining); Read(script,gri,L"WaveNum",wave);
        }
        std::lock_guard guard(mutex_);
        state_.World({reinterpret_cast<std::uintptr_t>(world),GameScript::ObjectName(world)});
        const auto hit=state_.Score({reinterpret_cast<std::uintptr_t>(victim),GameScript::ObjectName(victim)},amount,before,after);
        if (!hit.victim) {
            if (state_.Dropped()!=reportedDropped_) {
                reportedDropped_=state_.Dropped();
                Emit(Clock(),"\"event\":\"overflow\",\"dropped\":%llu",reportedDropped_);
            }
            return;
        }
        const auto now=Clock();
        // A kill is a separate event with the same hit id, so consumers can
        // rank death bursts without counting a contact as a death.
        const auto hitId=sequence_+1;
        const auto cause=Cause(script,kind);
        const char* physical=physicalDepth_ ? "vr_scaled_hit_scope" :
            (Derives(script,kind,L"VRDT_ZedSlam") ? "vr_grab_damage_type" :
            (cause==std::string_view("fist") || cause==std::string_view("glove_fist") ||
             cause==std::string_view("charged_fist") || cause==std::string_view("charged_glove") ? "vr_fist_damage_type" : "unknown"));
        Emit(now,"\"event\":\"hit\",\"hit_id\":%llu,\"world_epoch\":%u,\"player_id\":%d,"
            "\"victim_id\":%u,\"enemy\":\"%s\",\"cause\":\"%s\",\"damage\":%u,"
            "\"headshot_evidence\":\"%s\",\"physical_melee_evidence\":\"%s\",\"wave\":%d,\"zeds_remaining\":%d",
            hitId,state_.Epoch(),player,hit.victim,Enemy(script,victim),cause,hit.damage,
            Head(head),physical,wave,remaining);
        if (hit.kill) Emit(now,"\"event\":\"kill\",\"hit_id\":%llu,\"world_epoch\":%u,\"player_id\":%d,"
            "\"victim_id\":%u,\"enemy\":\"%s\",\"cause\":\"%s\",\"headshot_evidence\":\"%s\","
            "\"physical_melee_evidence\":\"%s\",\"kill_evidence\":\"lethal_health_transition\",\"session_kills\":%llu,\"wave\":%d,\"zeds_remaining\":%d",
            hitId,state_.Epoch(),player,hit.victim,Enemy(script,victim),cause,Head(head),physical,state_.Kills(),wave,remaining);
    } catch (...) { failed_=true; }
    void Marker(std::uint32_t marker,unsigned width,unsigned height,std::uint64_t frame) noexcept try {
        if (!Enabled()) return;
        std::lock_guard guard(mutex_);
        Anchor("sync_anchor");
        Emit(Clock(),"\"event\":\"sync\",\"marker_id\":%u,\"source\":\"desktop_backbuffer\","
            "\"width\":%u,\"height\":%u,\"frame_sample\":%llu",marker,width,height,frame);
        std::fflush(file_);
    } catch (...) { failed_=true; }
    std::uint64_t Frequency() const { return frequency_; }
private:
    struct Context { void* victim{}; float previous{}; bool known{}; };
    static const char* Head(Headshot evidence) {
        switch(evidence) { case Headshot::SameTick:return "same_game_tick_inferred";
            case Headshot::TimestampAdvanced:return "stock_timestamp_advanced"; default:return "unknown"; }
    }
    static bool Derives(GameScript& script,void* type,const wchar_t* name) {
        const auto wanted=script.Intern(name);
        for (unsigned i=0;type && i<64;++i,type=GameScript::SuperStruct(type))
            if (GameScript::ObjectName(type)==wanted) return true;
        return false;
    }
    static const char* Cause(GameScript& script,void* type) {
        const std::pair<const wchar_t*,const char*> types[]{
            {L"VRDT_ZedSlam","grab_slam"}, {L"VRDT_GloveCharged","charged_glove"},
            {L"VRDT_GloveChargedStun","charged_glove"},
            {L"VRDT_ChargedFist","charged_fist"}, {L"VRDT_ChargedFistStun","charged_fist"},
            {L"VRDT_GloveFist","glove_fist"}, {L"VRDT_FistDamage","fist"},
            {L"VRDT_GloveFistHeavy","glove_fist"}, {L"VRDT_FistDamageHeavy","fist"},
            {L"KFDT_Explosive","explosive_damage"}, {L"KFDT_Ballistic","ballistic"},
            {L"KFDT_Bludgeon","bludgeon"}, {L"KFDT_Slashing","slashing"},
            {L"KFDT_Fire","fire"}, {L"KFDT_Toxic","toxic"}, {L"KFDT_EMP","emp"}};
        for (const auto& entry:types) if (Derives(script,type,entry.first)) return entry.second;
        return "other";
    }
    static const char* Enemy(GameScript& script,void* victim) {
        const std::pair<const wchar_t*,const char*> types[]{
            {L"KFPawn_ZedClot_Cyst","cyst"}, {L"KFPawn_ZedClot_Alpha","alpha_clot"},
            {L"KFPawn_ZedClot_Slasher","slasher"}, {L"KFPawn_ZedCrawler","crawler"},
            {L"KFPawn_ZedStalker","stalker"}, {L"KFPawn_ZedGorefast","gorefast"},
            {L"KFPawn_ZedBloat","bloat"}, {L"KFPawn_ZedSiren","siren"},
            {L"KFPawn_ZedHusk","husk"}, {L"KFPawn_ZedScrake","scrake"},
            {L"KFPawn_ZedFleshpoundMini","quarterpound"}, {L"KFPawn_ZedFleshpound","fleshpound"}};
        for (const auto& entry:types) if (script.IsClass(victim,entry.first)) return entry.second;
        return "other";
    }
    void Anchor(const char* event) {
        const auto before=Clock(); FILETIME ft{}; GetSystemTimePreciseAsFileTime(&ft); const auto after=Clock();
        const auto utc=((static_cast<std::uint64_t>(ft.dwHighDateTime)<<32)|ft.dwLowDateTime)/10-11644473600000000ULL;
        Emit(before+(after-before)/2,"\"event\":\"%s\",\"utc_unix_us\":%llu,\"qpc_frequency\":%llu,"
            "\"anchor_read_span_us\":%llu",event,utc,frequency_,((after-before)*1000000+frequency_-1)/frequency_);
        std::fflush(file_);
    }
    void Emit(std::uint64_t now,const char* format,...) {
        if (failed_) return;
        if (bytes_>=64*1024*1024) {
            std::fprintf(file_,"{\"schema\":\"kf2vr/promo-events/1\",\"session_id\":\"%s\",\"role\":\"%s\","
                "\"event_id\":%llu,\"qpc_ticks\":%llu,\"t_us\":%llu,\"event\":\"log_limit\",\"limit_bytes\":67108864}\n",
                session_.data(),role_,++sequence_,now,(now-start_)*1000000/frequency_);
            std::fflush(file_); failed_=true; return;
        }
        auto count=std::fprintf(file_,"{\"schema\":\"kf2vr/promo-events/1\",\"session_id\":\"%s\",\"role\":\"%s\","
            "\"event_id\":%llu,\"qpc_ticks\":%llu,\"t_us\":%llu,",session_.data(),role_,++sequence_,now,
            (now-start_)*1000000/frequency_);
        va_list args; va_start(args,format); const auto fields=std::vfprintf(file_,format,args); va_end(args);
        if (count<0 || fields<0 || std::fputs("}\n",file_)<0) { failed_=true; return; }
        bytes_+=count+fields+2;
        if (now-lastFlush_>=frequency_) { std::fflush(file_); lastFlush_=now; }
    }
    FILE* file_{};
    std::array<char,37> session_{};
    const char* role_="driver";
    std::uint64_t frequency_{},start_{},lastFlush_{},sequence_{},bytes_{},reportedDropped_{};
    std::mutex mutex_;
    State state_;
    std::array<Context,16> damage_{};
    unsigned depth_{},physicalDepth_{};
    void* localController_{};
    int localPlayer_=-1;
    std::atomic<bool> failed_{false};
};
} // namespace kf2vr::adapter::promo
