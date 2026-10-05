#pragma once
#include <filesystem>
#include <string>
#include "EditorPropertyEdit.hpp"

// Pinned KFEditor AnimSet viewer call at 0x147f8d8. The editor importer owns
// the FBX scene and compressed tracks. Only our launcher/set/file are accepted.
// Argument 4 controls morph/blend-shape tracks, not skeletal resampling: option
// +0x30 gates deformer type 2 at 0x1378371. These inputs contain no blend shapes.
// See docs/re/ANIMATION_IMPORT_OFFLINE_2026-09-13.md for pinned-byte evidence.
namespace source_animation_import {
using ImportFbxAnimSet = void (*)(void*, const wchar_t*, void*, int, int*);
inline constexpr int kImportMorphTracks = 0;

inline void* Import(std::uintptr_t base, source_asset_edit::FindObject find,
                    const std::filesystem::path& inputRoot) {
    try {
        const auto allowed = std::filesystem::canonical(inputRoot / L"animations");
        const auto file = std::filesystem::canonical(allowed / L"StickyMechanism.fbx");
        if (file.parent_path() != allowed) return nullptr;
        void* package = find(nullptr, nullptr, L"KF2VRSource", 0);
        void* meshClass = find(nullptr, nullptr, L"Engine.SkeletalMesh", 0);
        void* setClass = find(nullptr, nullptr, L"Engine.AnimSet", 0);
        if (!package || !meshClass || !setClass) return nullptr;
        void* mesh = find(meshClass, nullptr, L"KF2VRSource.StickybombLauncher", 1);
        void* set = find(setClass, nullptr, L"KF2VRSource.StickybombLauncher_Anims", 1);
        if (!mesh || !set || !source_asset_edit::OwnedBy(mesh, package)
            || !source_asset_edit::OwnedBy(set, package)) return nullptr;
        int missingTrackWarning = 0;
        reinterpret_cast<ImportFbxAnimSet>(base + 0x1379c80)(set, file.c_str(), mesh, kImportMorphTracks, &missingTrackWarning);
        return missingTrackWarning == 0 ? set : nullptr;
    } catch (const std::filesystem::filesystem_error&) {
        return nullptr;
    }
}
} // namespace source_animation_import
