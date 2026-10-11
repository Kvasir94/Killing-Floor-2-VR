# Epic desktop package joining

The desktop companion pack supplies the compiled script and hand assets that
Epic KF2 cannot obtain through Steam Workshop. It uses ordinary KF2's server
browser rather than the KF2-VR launcher. Cross-store online play remains pending
local acceptance; the host must offer a session that ordinary Epic KF2 can join.

The full KF2-VR launcher's Epic option remains experimental menu-first **Solo VR**.
Host, Join, and Desktop through that launcher are unavailable. Copying this
desktop pack does not enable those options or change native VR support.

1. Get the desktop companion pack built from the same release as the host.
   The `KF2VR` folder contains `KF2VR.u`, `KF2VRNet.u`, and `KF2VRHands.upk`.
   Do not mix files from donor, older, or other local releases.
2. Close KF2 and its launcher. Locate your Epic installation's
   `KFGame/BrewedPC` folder explicitly.
3. If `KFGame/BrewedPC/KF2VR` already exists, move it to a backup folder outside
   `BrewedPC` before copying. Preserve it until the new pack is accepted.
4. Copy the pack's whole `KF2VR` folder into `KFGame/BrewedPC`. For example:
   `D:\Epic Games\KillingFloor2\KFGame\BrewedPC\KF2VR\KF2VRNet.u`.
5. Start ordinary KF2 through Epic and join the host using the server browser
   and its normal address/password. No special Launch Options, native DLLs,
   launcher broker, or profile changes are required for this package-copy path.

For Heroic or another Linux launcher, use its existing KF2 compatibility setup
and copy to that installation's explicit folder. This desktop route is
best-effort. In a terminal opened in the extracted companion pack, substitute
your actual installation path:

```bash
game="/your/actual/KillingFloor2"
test -f "$game/Binaries/Win64/KFGame.exe" || exit 1
test -d "$game/KFGame/BrewedPC" || exit 1
test ! -e "$game/KFGame/BrewedPC/KF2VR" || exit 1
cp -a -- KF2VR "$game/KFGame/BrewedPC/"
```

The command refuses to overwrite an existing folder; move an existing copy to
a backup location first. To update, repeat with the new matching pack. To undo,
remove only the folder you copied and restore your backup. Preserve unrelated
game files, assets, Workshop caches, and previous releases.

If the host changes builds, obtain its new pack. A script mismatch can prevent
joining even when both packages advertise the same protocol number. Package
availability does not establish cross-store authentication or runtime acceptance.

The manual-copy approach follows the
[donor Epic desktop pack](https://github.com/optimumbox/Killing-Floor-2-VR/releases/tag/v0.5.0-alpha.20261011).
