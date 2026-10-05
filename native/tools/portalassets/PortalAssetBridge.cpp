// Editor-only package saving for the pinned KF2 SDK. KF2 omits UDK DLLBind,
// and Actor.ConsoleCommand does not dispatch the editor's OBJ SAVEPACKAGE.
// A unique script FindObject request invokes SavePackage on the editor thread.
#include <windows.h>
#include <bcrypt.h>
#include <MinHook.h>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include "EditorPropertyEdit.hpp"

namespace {
constexpr char kSdkHash[] = "b937aadaa06f728354044461cb8490ef2c20b17245535cf88d3f23cd81ddb85c";
using FindObject = void* (*)(void*, void*, const wchar_t*, int);
using SavePackage = int (*)(void*, void*, std::uint64_t, const wchar_t*, void*, void*, int, int, std::uint32_t);
FindObject originalFind = nullptr;
std::uintptr_t editorBase = 0;
std::wstring outputPath;
std::wstring packageName = L"KF2VRPortal";
bool saving = false;

std::wstring Environment(const wchar_t* key) {
    const DWORD size = GetEnvironmentVariableW(key, nullptr, 0);
    if (!size || size > 32768) return {};
    std::wstring value(size, L'\0');
    const DWORD written = GetEnvironmentVariableW(key, value.data(), size);
    if (!written || written >= size) return {};
    value.resize(written);
    return value;
}

std::string HashFile(const wchar_t* path) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return {};
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    std::string result;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0 &&
        BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0) {
        std::array<UCHAR, 65536> buffer{};
        DWORD count = 0;
        bool ok = true;
        for (;;) {
            if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr)) { ok = false; break; }
            if (!count) break;
            if (BCryptHashData(hash, buffer.data(), count, 0) < 0) { ok = false; break; }
        }
        std::array<UCHAR, 32> digest{};
        if (ok && BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) >= 0) {
            constexpr char hex[] = "0123456789abcdef";
            for (const auto byte : digest) { result += hex[byte >> 4]; result += hex[byte & 15]; }
        }
    }
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    CloseHandle(file);
    return result;
}

void* FindWithSave(void* objectClass, void* outer, const wchar_t* name, int exactClass) {
    const std::wstring editPrefix = L"KF2VRPortal.Edit.";
    if (name && std::wstring(name).starts_with(editPrefix)) {
        const auto payload = std::wstring(name).substr(editPrefix.size());
        void* result = portal_asset_edit::Apply(editorBase, originalFind, packageName, payload);
        std::wofstream(std::filesystem::path(outputPath + L".property-edits"), std::ios::app)
            << L"success=" << (result != nullptr) << L" bytes=" << payload.size()
            << L" request=" << payload.substr(0, 90) << L" diagnostic=" << portal_asset_edit::lastDiagnostic << L'\n';
        return result;
    }
    if (!name || packageName + L".SaveRequest" != name)
        return originalFind(objectClass, outer, name, exactClass);
    if (saving) return nullptr;
    saving = true;
    void* packageClass = *reinterpret_cast<void**>(editorBase + 0x3c47d78);
    void* feedback = *reinterpret_cast<void**>(editorBase + 0x3c33ff8);
    void* package = packageClass ? originalFind(packageClass, nullptr, packageName.c_str(), 1) : nullptr;
    int result = 0;
    // Editor UObject layout differs from KFGame: Outer +0x40, Class +0x50.
    if (package && feedback && *reinterpret_cast<void**>(static_cast<char*>(package) + 0x50) == packageClass) {
        // Mirrors NativeEditorExec_Obj's save call at RVA 0x11f4f2e.
        result = reinterpret_cast<SavePackage>(editorBase + 0x2ffb0)(package, nullptr,
            0x8000000000000ULL, outputPath.c_str(), feedback, nullptr, 0, 1, 0);
    }
    std::ofstream(std::filesystem::path(outputPath + L".bridge-result")) << "save_result=" << result
        << " package=" << package << " package_class=" << packageClass
        << " actual_class=" << (package ? *reinterpret_cast<void**>(static_cast<char*>(package) + 0x50) : nullptr)
        << " feedback=" << feedback << '\n';
    saving = false;
    return result ? package : nullptr;
}

DWORD WINAPI Initialize(void*) {
    try {
        std::array<wchar_t, 32768> executable{};
        const DWORD length = GetModuleFileNameW(nullptr, executable.data(), static_cast<DWORD>(executable.size()));
        const bool portalAssets = wcsstr(GetCommandLineW(), L"PortalAssetTools.VRPortalAssetCommandlet") != nullptr;
        if (!length || length >= executable.size() ||
            _wcsicmp(std::filesystem::path(executable.data()).filename().c_str(), L"KFEditor.exe") != 0 ||
            !portalAssets ||
            !wcsstr(GetCommandLineW(), L"-unattended") || HashFile(executable.data()) != kSdkHash) return 1;
        const auto workspace = Environment(L"KF2VR_PORTAL_WORKSPACE");
        const auto requested = Environment(L"KF2VR_PORTAL_OUTPUT");
        if (workspace.empty() || requested.empty()) return 2;
        packageName = L"KF2VRPortal";
        const auto allowed = std::filesystem::canonical(std::filesystem::path(workspace) / L"build" /
            L"portal-asset-runs");
        const auto output = std::filesystem::weakly_canonical(requested);
        const auto prefix = allowed.wstring() + L"\\";
        outputPath = output.wstring();
        if (output.filename() != packageName + L".upk" || outputPath.size() <= prefix.size() ||
            _wcsnicmp(outputPath.c_str(), prefix.c_str(), prefix.size()) != 0 ||
            std::filesystem::exists(output)) return 3;
        editorBase = reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
        if (MH_Initialize() != MH_OK ||
            MH_CreateHook(reinterpret_cast<void*>(editorBase + 0xf4660), &FindWithSave,
                reinterpret_cast<void**>(&originalFind)) != MH_OK ||
            MH_EnableHook(reinterpret_cast<void*>(editorBase + 0xf4660)) != MH_OK) return 4;
        std::ofstream(std::filesystem::path(outputPath + L".bridge-ready")) << "pinned_editor_save_ready\n";
        return 0;
    } catch (...) { return 5; }
}
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
        // Hashing, hook installation and all file work happen outside loader lock.
        if (HANDLE thread = CreateThread(nullptr, 0, Initialize, nullptr, 0, nullptr)) CloseHandle(thread);
    }
    return TRUE;
}
