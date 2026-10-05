"""Local-only playtest transcription/formatting. No transcript is printed to stdout."""
from __future__ import annotations

import argparse
import contextlib
import ctypes
from ctypes import wintypes
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import wave

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
HIDDEN = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex[:8])
    try:
        temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
        # The companion polls these files; a replace that lands mid-read is refused, so retry briefly.
        for attempt in range(50):
            try:
                os.replace(temp, path)
                break
            except PermissionError:
                if attempt == 49:
                    raise
                time.sleep(.02)
    finally:
        temp.unlink(missing_ok=True)


def revision():
    return dt.datetime.now().strftime("%Y-%m-%d_%H%M%S") + "_" + uuid.uuid4().hex[:6]


def configure(path):
    path = Path(path)
    if path.exists():
        raise ValueError("Configuration already exists; edit it in place. Nothing was overwritten.")
    app = Path(os.environ.get("APPDATA", "")) / "open-webui"
    python = app / "python/python.exe"
    caches = [app / "data/cache/whisper/models", Path.home() / ".cache/huggingface/hub"]
    models = [p for cache in caches for p in cache.glob("models--Systran--faster-whisper-base/snapshots/*") if (p / "model.bin").is_file()]
    whisper = str(models[0]) if models else ""
    engine = Path("C:/llama-cpp/llama-server.exe")
    model = Path("C:/llama-cpp/models/gemma-4-12b-it-UD-Q4_K_XL.gguf")
    if not model.is_file():
        model = Path("C:/llama-cpp/models/Qwen3-VL-8B-Instruct-Q8_0.gguf")
    settings = {
        "notes_dir": str(REPO / "playtest-notes"),
        "python": str(python if python.exists() else Path(sys.executable)),
        "checklist": str(HERE / "checklist.json"), "microphone": "",
        "show_hud": True, "hud_width": 0.48, "hud_y": -0.38, "hud_z": -1.1,
        "vocabulary": str(HERE / "vocabulary.txt"), "cleanup_prompt": str(HERE / "cleanup-prompt.txt"),
        "whisper": {"model": whisper, "device": "cpu", "compute_type": "int8", "cpu_threads": 4, "language": "en"},
        "llm": {"server": str(engine), "model": str(model), "threads": 4, "context": 16384,
                "max_output_tokens": 4096, "startup_timeout": 180, "request_timeout": 900},
    }
    save(path, settings)
    print("Created local configuration:", path)


def validate(config, *, dependencies=False, transcription=True):
    required = ("notes_dir", "python", "checklist", "vocabulary", "cleanup_prompt", "whisper", "llm")
    for key in required:
        if not config.get(key):
            raise ValueError("Missing configuration: " + key)
    for key in ("notes_dir", "python", "checklist", "vocabulary", "cleanup_prompt"):
        if not Path(config[key]).is_absolute():
            raise ValueError(key + " must be an absolute path.")
    phases = read(config["checklist"])
    if not isinstance(phases, list) or not phases or any(not p.get("weapon") or not p.get("scenario") for p in phases):
        raise ValueError("Checklist must contain phases with weapon and scenario.")
    llm = config["llm"]
    context, output = int(llm["context"]), int(llm["max_output_tokens"])
    if output < 128 or context <= output + 1024 or context > 65536:
        raise ValueError("LLM context must leave room for both prompt and output (maximum 65536).")
    if not 1 <= int(llm["threads"]) <= 16 or not 1 <= int(config["whisper"]["cpu_threads"]) <= 16:
        raise ValueError("Set CPU thread counts between 1 and 16.")
    for key in ("startup_timeout", "request_timeout"):
        if not 1 <= float(llm[key]) <= 3600:
            raise ValueError(key + " must be between 1 and 3600 seconds.")
    if dependencies:
        paths = [config["python"], config["vocabulary"], config["cleanup_prompt"], llm["server"], llm["model"]]
        for name in paths:
            if not Path(name).is_file():
                raise ValueError("Required local file not found: " + name)
        if transcription:
            whisper = Path(config["whisper"]["model"])
            if not (whisper / "model.bin").is_file() or not (whisper / "tokenizer.json").is_file():
                raise ValueError("Whisper model must be a complete local model directory, including model.bin and tokenizer.json.")
            if importlib.util.find_spec("faster_whisper") is None:
                raise ValueError("Configured Python does not have faster-whisper. Use the existing Open WebUI Python environment.")


def game_running():
    result = subprocess.run(["tasklist.exe", "/FI", "IMAGENAME eq KFGame.exe", "/FO", "CSV", "/NH"],
                            capture_output=True, text=True, creationflags=HIDDEN, check=True)
    return '"kfgame.exe"' in result.stdout.lower()


def copy_text(text):
    # Send text over stdin, never interpolate dictation into executable commands.
    command = "$ErrorActionPreference='Stop'; [Console]::InputEncoding=[Text.UTF8Encoding]::new(); Set-Clipboard -Value ([Console]::In.ReadToEnd())"
    for _ in range(3):
        result = subprocess.run(["powershell.exe", "-NoProfile", "-STA", "-Command", command], input=text,
                                capture_output=True, text=True, encoding="utf-8", creationflags=HIDDEN, timeout=15)
        if result.returncode == 0:
            return
        time.sleep(.2)
    raise OSError("Clipboard is busy. Use CopyLatest to retry.")


@contextlib.contextmanager
def lock_session(folder):
    import msvcrt
    with (folder / "processing.lock").open("a+b") as f:
        f.seek(0); f.write(b"0"); f.flush(); f.seek(0)
        try:
            msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            raise ValueError("This session is already being processed.") from None
        try:
            yield
        finally:
            f.seek(0); msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)


def audio_path(folder, name):
    path = (folder / name).resolve()
    if path.parent != folder.resolve() or not path.is_file():
        raise ValueError("Missing or invalid session audio: " + name)
    return path


def audio_groups(session, folder):
    """Join contiguous recorder chunks so recognition does not cut words at file boundaries."""
    groups = []
    for part in session["audio"]:
        path = audio_path(folder, part["file"])
        duration = None
        if path.suffix.lower() == ".wav":
            try:
                with wave.open(str(path)) as wav:
                    if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 48000):
                        duration = wav.getnframes() / 48000
            except (wave.Error, EOFError):
                pass
        if groups and duration is not None and groups[-1]["end"] is not None and abs(groups[-1]["end"] - part["start"]) < .02:
            groups[-1]["paths"].append(path); groups[-1]["end"] += duration
        else:
            groups.append({"paths": [path], "start": part["start"], "end": part["start"] + duration if duration is not None else None})
    return groups


@contextlib.contextmanager
def joined_audio(group, folder):
    if len(group["paths"]) == 1:
        yield group["paths"][0]
        return
    target = folder / (".joined-" + uuid.uuid4().hex + ".wav")
    try:
        with wave.open(str(target), "wb") as out:
            out.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
            for path in group["paths"]:
                with wave.open(str(path), "rb") as source:
                    while data := source.readframes(48000):
                        out.writeframesraw(data)
        yield target
    finally:
        target.unlink(missing_ok=True)


def timestamp(seconds):
    whole = int(seconds)
    return f"{whole // 3600:02}:{whole // 60 % 60:02}:{whole % 60:02}"


def transcribe(config, session, folder, status):
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    from faster_whisper import WhisperModel
    w = config["whisper"]
    model = WhisperModel(w["model"], device=w["device"], compute_type=w["compute_type"],
                         cpu_threads=int(w["cpu_threads"]), local_files_only=True)
    words = [line.strip() for line in Path(config["vocabulary"]).read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    hints = ", ".join(words)
    rev = revision()
    text_path = folder / ("transcript_" + rev + ".txt")
    json_path = folder / ("transcript_" + rev + ".json")
    segments = []
    groups = audio_groups(session, folder)
    with text_path.open("x", encoding="utf-8") as out:
        for i, group in enumerate(groups):
            status(f"Transcribing recording {i + 1} / {len(groups)} locally…")
            with joined_audio(group, folder) as source:
                iterator, _ = model.transcribe(str(source), language=w.get("language", "en"),
                                              initial_prompt="KF2-VR playtest terminology: " + hints,
                                              vad_filter=True, condition_on_previous_text=False, beam_size=5)
                for s in iterator:
                    if not s.text.strip():
                        continue
                    item = {"start": round(group["start"] + s.start, 3), "end": round(group["start"] + s.end, 3), "text": s.text.strip()}
                    segments.append(item)
                    out.write(f"[{timestamp(item['start'])}–{timestamp(item['end'])}] {item['text']}\n")
                    out.flush()
    del model
    save(json_path, {"schema": 1, "segments": segments, "model": w["model"], "vocabulary": words})
    save(folder / "latest-transcript.json", {"text": str(text_path), "json": str(json_path)})
    if not segments:
        raise ValueError("No speech detected. Audio and empty transcript saved; check the microphone before recording again.")
    return segments


def request(base, route, value=None, timeout=30):
    url = base + route
    data = json.dumps(value).encode() if value is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    # Never send localhost requests through an inherited HTTP proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as response:
        return json.load(response)


class OwnedServer:
    """One temporary CPU server, reusing installed binaries/weights; never touches llama-swap."""
    def __init__(self, settings, folder):
        self.settings, self.folder = settings, folder
        self.process = self.log = self.job = None

    def __enter__(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]
        self.base = f"http://127.0.0.1:{port}"
        s = self.settings
        command = [s["server"], "--model", s["model"], "--host", "127.0.0.1", "--port", str(port),
                   "--n-gpu-layers", "0", "--threads", str(s["threads"]), "--threads-batch", str(s["threads"]),
                   "--ctx-size", str(s["context"]), "--parallel", "1", "--jinja", "--reasoning", "off", "--no-warmup"]
        try:
            self.log = (self.folder / ("processor_" + revision() + ".log")).open("w", encoding="utf-8")
            self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log,
                                            creationflags=HIDDEN, cwd=str(Path(s["server"]).parent))
            self.job = kill_with_parent(self.process)
            deadline = time.monotonic() + s["startup_timeout"]
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError("Local cleanup model could not start. See the session's processor log.")
                try:
                    if request(self.base, "/health", timeout=2).get("status") == "ok":
                        return self.base
                except (OSError, ValueError):
                    pass
                time.sleep(.5)
            raise TimeoutError("Local cleanup model startup timed out; audio/transcript are saved.")
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *args):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait()
        if self.job:
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            kernel.CloseHandle(self.job); self.job = None
        if self.log:
            self.log.close()


def kill_with_parent(process):
    """Windows job closes the owned model if this processor is killed unexpectedly."""
    class Basic(ctypes.Structure):
        _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64), ("flags", wintypes.DWORD),
                    ("minimum", ctypes.c_size_t), ("maximum", ctypes.c_size_t), ("active", wintypes.DWORD),
                    ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD), ("scheduling", wintypes.DWORD)]
    class IO(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in ("read", "write", "other", "read_bytes", "write_bytes", "other_bytes")]
    class Extended(ctypes.Structure):
        _fields_ = [("basic", Basic), ("io", IO), ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                    ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]; kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    job = kernel.CreateJobObjectW(None, None)
    if not job:
        raise ctypes.WinError(ctypes.get_last_error())
    info = Extended(); info.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not kernel.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info)) or not kernel.AssignProcessToJobObject(job, wintypes.HANDLE(int(process._handle))):
        error = ctypes.get_last_error(); kernel.CloseHandle(job); raise ctypes.WinError(error)
    return job


def cleanup(config, session, segments, folder, status):
    timeline = [{"at": e["at"], "kind": e["kind"], "phase": e["phase"], "lookback": e.get("lookback")}
                for e in session["events"] if e["kind"] in ("phase", "bug", "record", "pause", "audio_error")]
    source = {"checklist_context_not_results": session["phases"], "phase_timeline_not_results": timeline,
              "spoken_observations": segments}
    messages = [{"role": "system", "content": Path(config["cleanup_prompt"]).read_text(encoding="utf-8")},
                {"role": "user", "content": json.dumps(source, ensure_ascii=False)}]
    s = config["llm"]
    status("Loading local cleanup model on CPU…")
    with OwnedServer(s, folder) as base:
        status("Checking transcript length…")
        template = request(base, "/apply-template", {"messages": messages, "add_generation_prompt": True,
                                                     "chat_template_kwargs": {"enable_thinking": False}})
        tokens = request(base, "/tokenize", {"content": template["prompt"], "add_special": True})["tokens"]
        if len(tokens) + s["max_output_tokens"] + 128 > s["context"]:
            raise ValueError("Transcript is too long for the configured context. Raw transcript saved. Increase llm.context or use shorter sessions; no notes were silently dropped.")
        status("Formatting playtest notes locally…")
        response = request(base, "/v1/chat/completions", {"messages": messages, "temperature": 0.15,
                           "max_tokens": s["max_output_tokens"], "stream": False,
                           "chat_template_kwargs": {"enable_thinking": False}}, timeout=s["request_timeout"])
    choice = response["choices"][0]
    if choice.get("finish_reason") != "stop":
        raise ValueError("Cleanup did not finish completely. Transcript preserved; increase the output/context budget and rerun CleanLast.")
    body = choice["message"].get("content", "").strip()
    if body.startswith("```") and body.endswith("```"):
        body = body.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    if not body.startswith("## "):
        raise ValueError("Cleanup returned an unexpected format. Transcript preserved; rerun CleanLast or change the cleanup model.")
    # Release metadata is written by the application, never inferred by the model.
    release = str(session.get("selected_release", "unknown")).replace("\n", " ").replace("\r", " ")
    return f"# KF2-VR Playtest Feedback\n\nSelected release: {release}\nSession: {session['id']}\nStarted: {session['started_utc']}\n\n{body}\n"


def import_audio(config, source, release):
    source = Path(source).resolve()
    if not source.is_file():
        raise ValueError("Audio file not found.")
    sid = revision()
    folder = Path(config["notes_dir"]) / "raw" / sid
    folder.mkdir(parents=True)
    destination = folder / ("imported" + source.suffix)
    shutil.copy2(source, destination)
    # Existing audio may come from any build; do not attach today's selected release implicitly.
    session = {"schema": 1, "id": sid, "started_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
               "selected_release": release or "unknown (imported recording)", "status": "finished", "phase_index": 0,
               "phases": [{"weapon": "Freeform", "scenario": "Imported recording", "instruction": "", "watch": ""}],
               "events": [], "audio": [{"file": destination.name, "start": 0}]}
    save(folder / "session.json", session)
    return folder / "session.json"


def latest_session(config):
    # Finished/recorded sessions, not an empty new session or a re-cleaned older one.
    candidates = []
    for path in (Path(config["notes_dir"]) / "raw").glob("*/session.json"):
        item = read(path)
        if item.get("audio"):
            candidates.append((item["started_utc"], path))
    if not candidates:
        raise ValueError("No recorded session found.")
    return max(candidates, key=lambda pair: pair[0])[1]


def process(config, session_path, clean_only, copy):
    folder = Path(session_path).resolve().parent
    # One inference job at a time, plus the per-session lease shared with the recorder.
    with lock_session(Path(config["notes_dir"])), lock_session(folder):
        def status(message, state="running"):
            save(folder / "processing.json", {"state": state, "message": message})
        try:
            session = read(session_path)
            if session.get("schema") != 1 or not session.get("audio"):
                raise ValueError("Session has no recorded audio or uses an unsupported format.")
            if session.get("status") == "recording":
                raise ValueError("Pause/finish the session first. After a crash, reopen the companion to recover it.")
            if game_running():
                raise ValueError("Exit KF2 before processing. Recording remains saved for later.")
            if clean_only:
                latest = read(folder / "latest-transcript.json")
                segments = read(latest["json"])["segments"]
                if not segments:
                    raise ValueError("The saved transcript contains no speech.")
            else:
                status("Starting local transcription…")
                segments = transcribe(config, session, folder, status)
            report = cleanup(config, session, segments, folder, status)
            output = Path(config["notes_dir"]) / "cleaned" / (session["id"] + "_" + revision() + ".md")
            output.parent.mkdir(parents=True, exist_ok=True)
            with output.open("x", encoding="utf-8") as f:
                f.write(report)
            pointer = {"path": str(output), "session": str(session_path)}
            save(folder / "latest-report.json", pointer)
            save(Path(config["notes_dir"]) / "latest-report.json", pointer)
            message = "Report saved"
            if copy:
                try:
                    copy_text(report); message += " and copied — paste when ready"
                except (OSError, subprocess.TimeoutExpired):
                    message += "; clipboard busy — use Copy report to retry"
            status(message, "complete")
            print(message + ": " + str(output))
        except Exception as ex:
            status(str(ex), "failed")
            raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=HERE / "local.config.json")
    actions = parser.add_mutually_exclusive_group(required=True)
    for flag in ("configure", "check", "last", "copy-latest"):
        actions.add_argument("--" + flag, action="store_true")
    actions.add_argument("--session", type=Path)
    actions.add_argument("--audio", type=Path)
    parser.add_argument("--release")
    parser.add_argument("--clean-only", action="store_true")
    parser.add_argument("--copy", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.configure:
            configure(args.config); return 0
        config = read(args.config)
        if args.copy_latest:
            latest = read(Path(config["notes_dir"]) / "latest-report.json")
            copy_text(Path(latest["path"]).read_text(encoding="utf-8")); print("Latest report copied."); return 0
        validate(config, dependencies=True, transcription=not args.clean_only)
        if args.check:
            print("Local paths, checklist, model files and faster-whisper installation found.")
            print("Notes:", config["notes_dir"])
            print("Microphone:", config.get("microphone") or "Choose in the companion before recording")
            return 0
        if args.audio:
            path = import_audio(config, args.audio, args.release)
        else:
            path = args.session or latest_session(config)
        process(config, path, args.clean_only, args.copy)
        return 0
    except Exception as ex:
        print("Playtest processing: " + str(ex), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
