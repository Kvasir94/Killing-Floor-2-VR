# Gore chunk spike scripts (parked 2026-11-10)

Kvasir94 parked authoring new gore chunks. These are the working scripts from that
spike, kept as they ran so the work can resume without redoing it. They take a
scratch folder as their first argument and expect files made by the earlier steps.
Method and findings: docs/re/ZED_GORE_MESH_ALT_WEIGHTS.md.

| Script | What it does | State |
|---|---|---|
| `sockets.py` | Reads SkeletalMeshSocket properties (bone, offset, rotation, scale) from a package | works |
| `smesh.py` | Reads KF2 static meshes (positions, UVs, triangles); UModel can't | works |
| `living.py` | Blender: rebuilds the stock Clot gore mesh in stock vertex order on the PSK rig, with stock textures and the gore pieces on their sockets | works |
| `brk_living.py` | Blender: applies stock breaks to that scene, poses and renders | works |
| `chest_states.py` | Blender: renders the chest chunk states (intact, chunk, slice, both) | works |
| `export_fbx.py` | Blender: exports the chunk mesh as FBX plus the per-vertex sidecar for the weight patcher | exported once, never imported |
| `../import-gore-mesh.ps1`, `../editor-script` | Imports that FBX with the pinned SDK through the Engineer save bridge | never run (fixture was busy) |
| `../patch_altweights.py` | Writes the alternate weights into the saved package | never run |
| `../build_chest_chunk_v5.py` | The chest chunk look Kvasir94 preferred | works, +39% vertices |
| `../build_chest_chunk.py` | Lean chest chunk (+2% vertices) | works |
