#pragma once
#include "FileChannel.h"
#include "DiagnosticInput.h"
#include "../GameScript.h"
#include <shellapi.h>
#pragma comment(lib, "shell32.lib")

namespace kf2vr::localtest {
class Bridge {
public:
    static bool DiagnosticLaunchOptIn() {
        static const bool allowed=[] {
            int count=0; auto* arguments=CommandLineToArgvW(GetCommandLineW(),&count);
            bool diagnostic=false, control=false, stereo=false, forbidden=false;
            if (arguments) {
                for (int i=1;i<count;++i) {
                    diagnostic|=wcscmp(arguments[i],L"-kf2vr-local-test-diagnostic")==0;
                    control|=wcscmp(arguments[i],L"-kf2vr-local-test-control")==0;
                    stereo|=wcscmp(arguments[i],L"-kf2vr-stereo")==0;
                    forbidden|=wcscmp(arguments[i],L"-kf2vr-network")==0 || wcscmp(arguments[i],L"-kf2vr-hand-replay")==0 ||
                        wcscmp(arguments[i],L"-kf2vr-input-replay")==0 || wcscmp(arguments[i],L"-kf2vr-motion-fixture")==0 ||
                        wcscmp(arguments[i],L"-kf2vr-perf-capture")==0;
                }
                LocalFree(arguments);
            }
            return diagnostic && control && stereo && !forbidden;
        }();
        return allowed;
    }
    const DiagnosticInput& Input() const { return input_; }
    // The caller must first validate the current game's world thread and exact
    // owned NativeLocalTestPoll UFunction. The diagnostic verification field
    // is written only after the same session/world authority check.
    void Poll(adapter::GameScript& script,void* mutator,bool liveDiagnosticXr=false) {
        if (!LaunchOptIn()) { input_.Clear(); return; }
        const auto session=Text(script,mutator,L"SessionID",32);
        if (!HexId(session)) { input_.Clear(); return; }
        auto* world=script.Read<void*>(mutator,L"WorldInfo");
        if (!world || script.Read<std::uint8_t>(world,L"NetMode")!=0) { input_.Clear(); return; }
        if (!started_) {
            if (script.Read<int>(mutator,L"NativeTestEnabled")!=1) return;
            started_=true; owner_=mutator;
            if (!channel_.Start(session,true,true)) { Disable(script,mutator); return; }
        }
        // World travel/GC never transfers a session's authority to a new actor.
        if (owner_!=mutator || session!=channel_.Session()) { input_.Clear(); return; }
        const bool diagnostic=DiagnosticLaunchOptIn() && liveDiagnosticXr && channel_.Enabled() &&
            script.Read<int>(mutator,L"NativeTestEnabled")==1 && script.Read<int>(mutator,L"NativeDiagnosticEnabled")==1;
        script.Write(mutator,L"NativeDiagnosticVerified",diagnostic?1:0);
        input_.Update(diagnostic,script.Read<int>(mutator,L"NativeDiagnosticTriggerMask"),
            script.Read<int>(mutator,L"NativeDiagnosticButtonMask"),GetTickCount64());
        const auto completion=[&](const std::string& id) {
            if (Text(script,mutator,L"CompletedActionID",32)!=id) return std::string{};
            return Text(script,mutator,L"CompletedReceipt",65536);
        };
        if (script.Read<int>(mutator,L"NativeTestEnabled")!=1) {
            channel_.FinishPending(completion);
            input_.Clear(); channel_.Close(); return;
        }
        channel_.Poll([&](const Request& request) {
            const auto wire=request.session+"\t"+request.id+"\t"+request.operation+"\t"+request.player+"\t"+
                request.argument+"\t"+std::to_string(request.count);
            if (!Invoke(script,mutator,L"SubmitTestAction",wire)) return std::string("error\tgame_dispatch_failed");
            return Text(script,mutator,L"LastTestReceipt",65536);
        },completion);
        if (!channel_.Enabled()) { input_.Clear(); Disable(script,mutator); }
    }
private:
    struct ScriptString { const wchar_t* data; int count,capacity; };
    static bool LaunchOptIn() {
        static const bool allowed=[] {
            int count=0; auto* arguments=CommandLineToArgvW(GetCommandLineW(),&count);
            bool found=false;
            if (arguments) {
                for (int i=1;i<count;++i) if (wcscmp(arguments[i],L"-kf2vr-local-test-control")==0) found=true;
                LocalFree(arguments);
            }
            return found;
        }();
        return allowed;
    }
    static std::string Text(adapter::GameScript& script,void* object,const wchar_t* field,std::size_t maximum) {
        const auto value=script.Read<ScriptString>(object,field);
        if (value.count<0 || value.capacity<value.count || static_cast<std::size_t>(value.count)>maximum+1 ||
            (!value.data && value.count)) return {};
        std::string output;
        for (int i=0;i<value.count;++i) {
            const auto character=adapter::GameScript::At<wchar_t>(value.data,static_cast<std::size_t>(i)*sizeof(wchar_t));
            if (character==0) return output;
            if (character>127 || character==13 || (character<32 && character!=9 && character!=10)) return {};
            output.push_back(static_cast<char>(character));
        }
        return {}; // UE strings must carry a terminator.
    }
    static bool Invoke(adapter::GameScript& script,void* object,const wchar_t* function,const std::string& input) {
        std::wstring text(input.begin(),input.end());
        ScriptString parameters{text.c_str(),static_cast<int>(text.size()+1),static_cast<int>(text.size()+1)};
        return script.Invoke(object,script.FindFunction(object,function),&parameters);
    }
    static void Disable(adapter::GameScript& script,void* mutator) {
        Invoke(script,mutator,L"DisableLocalTest","native_channel_closed");
    }
    FileChannel channel_;
    DiagnosticInput input_;
    bool started_{};
    void* owner_{};
};
}
