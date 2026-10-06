# Source and asset provenance

The MIT licence in [LICENSE](../LICENSE) covers original KF2-VR contributions.
It does not cover third-party game code/content or grant rights to distribute it.
No legal clearance of game-derived assets is claimed by this source export.

| Material | Treatment |
| --- | --- |
| Original native adapter, UnrealScript additions and tooling | Included as source under the repository licence |
| OpenXR loader/SDK | Fetched separately; Khronos upstream licences, pinned in third_party/VERSIONS.md |
| MinHook/HDE | Pinned source included in the curated export with upstream BSD-style/HDE notices; hashes in third_party/VERSIONS.md |
| CPython/Microsoft components | Not in source export; playable packages retain upstream notices/licences |
| KF2/SDK binaries and extracted/derived meshes, textures and packages | Excluded; obtain game/SDK locally under their terms |
| Portal/Source/TF2 and other third-party content | No extracted assets included; code tools do not convey asset rights |
| Steam Workshop content/server/SteamCMD | Excluded; downloaded separately when requested |
| RAVEN-7 current atlas | Original AI-generated material source included; no game texture extraction |
| Embedded bell WAVs | CC0 BigSoundBank Boxing bell #1, trimmed/faded/normalized; included with source notice |
| Local logs, profiles, reports, history and chat/research archives | Excluded; source export contains no Git history |

Playable ZIPs are separate deliverables containing derived asset packages.
Public availability does not establish redistribution clearance of game-derived
content. Existing release bytes remain unchanged. The source build
extracts required game inputs only from the builder's local installations and
generates outputs locally. Owning a game is not by itself permission to
redistribute its assets. Keep licence/notices with third-party inputs you add.

Bell source: [BigSoundBank Boxing bell #1](https://bigsoundbank.com/boxing-bell-1-s1926.html),
listed as CC0 by the publisher. `native/adapter/assets/NOTICE.txt` records the
resource treatment. RAVEN-7's provenance and current atlas hash are in
`assets/weapons/raven7/README.md`. These documented non-game assets are retained;
there is no blanket exclusion of everything in a binary file format.
