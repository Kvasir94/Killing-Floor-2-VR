"""Export committed public source, a ZIP and a hashed inventory without publishing."""
from __future__ import annotations
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {".gitattributes", ".gitignore", ".rgignore", "AGENTS.md", "LICENSE",
              "README.md", "CONTRIBUTING.md", "CMakeLists.txt", "PLAY-MULTIPLAYER.md",
              "Play-KF2VR.cmd", "Play-KF2VR-TestMap.cmd"}
DOCS = {"docs/BUILDING.md", "docs/PROVENANCE.md", "docs/PUBLISHING.md", "docs/VR_CONTROLS.md", "docs/REPLAY_INPUT.md",
        "docs/intake/install_manifest.json",
        "docs/public-alpha/READ-ME-FIRST.txt", "docs/public-alpha/CONTROLS-CARD.txt",
        "docs/public-alpha/RELEASE-NOTES-DRAFT.md", "docs/public-alpha/FEEDBACK-QUESTIONS.md",
        "docs/public-alpha/THIRD-PARTY-NOTICES.txt", "docs/public-alpha/BREACHER.md"}
ASSETS = {"native/adapter/assets/ringside_bell_ding.wav", "native/adapter/assets/ringside_bell_ready.wav",
          "assets/weapons/raven7/material-atlas-v2.png"}
ASSET_DOCS = {"assets/weapons/raven7/README.md"}
SOURCE_DATA = {"tools/replay/stock-launchers.input"}
TEXT_SUFFIXES = {".cpp", ".h", ".hpp", ".c", ".asm", ".rc", ".def", ".uc", ".int",
                 ".py", ".ps1", ".cmd", ".json", ".cmake", ".txt", ".md", ".patch",
                 ".cs", ".csproj"}
EXCLUDE = {"tools/archive-project-history.py", "tools/start-terra-astra.ps1"}


def reason(path):
    if path.startswith(("history/", "kf2vr_chat_export/", "kf2-vr-research/", "docs/ai/")):
        return "private history, conversations or internal coordination"
    if path in EXCLUDE or path.startswith("tools/codex/"):
        return "local agent/archiving setup"
    if path in ASSETS or path in ASSET_DOCS or path in SOURCE_DATA:
        return None
    if Path(path).suffix.lower() in {".wav", ".png"}:
        return "legacy/nonessential binary asset outside current build"
    if path in ROOT_FILES or path in DOCS:
        return None
    if path in {"third_party/README.md", "third_party/VERSIONS.md", "third_party/xr-sdks.cmake"}:
        return None
    if path.startswith(("native/", "script/", "tools/", "project/", "staging/")) and Path(path).suffix.lower() in TEXT_SUFFIXES:
        return None
    return "outside curated source/documentation selection"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="new destination folder (must not exist)")
    args = parser.parse_args(argv)
    head = git("rev-parse", "HEAD").decode().strip()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    output = (args.output or ROOT / "build/public-source" / f"KF2VR-Source-{stamp}-{head[:12]}").resolve()
    archive_path = Path(str(output) + ".zip")
    manifest_path = Path(str(output) + ".manifest.json")
    if any(p.exists() for p in (output, archive_path, manifest_path)):
        raise SystemExit("Destination already exists; use a new folder. Existing exports are never removed.")
    if output == ROOT or output in ROOT.parents:
        raise SystemExit("Destination must be a new export folder, not the checkout or its ancestor.")
    tracked = git("ls-tree", "-r", "--name-only", head).decode().splitlines()
    selected = [p for p in tracked if reason(p) is None]
    missing = sorted((ROOT_FILES | DOCS) - set(tracked))
    if missing:
        raise SystemExit("Required committed files missing: " + ", ".join(missing))
    # Read committed blobs directly, never archive/extract private history.
    batch = subprocess.run(["git", "cat-file", "--batch"], cwd=ROOT,
        input="".join(f"{head}:{p}\n" for p in selected).encode(), stdout=subprocess.PIPE, check=True).stdout
    contents, offset = {}, 0
    for path in selected:
        end = batch.index(b"\n", offset)
        size = int(batch[offset:end].split()[-1])
        offset = end + 1
        contents[path] = batch[offset:offset + size]
        offset += size + 1
    external_sources = []
    # Small licensed source snapshot used by the native build, with the
    # complete upstream license. No upstream binary/tool cache is exported.
    pins = re.findall(r"\| `([^`]+)` \| `([a-f0-9]{64})` \|", contents["third_party/VERSIONS.md"].decode())
    if not pins:
        raise SystemExit("No MinHook source pins found.")
    for relative, expected in pins:
        path = "third_party/minhook/" + relative
        raw = (ROOT / path).read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected:
            raise SystemExit("Pinned dependency source differs: " + path)
        contents[path] = raw
        external_sources.append(path)
    rewrites = []
    link_pattern = re.compile(r"(!?)\[([^]\n]+)\]\(([^)]+)\)")
    for path, raw in list(contents.items()):
        if path in ASSETS:
            continue
        try:
            text = raw.decode("utf-16") if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else raw.decode("utf-8-sig")
        except UnicodeDecodeError:
            text = raw.decode("cp1252")
            rewrites.append({"file": path, "encoding": "cp1252 to utf-8"})
        if path == ".gitignore":
            text = text.split("# Curated, text-only historical evidence")[0]
            text += "\n# Private/local material stays outside a public repository\nhistory/\nkf2vr_chat_export/\nkf2-vr-research/\n.worktrees/\n.pytest_cache/\n*.log\n*.dmp\n.env\n.env.*\n!third_party/minhook/\n!third_party/minhook/**\n"
        if path == "docs/intake/install_manifest.json":
            # Keep compatibility hashes, replace local installation paths with examples.
            value = json.loads(text)
            def portable(v):
                if isinstance(v, dict): return {k: portable(x) for k, x in v.items()}
                if isinstance(v, list): return [portable(x) for x in v]
                if isinstance(v, str): return re.sub(r"(?i)D:[\\/]SteamLibrary[\\/]steamapps[\\/]common[\\/]killingfloor2", "C:/Games/KillingFloor2", v)
                return v
            text = json.dumps(portable(value), indent=2) + "\n"
        if path.endswith(".md"):
            def link(match):
                target = match[3].strip("<>").split("#")[0]
                if not target or re.match(r"^[a-z]+:", target, re.I): return match[0]
                resolved = os.path.normpath(str(Path(path).parent / target)).replace("\\", "/")
                if resolved in contents or any(p.startswith(resolved.rstrip("/") + "/") for p in contents): return match[0]
                rewrites.append({"file": path, "removed_link": target})
                return match[2]
            text = link_pattern.sub(link, text)
        contents[path] = text.encode("utf-8")
    username = os.environ.get("USERNAME", "")
    patterns = {
        "private-key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        "github-token": r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b",
        "cloud-key": r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
        "slack-token": r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b",
        "discord-webhook": r"https://(?:discord(?:app)?\.com)/api/webhooks/\d+/[A-Za-z0-9_-]{20,}",
        "personal-install-path": r"(?i)[A-Z]:[\\/]Users[\\/](?!Public\b|Default\b|Personal\b|PrivateTester\b|TestUser\b)[^\\/\s\"']+",
    }
    if username and username.lower() not in {"user", "runner", "administrator"}:
        patterns["local-account-name"] = r"(?i)\b" + re.escape(username) + r"\b"
    hits = []
    for path, raw in contents.items():
        scanned_text = raw.decode("latin1") if path in ASSETS else raw.decode()
        for number, line in enumerate(scanned_text.splitlines(), 1):
            for category, pattern in patterns.items():
                if re.search(pattern, line): hits.append({"file": path, "line": number, "category": category})
    if hits:
        print(json.dumps({"scan_findings": hits}, indent=2))
        raise SystemExit("Export stopped before writing files. Review the reported source locations.")
    output.mkdir(parents=True)
    for path, raw in contents.items():
        destination = output / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
    hashes = {p: hashlib.sha256(raw).hexdigest() for p, raw in sorted(contents.items())}
    with zipfile.ZipFile(archive_path, "x", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(contents): archive.write(output / path, output.name + "/" + path)
    # Review manifest stays beside the source, outside the files to publish.
    excluded = [{"path": p, "reason": reason(p)} for p in tracked if reason(p)]
    report = {"schema": "kf2vr/public-source/1", "source_commit": head,
        "files": len(hashes), "files_sha256": hashes,
        "zip_sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
        "excluded_counts": dict(Counter(x["reason"] for x in excluded)),
        "excluded_tracked_paths": [x for x in excluded if x["reason"] != "private history, conversations or internal coordination"], "included_pinned_dependency_sources": external_sources, "export_rewrites": rewrites,
        "scan_findings": hits, "git_history_included": False,
        "scan_limit": "Pattern scan plus curated exclusions; not a guarantee that every secret is recognizable.",
        "playable_build": "Requires separately supplied game/SDK/dependencies and excluded asset inputs; see docs/BUILDING.md."}
    manifest_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    with zipfile.ZipFile(archive_path) as archive:
        assert len(archive.namelist()) == len(hashes)
        for path, digest in hashes.items():
            assert hashlib.sha256(archive.read(output.name + "/" + path)).hexdigest() == digest
    print(json.dumps({"source_folder": str(output), "zip": str(archive_path),
        "manifest": str(manifest_path), "source_commit": head, "files": len(hashes),
        "zip_sha256": report["zip_sha256"], "excluded_counts": report["excluded_counts"],
        "scan_findings": hits}, indent=2))


if __name__ == "__main__":
    main()
