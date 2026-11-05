#pragma once
#include "CommandPolicy.h"
#include <windows.h>
#include <algorithm>
#include <filesystem>
#include <vector>

namespace kf2vr::localtest {
// Called only by the trusted adapter on its validated game thread. This opens
// files, never processes, ports, keyboard devices, or process-memory handles.
class FileChannel {
public:
    ~FileChannel() { Close(); }
    using Clock=std::uint64_t (*)();
    explicit FileChannel(Clock clock=[]() -> std::uint64_t { return GetTickCount64(); }) : clock_(clock) {}
    FileChannel(const FileChannel&)=delete;
    FileChannel& operator=(const FileChannel&)=delete;
    bool Start(const std::string& session, bool optIn, bool localAuthority) {
        if (started_ || !policy_.Enable(session,optIn,localAuthority)) return false;
        started_=true;
        wchar_t temp[MAX_PATH]{};
        const auto length=GetTempPathW(MAX_PATH,temp);
        if (!length || length>=MAX_PATH) return Fail();
        std::filesystem::path base(temp);
        if (!base.is_absolute() || base.native().starts_with(L"\\\\") || base.native().find(L"..")!=std::wstring::npos ||
            GetDriveTypeW(base.root_path().c_str())!=DRIVE_FIXED) return Fail();
        // Hold every ancestor without delete sharing; reject junctions/symlinks
        // using handles, so later filename opens cannot escape a swapped parent.
        auto folder=base.root_path();
        if (!HoldDirectory(folder)) return Fail();
        for (const auto& part:base.relative_path()) {
            if (part.empty()) continue;
            folder/=part;
            if (!HoldDirectory(folder)) return Fail();
        }
        folder/=L"KF2VRLocalTest";
        if (!CreateDirectoryW(folder.c_str(),nullptr) && GetLastError()!=ERROR_ALREADY_EXISTS) return Fail();
        if (!HoldDirectory(folder)) return Fail();
        root_=folder/std::wstring(session.begin(),session.end());
        // Never attach to/restart an existing session; IDs cannot replay after
        // process restart. Launcher must generate a fresh session each launch.
        if (!CreateDirectoryW(root_.c_str(),nullptr)) return Fail();
        ownsDirectory_=true;
        if (!HoldDirectory(root_)) return Fail();
        audit_=Open(root_/L"audit.tsv",GENERIC_WRITE,CREATE_NEW,FILE_SHARE_READ);
        if (audit_==INVALID_HANDLE_VALUE) return Fail();
        startedMs_=clock_();
        if (!Audit("session\t"+session+"\ttest_unranked\tcapacity_bypass_transient\tcheats_unchanged\n") ||
            !Publish(L"ready.tsv",Readiness())) return Fail();
        return true;
    }
    bool Enabled() const { return policy_.Enabled(); }
    const std::string& Session() const { return policy_.Session(); }
    // Travel removes readiness but retains IDs, rate state and the original
    // session identity. A successor cannot restart a closed session.
    bool Suspend() {
        if (!policy_.Suspend()) return false;
        if (!Audit("suspended\tworld_closed\n")) return Fail();
        if (!DeleteFileW((root_/L"ready.tsv").c_str()) && GetLastError()!=ERROR_FILE_NOT_FOUND) return Fail();
        return true;
    }
    bool Resume(const std::string& session,bool optIn,bool localAuthority) {
        if (!policy_.Resume(session,optIn,localAuthority)) return false;
        // Requests queued for the departed world must not affect a new pawn.
        FILETIME resumed{}; GetSystemTimePreciseAsFileTime(&resumed);
        ULARGE_INTEGER stamp{}; stamp.LowPart=resumed.dwLowDateTime; stamp.HighPart=resumed.dwHighDateTime;
        minimumRequestTime_=stamp.QuadPart;
        if (!Audit("resumed\tsame_launch_session\n") ||
            !Publish(L"ready.tsv",Readiness())) return Fail();
        return true;
    }
    void FinishPending(const std::function<std::string(const std::string&)>& completion) {
        if (activeId_.empty()) return;
        const auto finished=completion(activeId_);
        const auto receipt=finished.empty() || finished.starts_with("pending\t") ?
            std::string("error\tindeterminate_do_not_retry") : finished;
        policy_.Complete(activeId_,receipt);
        Result(activeId_,receipt);
        activeId_.clear();
    }
    void Poll(const Policy::Execute& execute,const std::function<std::string(const std::string&)>& completion) {
        const auto now=clock_();
        if (!Enabled() || (polled_ && now-lastPoll_<500)) return;
        polled_=true; lastPoll_=now;
        if (!activeId_.empty()) {
            const auto finished=completion(activeId_);
            if (!finished.empty() && !finished.starts_with("pending\t")) {
                if (!policy_.Complete(activeId_,finished) || !Result(activeId_,finished)) { Close(); return; }
                activeId_.clear();
            }
        }
        WIN32_FIND_DATAW entry{};
        HANDLE search=FindFirstFileW((root_/L"*.request").c_str(),&entry);
        if (search==INVALID_HANDLE_VALUE) return;
        std::wstring filename;
        unsigned examined=0;
        do {
            if (++examined>32) break;
            const std::wstring name(entry.cFileName);
            if (name.size()!=40 || name.substr(32)!=L".request" ||
                (entry.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT))) continue;
            const auto id=FilenameID(name);
            if (HexId(id)) { filename=name; break; }
        } while (FindNextFileW(search,&entry));
        FindClose(search);
        if (filename.empty()) return;
        HANDLE input=Open(root_/filename,GENERIC_READ,OPEN_EXISTING,0);
        if (input==INVALID_HANDLE_VALUE) return;
        LARGE_INTEGER size{}; std::array<char,513> bytes{}; DWORD read=0;
        FILETIME modified{},utc{}; GetSystemTimePreciseAsFileTime(&utc);
        const bool timed=GetFileTime(input,nullptr,nullptr,&modified)!=0;
        ULARGE_INTEGER written{},current{};
        written.LowPart=modified.dwLowDateTime; written.HighPart=modified.dwHighDateTime;
        current.LowPart=utc.dwLowDateTime; current.HighPart=utc.dwHighDateTime;
        const bool fresh=timed && FreshRequest(written.QuadPart,current.QuadPart,minimumRequestTime_);
        const bool valid=GetFileSizeEx(input,&size) && size.QuadPart>0 && size.QuadPart<=512 &&
            ReadFile(input,bytes.data(),static_cast<DWORD>(size.QuadPart),&read,nullptr) && read==size.QuadPart;
        CloseHandle(input);
        const auto id=FilenameID(filename);
        const std::string wire(bytes.data(),read);
        Request request; std::string receipt;
        if (!valid || !Parse(wire,request) || request.id!=id) receipt="error\tinvalid_request";
        else if (!fresh) receipt="error\texpired_request";
        else {
            receipt=policy_.Apply(wire,now,[&](const Request& action) {
                // Durable intent before executing. Result writes may fail, but
                // no audit failure can result in an unaudited game mutation.
                if (!Audit("accepted\t"+wire+"\n")) { policy_.Close(); return std::string("error\taudit_unavailable"); }
                return execute(action);
            });
        }
        if (receipt.starts_with("pending\t")) activeId_=id;
        // Disable may cancel a previously accepted job; retain its final partial
        // receipt before closing the channel and leave all granted inventory.
        if (!Enabled() && !activeId_.empty()) {
            const auto finished=completion(activeId_);
            if (!finished.empty() && !finished.starts_with("pending\t")) {
                policy_.Complete(activeId_,finished);
                if (!Result(activeId_,finished)) { Close(); return; }
                activeId_.clear();
            }
        }
        if (!Result(id,receipt)) {
            // Leave request and intent audit; never retry uncertain actions.
            Close(); return;
        }
        DeleteFileW((root_/filename).c_str());
        if (!Enabled() && !policy_.Suspended()) Close();
    }
    void Close() {
        policy_.Close();
        if (ownsDirectory_) DeleteFileW((root_/L"ready.tsv").c_str());
        ownsDirectory_=false;
        if (audit_!=INVALID_HANDLE_VALUE) { CloseHandle(audit_); audit_=INVALID_HANDLE_VALUE; }
        for (auto handle:directories_) CloseHandle(handle);
        directories_.clear();
        root_.clear();
    }
private:
    std::string Readiness() const {
        // Additive metadata only: the first three columns retain their wire
        // meaning. Authority ends with this process or explicit disable.
        return policy_.Session()+"\t"+std::to_string(GetCurrentProcessId())+"\ttest_unranked"
            +"\tstart_tick_ms="+std::to_string(startedMs_)
            +"\tduration=game_session\n";
    }
    static std::string FilenameID(std::wstring_view name) {
        if (name.size()<32) return {};
        std::string id; id.reserve(32);
        for (std::size_t i=0;i<32;++i) {
            if (name[i]>127) return {};
            id.push_back(static_cast<char>(name[i]));
        }
        return HexId(id) ? id : std::string{};
    }
    bool Result(const std::string& id,const std::string& receipt) {
        if (!ownsDirectory_ || root_.empty() || audit_==INVALID_HANDLE_VALUE) return false;
        auto escaped=receipt;
        for (std::size_t at=0;(at=escaped.find('\n',at))!=std::string::npos;at+=2) escaped.replace(at,1,"\\n");
        return Audit("result\t"+id+"\t"+escaped+"\n") &&
            Publish(std::wstring(id.begin(),id.end())+L".receipt",policy_.Session()+"\t"+id+"\t"+receipt+"\n");
    }
    bool Fail() { Close(); return false; }
    bool HoldDirectory(const std::filesystem::path& path) {
        HANDLE handle=CreateFileW(path.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,
            OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
        if (handle==INVALID_HANDLE_VALUE) return false;
        BY_HANDLE_FILE_INFORMATION info{};
        if (!GetFileInformationByHandle(handle,&info) || !(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY) ||
            (info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)) { CloseHandle(handle); return false; }
        directories_.push_back(handle); return true;
    }
    static HANDLE Open(const std::filesystem::path& path,DWORD access,DWORD disposition,DWORD share) {
        HANDLE handle=CreateFileW(path.c_str(),access,share,nullptr,disposition,
            FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
        if (handle==INVALID_HANDLE_VALUE) return handle;
        BY_HANDLE_FILE_INFORMATION info{};
        if (!GetFileInformationByHandle(handle,&info) ||
            (info.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT)) || info.nNumberOfLinks!=1) {
            CloseHandle(handle); return INVALID_HANDLE_VALUE;
        }
        return handle;
    }
    bool Audit(const std::string& line) {
        DWORD written=0;
        return audit_!=INVALID_HANDLE_VALUE && WriteFile(audit_,line.data(),static_cast<DWORD>(line.size()),&written,nullptr) &&
            written==line.size() && FlushFileBuffers(audit_);
    }
    bool Publish(const std::wstring& name,const std::string& text) {
        if (!ownsDirectory_ || root_.empty()) return false;
        const auto temporary=root_/(name+L".pending");
        HANDLE output=Open(temporary,GENERIC_WRITE,CREATE_NEW,0);
        if (output==INVALID_HANDLE_VALUE) return false;
        DWORD written=0;
        const bool saved=WriteFile(output,text.data(),static_cast<DWORD>(text.size()),&written,nullptr) &&
            written==text.size() && FlushFileBuffers(output);
        CloseHandle(output);
        if (!saved || !MoveFileExW(temporary.c_str(),(root_/name).c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)) {
            DeleteFileW(temporary.c_str()); return false;
        }
        return true;
    }
    Clock clock_;
    Policy policy_;
    bool started_{},polled_{},ownsDirectory_{};
    std::string activeId_;
    std::uint64_t startedMs_{},lastPoll_{};
    std::uint64_t minimumRequestTime_{};
    std::filesystem::path root_;
    HANDLE audit_=INVALID_HANDLE_VALUE;
    std::vector<HANDLE> directories_;
};
}
