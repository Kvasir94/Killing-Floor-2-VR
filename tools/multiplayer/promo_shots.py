"""Find trailer shots in highlight logs (promo-events.jsonl).

Reads the logs a -PromoEvents session writes; it never launches, controls or
records a game. Each shot on the trailer shot list that the log can see has a
rule that looks for its moment (a 9mm reload followed by a 9mm kill, a Zed
throw followed by a slam kill, Zed Time kills on a Scrake, ...). The output
lists the best candidates per shot with their times in the video, and can cut
them out of the recording with ffmpeg.

    runtime/python.exe tools/multiplayer/promo_shots.py SESSION_FOLDER --sync 12.4
    ... --video take3.mkv --clips clips/

--sync is the time in the video (seconds) where the first F9 mark shows; add
--sync-index N when the video starts at a later F9 press. Without --sync the
times are seconds since the session started, which only matches a recording
started at the same moment.
"""
import argparse
import csv
import io
import json
import shutil
import subprocess
import sys
from pathlib import Path

import promo_events as promo

# Seconds of picture to keep around a moment. Reload and catch events are
# logged when the action completes, so they need the longest lead-in.
LEAD_IN = 4.0
TAIL = 2.0

# Shot IDs and names follow the trailer plan's shot list.
SHOTS = {
    "01-02": "9mm reload, then a 9mm kill",
    "03": "AK12 magazine reload",
    "05": "Pump shotgun reload and fight",
    "06": "Mosin reload",
    "07": "Belt-fed reload",
    "08": "Break-action reload",
    "09": "Compound bow kill",
    "10": "M32 reload",
    "11": "Dual 9mm reload",
    "12": "Lever rifle reload",
    "13": "Gravity grab, then a kill",
    "14": "Thrown gun hits a Zed",
    "16": "Tomahawk recall",
    "17": "Zed grabbed and thrown",
    "19": "Bare-hands kill (fists or Boxing Gloves)",
    "20": "Parry, then a kill",
    "21": "Grenade throw and kills",
    "23": "Welder taken at a door",
    "24": "Gun caught",
    "26": "Zed Time kills",
    "streak": "Kill streaks (any weapon)",
}
UNTRACKED = {
    "15": "magazine bounce and loose rounds",
    "18": "Super Strength fling (shows as a normal Zed throw under 17)",
    "22": "covering a teammate's reload",
    "25": "high five or dosh toss",
    "27": "end card",
}
RELOAD_SHOTS = {"03": "ak12", "06": "mosin", "07": "belt_fed", "08": "break_action", "10": "m32",
                "11": "dual_9mm", "12": "lever"}
BIG_ZEDS = {"scrake", "fleshpound", "quarterpound"}


class Clock:
    """Converts QPC ticks to video seconds for one launcher session."""

    def __init__(self, events, sync=None, sync_index=1):
        starts = [e for e in events if e["event"] == "session_start" and e.get("qpc_frequency", 0) > 0]
        if not starts:
            raise ValueError("No session_start row: is this a promo-events.jsonl file?")
        sessions = {e["session_id"] for e in starts}
        if len(sessions) > 1:
            raise ValueError("These logs come from %d launches; pass one session's files at a time" % len(sessions))
        self.frequency = starts[0]["qpc_frequency"]
        self.origin = min(e["qpc_ticks"] for e in starts)
        self.offset = 0.0
        self.label = "session time"
        if sync is not None:
            marks = sorted((e for e in events if e["event"] == "sync"), key=lambda e: e["qpc_ticks"])
            if not 1 <= sync_index <= len(marks):
                raise ValueError("--sync-index %d, but the log has %d F9 marks" % (sync_index, len(marks)))
            self.origin = marks[sync_index - 1]["qpc_ticks"]
            self.offset = sync
            self.label = "video time"

    def seconds(self, event):
        return self.offset + (event["qpc_ticks"] - self.origin) / self.frequency


def stamp(seconds):
    sign = "-" if seconds < 0 else ""
    seconds = abs(seconds)
    return "%s%d:%04.1f" % (sign, int(seconds // 60), seconds % 60)


def describe_kill(kill):
    parts = [kill.get("weapon", "other").replace("_", " "), "kill"]
    if kill.get("headshot_evidence") == "stock_timestamp_advanced":
        parts.insert(1, "headshot")
    if kill.get("enemy") not in (None, "other", "none"):
        parts.append("(%s)" % kill["enemy"].replace("_", " "))
    if kill.get("zed_time"):
        parts.append("in Zed Time")
    return " ".join(parts)


class Finder:
    def __init__(self, events, clock):
        self.clock = clock
        rows = sorted(events, key=lambda e: e["qpc_ticks"])
        self.actions = [(clock.seconds(e), e) for e in rows if e["event"] == "action"]
        self.kills = [(clock.seconds(e), e) for e in rows if e["event"] == "kill"]
        self.hits = [(clock.seconds(e), e) for e in rows if e["event"] == "hit"]

    def action(self, name, weapon=None, minimum=None):
        result, last = [], None
        for t, e in self.actions:
            if e["action"] != name or (weapon and e.get("weapon") != weapon):
                continue
            if minimum is not None and e.get("value", 0) < minimum:
                continue
            # Some actions repeat while held (a recall retries until caught).
            if last is not None and t - last < 1.0:
                continue
            last = t
            result.append((t, e))
        return result

    @staticmethod
    def after(rows, t, seconds, test=lambda e: True):
        return [(u, e) for u, e in rows if t <= u <= t + seconds and test(e)]

    def candidate(self, shot, start, end, score, summary, lead=LEAD_IN):
        return {"shot": shot, "start": start - lead, "end": end + TAIL, "moment": start,
                "score": round(score, 2), "summary": summary}

    def reloads(self, shot, weapon, kill_weapons, follow=8.0):
        out = []
        for t, e in self.action("reload", weapon):
            kills = self.after(self.kills, t, follow, lambda k: k.get("weapon") in kill_weapons)
            heads = sum(k.get("headshot_evidence") == "stock_timestamp_advanced" for _, k in kills)
            summary = "%s reload, +%d rounds" % (weapon.replace("_", " "), max(e.get("value", 0), 0))
            if kills:
                summary += "; then " + ", ".join(describe_kill(k) for _, k in kills[:3])
                summary += " (first %.1f s later)" % (kills[0][0] - t)
            end = kills[-1][0] if kills else t
            out.append(self.candidate(shot, t, end, 1 + 2 * len(kills[:3]) + 2 * heads, summary, lead=5.0))
        return out

    def find(self):
        found = []
        found += self.reloads("01-02", "9mm", {"9mm"})
        for shot, weapon in RELOAD_SHOTS.items():
            found += self.reloads(shot, weapon, {weapon})
        found += self.reloads("05", "pump_shotgun", {"pump_shotgun"}, follow=12.0)
        for t, k in self.kills:
            if k.get("weapon") == "bow":
                head = k.get("headshot_evidence") == "stock_timestamp_advanced"
                found.append(self.candidate("09", t, t, 2 + 2 * head, describe_kill(k)))
            if k.get("cause") in {"fist", "charged_fist", "glove_fist", "charged_glove"}:
                gloves = "glove" in k["cause"]
                found.append(self.candidate("19", t, t, 2 + gloves, describe_kill(k).replace(
                    "other ", "Boxing Gloves " if gloves else "fist ", 1)))
        for t, e in self.action("gravity_pull"):
            kills = self.after(self.kills, t, 6.0)
            found.append(self.candidate("13", t, kills[-1][0] if kills else t + 1.5, 1 + 2 * len(kills[:3]),
                                        "gravity pull" + ("; then " + describe_kill(kills[0][1]) if kills else ""),
                                        lead=2.0))
        for t, e in self.action("gun_release", minimum=350):
            hits = self.after(self.hits, t, 3.0, lambda h: h.get("weapon") == "thrown_weapon")
            if not hits:
                continue
            kill = self.after(self.kills, t, 3.0, lambda k: k.get("weapon") == "thrown_weapon")
            found.append(self.candidate("14", t, hits[-1][0], 3 + 2 * bool(kill) + e["value"] / 1000.0,
                                        "%s thrown at %d UU/s, hits a %s%s" % (
                                            e.get("weapon", "gun").replace("_", " "), e["value"],
                                            hits[0][1].get("enemy", "Zed").replace("_", " "),
                                            " and kills it" if kill else ""), lead=2.0))
        for t, e in self.action("tomahawk_recall"):
            before = [k for u, k in self.kills if t - 5.0 <= u <= t and k.get("weapon") == "tomahawk"]
            found.append(self.candidate("16", t, t + 1.5, 1 + 2 * bool(before),
                                        "tomahawk recall" + (" after a tomahawk kill" if before else ""), lead=3.0))
        for t, e in self.action("zed_throw"):
            slams = self.after(self.kills, t, 4.0, lambda k: k.get("cause") == "grab_slam")
            found.append(self.candidate("17", t, slams[-1][0] if slams else t + 1.5,
                                        1 + 2 * len(slams) + e.get("value", 0) / 1000.0,
                                        "%s thrown at %d UU/s%s" % (e.get("enemy", "Zed").replace("_", " "),
                                                                   e.get("value", 0),
                                                                   ", %d slam kill(s)" % len(slams) if slams else ""),
                                        lead=3.0))
        for t, e in self.action("parry"):
            kills = self.after(self.kills, t, 5.0)
            found.append(self.candidate("20", t, kills[0][0] if kills else t + 1.0, 1 + 3 * bool(kills),
                                        "parry" + (" (%s)" % e["enemy"].replace("_", " ") if e.get("enemy") not in (None, "none", "other") else "")
                                        + ("; then " + describe_kill(kills[0][1]) if kills else ""), lead=2.0))
        for t, e in self.action("grenade_throw"):
            kills = self.after(self.kills, t, 6.0, lambda k: k.get("weapon") == "grenade")
            found.append(self.candidate("21", t, kills[-1][0] if kills else t + 3.0, 1 + 2 * len(kills),
                                        "grenade thrown" + (", %d kill(s)" % len(kills) if kills else ""), lead=2.5))
        for t, e in self.action("welder_taken"):
            found.append(self.candidate("23", t, t + 6.0, 1, "welder taken from the door hologram", lead=1.5))
        for t, e in self.action("gun_catch"):
            kills = self.after(self.kills, t, 4.0)
            found.append(self.candidate("24", t, kills[0][0] if kills else t + 1.5, 1 + 2 * bool(kills),
                                        "%s caught" % e.get("weapon", "gun").replace("_", " ")
                                        + ("; then " + describe_kill(kills[0][1]) if kills else ""), lead=2.5))
        found += self.zed_time()
        found += self.streaks()
        return found

    def zed_time(self):
        out, group = [], []
        for t, k in [(t, k) for t, k in self.kills if k.get("zed_time")] + [(None, None)]:
            if group and (t is None or t - group[-1][0] > 4.0):
                big = sum(k.get("enemy") in BIG_ZEDS for _, k in group)
                heads = sum(k.get("headshot_evidence") == "stock_timestamp_advanced" for _, k in group)
                out.append(self.candidate("26", group[0][0], group[-1][0], len(group) + 3 * big + heads,
                                          "%d Zed Time kill(s): %s" % (len(group), ", ".join(
                                              describe_kill(k).replace(" in Zed Time", "") for _, k in group[:4]))))
                group = []
            if t is not None:
                group.append((t, k))
        return out

    def streaks(self, window=5.0):
        out, used = [], -1
        for i, (t, k) in enumerate(self.kills):
            if i <= used:
                continue
            j = i
            while j + 1 < len(self.kills) and self.kills[j + 1][0] - t <= window:
                j += 1
            if j - i + 1 >= 3:
                burst = self.kills[i:j + 1]
                heads = sum(k.get("headshot_evidence") == "stock_timestamp_advanced" for _, k in burst)
                out.append(self.candidate("streak", t, burst[-1][0], len(burst) + 0.5 * heads,
                                          "%d kills in %.1f s, %d headshot(s)" % (len(burst), burst[-1][0] - t, heads),
                                          lead=3.0))
                used = j
        return out


def best(candidates, top):
    """Highest scores per shot, dropping candidates that overlap a better one."""
    result = {}
    for shot in SHOTS:
        kept = []
        for c in sorted((c for c in candidates if c["shot"] == shot), key=lambda c: (-c["score"], c["start"])):
            if all(c["end"] < k["start"] or c["start"] > k["end"] for k in kept):
                kept.append(c)
            if len(kept) >= top:
                break
        result[shot] = kept
    return result


def markdown(ranked, label):
    lines = ["# Trailer shot candidates", "", "Times are %s. Each clip starts a few seconds before the moment." % label, ""]
    for shot, title in SHOTS.items():
        lines.append("## %s · %s" % (shot, title))
        if not ranked[shot]:
            lines += ["", "No candidate in this log.", ""]
            continue
        lines += ["", "| # | Clip | Moment | Score | What happened |", "| --- | --- | --- | --- | --- |"]
        for i, c in enumerate(ranked[shot], 1):
            lines.append("| %d | %s–%s | %s | %s | %s |" % (i, stamp(c["start"]), stamp(c["end"]),
                                                           stamp(c["moment"]), c["score"], c["summary"]))
        lines.append("")
    lines.append("Not in the log, so log these by hand: " +
                 "; ".join("%s %s" % (k, v) for k, v in UNTRACKED.items()) + ".")
    return "\n".join(lines) + "\n"


def table(ranked):
    stream = io.StringIO()
    writer = csv.writer(stream, lineterminator="\n")
    writer.writerow(["shot", "rank", "start_s", "end_s", "moment_s", "score", "summary"])
    for shot, rows in ranked.items():
        for i, c in enumerate(rows, 1):
            writer.writerow([shot, i, "%.2f" % c["start"], "%.2f" % c["end"], "%.2f" % c["moment"], c["score"], c["summary"]])
    return stream.getvalue()


def clip_commands(ranked, video, folder, ffmpeg="ffmpeg"):
    commands = []
    for shot, rows in ranked.items():
        for i, c in enumerate(rows, 1):
            start = max(c["start"], 0.0)
            name = "%s_%d_%s.mkv" % (shot, i, stamp(c["moment"]).replace(":", "m").replace(".", "s"))
            commands.append([ffmpeg, "-hide_banner", "-loglevel", "error", "-n", "-ss", "%.2f" % start,
                             "-i", str(video), "-t", "%.2f" % (c["end"] - start), "-map", "0", "-c", "copy",
                             str(Path(folder) / name)])
    return commands


def inputs(paths):
    files = []
    for path in map(Path, paths):
        files += sorted(path.rglob("promo-events.jsonl")) if path.is_dir() else [path]
    if not files:
        raise ValueError("No promo-events.jsonl found in " + ", ".join(paths))
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description="List trailer shot candidates from -PromoEvents logs.")
    parser.add_argument("paths", nargs="+", help="promo-events.jsonl files or a session folder")
    parser.add_argument("--sync", type=float, help="video time in seconds where the F9 mark appears")
    parser.add_argument("--sync-index", type=int, default=1, help="which F9 press --sync refers to (1 = first)")
    parser.add_argument("--top", type=int, default=5, help="candidates per shot (default 5)")
    parser.add_argument("--format", choices=("md", "csv", "json"), default="md")
    parser.add_argument("--out", help="write the list to this file instead of the screen")
    parser.add_argument("--video", help="recording to cut clips from (needs --sync and --clips)")
    parser.add_argument("--clips", help="folder for cut clips; ffmpeg copies the streams without re-encoding")
    args = parser.parse_args(argv)
    try:
        events = promo.read_events(inputs(args.paths))
        clock = Clock(events, args.sync, args.sync_index)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2
    ranked = best(Finder(events, clock).find(), args.top)
    text = (markdown(ranked, clock.label) if args.format == "md" else table(ranked) if args.format == "csv"
            else json.dumps(ranked, indent=1) + "\n")
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    if args.video or args.clips:
        if not (args.video and args.clips and args.sync is not None):
            print("Cutting clips needs --video, --clips and --sync together.", file=sys.stderr)
            return 2
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            print("ffmpeg is not on PATH; the list above still has every clip time.", file=sys.stderr)
            return 3
        Path(args.clips).mkdir(parents=True, exist_ok=True)
        for command in clip_commands(ranked, args.video, args.clips, ffmpeg):
            subprocess.run(command, check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
