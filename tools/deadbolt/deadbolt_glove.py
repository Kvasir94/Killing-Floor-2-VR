# Display glove for the Deadbolt renders: the runtime right hand, fingers relaxed toward the concept's
# open pose, baked to a static mesh in the weapon frame (wrist at origin, forearm -> +X, back of hand -> +Z,
# thumb -> +Y). Display only; the weapon itself does not depend on it.
import os
import bpy, bmesh
from mathutils import Matrix

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HANDS_FBX = os.path.join(ROOT, "build", "hand-meshes", "VRFloatingHands.fbx")   # tools/build-hand-assets.ps1
COLL = "DB_Hand"

# (finger, target curl at knuckle 1, knuckle 2) in radians; knuckle 3 follows knuckle 2 at 70 %
CURL = [("Index", 0.18, 0.22), ("Middle", 0.20, 0.25), ("Ring", 0.24, 0.30), ("Pinky", 0.30, 0.35)]

def build_glove():
    old = bpy.data.objects.get("DB_Glove")
    if old:
        return old
    coll = bpy.data.collections.get(COLL) or bpy.data.collections.new(COLL)
    if coll.name not in bpy.context.scene.collection.children:
        bpy.context.scene.collection.children.link(coll)
    before = set(bpy.data.objects)
    bpy.context.view_layer.active_layer_collection = bpy.context.view_layer.layer_collection.children[coll.name]
    bpy.ops.import_scene.fbx(filepath=HANDS_FBX)
    new = [o for o in bpy.data.objects if o not in before]
    arm = next(o for o in new if o.type == 'ARMATURE')
    src = next(o for o in new if o.type == 'MESH')
    M = arm.matrix_world

    def H(n):
        return M @ arm.pose.bones[n].head

    def rot_bone(n, axis_w, ang, pivot_w):
        pb = arm.pose.bones[n]
        Mi = M.inverted()
        piv = Mi @ pivot_w
        R = Matrix.Rotation(ang, 4, (Mi.to_3x3() @ axis_w).normalized())
        pb.matrix = Matrix.Translation(piv) @ R @ Matrix.Translation(-piv) @ pb.matrix
        bpy.context.view_layer.update()

    # straighten the wrist most of the way onto the forearm line
    fa = (H("RightHand_1stP") - H("RightForeArm_1stP")).normalized()
    hv = (H("RightHandMiddle1_1stP") - H("RightHand_1stP")).normalized()
    rot_bone("RightHand_1stP", hv.cross(fa), hv.angle(fa)*0.85, H("RightHand_1stP"))
    # open the grip to a relaxed curl
    for F, t1, t2 in CURL:
        b = [f"RightHand{F}{i}_1stP" for i in (1, 2, 3)]
        p = H(b[0]) - H("RightHand_1stP"); s = H(b[1]) - H(b[0])
        rot_bone(b[0], s.cross(p), p.angle(s) - t1, H(b[0]))
        p = H(b[1]) - H(b[0]); s = H(b[2]) - H(b[1]); a2 = p.angle(s); ax = s.cross(p)
        rot_bone(b[1], ax, a2 - t2, H(b[1]))
        rot_bone(b[2], ax, (a2 - t2)*0.7, H(b[2]))

    # bake the posed right hand into the weapon frame
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(src.evaluated_get(dg), depsgraph=dg)
    me.transform(src.matrix_world)
    bm = bmesh.new(); bm.from_mesh(me)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.x > 0], context='VERTS')   # left hand lives at +X
    w = H("RightHand_1stP")
    X = (w - H("RightForeArm_1stP")).normalized()
    Z = X.cross((H("RightHandIndex1_1stP") - H("RightHandPinky1_1stP")).normalized()).normalized()
    Y = Z.cross(X)
    bm.transform(Matrix((X, Y, Z)).to_4x4() @ Matrix.Translation(-w))
    bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new("DB_Glove", me)
    coll.objects.link(ob)
    for o in new:
        bpy.data.objects.remove(o, do_unlink=True)
    return ob
