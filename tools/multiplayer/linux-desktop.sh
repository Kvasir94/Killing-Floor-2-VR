#!/usr/bin/env bash
# Best-effort Steam/Proton desktop join. Keep Steam's actual Proton wrapper and
# let friends.py own isolated configuration, game launch and session cleanup.
set -euo pipefail

die() { printf 'KF2-VR: %s\n' "$*" >&2; exit 1; }
winpath() { local value="Z:$1"; printf '%s' "${value//\//\\}"; }
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
package="$(cd -- "$here/../.." && pwd -P)"
game="" join="" launch=0 normal=0
while (($#)); do
    case "$1" in
        --package|--game-root|--join)
            (($# >= 2)) || die "Missing value for $1"
            case "$1" in
                --package) package="$2" ;;
                --game-root) game="$2" ;;
                --join) join="$2" ;;
            esac
            shift 2 ;;
        --normal) normal=1; shift ;;
        --launch) launch=1; shift; break ;;
        --help)
            printf '%s\n' 'Steam Launch Options:' \
                'bash "/path/app/tools/multiplayer/linux-desktop.sh" --game-root "/path/killingfloor2" --launch %command%' \
                'Optional: --package "/path/release/app", --join KF2VR1:..., --normal.'
            exit 0 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done
((launch && $#)) || die 'Run through Steam Launch Options with --launch %command%.'
((normal)) && exec "$@"
[[ -d $package ]] || die 'Extract the matching full release first.'
package="$(cd -- "$package" && pwd -P)"
[[ -f $package/release.json ]] || {
    [[ -f $package/app/release.json ]] || die 'The package folder has no release.json.'
    package="$package/app"
}
[[ -n $game && -d $game ]] || die 'Set --game-root to your Steam Killing Floor 2 folder.'
game="$(cd -- "$game" && pwd -P)"
[[ -f $game/Binaries/Win64/KFGame.exe ]] || die 'KFGame.exe is missing from --game-root.'
[[ -f $package/runtime/python.exe && -f $package/tools/multiplayer/friends.py ]] || die 'Incomplete full release.'

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
