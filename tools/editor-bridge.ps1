# Load the pinned package-save helper into the editor process started by the
# hand asset builder. It is never staged in the game installation or game run.
function Import-EditorSaveBridge([Diagnostics.Process]$Process, [string]$DllPath) {
    if ($Process.HasExited -or $Process.ProcessName -ne 'KFEditor') { throw 'The owned editor is unavailable for its save bridge.' }
    if (-not ('KF2VR.EditorBridgeLoader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
namespace KF2VR {
    public static class EditorBridgeLoader {
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UIntPtr size, uint type, uint protect);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool VirtualFreeEx(IntPtr process, IntPtr address, UIntPtr size, uint type);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool WriteProcessMemory(IntPtr process, IntPtr address, byte[] data, UIntPtr size, out UIntPtr written);
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateRemoteThread(IntPtr process, IntPtr attributes, UIntPtr stack, IntPtr start, IntPtr parameter, uint flags, IntPtr id);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeThread(IntPtr thread, out uint code);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
        [DllImport("kernel32.dll", CharSet=CharSet.Ansi, ExactSpelling=true)] static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        static Exception Error(string operation) { return new Win32Exception(Marshal.GetLastWin32Error(), operation); }
        public static void Load(Process target, string file) {
            IntPtr process=IntPtr.Zero, memory=IntPtr.Zero, thread=IntPtr.Zero;
            bool finished=false;
            try {
                // Resolve the containing module because kernel32 may forward
                // LoadLibraryW to KernelBase, whose base differs by process.
                IntPtr local = GetProcAddress(GetModuleHandle("kernel32.dll"), "LoadLibraryW");
                string moduleName=null; long offset=0;
                foreach (ProcessModule module in Process.GetCurrentProcess().Modules) {
                    long delta=local.ToInt64()-module.BaseAddress.ToInt64();
                    if (delta >= 0 && delta < module.ModuleMemorySize) { moduleName=module.ModuleName; offset=delta; break; }
                }
                IntPtr remote=IntPtr.Zero;
                foreach (ProcessModule module in target.Modules)
                    if (String.Equals(module.ModuleName,moduleName,StringComparison.OrdinalIgnoreCase)) remote=new IntPtr(module.BaseAddress.ToInt64()+offset);
                if (local==IntPtr.Zero || remote==IntPtr.Zero) throw new InvalidOperationException("Cannot resolve the owned editor's DLL loader.");
                process=OpenProcess(0x43A,false,target.Id);
                if (process==IntPtr.Zero) throw Error("Open owned editor");
                byte[] data=Encoding.Unicode.GetBytes(file+"\0");
                memory=VirtualAllocEx(process,IntPtr.Zero,(UIntPtr)data.Length,0x3000,4);
                if (memory==IntPtr.Zero) throw Error("Allocate editor DLL path");
                UIntPtr written;
                if (!WriteProcessMemory(process,memory,data,(UIntPtr)data.Length,out written) || written.ToUInt64()!=(ulong)data.Length) throw Error("Write editor DLL path");
                thread=CreateRemoteThread(process,IntPtr.Zero,UIntPtr.Zero,remote,memory,0,IntPtr.Zero);
                if (thread==IntPtr.Zero) throw Error("Load editor save bridge");
                finished=WaitForSingleObject(thread,10000)==0;
                if (!finished) throw new TimeoutException("Editor save bridge DLL load exceeded 10 seconds.");
                uint code;
                if (!GetExitCodeThread(thread,out code) || code==0) throw Error("Editor save bridge DLL load failed");
            } finally {
                if (thread!=IntPtr.Zero) CloseHandle(thread);
                if (memory!=IntPtr.Zero && finished) VirtualFreeEx(process,memory,UIntPtr.Zero,0x8000);
                if (process!=IntPtr.Zero) CloseHandle(process);
            }
        }
    }
}
'@
    }
    [KF2VR.EditorBridgeLoader]::Load($Process, [IO.Path]::GetFullPath($DllPath))
}
