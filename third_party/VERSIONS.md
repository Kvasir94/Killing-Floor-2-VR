# Dependency pins

Place SDK checkouts under third_party/; they are fetched separately and retain
upstream licences. The adapter uses OpenXR. OpenVR is optional for xrprobe.

| Component | Pin | Upstream |
| --- | --- | --- |
| OpenXR-SDK | release-1.1.63, f2448a8 | https://github.com/KhronosGroup/OpenXR-SDK |
| OpenVR | v2.15.6, 0924064 | https://github.com/ValveSoftware/openvr |
| CPython portable player runtime | 3.14.3; archive SHA-256 in tools/dependency-pins.json | https://www.python.org/ |

The build uses OpenXR-SDK with pre-generated headers, not OpenXR-SDK-Source.
MinHook source hashes follow. These are the private build's pins, not a claim
that all excluded dependency inputs can be fetched by this export automatically.
See [BUILDING](../docs/BUILDING.md) for limitations.

## MinHook source pin

`third_party/minhook/` was copied with `LICENSE.txt` from
a private KF1-VR development snapshot. At verification, the KF1 repository HEAD was
`8f33f4c42054068f2a63c20f85e90da273f8e870`, with no changes reported for that
directory. Every file below is byte-identical to the KF1 source copy. Upstream
project: [TsudaKageyu/minhook](https://github.com/TsudaKageyu/minhook).

This is pinned as a KF1 source snapshot, not an asserted upstream tag: the
vendored README lists v1.3.4 while its CMake metadata declares 1.3.3. The
adapter's CMake directly compiles the four x64 C sources, rather than invoking
the vendored CMake project. These SHA256s pin its x64 sources, included headers,
license and version/provenance files:

| Relative file | SHA256 |
|---|---|
| `LICENSE.txt` | `4f21f857550d7be854da6ea5f2da4e6775ca4e3fbb535e4f3d961c47d0bf3335` |
| `README.md` | `a53a4607b65f528c48332dd82117cdd7d4edc7a9afc74b6a25406784c0c05f8a` |
| `CMakeLists.txt` | `a04559ecf74dec745ef8c75f2b1d977e7e23bb6e08390035122511b382776a5d` |
| `include/MinHook.h` | `d5cf8db333895134398c7f69bac43f232835fda1cccbd86875c654cd69989b23` |
| `src/buffer.c` | `e6ec0912f8b017f4d3108d5a50ec972dd4f6991edb9aae5b5748c16f2713db64` |
| `src/buffer.h` | `175ec5496c020509cf4c7670322b51b5bcd5b63a345bfefc4a19b43675857fa7` |
| `src/hook.c` | `c6eec4f8dc5fb6513347c3f44fbdb25ca0bba7a2bcbe141d238c7da97094cd9d` |
| `src/trampoline.c` | `58ae2dcc65317983535963654bb10a4398dae4a90da08af1007ab1dcf0db82a9` |
| `src/trampoline.h` | `c93c66f8db04561f3345835f1185451f61043c1549e33425d87af86448580379` |
| `src/hde/hde64.c` | `a49af94bad8e43242828a08e5f9f2182a9acd4f8dbc6846847a296f796975512` |
| `src/hde/hde64.h` | `ffee8c552a9010cadd3b3bc07c0f82e9b5b681b13982fb559a227bf287009fc9` |
| `src/hde/pstdint.h` | `975488009779ea99c7e04b83a160397d5cd7195cb5bf6ad79180805f756c7d00` |
| `src/hde/table64.h` | `769ffac902895554ae0709686a94688204cc7dd975504f71d1ba58a17485d716` |

Retain the supplied MinHook and bundled HDE copyright/license notices. The curated public export
includes these pinned source files and their licence. Verify their hashes above;
an upstream tag with a similar version label does not establish identical bytes.
A mismatch requires a reviewed dependency update.
