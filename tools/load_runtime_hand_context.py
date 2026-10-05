"""Read the production FBX's actual left-hand surface in the left authoring frame."""
import bpy
from mathutils import Matrix,Vector

def load_left_hand(path,scene):
    bpy.context.window.scene=scene;before=set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=str(path),use_custom_normals=True)
    imported=[o for o in bpy.data.objects if o not in before]
    rig=next(o for o in imported if o.type=='ARMATURE')
    bones={b.name:rig.matrix_world@b.head_local for b in rig.data.bones}
    origin=bones['LeftHand_1stP']
    f=(bones['LeftHandMiddle1_1stP']-origin).normalized()
    t=bones['LeftHandIndex1_1stP']-bones['LeftHandPinky1_1stP'];t=(t-f*t.dot(f)).normalized()
    d=-f.cross(t).normalized();frame=Matrix((f,-t,d))
    # FBX import already converts to the active scene's units.
    scale=scene.unit_settings.scale_length/.01
    vertices=[];faces=[];uvs=[];normals=[]
    for ob in imported:
        if ob.type!='MESH':continue
        me=ob.data;groups={g.index:g.name for g in ob.vertex_groups}
        left={v.index for v in me.vertices if v.groups and groups[max(v.groups,key=lambda x:x.weight).group].startswith('Left')}
        remap={};uv=me.uv_layers.active
        normal_matrix=frame@ob.matrix_world.to_3x3().inverted().transposed()
        for p in me.polygons:
            if not all(i in left for i in p.vertices):continue
            ids=[]
            for li in p.loop_indices:
                vi=me.loops[li].vertex_index
                if vi not in remap:
                    remap[vi]=len(vertices);vertices.append((frame@(ob.matrix_world@me.vertices[vi].co-origin))*scale)
                ids.append(remap[vi]);uvs.append(uv.data[li].uv.copy())
                normals.append((normal_matrix@me.corner_normals[li].vector).normalized())
            faces.append(ids)
    mesh=bpy.data.meshes.new('Production left hand, original UVs');mesh.from_pydata(vertices,[],faces);mesh.update()
    uv=mesh.uv_layers.new(name='RuntimeUV')
    for value,co in zip(uv.data,uvs):value.uv=co
    for p in mesh.polygons:p.use_smooth=True
    mesh.normals_split_custom_set(normals)
    hand=bpy.data.objects.new('Runtime hand from production FBX',mesh);scene.collection.objects.link(hand)
    for o in imported:bpy.data.objects.remove(o,do_unlink=True)
    mesh.calc_loop_triangles()
    return hand,{'left_triangles':len(mesh.loop_triangles),'left_vertices':len(mesh.vertices),
                 'authoring_frame_determinant':frame.determinant(),'source_fbx':str(path)}
