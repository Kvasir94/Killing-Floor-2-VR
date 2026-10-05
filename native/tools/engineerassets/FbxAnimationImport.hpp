#pragma once
#include <filesystem>
#include <string>
#include "EditorPropertyEdit.hpp"

// Pinned KFEditor AnimSet viewer import call: RVA 0x147f8d8 calls
// 0x1379c80 with (selected AnimSet, wchar filename, selected SkeletalMesh,
// import-morph-tracks flag, address of missing-track warning flag). The helper owns the
// FBX scene lifetime, builds tracks, imports every take and compresses them.
// This bypasses no gameplay code and requires the editor-only bridge guard.
// Argument 4 writes option +0x30 and gates deformer type 2 (blend shapes) at
// 0x1378371. These inputs contain no blend shapes; this is not a resample flag.
// See docs/re/ANIMATION_IMPORT_OFFLINE_2026-09-13.md for pinned-byte evidence.
namespace engineer_animation_import {
using ImportFbxAnimSet = void (*)(void*, const wchar_t*, void*, int, int*);
inline constexpr int kImportMorphTracks = 0;

inline void* Import(std::uintptr_t base, engineer_asset_edit::FindObject find,
                    const std::wstring& packageName, const std::filesystem::path& inputRoot,
                    const std::wstring& meshName) {
    if (!engineer_asset_edit::SimplePath(meshName) || meshName.find(L'.') != std::wstring::npos)
        return nullptr;
    const auto file = std::filesystem::canonical(inputRoot / (meshName + L".fbx"));
    if (file.parent_path() != std::filesystem::canonical(inputRoot)) return nullptr;
    void* package = find(nullptr, nullptr, packageName.c_str(), 0);
    void* meshClass = find(nullptr, nullptr, L"Engine.SkeletalMesh", 0);
    void* setClass = find(nullptr, nullptr, L"Engine.AnimSet", 0);
    if (!package || !meshClass || !setClass) return nullptr;
    void* mesh = find(meshClass, nullptr, (packageName + L"." + meshName).c_str(), 1);
    void* set = find(setClass, nullptr, (packageName + L"." + meshName + L"_Anims").c_str(), 1);
    if (!mesh || !set || !engineer_asset_edit::OwnedBy(mesh, package)
        || !engineer_asset_edit::OwnedBy(set, package)) return nullptr;
    int missingTrackWarning = 0;
    reinterpret_cast<ImportFbxAnimSet>(base + 0x1379c80)(set, file.c_str(), mesh, kImportMorphTracks, &missingTrackWarning);
    return missingTrackWarning == 0 ? set : nullptr;
}
} // namespace engineer_animation_import
