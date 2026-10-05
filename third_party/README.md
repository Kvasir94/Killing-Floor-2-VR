# Third-party dependencies

SDKs are fetched locally under this directory. The public source export also
includes the small pinned MinHook/HDE source snapshot and upstream licence.
See [VERSIONS](VERSIONS.md) for the exact pins and hashes. Preserve upstream
licences when building or redistributing any independently cleared component.

- OpenXR-SDK supplies the headers and loader used by the adapter.
- MinHook/HDE supplies native function hooks; verify the recorded source hashes.
- OpenVR is optional for xrprobe, not the game adapter backend.
- Ghidra, a JDK and RenderDoc are optional investigation tools, not player prerequisites.
- Python is required for tooling; playable packages carry their pinned runtime.

The public source export contains no upstream SDK checkout or compiled runtime.
See [BUILDING](../docs/BUILDING.md) and [PROVENANCE](../docs/PROVENANCE.md).
