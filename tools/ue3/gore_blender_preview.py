"""
Rebuild a stock KF2 gore mesh in Blender from gore_altweights.py --geometry output
(stock vertex order, so the alternate weights line up), apply the alternate
weights of the named breaks, pose them, and render a check image.

    blender -b --python tools/ue3/gore_blender_preview.py -- <gore.json> <umodel.gltf> \
        <out.png> <Break[,Break...]|none> [--save file.blend]

The glTF (UModel export of the same mesh) supplies only the armature.
Breaks named Gore_* are shrunk like stock HideBoneByName; others are pulled away.
Docs: docs/re/ZED_GORE_MESH_ALT_WEIGHTS.md.
"""
import bpy, json, math, sys, mathutils

argv = sys.argv[sys.argv.index('--') + 1:]
data_path, gltf_path, out_png, breaks = argv[:4]
breaks = [b for b in breaks.split(',') if b != 'none']
save = argv[argv.index('--save') + 1] if '--save' in argv else None
D = json.load(open(data_path))

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=gltf_path)
arm = next(o for o in bpy.context.scene.objects if o.type == 'ARMATURE')
for o in [o for o in bpy.context.scene.objects if o.type == 'MESH']:
    bpy.data.objects.remove(o)

# Stock axes (cm) -> Blender metres as the glTF importer places the armature.
verts = [(p[0] / 100, -p[1] / 100, p[2] / 100) for p in D['positions_cm']]
me = bpy.data.meshes.new(D['mesh']); me.from_pydata(verts, [], D['triangles']); me.update()
ob = bpy.data.objects.new(D['mesh'], me); bpy.context.scene.collection.objects.link(ob)


def mat(name, col):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = col; b.inputs['Roughness'].default_value = 0.55
    return m


me.materials.append(mat('skin', (0.62, 0.6, 0.58, 1)))
me.materials.append(mat('meat', (0.7, 0.03, 0.02, 1)))
meat_base = D['chunks'][-1]['base'] if len(D['chunks']) > 1 else len(verts)
for p in me.polygons:
    p.material_index = 1 if p.vertices[0] >= meat_base else 0
    p.use_smooth = True

groups = {}
def group(n):
    if n not in groups: groups[n] = ob.vertex_groups.new(name=str(n))
    return groups[n]

for v, inf in enumerate(D['base_weights']):
    for n, w in inf: group(n).add([v], w / 255, 'ADD')
for b in breaks:
    for v, inf in D['joints'][b]['alt'].items():
        v = int(v)
        for g in ob.vertex_groups: g.remove([v])
        for n, w in inf: group(n).add([v], w / 255, 'REPLACE')
ob.modifiers.new('arm', 'ARMATURE').object = arm

bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode='POSE')
for b in breaks:
    pb = arm.pose.bones[b]
    if b.lower().startswith('gore'): pb.scale = (0.001,) * 3
    else: pb.location = (0, 0.12, 0.04)
bpy.ops.object.mode_set(mode='OBJECT'); bpy.context.view_layer.update()

focus = 'head' if not breaks or any(b.lower().startswith('gore') or b in ('head', 'neck') for b in breaks) else breaks[0]
tgt = arm.matrix_world @ arm.pose.bones[focus].head
sc = bpy.context.scene; sc.render.engine = 'BLENDER_EEVEE'
sc.render.resolution_x = sc.render.resolution_y = 700
w = bpy.data.worlds.new('w'); sc.world = w; w.use_nodes = True
w.node_tree.nodes['Background'].inputs[0].default_value = (0.1, 0.1, 0.11, 1)
cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
d = mathutils.Vector((math.sin(math.radians(20)), -math.cos(math.radians(20)), 0.3)).normalized()
cam.location = tgt + d * (0.75 if focus == 'head' else 1.2)
cam.rotation_euler = (-d).to_track_quat('-Z', 'Y').to_euler()
sun = bpy.data.objects.new('key', bpy.data.lights.new('key', 'SUN')); sun.data.energy = 3.5
sc.collection.objects.link(sun); sun.rotation_euler = cam.rotation_euler
sc.render.filepath = out_png; bpy.ops.render.render(write_still=True)
if save:
    bpy.ops.wm.save_as_mainfile(filepath=save)
