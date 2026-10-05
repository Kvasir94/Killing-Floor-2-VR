# KF2-VR playtest companion

A separate Windows application provides a SteamVR dashboard checklist, a small
read-only status panel, microphone recording and local Markdown reports. It does
not change KF2, SteamVR bindings, the default audio device or the shared AI service.
OpenVR is used under its bundled Valve SDK license in `third_party/openvr/LICENSE`.

## Start and record

From the repository root:

```powershell
.\Playtest-Dictation.ps1
```

Start SteamVR normally. In the companion's desktop window, select your headset
microphone by name. Use **Refresh mics** after connecting the headset. Start a
recording and check that the green meter responds to your voice. The choice is
saved; missing or duplicate device names produce an error instead of falling back
to another microphone. Windows must allow desktop applications microphone access.

Open the SteamVR dashboard and choose **KF2-VR Playtest**. Its buttons work with
the dashboard's normal controller pointer. The compact panel during gameplay is
read-only; it does not take controller input. **Hide status panel** removes it.
Desktop buttons perform the same actions when SteamVR is unavailable.

- **Start recording / Pause recording:** capture or stop microphone audio.
- **Previous / Next:** change the phase and timestamp the change. Next never means
  PASS. Say your actual result aloud, including anything explicitly not tested.
- **Mark bug:** bookmark this moment and the preceding 15 seconds. Describe the
  problem aloud; the bookmark itself does not invent a bug description.
- **Finish / save:** stop recording and finish this session, without inference.
- **Process now:** transcribe and format the saved session after KF2 has closed.
  CPU processing may take several minutes. The panel displays its current stage.
- **Copy report:** copy this session's latest successful report.
- **New session:** start another checklist after finishing the current session.

Describe unrelated discoveries naturally: spoken weapon names override the current
checklist context. The microphone records continuously between Start and Pause;
there is no speech-command listener, push-to-talk hook or automatic pass/fail detection.
If SteamVR closes, recording continues through Windows. If the companion closes,
audio is saved and recording pauses. Reopen to resume the checklist, then explicitly
start recording again. Do not exit the companion while report processing is active.

## Files and build association

```text
playtest-notes/
  raw/<session-id>/
    session.json             # checklist snapshot, selected release, timed events
    audio_<id>.wav           # 30-second durable chunks, mono 48 kHz PCM
    transcript_<revision>.txt
    transcript_<revision>.json
    latest-transcript.json
    latest-report.json
    processing.json
    processor_<revision>.log
  cleaned/<session-id>_<revision>.md
  active.json
  latest-report.json
```

Sessions use local date/time to the second plus a unique suffix. Metadata records
UTC start time; transcript timestamps are elapsed session time and preserve gaps
between recordings. Contiguous audio chunks are joined temporarily for transcription
so file boundaries do not cut words. Notes, local preferences and build output are
ignored by Git. Existing audio/transcripts/reports are not silently overwritten.

New sessions snapshot `build/multiplayer/current-release.json`. The report calls
this **Selected release** because it cannot verify which game build actually ran.
An explicit override is available:

```powershell
.\Playtest-Dictation.ps1 -Release 'KF2VR-Multiplayer-20260928-024353'
```

The override applies to new sessions created in that invocation; a resumed session
keeps its original release. Imported audio has an unknown release unless specified.

## Process later, re-clean, import or copy

```powershell
.\Playtest-Dictation.ps1 -Action ProcessLast
.\Playtest-Dictation.ps1 -Action CleanLast
.\Playtest-Dictation.ps1 -Action CopyLatest
.\Playtest-Dictation.ps1 -Action Import -Audio 'D:\recordings\test.wav' -Release 'my-build'
```

ProcessLast transcribes the most recently started session containing audio.
CleanLast reuses that session's latest complete timestamped transcript JSON and
creates a new Markdown revision; it does not transcribe again. CopyLatest copies
the most recently generated successful report. All processing actions copy the
report when successful. Clipboard failure never discards a saved report.

To process an older session, invoke the processor with its saved configuration:

```powershell
$config = Get-Content .\tools\playtest-dictation\local.config.json -Raw | ConvertFrom-Json
& $config.python .\tools\playtest-dictation\process.py --config .\tools\playtest-dictation\local.config.json --session 'D:\KF2-VR\playtest-notes\raw\SESSION\session.json' --clean-only --copy
```

Review the Markdown locally if desired, then deliberately paste it into Codex.
The companion never submits notes to a chat, GitHub or another service.

## Configuration and models

The first launch creates `tools/playtest-dictation/local.config.json` using existing
local installations. Run `-Action Configure` to check paths; it never overwrites
your choices. Close the companion before manually editing preferences.

- **Whisper:** `whisper.model` is a complete local faster-whisper model directory
  containing `model.bin`, `config.json`, `tokenizer.json` and its supporting files.
  The discovered Open WebUI base model is the initial default. Change this path to
  another installed CTranslate2 Whisper model. `device: cpu`, `compute_type: int8`
  and four CPU threads avoid CUDA dependencies. Runtime downloads are disabled.
- **Python:** `python` initially points to Open WebUI's existing Python, which
  already includes faster-whisper. No packages are added to that environment.
  If Open WebUI moves or removes it, update this path to an environment with
  faster-whisper installed, then run Configure.
- **Cleanup LLM:** `llm.server` points to the existing `llama-server.exe` and
  `llm.model` to a local instruction-tuned GGUF with a working chat template.
  Initially this uses the existing Gemma 4 12B Instruct Q4 weights for text only
  (the configurator falls back to Qwen3-VL 8B if those weights are unavailable).
  Change the model path to use another compatible installed model. The companion
  starts its own loopback CPU server after recording and stops only that server
  afterward. It does not change llama-gate, llama-swap or their loaded models.
- **Budgets:** `llm.context`, `max_output_tokens`, `threads`, `startup_timeout`
  and `request_timeout` are configurable. Context is checked before generation;
  an oversized transcript or incomplete generation fails clearly rather than
  silently truncating notes. Prefer shorter focused sessions if this occurs.
- **Vocabulary:** edit `vocabulary.txt`, one term per line. It biases Whisper;
  it is not a guarantee and no broad substitutions rewrite your raw transcript.
- **Cleanup behavior:** edit `cleanup-prompt.txt`; CleanLast applies the revised
  instructions while retaining the original transcript and previous reports.
- **Checklist:** edit `checklist.json`, or point `checklist` at another file. Each
  phase has `weapon`, `scenario`, `instruction`, and optional `watch`. Changes apply
  to new sessions, preserving the checklist used by existing recordings.
- **Panel position:** `hud_width` is width in meters; `hud_y` and `hud_z` position
  it relative to your head. Negative Y is below eye level; negative Z is forward.
  Restart the companion after changing these values.
- **Output:** `notes_dir` can point to another absolute local directory.

## Recovery and limits

An audio failure stops recording and appears in the panel. WAV headers are updated
after each captured buffer, so interrupted recordings retain completed buffers.
After a crash, reopen the companion before processing a session still marked as
recording. A microphone that delivers silent samples can still be the wrong device:
use the meter and listen to a short recording before a long test.

If transcription fails, the audio remains. If cleanup fails, the complete raw
transcript remains and CleanLast can retry. Partial transcription text is retained
under its revision filename but is not selected as a complete transcript. Processing
locks prevent another process from cleaning a session while it is recording.

The report is a local model's draft; preserve uncertainties and check the raw
transcript when wording matters. The initial version does not record video, gather
game telemetry, infer test results or change gameplay. SteamVR must be the active
VR runtime for its overlay to be visible. Dashboard interaction and microphone
routing still need a real headset check on your connection method.

## Rebuild

The installed .NET 8 SDK and repository OpenVR SDK are sufficient; no extra NuGet
packages are used. Close KF2 and the companion, then run:

```powershell
.\tools\build-playtest-dictation.ps1
```

This standalone build uses the shared KF2-VR build mutex and writes only under
`build/playtest-dictation/`. It does not rebuild or select a different game package.
