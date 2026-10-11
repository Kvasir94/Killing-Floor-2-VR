"""Deadbolt trader/selector icon (run inside Blender 5.2 after export_deadbolt.py):

    blender --background --factory-startup --python tools/deadbolt/make_icon.py

Renders the exported gauntlet, its glow and its spike in the spike's launch position as a flat
white silhouette on transparent, 256x128 RGBA TARGA: the same recipe as VRTomahawkIcon.tga
(tools/raven7_rig.py), which build-hand-assets.ps1 and VRHandAssetCommandlet import as a
TEXTUREGROUP_UI texture. Barrel to the image right, forearm to the left.

Writes build/hand-meshes/VRDeadboltIcon.tga.
"""
import json, math, os
import bpy
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MESHES = os.path.join(ROOT, "build", "hand-meshes")
OUT = os.path.join(MESHES, "VRDeadboltIcon.tga")
SIZE = (256, 128)


def load(name):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=os.path.join(MESHES, name), axis_forward='-X', axis_up='Z')
    return [o for o in bpy.data.objects if o not in before and o.type == 'MESH']


def white():
    mat = bpy.data.materials.new('Deadbolt icon white')
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    nodes.clear()
    out = nodes.new('ShaderNodeOutputMaterial')
    emit = nodes.new('ShaderNodeEmission')
    emit.inputs[1].default_value = 1.0
    mat.node_tree.links.new(emit.outputs[0], out.inputs[0])
    return mat


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    report = json.load(open(os.path.join(MESHES, "VRDeadbolt.json")))
    meshes = load("VRDeadbolt.fbx")
    spike = load("VRDeadboltSpike.fbx")
    if not meshes or not spike:
        raise SystemExit("Deadbolt FBX files are missing or empty")
    # The spike's origin is its base on the bore axis; seat it at the launch socket.
    # FBX import turns centimetres into metres, so the socket is placed in metres too.
    socket = Vector(report["spike_socket_cm"]) * 0.01
    for o in spike:
        o.parent = None
        o.location = socket
    mat = white()
    for o in meshes + spike:
        o.data.materials.clear()
        o.data.materials.append(mat)
    bpy.context.view_layer.update()
    corners = [o.matrix_world @ Vector(c) for o in meshes + spike for c in o.bound_box]
    lo = Vector([min(c[i] for c in corners) for i in range(3)])
    hi = Vector([max(c[i] for c in corners) for i in range(3)])
    centre = (lo + hi) / 2
    scene = bpy.context.scene
    cam = bpy.data.objects.new('Icon camera', bpy.data.cameras.new('Icon camera'))
    scene.collection.objects.link(cam)
    cam.data.type = 'ORTHO'
    # Side view from -Y: +X (fingers, barrel) is image right, +Z up. Fit the 2:1 frame with margin.
    cam.data.ortho_scale = max(hi.x - lo.x, (hi.z - lo.z) * 2) * 1.12
    cam.location = (centre.x, lo.y - 50, centre.z)
    cam.rotation_euler = (math.radians(90), 0, 0)
    scene.camera = cam
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = 16
    scene.render.film_transparent = True
    scene.render.resolution_x, scene.render.resolution_y = SIZE
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'TARGA'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.view_settings.view_transform = 'Standard'
    scene.render.filepath = OUT
    bpy.ops.render.render(write_still=True)
    print("DEADBOLT_ICON", OUT, "bounds_m", tuple(lo), tuple(hi))


main()
