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
#include "../portalassets/EditorPropertyEdit.hpp"
#include "../engineerassets/FbxAnimationImport.hpp"

namespace {
constexpr char kSdkHash[] = "b937aadaa06f728354044461cb8490ef2c20b17245535cf88d3f23cd81ddb85c";
using FindObject = void* (*)(void*, void*, const wchar_t*, int);
using SavePackage = int (*)(void*, void*, std::uint64_t, const wchar_t*, void*, void*, int, int, std::uint32_t);
FindObject originalFind = nullptr;
std::uintptr_t editorBase = 0;
std::wstring outputPath;
std::filesystem::path animationInputRoot;
std::wstring packageName = L"KF2VRHands";
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
    // Takes for a rig imported into this package, e.g. the RAVEN-7 Idle grip.
    // The pinned AnimSet importer is shared with the Engineer bridge; input is
    // restricted to <mesh>.fbx directly under build/hand-meshes.
    const std::wstring animationPrefix = L"KF2VRHands.ImportAnimations.";
    if (name && packageName == L"KF2VRHands" && std::wstring(name).starts_with(animationPrefix)) {
        const auto meshName = std::wstring(name).substr(animationPrefix.size());
        void* result = nullptr;
        try { result = engineer_animation_import::Import(editorBase, originalFind, packageName, animationInputRoot, meshName); }
        catch (...) { result = nullptr; }
        // A script-created AnimSet lacks RF_Public|RF_Standalone, so SavePackage
        // (top-level flag RF_Standalone) would drop it. ObjectFlags is the
        // UObject qword at +0x10; confirm that on the factory-imported mesh,
        // which always carries both flags, before copying them to the set.
        constexpr std::uint64_t kPublicStandalone = 0x0000000400000000ULL | 0x0008000000000000ULL;
        std::uint64_t meshFlags = 0, setFlags = 0;
        if (result) {
            void* mesh = originalFind(originalFind(nullptr, nullptr, L"Engine.SkeletalMesh", 0), nullptr,
                (packageName + L"." + meshName).c_str(), 1);
            meshFlags = mesh ? *reinterpret_cast<std::uint64_t*>(static_cast<char*>(mesh) + 0x10) : 0;
            auto* flags = reinterpret_cast<std::uint64_t*>(static_cast<char*>(result) + 0x10);
            if ((meshFlags & kPublicStandalone) == kPublicStandalone) { *flags |= kPublicStandalone; setFlags = *flags; }
            else result = nullptr;
        }
        std::wofstream(std::filesystem::path(outputPath + L".animation-imports"), std::ios::app)
            << L"success=" << (result != nullptr) << L" mesh=" << meshName << std::hex
            << L" mesh_flags=0x" << meshFlags << L" set_flags=0x" << setFlags << std::dec << L'\n';
        return result;
    }
    const std::wstring editPrefix = L"KF2VRHands.Edit.";
    if (name && std::wstring(name).starts_with(editPrefix)) {
        const auto payload = std::wstring(name).substr(editPrefix.size());
        // Reuse the pinned editor's validated property importer, restricted to
        // textures owned by this hand package and these texture properties.
        if (payload.find(L"|SRGB|") == std::wstring::npos &&
            payload.find(L"|CompressionSettings|") == std::wstring::npos &&
            payload.find(L"|LODGroup|") == std::wstring::npos) return nullptr;
        void* result = portal_asset_edit::Apply(editorBase, originalFind, packageName, payload);
        std::wofstream(std::filesystem::path(outputPath + L".property-edits"), std::ios::app)
            << L"success=" << (result != nullptr) << L" request=" << payload << L'\n';
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
        const bool sourceAssets = wcsstr(GetCommandLineW(), L"SourceAssetTools.VRSourceAssetCommandlet") != nullptr;
        if (!length || length >= executable.size() ||
            _wcsicmp(std::filesystem::path(executable.data()).filename().c_str(), L"KFEditor.exe") != 0 ||
            (!sourceAssets && !wcsstr(GetCommandLineW(), L"HandAssetTools.VRHandAssetCommandlet") &&
                !wcsstr(GetCommandLineW(), L"HandAssetTools.VRReloadAssetCommandlet")) ||
            !wcsstr(GetCommandLineW(), L"-unattended") || HashFile(executable.data()) != kSdkHash) return 1;
        const auto workspace = Environment(L"KF2VR_HAND_WORKSPACE");
        const auto requested = Environment(L"KF2VR_HAND_OUTPUT");
        if (workspace.empty() || requested.empty()) return 2;
        packageName = sourceAssets ? L"KF2VRSource" : L"KF2VRHands";
        if (!sourceAssets)
            animationInputRoot = std::filesystem::canonical(std::filesystem::path(workspace) / L"build" / L"hand-meshes");
        const auto allowed = std::filesystem::canonical(std::filesystem::path(workspace) / L"build" /
            (sourceAssets ? L"source-asset-runs" : L"hand-asset-runs"));
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
