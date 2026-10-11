# Checkout-local compiler ownership. Resolve directory aliases before naming the
# mutex so junctions, drive mappings and short paths cannot create another owner.
if (-not ('KF2VRBuildPath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class KF2VRBuildPath {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,
        StringBuilder path, uint length, uint flags);
    public static string Resolve(string path) {
        using (var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            var result = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(handle, result, (uint)result.Capacity, 0);
            if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (length >= result.Capacity) throw new InvalidOperationException("Build path is too long");
            return result.ToString().TrimEnd('\\');
        }
    }
}
'@
}

function Get-KF2VRBuildMutexName([string]$ProjectRoot) {
    $physical = [KF2VRBuildPath]::Resolve([IO.Path]::GetFullPath($ProjectRoot)).ToUpperInvariant()
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($physical))).Replace('-', '') }
    finally { $hasher.Dispose() }
    return 'Local\KF2VR_Build_' + $hash
}

function Assert-KF2VRBuildOutput([string]$Path, [string]$ProjectRoot, [switch]$InspectEntries) {
    $checkout = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($checkout + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Build output must stay within this checkout.'
    }
    $ancestor = [IO.DirectoryInfo]::new($fullPath)
    while ($null -ne $ancestor -and $ancestor.FullName.TrimEnd('\') -ine $checkout) {
        if ($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Build refuses linked output ancestors: $($ancestor.FullName)"
        }
        $ancestor = $ancestor.Parent
    }
    if ($InspectEntries -and (Test-Path -LiteralPath $Path)) {
        if (Get-ChildItem -LiteralPath $Path -Recurse -Force |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.LinkType } |
            Select-Object -First 1) {
            throw "Build refuses linked build output entries: $Path"
        }
    }
}
