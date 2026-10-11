# Experimental DLSS

DLSS is Off by default. In the portable launcher, Solo, Host and Join expose Off, DLAA, Quality, Balanced, Performance and Ultra Performance. NVIDIA RTX hardware and a compatible driver are required. This is Super Resolution/DLAA, not frame generation. Motion vectors describe camera motion only, so moving hands and enemies can show artifacts. Headset and real online play remain the acceptance tests.

The eye render percentage sets output resolution. DLSS reduces input resolution within that output; DLAA keeps full input resolution. Both eyes share jitter and keep separate histories. If either evaluation fails, both complete ordinary eye images fill the headset outputs through the normal atlas blit, and subsequent pairs use ordinary sizing. Off follows the ordinary copy path. Menu/world resets discard history; large camera cuts also discard it. Allocation/device failures can still prevent presenting a frame.

Portable options: `--dlss quality --dlss-sharpness 0`, or `--dlss off`. Sharpness is an integer from 0 to 100, initially 0. Explicit non-Off DLSS requires VR. Settings are personal, including when joining; joining does not overwrite host/loadout preferences. Malformed saved options fall back to Off/0; malformed JSON is preserved and must be repaired before saving.

`--hide-bile-lens` is initially on for VR; `--no-hide-bile-lens` restores Bloat screen splatter. It suppresses the stock puke lens class and subclasses, not damage or poisoning. Steam and Epic Solo deliver the same typed graphics options. Epic multiplayer restrictions remain unchanged. No arbitrary environment forwarding is allowed.

Build with `tools/fetch-ngx.ps1`, then `tools/build-kf2vr.ps1 -NoSelect -Dlss`. The official NVIDIA v310.7.0 SDK commit, all header/library/license hashes and runtime hash are pinned in `tools/ngx-pins.json`. The runtime stays in the verified package Native folder. Build receipts and frozen reuse include its identity. Without `-Dlss`, the adapter builds with an Off stub and no NGX dependency; math tests remain available.

NVIDIA DLSS/NGX is separately licensed by NVIDIA, not covered by this project's MIT licence. See `third_party/NVIDIA-DLSS-LICENSE.txt` (distributed as `notices/NVIDIA-DLSS-LICENSE.txt`). This software contains source code provided by NVIDIA Corporation. NVIDIA GeForce RTX and NVIDIA RTX are NVIDIA trademarks. SDK use can create `%LOCALAPPDATA%\KF2VR\ngx`; NVIDIA's licence permits over-the-air updates. Neither offline operation nor vendor-runtime byte reproducibility is promised. Close the game before removing that cache.

CAS sharpening adapts AMD FidelityFX CAS, pinned provenance `GPUOpen-Effects/FidelityFX-CAS` commit `9fabcc9a2c45f958aff55ddfda337e74ef894b7f`, with its full notice in `third_party/AMD-CAS-LICENSE.txt` and the package notices folder. Fork implementation credit: optimumbox, original commit `e080bc0e1e1a56e3de61498634f40ca2c29692ed`, with Claude Opus 5.5 co-author attribution.

Release `v0.2.0-alpha.20261011` includes the DLSS-enabled 213005 payload, with the
full NVIDIA licence and attribution in its notices. The maintainer confirmed
approval and mark-placement coverage for that release. Future distributors must
review NVIDIA's licence obligations for their own distribution; including a
notice alone does not complete them.

Single-pass stereo is an experimental Steam option from optimumbox's
`0e972979` contribution, initially On for Steam VR (saved Off choices remain).
`--no-single-pass` or root `-SinglePass Off` restores sequential stereo. It renders
both eye rectangles together, with the author's visibility, shadow and HBAO
handling preserved. The combined render target is capped at 8192 pixels wide.
DLSS still retains complete source images for pair-wide failure fallback.

HBAO and reflections are initially On; `--no-hbao` and `--no-reflections`
disable them. `--hide-blood-lens` is initially On, independently of
bile suppression; `--no-hide-blood-lens` restores blood lens splatter. These
personal settings are available in the player window. Steam Solo/Host/Join
share them; Epic Solo supports the effect choices but keeps sequential stereo.
Frame timing logging does not capture eye images.
