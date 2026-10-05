# RAVEN-7 material source

The current material-atlas-v2.png is an original AI-generated bitmap material
atlas. The image
contains four flat cloth/metal surface tiles, with no extracted game texture.
SHA-256: D6CEAD3AEBF5378E229C0602C60DB73AA1699A94AA2CE933BE3EB51E1F926BD1.

The current atlas is included in the public source export as an original
KF2-VR asset inputs. tools/raven7_model.py extracts its tiles and generates
diffuse/normal/specular textures under ignored build/hand-meshes/. Geometry is
authored by the RAVEN-7 model tools; the atlas is not a model render. Rig/grip
building also requires the floating-hand source skin described in docs/BUILDING.md.

Version 1 remains preserved in the private workspace as a legacy asset and is
not required by the current build or included in the curated public export.
