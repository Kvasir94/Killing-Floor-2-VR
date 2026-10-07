#pragma once
#include <windows.h>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace kf2vr::adapter::epic {
enum class Result { NotRequested, Accepted, Refused };
struct Marker { std::wstring session; DWORD pid{}; std::uint64_t created{}; };
inline bool Number(std::wstring_view text,std::uint64_t& out) {
    if (text.empty()) return false;
    out=0;
    for (auto c:text) { if(c<L'0'||c>L'9'||out>(UINT64_MAX-(c-L'0'))/10) return false; out=out*10+(c-L'0'); }
    return out!=0;
}
inline bool Uuid(std::wstring_view text) {
    if(text.size()!=36) return false;
    for(size_t i=0;i<36;++i) {
        if(i==8||i==13||i==18||i==23) { if(text[i]!=L'-') return false; }
        else if(!((text[i]>=L'0'&&text[i]<=L'9')||(text[i]>=L'a'&&text[i]<=L'f'))) return false;
    }
    return true;
}
inline Result Parse(std::wstring_view command,Marker& marker) {
    constexpr std::wstring_view key=L"-kf2vr-epic-session=";
    const auto at=command.find(key);
    if(at==command.npos) return Result::NotRequested;
    if((at && command[at-1]!=L' ' && command[at-1]!=L'\t') || command.find(key,at+key.size())!=command.npos) return Result::Refused;
    const auto begin=at+key.size(),end=command.find_first_of(L" \t\r\n",begin);
    const auto value=command.substr(begin,end==command.npos?command.size()-begin:end-begin);
    const auto first=value.find(L':'),second=value.find(L':',first==value.npos?0:first+1);
    std::uint64_t pid=0,created=0;
    if(first==value.npos||second==value.npos||!Uuid(value.substr(0,first))||
       !Number(value.substr(first+1,second-first-1),pid)||pid>MAXDWORD||!Number(value.substr(second+1),created)) return Result::Refused;
    marker={std::wstring(value.substr(0,first)),static_cast<DWORD>(pid),created};return Result::Accepted;
}
struct Handle {
    HANDLE value=nullptr;
    explicit Handle(HANDLE h=nullptr):value(h) {}
    ~Handle(){if(value&&value!=INVALID_HANDLE_VALUE) CloseHandle(value);}
    Handle(const Handle&)=delete; Handle& operator=(const Handle&)=delete;
};
inline bool SameUser(HANDLE process) {
    HANDLE rawOwn=nullptr,rawPeer=nullptr;
    if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&rawOwn))return false;
    Handle own(rawOwn);
    if(!OpenProcessToken(process,TOKEN_QUERY,&rawPeer))return false;
    Handle peer(rawPeer);
    DWORD ownBytes=0,peerBytes=0;
    GetTokenInformation(own.value,TokenUser,nullptr,0,&ownBytes);
    GetTokenInformation(peer.value,TokenUser,nullptr,0,&peerBytes);
    if(!ownBytes||!peerBytes||ownBytes>65536||peerBytes>65536)return false;
    std::vector<unsigned char> a(ownBytes),b(peerBytes);
    if(!GetTokenInformation(own.value,TokenUser,a.data(),ownBytes,&ownBytes)||
       !GetTokenInformation(peer.value,TokenUser,b.data(),peerBytes,&peerBytes))return false;
    return EqualSid(reinterpret_cast<TOKEN_USER*>(a.data())->User.Sid,reinterpret_cast<TOKEN_USER*>(b.data())->User.Sid)!=FALSE;
}
inline bool Transfer(HANDLE pipe,bool writing,std::string& data) {
    OVERLAPPED operation{};Handle event(CreateEventW(nullptr,TRUE,FALSE,nullptr));
    if(!event.value)return false;operation.hEvent=event.value;
    std::vector<char> incoming(writing?0:65536);
    DWORD done=0;
    BOOL ok=writing?WriteFile(pipe,data.data(),static_cast<DWORD>(data.size()),&done,&operation):
        ReadFile(pipe,incoming.data(),static_cast<DWORD>(incoming.size()),&done,&operation);
    if(!ok) {
        if(GetLastError()!=ERROR_IO_PENDING)return false;
        if(WaitForSingleObject(event.value,5000)!=WAIT_OBJECT_0) {
            CancelIoEx(pipe,&operation);GetOverlappedResult(pipe,&operation,&done,TRUE);return false;
        }
        if(!GetOverlappedResult(pipe,&operation,&done,FALSE))return false;
    }
    if(writing)return done==data.size();
    data.assign(incoming.data(),done);return true;
}
inline bool Send(HANDLE pipe,std::string text){return Transfer(pipe,true,text);}
inline std::string Narrow(std::wstring_view text) {return std::string(text.begin(),text.end());}
inline bool Root(std::string_view utf8,std::wstring& root) {
    if(utf8.empty()||utf8.size()>30000||utf8.find_first_of("\r\n\0",0,3)!=utf8.npos)return false;
    const auto count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,utf8.data(),static_cast<int>(utf8.size()),nullptr,0);
    if(!count)return false;root.resize(count);
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,utf8.data(),static_cast<int>(utf8.size()),root.data(),count))return false;
    if(root.size()<3||root[1]!=L':'||root[2]!=L'\\'||root.back()==L'\\')return false;
    const auto attributes=GetFileAttributesW(root.c_str());
    if(attributes==INVALID_FILE_ATTRIBUTES||!(attributes&FILE_ATTRIBUTE_DIRECTORY)||(attributes&FILE_ATTRIBUTE_REPARSE_POINT))return false;
    Handle directory(CreateFileW(root.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr));
    if(directory.value==INVALID_HANDLE_VALUE)return false;
    wchar_t finalPath[32768]{};
    const auto length=GetFinalPathNameByHandleW(directory.value,finalPath,32768,FILE_NAME_NORMALIZED);
    if(length<4||length>=32768||wcsncmp(finalPath,L"\\\\?\\",4)||_wcsicmp(finalPath+4,root.c_str()))return false;
    for(const auto* name:{L"\\native.log",L"\\stop.request",L"\\playable.ready"}) {
        if(GetFileAttributesW((root+name).c_str())!=INVALID_FILE_ATTRIBUTES||GetLastError()!=ERROR_FILE_NOT_FOUND)return false;
    }
    return true;
}
inline bool GraphicsOptions(std::string_view mode,std::string_view sharp,std::string_view bile) {
    if(mode!="off" && mode!="dlaa" && mode!="quality" && mode!="balanced" && mode!="performance" && mode!="ultraperformance") return false;
    if(sharp.empty() || sharp.size()>3 || sharp.find_first_not_of("0123456789")!=sharp.npos) return false;
    unsigned value=0;for(char c:sharp)value=value*10+static_cast<unsigned>(c-'0');
    return value<=100 && (bile=="0" || bile=="1");
}
inline Result Consume(std::wstring_view command) {
    Marker marker;const auto parsed=Parse(command,marker);
    if(parsed!=Result::Accepted)return parsed;
    const std::wstring name=L"\\\\.\\pipe\\KF2VR.Epic."+marker.session;
    if(!WaitNamedPipeW(name.c_str(),5000))return Result::Refused;
    Handle pipe(CreateFileW(name.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr));
    if(pipe.value==INVALID_HANDLE_VALUE)return Result::Refused;
    ULONG serverPid=0;
    if(!GetNamedPipeServerProcessId(pipe.value,&serverPid)||serverPid!=marker.pid)return Result::Refused;
    Handle server(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,serverPid));
    FILETIME created{},exited{},kernel{},user{};
    if(!server.value||!GetProcessTimes(server.value,&created,&exited,&kernel,&user)||
       ((std::uint64_t(created.dwHighDateTime)<<32)|created.dwLowDateTime)!=marker.created||!SameUser(server.value))return Result::Refused;
    DWORD pipeMode=PIPE_READMODE_MESSAGE;
    if(!SetNamedPipeHandleState(pipe.value,&pipeMode,nullptr,nullptr))return Result::Refused;
    std::string challenge;
    if(!Transfer(pipe.value,false,challenge)||challenge.size()!=83||challenge.substr(0,18)!="KF2VR-CHALLENGE/1\n"||challenge.back()!='\n')return Result::Refused;
    const auto nonce=challenge.substr(18,64);
    if(nonce.find_first_not_of("0123456789abcdef")!=nonce.npos)return Result::Refused;
    if(!Send(pipe.value,"KF2VR-HELLO/1\n"+Narrow(marker.session)+"\n"+nonce+"\n"))return Result::Refused;
    std::string config;
    if(!Transfer(pipe.value,false,config)||config.size()>60000)return Result::Refused;
    std::vector<std::string> lines;size_t at=0;
    while(at<config.size()) {const auto end=config.find('\n',at);if(end==config.npos)return Result::Refused;lines.push_back(config.substr(at,end-at));at=end+1;}
    if(lines.size()!=7||lines[0]!="KF2VR-CONFIG/2"||lines[1]!=Narrow(marker.session))return Result::Refused;
    std::wstring root;std::uint64_t percent=0;const std::wstring percentText(lines[3].begin(),lines[3].end());
    if(!Root(lines[2],root)||!Number(percentText,percent)||percent<50||percent>100)return Result::Refused;
    // Typed options only. Runtime location is derived from the authenticated
    // packaged broker executable, never accepted as a supplied path or env map.
    const auto& mode=lines[4];
    const auto& sharp=lines[5];
    if(!GraphicsOptions(mode,sharp,lines[6])) return Result::Refused;
    std::wstring ngx;
    if(mode!="off") {
        wchar_t executable[32768]{};DWORD size=32768;
        if(!QueryFullProcessImageNameW(server.value,0,executable,&size)) return Result::Refused;
        std::wstring path(executable,size);const auto slash=path.find_last_of(L"\\");
        if(slash==path.npos) return Result::Refused;
        path.resize(slash);const auto parent=path.find_last_of(L"\\");
        if(parent==path.npos || _wcsicmp(path.substr(parent+1).c_str(),L"runtime")) return Result::Refused;
        path.resize(parent);ngx=path+L"\\Native";
        const auto attr=GetFileAttributesW((ngx+L"\\nvngx_dlss.dll").c_str());
        if(attr==INVALID_FILE_ATTRIBUTES || (attr&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT))) return Result::Refused;
    }
    if(!Send(pipe.value,"KF2VR-READY/1\n"))return Result::Refused;
    std::string accepted;
    if(!Transfer(pipe.value,false,accepted)||accepted!="KF2VR-ACCEPTED/1\n"||WaitForSingleObject(server.value,0)!=WAIT_TIMEOUT)return Result::Refused;
    // Only fixed owned output paths, never arbitrary environment assignments.
    auto* block=GetEnvironmentStringsW();if(!block)return Result::Refused;
    std::vector<std::wstring> remove;
    for(auto* line=block;*line;line+=wcslen(line)+1)if(!_wcsnicmp(line,L"KF2VR_",6)) {const auto* equals=wcschr(line,L'=');if(equals)remove.emplace_back(line,static_cast<size_t>(equals-line));}
    FreeEnvironmentStringsW(block);
    for(const auto& key:remove)if(!SetEnvironmentVariableW(key.c_str(),nullptr))return Result::Refused;
    if(!SetEnvironmentVariableW(L"KF2VR_LOG_PATH",(root+L"\\native.log").c_str())||
       !SetEnvironmentVariableW(L"KF2VR_STOP_PATH",(root+L"\\stop.request").c_str())||
       !SetEnvironmentVariableW(L"KF2VR_PLAYABLE_PATH",(root+L"\\playable.ready").c_str())||
       !SetEnvironmentVariableW(L"KF2VR_EYE_RENDER_PERCENT",percentText.c_str()) ||
       !SetEnvironmentVariableW(L"KF2VR_DLSS",std::wstring(mode.begin(),mode.end()).c_str()) ||
       !SetEnvironmentVariableW(L"KF2VR_DLSS_SHARPNESS",std::wstring(sharp.begin(),sharp.end()).c_str()) ||
       !SetEnvironmentVariableW(L"KF2VR_HIDE_BILE_LENS",lines[6]=="1"?L"1":L"0") ||
       (!ngx.empty() && !SetEnvironmentVariableW(L"KF2VR_NGX_DIR",ngx.c_str())))return Result::Refused;
    return Result::Accepted;
}
} // namespace kf2vr::adapter::epic
