"""Repack existing hand UV islands; preserve geometry, skeleton and weights."""
import bpy, runpy, struct, hashlib
from mathutils import Vector, Matrix
from mathutils.kdtree import KDTree


def repack(hand, baseline, output, root, layout=None):
    g=runpy.run_path(str(root/'tools/generate_floating_hands.py'),run_name='asset_source')
    chunks=g['read_psk'](baseline/'VRFloatingHands.psk')
    # Retain UV coverage for tiny source triangles omitted by Blender's FBX
    # importer. The PSK's geometry is kept byte-identical on re-export.
    initial_uv=hand.data.uv_layers['RuntimeUV'];uvtree=KDTree(len(initial_uv.data))
    for i,value in enumerate(initial_uv.data):uvtree.insert(Vector((*value.uv,0)),i)
    uvtree.balance();points,wedges,faces,weights=g['decode_geometry'](chunks)
    bones,names=g['bone_data'](chunks);bind=g['bind_positions'](bones);origin=bind[names.index('LeftHand_1stP')]
    f=(bind[names.index('LeftHandMiddle1_1stP')]-origin).normalized()
    t=bind[names.index('LeftHandIndex1_1stP')]-bind[names.index('LeftHandPinky1_1stP')];t=(t-f*t.dot(f)).normalized()
    frame=Matrix((f,-t,-f.cross(t).normalized()))
    extras=[]
    for face in faces:
        if not names[max(weights[wedges[face[0]][0]],key=weights[wedges[face[0]][0]].get)].startswith('Left'):continue
        if any(uvtree.find(Vector((wedges[i][1],1-wedges[i][2],0)))[2]>.00001 for i in face[:3]):extras.append(face)
    if extras:
        vertices=[v.co.copy() for v in hand.data.vertices];polys=[list(p.vertices) for p in hand.data.polygons]
        texcoords=[v.uv.copy() for v in initial_uv.data];normals=[n.vector.copy() for n in hand.data.corner_normals]
        spatial=KDTree(len(hand.data.vertices))
        for v in hand.data.vertices:spatial.insert(v.co,v.index)
        spatial.balance()
        for face in extras:
            ids=[]
            # Original left PSK uses clockwise triangles in the stock frame.
            for wi in reversed(face[:3]):
                wedge=wedges[wi];co=frame@(Vector(points[wedge[0]])-origin)
                ids.append(len(vertices));vertices.append(co);texcoords.append(Vector((wedge[1],1-wedge[2])))
                _,near,_=spatial.find(co);normals.append(hand.data.vertices[near].normal.copy())
            polys.append(ids)
        mesh=bpy.data.meshes.new('Production hand plus omitted source UV coverage');mesh.from_pydata(vertices,[],polys);mesh.update()
        uv=mesh.uv_layers.new(name='RuntimeUV')
        for value,co in zip(uv.data,texcoords):value.uv=co
        for p in mesh.polygons:p.use_smooth=True
        mesh.normals_split_custom_set(normals);hand.data=mesh
    uv=hand.data.uv_layers['RuntimeUV'];old=[v.uv.copy() for v in uv.data]
    bpy.ops.object.select_all(action='DESELECT');hand.select_set(True);bpy.context.view_layer.objects.active=hand
    hand.data.uv_layers.active=uv;uv.active_render=True
    if layout is None:
        bpy.ops.object.mode_set(mode='EDIT');bpy.ops.mesh.select_all(action='SELECT');bpy.ops.uv.select_all(action='SELECT')
        bpy.ops.uv.average_islands_scale()
        bpy.ops.uv.pack_islands(rotate=True,rotate_method='CARDINAL',scale=True,margin_method='FRACTION',margin=.0015)
        bpy.ops.object.mode_set(mode='OBJECT')
    # Edit-mode rebuilds the mesh CustomData. Reacquire the UV-layer handle.
    uv=hand.data.uv_layers['RuntimeUV']
    if layout is not None:
        packed=layout.data.uv_layers['RuntimeUV']
        assert len(packed.data)==len(uv.data),(len(packed.data),len(uv.data))
        for value,source in zip(uv.data,packed.data):value.uv=source.uv
    tree=KDTree(len(old))
    for i,p in enumerate(old):tree.insert(Vector((p.x,p.y,0)),i)
    tree.balance()
    preserved={k:hashlib.sha256(b''.join(c.rows)).hexdigest() for k,c in chunks.items() if k!='VTXW0000'}
    rows=[];maximum=0;missing=[]
    for wedge_index,row in enumerate(chunks['VTXW0000'].rows):
        point,u,v,material,reserved1,reserved2=g['WEDGE'].unpack(row)
        _,index,distance=tree.find(Vector((u,1-v,0)));maximum=max(maximum,distance)
        if distance>=.00001:missing.append(wedge_index)
        mapped=uv.data[index].uv
        rows.append(g['WEDGE'].pack(point,mapped.x,1-mapped.y,material,reserved1,reserved2))
    source_points=[Vector(struct.unpack('<3f',row)) for row in chunks['PNTS0000'].rows]
    wedges=[g['WEDGE'].unpack(row) for row in chunks['VTXW0000'].rows]
    affected=[]
    for face_index,row in enumerate(chunks['FACE0000'].rows):
        face=g['FACE'].unpack(row)
        if not set(face[:3]).intersection(missing):continue
        a,b,c=(source_points[wedges[i][0]] for i in face[:3])
        affected.append({'face':face_index,'area_cm2':(b-a).cross(c-a).length*.5})
    assert not missing,(maximum,affected)
    chunks['VTXW0000'].rows=rows
    psk=output/'VRFloatingHands.psk';psk.write_bytes(b''.join(c.encode() for c in chunks.values()))
    check=g['read_psk'](psk)
    assert preserved=={k:hashlib.sha256(b''.join(c.rows)).hexdigest() for k,c in check.items() if k!='VTXW0000'}
    export=g['export_fbx'](psk,output/'VRFloatingHands.fbx')
    return {'uv_changed':True,'non_uv_psk_chunks_preserved':preserved,'source_uv_match_error':maximum,
            'source_uv_coverage_faces_added_to_bake_target':len(extras),**export}
