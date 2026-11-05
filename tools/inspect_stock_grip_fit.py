"""Offline stock Idle grip geometry on the current floating-hand asset.

Run with Blender --background --python tools/inspect_stock_grip_fit.py --
--output build/grip-fit-inspection. Reads existing PSK/PSA exports and renders
isolated scenes; never loads the game, changes installed assets or edits a
running Blender session. Surface intersections are measurements, not headset
acceptance. ActorX's reflected Y is retained consistently throughout.
"""
from pathlib import Path
import argparse
import json
import math
import struct
import sys
from collections import Counter

import bpy
from mathutils import Matrix, Quaternion, Vector
from mathutils.bvhtree import BVHTree

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'tools'), str(ROOT / 'tools/re')]
from generate_floating_hands import Chunk, SUPPORTED, decode_geometry
from audit_flamethrower_assets import chunks, parse_bones, INFO, KEY, ctext

HAND = ROOT / 'build/watch-detail-20260924/72/runtime/VRFloatingHands.psk'
EXPORT = ROOT / 'build/grip-fit-inspection/export'
WEAPONS = {
    'SCAR': (ROOT/'build/scar-audit/export/WEP_1P_SCAR_MESH/SkeletalMesh3/Wep_1stP_SCAR_Rig.psk', EXPORT/'WEP_1P_SCAR_ANIM/AnimSet/Wep_1stP_SCAR_Anim.psa'),
    'AK12': (EXPORT/'WEP_1P_AK12_MESH/SkeletalMesh3/Wep_1stP_AK12_Rig.psk', EXPORT/'WEP_1P_AK12_ANIM/AnimSet/Wep_1st_AK12_Anim.psa'),
    'MKB42': (ROOT/'build/mkb42-audit/export/WEP_1P_MKB42_MESH/SkeletalMesh3/Wep_1stP_MKB42_Rig.psk', EXPORT/'WEP_1P_MKB42_ANIM/AnimSet/wep_1p_mkb42_anim.psa'),
    'M16': (ROOT/'build/m16m203-audit/export/WEP_1P_M16_M203_MESH/SkeletalMesh3/Wep_1stP_M16_M203_Rig.psk', ROOT/'build/m16m203-audit/export/WEP_1P_M16_M203_ANIM/AnimSet/Wep_1stP_M16_M203_Anim.psa'),
    'Sentinel': (ROOT/'build/autoturret-audit/export/Wep_1P_AutoTurret_MESH/SkeletalMesh3/Wep_1stP_AutoTurret_Rig.psk', ROOT/'build/autoturret-audit/export/Wep_1P_AutoTurret_ANIM/AnimSet/wep_1p_autoturret_anim.psa'),
}


def quat(values):
    x, y, z, w = values
    return Quaternion((w, x, y, z))


def pose(bones, tracks=None, reference_translation=False):
    positions, rotations = [], []
    for i, b in enumerate(bones):
        track = tracks.get(b['name']) if tracks else None
        p = Vector(b['local_position'] if not track or reference_translation else track[:3])
        q = quat(track[3:7] if track else b['local_quaternion'])
        if i:
            parent = b['parent_index']
            p = positions[parent] + rotations[parent] @ p
            q = rotations[parent] @ q.conjugated()
        positions.append(p)
        rotations.append(q)
    return positions, rotations


def geometry(path):
    source = chunks(path)
    # Read-only geometry analysis does not consume or rewrite optional UV sets.
    raw = {name: Chunk(name, 0, size, [data[i:i+size] for i in range(0,len(data),size)] if size else [])
           for name,(size,count,data) in source.items() if name in SUPPORTED}
    points, wedges, faces, weights = decode_geometry(raw)
    bones = parse_bones(source['REFSKELT'])
    return dict(points=points, faces=[tuple(wedges[w][0] for w in f[:3]) for f in faces],
                weights=weights, bones=bones, names=[b['name'] for b in bones])


def idle_tracks(path):
    raw = chunks(path)
    names = [b['name'] for b in parse_bones(raw['BONENAMES'])]
    info = next(i for i in INFO.iter_unpack(raw['ANIMINFO'][2]) if ctext(i[0]) == 'Idle')
    return {name: KEY.unpack_from(raw['ANIMKEYS'][2], (info[10] * info[2] + i) * KEY.size)
            for i, name in enumerate(names)}


def skin(mesh, target):
    rest_p, rest_q = pose(mesh['bones'])
    target_p, target_q = target
    result = []
    for p, weights in zip(mesh['points'], mesh['weights']):
        point = Vector(p)
        result.append(sum(((target_p[b] + target_q[b] @ (rest_q[b].inverted() @ (point-rest_p[b]))) * w
                           for b, w in weights.items()), Vector()))
    return result


def selected_faces(mesh, predicate):
    keep = {i for i, ws in enumerate(mesh['weights'])
            if predicate(mesh['names'][max(ws, key=ws.get)])}
    return [f for f in mesh['faces'] if all(i in keep for i in f)]


def wrist_basis(hand, side):
    p,q=pose(hand['bones'])
    i=hand['names'].index(side+'Hand_1stP')
    f=(p[hand['names'].index(side+'HandMiddle1_1stP')]-p[i]).normalized()
    t=p[hand['names'].index(side+'HandIndex1_1stP')]-p[hand['names'].index(side+'HandPinky1_1stP')]
    t=(t-f*t.dot(f)).normalized()
    align=f.rotation_difference(Vector((1,0,0)))
    return (align@t).rotation_difference(Vector((0,0,1)))@align@q[i]


def material(name, rgba):
    m = bpy.data.materials.new(name)
    m.diffuse_color = rgba
    return m


def object_mesh(scene, name, points, faces, mat):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(points, [], faces)
    mesh.update()
    ob = bpy.data.objects.new(name, mesh)
    scene.collection.objects.link(ob)
    ob.data.materials.append(mat)
    return ob


def mirrored_support(name,hand,output,degrees):
    """Measure the opposite anatomy with the production role-pose reflection."""
    weapon=geometry(WEAPONS[name][0])
    tracks=idle_tracks(WEAPONS[name][1])
    wp,wq=pose(weapon['bones'],tracks)
    hp,hq=pose(hand['bones'],tracks,reference_translation=True)
    rp,rq=pose(hand['bones'])
    li=hand['names'].index('LeftHand_1stP')
    ri=hand['names'].index('RightHand_1stP')
    lb,rb=wrist_basis(hand,'Left'),wrist_basis(hand,'Right')
    def mirror(q):
        return Quaternion((q.w,-q.x,q.y,-q.z))
    for digit in ('Thumb','Index','Middle','Ring','Pinky'):
        for joint in range(1,4):
            left=hand['names'].index(f'LeftHand{digit}{joint}_1stP')
            right=hand['names'].index(f'RightHand{digit}{joint}_1stP')
            parent=hand['bones'][right]['parent_index']
            source=lb@hq[li].inverted()@hq[left]
            reference=lb@rq[li].inverted()@rq[left]
            delta=mirror(source@reference.inverted())
            target=rb.inverted()@delta@rb@rq[ri].inverted()@rq[right]
            hp[right]=hp[parent]+hq[parent]@(rq[parent].inverted()@(rp[right]-rp[parent]))
            hq[right]=hq[ri]@target
    root=weapon['names'].index('RW_Weapon')
    left=weapon['names'].index('LeftHand_1stP')
    inv=wq[root].inverted()
    wrist=inv@(wp[left]-wp[root])
    wrist.y=-wrist.y
    target=mirror(inv@wq[left]@lb.inverted())@rb
    correction=target@hq[ri].inverted()
    points=[wrist+correction@(p-hp[ri]) for p in skin(hand,(hp,hq))]
    faces=selected_faces(hand,lambda n:n.startswith('Right'))
    middle=hand['names'].index('RightHandMiddle1_1stP')
    index=hand['names'].index('RightHandIndex1_1stP')
    pinky=hand['names'].index('RightHandPinky1_1stP')
    pivot=wrist+correction@(hp[middle]-hp[ri])
    forward=(pivot-wrist).normalized()
    thumb=correction@(hp[index]-hp[pinky])
    thumb=(thumb-forward*thumb.dot(forward)).normalized()
    swing=Quaternion(thumb,math.radians(degrees))
    moved=[pivot+swing@(p-pivot) for p in points]
    weapon_points=[inv@(p-wp[root]) for p in skin(weapon,(wp,wq))]
    weapon_faces=selected_faces(weapon,lambda n:n.startswith('RW_'))
    tree=BVHTree.FromPolygons(weapon_points,weapon_faces,all_triangles=True)
    cuff=[i for i,f in enumerate(faces) if sum((points[v]-wrist).dot(forward) for v in f)/3<-2]
    rows={}
    for state,positions in (('before',points),('after',moved)):
        hits=BVHTree.FromPolygons(positions,faces,all_triangles=True).overlap(tree)
        cuff_hits=[(a,b) for a,b in hits if a in cuff]
        probes=[positions[v] for i in cuff for v in faces[i]]
        probes += [sum((positions[v] for v in faces[i]),Vector())/3 for i in cuff]
        rows[state]=dict(cuff_crossings=len(cuff_hits),cuff_faces=len(cuff),
                         sampled_clearance_cm=min((tree.find_nearest(p)[3] for p in probes),default=None))
    scene=bpy.data.scenes.new('Mirrored support '+name)
    scene.render.engine='BLENDER_WORKBENCH'
    scene.display.shading.light='STUDIO'
    scene.display.shading.color_type='MATERIAL'
    scene.display.shading.show_cavity=True
    scene.world=bpy.data.worlds.new('Mirrored backdrop '+name)
    scene.world.color=(0.08,0.08,0.08)
    object_mesh(scene,'Mirrored weapon '+name,weapon_points,weapon_faces,material('Mirrored gun '+name,(0.25,0.29,0.32,1)))
    before=object_mesh(scene,'Mirrored before '+name,points,faces,material('Mirrored blue '+name,(0.14,0.44,0.66,1)))
    after=object_mesh(scene,'Mirrored after '+name,moved,faces,before.data.materials[0])
    data=bpy.data.cameras.new('Mirrored camera '+name)
    camera=bpy.data.objects.new(data.name,data)
    scene.collection.objects.link(camera)
    scene.camera=camera
    data.type='ORTHO'
    data.ortho_scale=38
    scene.render.resolution_x=1100
    scene.render.resolution_y=800
    scene.render.resolution_percentage=100
    for view,offset in (('',(-22,-36,22)),('-opposite',(22,36,22))):
        camera.location=wrist+Vector(offset)
        camera.rotation_euler=(wrist-camera.location).to_track_quat('-Z','Y').to_euler()
        for state in ('before','after'):
            before.hide_render=state!='before'
            after.hide_render=state!='after'
            scene.render.filepath=str(output/f'{name}-RightSupport-{state}{view}.png')
            bpy.ops.render.render(write_still=True,scene=scene.name)
    return dict(degrees=degrees,pivot=list(pivot),**rows)


def inspect(name, hand, output):
    mesh_path, anim_path = WEAPONS[name]
    weapon = geometry(mesh_path)
    tracks = idle_tracks(anim_path)
    wp, wq = pose(weapon['bones'], tracks)
    root = weapon['names'].index('RW_Weapon')
    inv = wq[root].inverted()
    weapon_points = [inv @ (p-wp[root]) for p in skin(weapon, (wp, wq))]
    weapon_faces = selected_faces(weapon, lambda n: n.startswith('RW_'))
    weapon_tree = BVHTree.FromPolygons(weapon_points, weapon_faces, all_triangles=True)
    hp, hq = pose(hand['bones'], tracks, reference_translation=True)
    hand_points = skin(hand, (hp, hq))
    scene = bpy.data.scenes.new('Offline grip fit '+name)
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'
    scene.display.shading.color_type = 'MATERIAL'
    scene.display.shading.show_shadows = True
    scene.display.shading.show_cavity = True
    scene.world = bpy.data.worlds.new('Grip backdrop '+name)
    scene.world.color = (0.08, 0.08, 0.08)
    object_mesh(scene, name+' weapon', weapon_points, weapon_faces, material('Gun '+name, (0.25,0.29,0.32,1)))
    result = dict(mesh=str(mesh_path), animation=str(anim_path), hands={})
    for side in ('Left', 'Right'):
        wrist_name = side+'Hand_1stP'
        hi = hand['names'].index(wrist_name)
        wi = weapon['names'].index(wrist_name)
        correction = inv @ wq[wi] @ hq[hi].inverted()
        wrist = inv @ (wp[wi]-wp[root])
        points = [wrist + correction @ (p-hp[hi]) for p in hand_points]
        faces = selected_faces(hand, lambda n: n.startswith(side))
        hand_tree = BVHTree.FromPolygons(points, faces, all_triangles=True)
        hits = hand_tree.overlap(weapon_tree)
        middle = hand['names'].index(side+'HandMiddle1_1stP')
        forward = (correction @ (hp[middle]-hp[hi])).normalized()
        cuff_hits = [(a,b) for a,b in hits if sum((points[v]-wrist).dot(forward) for v in faces[a])/3 < -2]
        hit_faces = [faces[i] for i in sorted({a for a,b in cuff_hits})]
        candidates = []
        if side == 'Left' and name in ('SCAR', 'AK12', 'MKB42', 'M16'):
            index=hand['names'].index(side+'HandIndex1_1stP')
            pinky=hand['names'].index(side+'HandPinky1_1stP')
            thumb=correction@(hp[index]-hp[pinky])
            thumb=(thumb-forward*thumb.dot(forward)).normalized()
            palm=forward.cross(thumb).normalized()
            pivot=wrist+correction@(hp[middle]-hp[hi])
            params=[dict(degrees=degrees,axis_degrees=axis_angle)
                    for degrees in range(2,31,2) for axis_angle in range(0,360,45)]
            for param in params:
                angle=math.radians(param['axis_degrees'])
                axis=thumb*math.cos(angle)+palm*math.sin(angle)
                swing=Quaternion(axis,math.radians(param['degrees']))
                moved=[pivot+swing@(p-pivot) for p in points]
                cross = BVHTree.FromPolygons(moved, faces, all_triangles=True).overlap(weapon_tree)
                cuff_cross = [(a,b) for a,b in cross if sum((points[v]-wrist).dot(forward) for v in faces[a])/3 < -2]
                cuff_vertices = {v for f in faces for v in f if (points[v]-wrist).dot(forward)<-2}
                # A cuff is an open wearable surface; include triangle centres
                # so the clearance isn't overstated by coarse edge vertices.
                probes = [moved[v] for v in cuff_vertices]
                probes += [sum((moved[v] for v in f),Vector())/3 for f in faces
                           if sum((points[v]-wrist).dot(forward) for v in f)/3 < -2]
                clearance = min(weapon_tree.find_nearest(p)[3] for p in probes)
                candidates.append(dict(**param,axis=list(axis),pivot=list(pivot),cuff_crossings=len(cuff_cross),
                                       sampled_clearance_cm=clearance,
                                       wrist_displacement_cm=(pivot+swing@(wrist-pivot)-wrist).length,
                                       maximum_contact_displacement_cm=max((points[v]-moved[v]).length for f in faces for v in f if (points[v]-wrist).dot(forward)>0),
                                       max_displacement=max((points[v]-moved[v]).length for v in cuff_vertices)))
                if not cuff_cross and clearance>=0.1:
                    after = object_mesh(scene,side+' corrected cuff',moved,faces,
                                        material('Corrected glove '+name,(0.14,0.44,0.66,1)))
                    after.hide_render=True
                    break
        ob = object_mesh(scene, side+' runtime hand', points, faces, material(side+' glove '+name, (0.14,0.44,0.66,1)))
        object_mesh(scene, side+' cuff intersections', points, hit_faces, material(side+' hit '+name, (1.0,0.10,0.06,1)))
        result['hands'][side] = dict(wrist_in_weapon=list(wrist), forward=list(forward),
                                    surface_crossings=len(hits), cuff_surface_crossings=len(cuff_hits),
                                    crossed_cuff_faces=len(hit_faces),
                                    cuff_hit_axial_cm=sorted({round((points[v]-wrist).dot(forward),2) for f in hit_faces for v in f}),
                                    cuff_crossed_weapon_bones=dict(Counter(
                                        weapon['names'][max(weapon['weights'][v],key=weapon['weights'][v].get)]
                                        for a,b in cuff_hits for v in weapon_faces[b])),
                                    cuff_candidates=candidates)
        # Frame the specific hand against the receiver; hide only the other
        # hand in this independent background-process scene.
        for other in scene.objects:
            if other.name.startswith(('Left ', 'Right ')):
                other.hide_render = not other.name.startswith(side)
        if candidates and not candidates[-1]['cuff_crossings'] and candidates[-1]['sampled_clearance_cm']>=0.1:
            after.hide_render=True
        camera_data = bpy.data.cameras.new(side+' camera '+name)
        camera = bpy.data.objects.new(side+' camera '+name, camera_data)
        scene.collection.objects.link(camera)
        camera.location = wrist + Vector((-22,-36,22))
        camera.rotation_euler = (wrist-camera.location).to_track_quat('-Z','Y').to_euler()
        camera_data.type = 'ORTHO'
        camera_data.ortho_scale = 38
        scene.camera = camera
        scene.render.resolution_x = 1100
        scene.render.resolution_y = 800
        scene.render.resolution_percentage = 100
        scene.render.image_settings.file_format = 'PNG'
        scene.render.filepath = str(output/(name+'-'+side+'.png'))
        bpy.ops.render.render(write_still=True, scene=scene.name)
        if candidates and not candidates[-1]['cuff_crossings'] and candidates[-1]['sampled_clearance_cm']>=0.1:
            for other in scene.objects:
                if other.name.startswith(side+' '):
                    other.hide_render=True
            after.hide_render=False
            scene.render.filepath=str(output/(name+'-'+side+'-corrected.png'))
            bpy.ops.render.render(write_still=True,scene=scene.name)
        if side=='Left':
            camera.location=wrist+Vector((22,36,22))
            camera.rotation_euler=(wrist-camera.location).to_track_quat('-Z','Y').to_euler()
            if candidates and not candidates[-1]['cuff_crossings'] and candidates[-1]['sampled_clearance_cm']>=0.1:
                scene.render.filepath=str(output/(name+'-'+side+'-corrected-opposite.png'))
                bpy.ops.render.render(write_still=True,scene=scene.name)
                after.hide_render=True
            ob.hide_render=False
            scene.render.filepath=str(output/(name+'-'+side+'-opposite.png'))
            bpy.ops.render.render(write_still=True,scene=scene.name)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--weapons', nargs='+', choices=WEAPONS, default=list(WEAPONS))
    args = parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    if not args.output.is_absolute():
        args.output = ROOT / args.output
    args.output.mkdir(parents=True, exist_ok=True)
    hand = geometry(HAND)
    report = {name: inspect(name, hand, args.output) for name in args.weapons}
    for name,row in report.items():
        candidates=row['hands']['Left']['cuff_candidates']
        if candidates and not candidates[-1]['cuff_crossings']:
            # Production art is asymmetric: the right glove ends at the wrist,
            # so role mirroring must not mirror the left cuff's correction.
            row['mirrored_support']=mirrored_support(name,hand,args.output,0)
    (args.output/'measurements.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({name:{side:{k:v for k,v in row.items() if k not in ('cuff_hit_axial_cm','forward','cuff_candidates')}
                           for side,row in data['hands'].items()} for name,data in report.items()}))


if __name__ == '__main__':
    main()
