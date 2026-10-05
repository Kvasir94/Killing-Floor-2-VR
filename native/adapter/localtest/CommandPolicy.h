#pragma once
#include <array>
#include <charconv>
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <unordered_map>

namespace kf2vr::localtest {
// No shell/console string is accepted. All values are bounded protocol tokens.
struct Request {
    std::string session, id, operation, player, argument;
    unsigned count{};
};
inline bool HexId(std::string_view value) {
    if (value.size()!=32) return false;
    for (char c:value) if (!((c>='0' && c<='9') || (c>='a' && c<='f'))) return false;
    return true;
}
inline bool Token(std::string_view value, std::size_t maximum=96) {
    if (value.empty() || value.size()>maximum) return false;
    for (char c:value) if (!((c>='a' && c<='z') || (c>='A' && c<='Z') ||
        (c>='0' && c<='9') || c=='_' || c=='-' || c=='.')) return false;
    return value.find("..") == std::string_view::npos;
}
inline bool Decimal(std::string_view value, unsigned& output) {
    if (value.empty() || value.size()>10 || (value.size()>1 && value[0]=='0')) return false;
    const auto [end,error]=std::from_chars(value.data(),value.data()+value.size(),output);
    return error==std::errc{} && end==value.data()+value.size();
}
inline bool Parse(std::string_view wire, Request& output) {
    if (wire.empty() || wire.size()>512) return false;
    if (wire.back()=='\n') wire.remove_suffix(1);
    std::array<std::string_view,6> fields{};
    for (std::size_t i=0;i<fields.size();++i) {
        const auto separator=wire.find('\t');
        if (i+1==fields.size()) { if (separator!=wire.npos) return false; fields[i]=wire; }
        else { if (separator==wire.npos) return false; fields[i]=wire.substr(0,separator); wire.remove_prefix(separator+1); }
    }
    unsigned player=0,count=0;
    if (!HexId(fields[0]) || !HexId(fields[1]) || !Decimal(fields[3],player) ||
        player>2147483647u || !Token(fields[4]) || !Decimal(fields[5],count)) return false;
    const auto op=fields[2],arg=fields[4];
    if (op=="status" || op=="disable") { if (arg!="-" || count!=0) return false; }
    else if (op=="catalog" || op=="give-all") { if (count!=0) return false; }
    else if (op=="give-one") { if (arg=="-" || count!=1) return false; }
    else if (op=="spawn-zeds") {
        constexpr std::array kinds{"cyst","alpha","slasher","crawler","gorefast","bloat","husk","scrake","fleshpound"};
        bool found=false; for (auto kind:kinds) found=found || arg==kind;
        if (!found || count<1 || count>6) return false;
    } else return false;
    output={std::string(fields[0]),std::string(fields[1]),std::string(op),std::string(fields[3]),std::string(arg),count};
    return true;
}
// Game-thread-owned. Preserve every ID until shutdown; never evict and reapply.
// A full ledger closes the session to further actions (apart from disable).
class Policy {
public:
    using Execute=std::function<std::string(const Request&)>;
    bool Enable(std::string session, bool explicitOptIn, bool localAuthority) {
        if (enabled_ || closed_ || !explicitOptIn || !localAuthority || !HexId(session)) return false;
        session_=std::move(session); enabled_=true; return true;
    }
    bool Enabled() const { return enabled_; }
    const std::string& Session() const { return session_; }
    bool Complete(const std::string& id,const std::string& receipt) {
        const auto entry=ledger_.find(id);
        if (entry==ledger_.end() || !entry->second.receipt.starts_with("pending\t") ||
            receipt.empty() || receipt.size()>65536 || receipt.starts_with("pending\t")) return false;
        entry->second.receipt=receipt; return true;
    }
    std::string Apply(std::string_view wire, std::uint64_t nowMs, const Execute& execute) {
        Request request;
        if (!Parse(wire,request)) return "error\tinvalid_request";
        if (request.session!=session_) return "error\twrong_session";
        if (const auto existing=ledger_.find(request.id);existing!=ledger_.end())
            return existing->second.wire==wire ? existing->second.receipt : "error\tid_conflict";
        if (!enabled_) return "error\tcontrols_off";
        if (ledger_.size()>=MaxActions && request.operation!="disable") return "error\tsession_action_limit";
        if (request.operation!="disable" && seenTime_ && (nowMs<lastTime_ || nowMs-lastTime_<500))
            return Remember(request.id,wire,"error\trate_limited");
        lastTime_=nowMs; seenTime_=true;
        // Reserve ID before dispatch. If dispatch fails after any effect, retry
        // returns indeterminate rather than executing an effect a second time.
        Remember(request.id,wire,"error\tindeterminate_do_not_retry");
        std::string receipt;
        try { receipt=execute(request); }
        catch (...) { receipt="error\tindeterminate_do_not_retry"; }
        if (receipt.empty() || receipt.size()>65536) receipt="error\tinvalid_game_receipt";
        ledger_.at(request.id).receipt=receipt;
        if (request.operation=="disable" && receipt.starts_with("ok\t")) { enabled_=false; closed_=true; }
        return receipt;
    }
    void Close() { enabled_=false; closed_=true; }
    static constexpr std::size_t MaxActions=256;
private:
    struct Entry { std::string wire,receipt; };
    std::string Remember(const std::string& id,std::string_view wire,std::string receipt) {
        ledger_.emplace(id,Entry{std::string(wire),receipt}); return receipt;
    }
    bool enabled_{},closed_{},seenTime_{};
    std::uint64_t lastTime_{};
    std::string session_;
    std::unordered_map<std::string,Entry> ledger_;
};
}
