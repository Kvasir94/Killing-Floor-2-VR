// Diagnostic wall-clock stack sampling of one explicitly owned x64 thread.
// Only copy context + committed stack while suspended. Resume BEFORE DbgHelp,
// symbol lookup, allocation, logging, or walking. No injected game code.
#include <windows.h>
#include <dbghelp.h>
#include <psapi.h>
#include <array>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

double Now() { return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
unsigned long long FileTicks(FILETIME f) { return (static_cast<unsigned long long>(f.dwHighDateTime)<<32)|f.dwLowDateTime; }
struct Handle {
    HANDLE value=nullptr;
    ~Handle(){ if(value && value!=INVALID_HANDLE_VALUE) CloseHandle(value); }
};
struct Module { DWORD64 base=0;DWORD size=0;std::string path,name; };
std::vector<Module> Modules(HANDLE process) {
    std::array<HMODULE,2048> handles{};DWORD bytes=0;
    std::vector<Module> result;
    if(!EnumProcessModulesEx(process,handles.data(),sizeof(handles),&bytes,LIST_MODULES_64BIT) || bytes>sizeof(handles)) return result;
    for(unsigned i=0;i<bytes/sizeof(HMODULE);++i) {
        MODULEINFO info{};char path[32768]{};
        if(GetModuleInformation(process,handles[i],&info,sizeof(info)) && GetModuleFileNameExA(process,handles[i],path,sizeof(path)))
            result.push_back({reinterpret_cast<DWORD64>(info.lpBaseOfDll),info.SizeOfImage,path,std::filesystem::path(path).filename().string()});
    }
    return result;
}
struct Snapshot {
    CONTEXT context{};
    std::array<unsigned char,65536> stack{};
    DWORD64 base=0;SIZE_T bytes=0;
    double tick=0,paused=0;
    unsigned long long cpu=0;
    bool ok=false,cpuValid=false,resumed=true,truncated=false;
};
// All operations in this interval are Windows context/memory/counter calls.
void Capture(HANDLE process,HANDLE thread,Snapshot& out) {
    out.context={};out.context.ContextFlags=CONTEXT_FULL;
    out.bytes=0;out.ok=false;out.cpuValid=false;out.truncated=false;out.resumed=true;
    const double start=Now();out.tick=start;
    const DWORD previous=SuspendThread(thread);
    if(previous==DWORD(-1)) return;
    if(previous==0) {
        out.ok=GetThreadContext(thread,&out.context)!=FALSE;
        out.tick=Now();
        if(out.ok) {
            out.base=out.context.Rsp;
            MEMORY_BASIC_INFORMATION region{};
            if(VirtualQueryEx(process,reinterpret_cast<void*>(out.base),&region,sizeof(region)) &&
               region.State==MEM_COMMIT && !(region.Protect&(PAGE_NOACCESS|PAGE_GUARD))) {
                const auto end=reinterpret_cast<DWORD64>(region.BaseAddress)+region.RegionSize;
                const auto wanted=static_cast<SIZE_T>(std::min<DWORD64>(out.stack.size(),end-out.base));
                out.truncated=end-out.base>out.stack.size();
                ReadProcessMemory(process,reinterpret_cast<void*>(out.base),out.stack.data(),wanted,&out.bytes);
            }
            FILETIME created{},exited{},kernel{},user{};
            out.cpuValid=GetThreadTimes(thread,&created,&exited,&kernel,&user)!=FALSE;
            out.cpu=FileTicks(kernel)+FileTicks(user);
        }
    }
    // Always remove exactly our suspension, including when already suspended.
    out.resumed=ResumeThread(thread)!=DWORD(-1);
    out.paused=Now()-start;
}
Snapshot* activeSnapshot=nullptr;
const std::vector<Module>* activeModules=nullptr;
BOOL CALLBACK ReadSnapshot(HANDLE process,DWORD64 address,PVOID buffer,DWORD size,LPDWORD read) {
    *read=0;
    if(!activeSnapshot || address+size<address) return FALSE;
    const auto& s=*activeSnapshot;
    if(address>=s.base && address+size<=s.base+s.bytes) {
        std::memcpy(buffer,s.stack.data()+static_cast<SIZE_T>(address-s.base),size);*read=size;return TRUE;
    }
    // After resume, only image/unwind data may be read live. Never consult the
    // moving remote stack or arbitrary heap; missing snapshot data truncates.
    for(const auto& m:*activeModules) if(address>=m.base && address+size<=m.base+m.size) {
        SIZE_T count=0;
        const bool ok=ReadProcessMemory(process,reinterpret_cast<void*>(address),buffer,size,&count)!=FALSE;
        *read=static_cast<DWORD>(count);return ok;
    }
    return FALSE;
}
std::vector<DWORD64> Walk(HANDLE process,HANDLE thread,Snapshot& snapshot,const std::vector<Module>& modules) {
    std::vector<DWORD64> result;
    if(!snapshot.ok || !snapshot.resumed) return result;
    activeSnapshot=&snapshot;activeModules=&modules;
    CONTEXT context=snapshot.context;
    STACKFRAME64 frame{};
    frame.AddrPC={context.Rip,0,AddrModeFlat};frame.AddrStack={context.Rsp,0,AddrModeFlat};frame.AddrFrame={context.Rbp,0,AddrModeFlat};
    result.push_back(context.Rip);
    DWORD64 previousIp=context.Rip,previousSp=context.Rsp;
    for(int i=0;i<48;++i) {
        if(!StackWalk64(IMAGE_FILE_MACHINE_AMD64,process,thread,&frame,&context,&ReadSnapshot,
            SymFunctionTableAccess64,SymGetModuleBase64,nullptr) || !frame.AddrPC.Offset) break;
        if(frame.AddrPC.Offset==previousIp && frame.AddrStack.Offset==previousSp) {
            if(i==0) continue;
            break;
        }
        // A truncated unwind must not turn stack data into invented callers.
        MEMORY_BASIC_INFORMATION region{};
        const bool image=std::any_of(modules.begin(),modules.end(),[&](const Module& m) {
            return frame.AddrPC.Offset>=m.base && frame.AddrPC.Offset<m.base+m.size;
        });
        if(!image || frame.AddrStack.Offset<previousSp || frame.AddrStack.Offset>snapshot.base+snapshot.bytes ||
           !VirtualQueryEx(process,reinterpret_cast<void*>(frame.AddrPC.Offset),&region,sizeof(region)) ||
           !(region.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY))) break;
        result.push_back(frame.AddrPC.Offset);previousIp=frame.AddrPC.Offset;previousSp=frame.AddrStack.Offset;
    }
    activeSnapshot=nullptr;activeModules=nullptr;return result;
}
std::string Clean(std::string value) { for(auto& c:value) if(c==',' || c=='\r' || c=='\n' || c=='"') c='_';return value; }
int Record(DWORD pid,DWORD tid,unsigned long long creation,unsigned seconds,const std::filesystem::path& output,bool selfTest=false,
           const std::filesystem::path& symbolDirectory={}) {
    Handle process{OpenProcess(PROCESS_QUERY_INFORMATION|PROCESS_VM_READ|SYNCHRONIZE,FALSE,pid)};
    Handle thread{OpenThread(THREAD_GET_CONTEXT|THREAD_SUSPEND_RESUME|THREAD_QUERY_INFORMATION|SYNCHRONIZE,FALSE,tid)};
    FILETIME started{},ended{},kernel{},user{};
    if(!process.value || !thread.value || GetProcessIdOfThread(thread.value)!=pid ||
       !GetProcessTimes(process.value,&started,&ended,&kernel,&user) || FileTicks(started)!=creation) {
        std::fprintf(stderr,"Process/thread ownership check failed (%lu)\n",GetLastError());return 2;
    }
    auto modules=Modules(process.value);
    if(modules.empty()) return 3;
    SymSetOptions(SYMOPT_DEFERRED_LOADS|SYMOPT_FAIL_CRITICAL_ERRORS|SYMOPT_NO_PROMPTS|SYMOPT_IGNORE_NT_SYMPATH);
    // Explicit local path only; never contact a symbol server during capture.
    const auto symbols=std::filesystem::path(modules.front().path).parent_path().string()+
        (symbolDirectory.empty()?"":";"+symbolDirectory.string());
    if(!SymInitialize(process.value,symbols.c_str(),TRUE)) return 3;
    FILE* samples=nullptr;FILE* stacks=nullptr;
    const auto samplePath=output/L"stack-samples.csv",stackPath=output/L"stack-frames.csv";
    _wfopen_s(&samples,samplePath.c_str(),L"wbx");_wfopen_s(&stacks,stackPath.c_str(),L"wbx");
    if(!samples || !stacks) { if(samples) std::fclose(samples);if(stacks) std::fclose(stacks);SymCleanup(process.value);return 4; }
    std::setvbuf(samples,nullptr,_IOFBF,65536);std::setvbuf(stacks,nullptr,_IOFBF,1024*1024);
    std::fputs("tickMs,sample,pausedMs,threadCpu100ns,cpuCounterValid,contextOk,stackBytes,stackCapacityLimited,depth\n",samples);
    std::fputs("sample,depth,ip,module,rva,symbol,displacement\n",stacks);
    Snapshot snapshot;unsigned count=0,walks=0;double pauseTotal=0,maxPause=0;
    std::uint32_t random=0xa341316c;const double start=Now();bool bad=false;
    while(Now()-start<seconds*1000 && WaitForSingleObject(process.value,0)==WAIT_TIMEOUT && WaitForSingleObject(thread.value,0)==WAIT_TIMEOUT) {
        Capture(process.value,thread.value,snapshot);
        if(!snapshot.resumed) { bad=true;break; }
        const auto addresses=Walk(process.value,thread.value,snapshot,modules);
        ++count;walks+=addresses.size()>1;pauseTotal+=snapshot.paused;maxPause=std::max(maxPause,snapshot.paused);
        std::fprintf(samples,"%.6f,%u,%.6f,%llu,%d,%d,%zu,%d,%zu\n",snapshot.tick,count,snapshot.paused,
            snapshot.cpu,snapshot.cpuValid,snapshot.ok,snapshot.bytes,snapshot.truncated,addresses.size());
        for(std::size_t depth=0;depth<addresses.size();++depth) {
            const auto address=addresses[depth];std::string module="unknown";DWORD64 rva=address;
            for(const auto& m:modules) if(address>=m.base && address<m.base+m.size) { module=m.name;rva=address-m.base;break; }
            alignas(SYMBOL_INFO) unsigned char storage[sizeof(SYMBOL_INFO)+MAX_SYM_NAME]{};
            auto* symbol=reinterpret_cast<SYMBOL_INFO*>(storage);symbol->SizeOfStruct=sizeof(SYMBOL_INFO);symbol->MaxNameLen=MAX_SYM_NAME;
            DWORD64 displacement=0;const bool named=SymFromAddr(process.value,address,&displacement,symbol)!=FALSE;
            std::fprintf(stacks,"%u,%zu,%llx,%s,%llx,%s,%llu\n",count,depth,address,Clean(module).c_str(),rva,
                named?Clean(symbol->Name).c_str():"",named?displacement:0);
        }
        // Stop after an excessive pause instead of silently distorting the run.
        // This is an observed limit, not a hard real-time OS guarantee.
        if(snapshot.paused>5.0 || (count>=20 && pauseTotal/(Now()-start)>.02)) { bad=true;break; }
        if(std::ferror(samples) || std::ferror(stacks)) { bad=true;break; }
        random^=random<<13;random^=random>>17;random^=random<<5;
        Sleep(17+random%7); // Jitter avoids locking to the application's period.
    }
    const double elapsed=Now()-start;
    const int sampleClose=std::fclose(samples),stackClose=std::fclose(stacks);
    if(sampleClose!=0 || stackClose!=0) bad=true;
    SymCleanup(process.value);
    FILE* receipt=nullptr;const auto receiptPath=output/L"stack-receipt.json";
    _wfopen_s(&receipt,receiptPath.c_str(),L"wbx");
    if(!receipt) return 4;
    std::fprintf(receipt,"{\"schema\":\"kf2vr/stack-samples/1\",\"process_id\":%lu,\"thread_id\":%lu,\"samples\":%u,\"walked_samples\":%u,\"elapsed_ms\":%.6f,\"paused_ms\":%.6f,\"max_pause_ms\":%.6f,\"aborted\":%s,\"self_test\":%s,\"scope\":\"wall-clock-user-stacks-not-on-cpu-samples\"}\n",
        pid,tid,count,walks,elapsed,pauseTotal,maxPause,bad?"true":"false",selfTest?"true":"false");
    std::fclose(receipt);
    std::printf("samples=%u walked=%u paused=%.3fms maxPause=%.3fms elapsed=%.1fms aborted=%d\n",count,walks,pauseTotal,maxPause,elapsed,bad);
    return bad || !count || !walks ? 5:0;
}
__declspec(noinline) void FixtureWork() {
    const double deadline=Now()+4000;volatile unsigned long long value=7;
    while(Now()<deadline) { for(int i=0;i<10000;++i) value=value*6364136223846793005ULL+1;Sleep(1); }
}
__declspec(noinline) int FixtureRoot() { FixtureWork();return GetCurrentThreadId()!=0?0:1; }
BOOL CALLBACK FindAdapterSymbol(PSYMBOL_INFO info,ULONG,void* found) {
    if(std::string(info->Name).ends_with("::HookProcessInternal")) {
        *static_cast<bool*>(found)=true;std::printf("resolved=%s address=%llx\n",info->Name,info->Address);
    }
    return TRUE;
}
int wmain(int argc,wchar_t** argv) {
    if(argc==4 && std::wstring(argv[1])==L"--symbols-test") {
        const auto process=GetCurrentProcess();bool found=false;
        SymSetOptions(SYMOPT_DEFERRED_LOADS|SYMOPT_FAIL_CRITICAL_ERRORS|SYMOPT_NO_PROMPTS|SYMOPT_IGNORE_NT_SYMPATH);
        if(!SymInitialize(process,std::filesystem::path(argv[3]).string().c_str(),FALSE)) return 8;
        const auto base=SymLoadModuleEx(process,nullptr,std::filesystem::path(argv[2]).string().c_str(),nullptr,0,0,nullptr,0);
        if(base) SymEnumSymbols(process,base,"*HookProcessInternal*",&FindAdapterSymbol,&found);
        SymCleanup(process);return found?0:8;
    }
    if(argc==2 && std::wstring(argv[1])==L"--fixture") return FixtureRoot();
    if(argc==2 && std::wstring(argv[1])==L"--self-test") {
        wchar_t exe[32768]{};GetModuleFileNameW(nullptr,exe,32768);
        std::wstring command=L"\""+std::wstring(exe)+L"\" --fixture";
        STARTUPINFOW startup{sizeof(startup)};PROCESS_INFORMATION child{};
        if(!CreateProcessW(exe,command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child)) return 6;
        Handle process{child.hProcess},thread{child.hThread};FILETIME created{},ended{},kernel{},user{};
        GetProcessTimes(process.value,&created,&ended,&kernel,&user);
        const auto root=std::filesystem::temp_directory_path()/(L"kf2vr-sampler-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
        std::filesystem::create_directories(root);Sleep(250);
        const auto result=Record(child.dwProcessId,child.dwThreadId,FileTicks(created),1,root,true);
        // Natural exit proves the sampled thread wasn't left suspended.
        const bool exited=WaitForSingleObject(process.value,6000)==WAIT_OBJECT_0;
        FILE* frames=nullptr;_wfopen_s(&frames,(root/L"stack-frames.csv").c_str(),L"rb");
        bool rootFound=false,workFound=false;
        if(frames) { char line[4096];while(std::fgets(line,sizeof(line),frames)) {
            rootFound=rootFound || std::strstr(line,",FixtureRoot,")!=nullptr;
            workFound=workFound || std::strstr(line,",FixtureWork,")!=nullptr;
        } std::fclose(frames); }
        std::printf("fixtureExited=%d rootFound=%d workFound=%d output=%ls\n",exited,rootFound,workFound,root.c_str());
        return result || !exited || !rootFound || !workFound ? 7:0;
    }
    if(argc!=6 && argc!=7) { std::fprintf(stderr,"Usage: sampler PID TID processCreationFileTime seconds existing-output-directory [local-symbol-directory]\n");return 1; }
    const DWORD pid=wcstoul(argv[1],nullptr,10),tid=wcstoul(argv[2],nullptr,10);
    const auto creation=_wcstoui64(argv[3],nullptr,10);const unsigned seconds=wcstoul(argv[4],nullptr,10);
    if(!pid || !tid || !creation || seconds<1 || seconds>60 || !std::filesystem::is_directory(argv[5])) return 1;
    if(argc==7 && !std::filesystem::is_directory(argv[6])) return 1;
    return Record(pid,tid,creation,seconds,argv[5],false,argc==7?std::filesystem::path(argv[6]):std::filesystem::path{});
}
