#!/usr/bin/env bash
# Best-effort Steam/Proton desktop join. Keep Steam's actual Proton wrapper and
# let friends.py own isolated configuration, game launch and session cleanup.
set -euo pipefail

die() { printf 'KF2-VR: %s\n' "$*" >&2; exit 1; }
winpath() { local value="Z:$1"; printf '%s' "${value//\//\\}"; }
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
package="$(cd -- "$here/../.." && pwd -P)"
game="" join="" launch=0 normal=0 setup=0 explicit_package=0
while (($#)); do
    case "$1" in
        --package|--game-root|--join)
            (($# >= 2)) || die "Missing value for $1"
            case "$1" in
                --package) package="$2"; explicit_package=1 ;;
                --game-root) game="$2" ;;
                --join) join="$2" ;;
            esac
            shift 2 ;;
        --normal) normal=1; shift ;;
        --setup) setup=1; shift ;;
        --launch) launch=1; shift; break ;;
        --help)
            printf '%s\n' 'Setup: bash linux-desktop.sh --setup [--package "/path/release/app"] [--game-root "/path/killingfloor2"]' \
                'Steam Launch Options: bash "/path/app/tools/multiplayer/linux-desktop.sh" --launch %command%' \
                'Optional: --package "/path/release/app", --game-root "/path/killingfloor2", --join KF2VR1:..., --normal.' \
                'Setup can extract one adjacent full release ZIP into a fresh folder; extraction requires python3.'
            exit 0 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done
if ((setup)); then
    ((!launch && !normal)) || die 'Use --setup separately from --launch or --normal.'
else
    ((launch && $#)) || die 'Run through Steam Launch Options with --launch %command%, or use --setup.'
fi
((normal)) && exec "$@"
if ((setup && !explicit_package)) && [[ ! -f $package/release.json && ! -f $package/app/release.json ]]; then
    command -v python3 >/dev/null || die 'Extract the full release ZIP first, or install python3 for setup extraction.'
    package="$(python3 - "$here" <<'PY'
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile

folder = Path(sys.argv[1])
candidates = []
for archive in folder.glob("*.zip"):
    with zipfile.ZipFile(archive) as zipped:
        manifests = [name for name in zipped.namelist() if name == "app/release.json" or name.endswith("/app/release.json")]
        if len(manifests) == 1:
            candidates.append((archive, manifests[0]))
if len(candidates) != 1:
    sys.exit("KF2-VR: Expected one adjacent full release ZIP; extract the matching release and use --package.")
archive, manifest = candidates[0]
destination = archive.with_name(archive.stem + "-linux")
if destination.exists():
    sys.exit("KF2-VR: Setup folder already exists; use --package with that release or choose a fresh location.")
with zipfile.ZipFile(archive) as zipped:
    names = zipped.namelist()
    if len(names) != len(set(names)):
        sys.exit("KF2-VR: ZIP contains duplicate paths.")
    for entry in zipped.infolist():
        path = PurePosixPath(entry.filename)
        if path.is_absolute() or ".." in path.parts or "\\" in entry.filename or stat.S_ISLNK(entry.external_attr >> 16):
            sys.exit("KF2-VR: ZIP contains an unsafe path or symbolic link.")
    prefix = manifest.removesuffix("release.json")
    required = ("runtime/python.exe", "tools/multiplayer/friends.py", "tools/multiplayer/linux-desktop.sh")
    if not all(prefix + name in names for name in required) or not isinstance(json.loads(zipped.read(manifest)), dict):
        sys.exit("KF2-VR: Incomplete full release ZIP.")
    destination.mkdir()
    zipped.extractall(destination)
print((destination / prefix).as_posix())
PY
)" || exit 1
fi
[[ -d $package ]] || die 'Extract the matching full release first.'
package="$(cd -- "$package" && pwd -P)"
[[ -f $package/release.json ]] || {
    [[ -f $package/app/release.json ]] || die 'The package folder has no release.json.'
    package="$package/app"
}
if [[ -z $game ]]; then
    libraries=() games=()
    for root in "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}" "$HOME/.steam/steam" "$HOME/.local/share/Steam" \
            "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
        [[ -n $root && -d $root ]] || continue
        libraries+=("$root")
        for metadata in "$root/steamapps/libraryfolders.vdf" "$root/config/libraryfolders.vdf"; do
            [[ -f $metadata ]] || continue
            while IFS= read -r library; do
                libraries+=("${library//\\\\/\\}")
            done < <(sed -nE 's/^[[:space:]]*"(path|[0-9]+)"[[:space:]]*"([^"]+)".*/\2/p' "$metadata")
        done
    done
    for library in "${libraries[@]}"; do
        install="killingfloor2"
        manifest="$library/steamapps/appmanifest_232090.acf"
        if [[ -f $manifest ]]; then
            install="$(sed -nE 's/^[[:space:]]*"installdir"[[:space:]]*"([^"]+)".*/\1/p' "$manifest")"
        fi
        candidate="$library/steamapps/common/$install"
        [[ -f $candidate/Binaries/Win64/KFGame.exe ]] || continue
        candidate="$(cd -- "$candidate" && pwd -P)"
        duplicate=0
        for known in "${games[@]}"; do [[ $known != "$candidate" ]] || duplicate=1; done
        ((duplicate)) || games+=("$candidate")
    done
    ((${#games[@]} == 1)) || die 'Could not select one Steam KF2 installation; set --game-root explicitly.'
    game="${games[0]}"
fi
[[ -d $game ]] || die 'Set --game-root to your Steam Killing Floor 2 folder.'
game="$(cd -- "$game" && pwd -P)"
[[ -f $game/Binaries/Win64/KFGame.exe ]] || die 'KFGame.exe is missing from --game-root.'
[[ -f $package/runtime/python.exe && -f $package/tools/multiplayer/friends.py ]] || die 'Incomplete full release.'
if ((setup)); then
    printf '%s\n' 'Save your previous Steam Launch Options, then paste this line:'
    printf '%q ' bash "$package/tools/multiplayer/linux-desktop.sh" --package "$package" --game-root "$game" --launch
    printf '%s\n' '%command%'
    exit 0
fi

if [[ -z $join ]]; then
    if command -v zenity >/dev/null; then
        join="$(zenity --entry --title='KF2-VR desktop join' --text='Paste the matching host KF2VR1: join code. Cancel starts ordinary KF2.' 2>/dev/null)" || exec "$@"
    elif command -v kdialog >/dev/null; then
        join="$(kdialog --title 'KF2-VR desktop join' --inputbox 'Paste the matching host KF2VR1: join code. Cancel starts ordinary KF2.' 2>/dev/null)" || exec "$@"
    elif [[ -r /dev/tty ]]; then
        printf 'Paste the matching KF2VR1: join code (empty starts ordinary KF2): ' >/dev/tty
        IFS= read -r join </dev/tty || exec "$@"
    else
        die 'A dialog tool or terminal is required; supply --join or use --normal.'
    fi
fi
[[ -n $join ]] || exec "$@"
[[ $join == KF2VR1:* && $join != *$'\n'* && $join != *$'\r'* ]] || die 'Use the host KF2VR1: join code.'

command=() found=0
for arg in "$@"; do
    ((found)) && continue
    case "${arg,,}" in
        */kfgame.exe|*\\kfgame.exe)
            command+=("$package/runtime/python.exe" "$(winpath "$package/tools/multiplayer/friends.py")"
                --desktop --store steam --game-root "$(winpath "$game")" --address "$join")
            found=1 ;;
        *) command+=("$arg") ;;
    esac
done
((found)) || die 'Steam command does not contain KFGame.exe; no command was changed.'
export STEAM_COMPAT_MOUNTS="$package${STEAM_COMPAT_MOUNTS:+:$STEAM_COMPAT_MOUNTS}"
mkdir -p -- "$package/logs"
# Do not log the join code or command arguments; the code contains a password.
exec "${command[@]}" >>"$package/logs/linux-desktop.log" 2>&1
