"""Does the left bracer or the watch run into a gun the left hand supports? (Blender, offline)

The left arm carries a long leather bracer and the wrist panel, both rigid with
the hand. On many guns the support hand sits just ahead of the magazine, so the
bracer would pass through it; `VRHandsBridge.FitSupportWrist` turns the support
wrist out by a few degrees per gun to clear it (#16 Tommy Gun glove cuff clips
the drum, #134 AK12 glove cuff against the magazine). Those angles were found
for one bracer length. This measures any hand revision against the same stock
idle poses, with the angle each gun has today, and looks for the smallest angle
on the same axis that clears when today's does not.

    blender --background --python tools/measure_support_cuff.py -- <runtime dir> [<runtime dir> ...] --output <json>

Each runtime dir holds VRFloatingHands.psk and VRWristwatch.fbx (and
watch-move.json when the watch was moved). Guns whose stock rig or idle export
is not on disk under build/ are skipped and listed. Crossings are surface
measurements on a static pose, not headset acceptance.
"""
import json, math, runpy, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
B = ROOT / 'build'
E = B / 'grip-fit-inspection/export'
# Gun: (stock rig, idle animation set, degrees and axis from VRHandsBridge.FitSupportWrist; 0 where it has none).
GUNS = {
    'SCAR': (B/'scar-audit/export/WEP_1P_SCAR_MESH/SkeletalMesh3/Wep_1stP_SCAR_Rig.psk', E/'WEP_1P_SCAR_ANIM/AnimSet/Wep_1stP_SCAR_Anim.psa', 14, 180),
    'AK12': (E/'WEP_1P_AK12_MESH/SkeletalMesh3/Wep_1stP_AK12_Rig.psk', E/'WEP_1P_AK12_ANIM/AnimSet/Wep_1st_AK12_Anim.psa', 18, 180),
    'MKB42': (B/'mkb42-audit/export/WEP_1P_MKB42_MESH/SkeletalMesh3/Wep_1stP_MKB42_Rig.psk', E/'WEP_1P_MKB42_ANIM/AnimSet/wep_1p_mkb42_anim.psa', 8, 180),
    'M16 M203': (B/'m16m203-audit/export/WEP_1P_M16_M203_MESH/SkeletalMesh3/Wep_1stP_M16_M203_Rig.psk', B/'m16m203-audit/export/WEP_1P_M16_M203_ANIM/AnimSet/Wep_1stP_M16_M203_Anim.psa', 10, 180),
    'M14 EBR': (B/'m14-audit/export/WEP_1P_M14EBR_MESH/SkeletalMesh3/WEP_1stP_M14_EBR.psk', B/'m14-audit/export/WEP_1P_M14EBR_ANIM/AnimSet/Wep_1stP_M14_EBR_Anim.psa', 4, 180),
    'MP5': (B/'mp5ras-audit/export/WEP_1P_MP5RAS_MESH/SkeletalMesh3/Wep_1stP_MP5RAS_Rig.psk', B/'sight-measurements/smg-medic-batch/export/WEP_1P_MP5RAS_ANIM/AnimSet/wep_1p_mp5ras_anim.psa', 2, 180),
    'MP7': (B/'mp7-audit/export/wep_1p_mp7_mesh/SkeletalMesh3/Wep_1stP_MP7_Rig.psk', B/'sight-measurements/original-18-native/export/WEP_1P_MP7_ANIM/AnimSet/wep_1p_mp7_anim.psa', 6, 180),
    'Kriss': (B/'kriss-audit/export/wep_1p_kriss_mesh/SkeletalMesh3/Wep_1stP_KRISS_Rig.psk', B/'sight-measurements/rifle-smg-batch/export/WEP_1P_KRISS_ANIM/AnimSet/wep_1p_kriss_anim.psa', 12, 180),
    'FAMAS': (B/'famas-audit/export/WEP_1P_Famas_MESH/SkeletalMesh3/WEP_1stP_Famas_Rig.psk', B/'famas-audit/export/WEP_1P_Famas_ANIM/AnimSet/Wep_1stP_Famas_Anim.psa', 4, 135),
    'AR15': (B/'ar15-audit/export/WEP_1P_AR15_9mm_MESH/SkeletalMesh3/Wep_1stP_AR15_9mm_Rig.psk', B/'sight-measurements/original-18-native/export/WEP_1P_AR15_9mm_ANIM/AnimSet/Wep_1stP_AR15_9mm_Anim.psa', 6, 225),
    'FN FAL': (B/'fnfal-audit/export/WEP_1P_FNFAL_MESH/SkeletalMesh3/WEP_1stP_FNFAL_Rig.psk', B/'sight-measurements/rifle-smg-native/export/WEP_1P_FNFAL_ANIM/AnimSet/Wep_1stP_FNFAL_Anim.psa', 13, 195),
    'MG3': (B/'mg3-audit/export/WEP_1P_MG3_MESH/SkeletalMesh3/WEP_1stP_MG3_Rig.psk', B/'sight-measurements/heavy-special-batch/export/WEP_1P_MG3_ANIM/AnimSet/Wep_1stP_MG3_Anim.psa', 8, 270),
    'Stoner': (B/'stoner63a-audit/export/WEP_1P_Stoner63A_MESH/SkeletalMesh3/Wep_1stP_Stoner63A_Rig.psk', B/'stoner63a-audit/export/WEP_1P_Stoner63A_ANIM/AnimSet/Wep_1stP_Stoner63A_Anim.psa', 6, 225),
    'HMTech-401': (B/'hmtech401-audit/export/WEP_1P_Medic_Assault_MESH/SkeletalMesh3/Wep_1stP_Medic_Assault_Rig.psk', B/'sight-measurements/assault-feed-native/export-current/WEP_1P_Medic_Assault_ANIM/AnimSet/Wep_1stP_Medic_Assault_Anim.psa', 12, 225),
    'Tommy Gun': (B/'tommygun-audit/export/WEP_1P_TommyGun_MESH/SkeletalMesh3/Wep_1stP_TommyGun_Rig.psk', B/'sight-measurements/smg-medic-native/export/WEP_1P_TommyGun_ANIM/AnimSet/WEP_1stP_TommyGun_Anim.psa', 24, 180),
    'Bullpup': (B/'sa80-audit/export/WEP_1P_L85A2_MESH/SkeletalMesh3/Wep_1stP_L85A2_Rig.psk', B/'sight-measurements/rifle-smg-native/export/WEP_1P_L85A2_ANIM/AnimSet/Wep_1st_L85A2_Anim.psa', 0, 180),
    'HMTech-501': (B/'hmtech501-audit/export/WEP_1P_Medic_GrenadeLauncher_MESH/SkeletalMesh3/Wep_1stP_Medic_GrenadeLauncher_Rig.psk', B/'hmtech501-audit/export/WEP_1P_Medic_GrenadeLauncher_ANIM/AnimSet/Wep_1stP_Medic_GrenadeLauncher_Anim.psa', 0, 180),
    'P90': (B/'p90-audit/export/wep_1p_p90_mesh/SkeletalMesh3/Wep_1stP_P90_Rig.psk', B/'sight-measurements/rifle-smg-native/export/wep_1p_p90_anim/AnimSet/Wep_1stP_P90_Anim.psa', 0, 180),
    'Winchester': (B/'winchester-audit/export/WEP_1P_Winchester_MESH/SkeletalMesh3/Wep_1stP_Winchester_Rig.psk', B/'sight-measurements/rifle-smg-native/export/WEP_1P_Winchester_ANIM/AnimSet/Wep_1stP_Winchester_Anim.psa', 0, 180),
    'Centerfire': (B/'spx464-audit/export/WEP_1P_Centerfire_MESH/SkeletalMesh3/Wep_1stP_Centerfire_Rig.psk', B/'sight-measurements/heavy-sight-native/raw/79/Wep_1stP_Centerfire_Anim.psa', 0, 180),
    'Mosin': (B/'mosin-audit/export/WEP_1P_Mosin_MESH/SkeletalMesh3/WEP_1stP_Mosin_Rig.psk', B/'sight-measurements/heavy-sight-native/raw/82/Wep_1stP_Mosin_ANIM.psa', 0, 180),
}
CUFF_BEHIND_WRIST_CM = 2.0       # hand faces further behind the wrist than this are bracer
CLEAR_CM = 0.1


def measure(runtime, g, seat):
    from mathutils import Matrix, Quaternion, Vector
    from mathutils.bvhtree import BVHTree
    hand = g.geometry(runtime / 'VRFloatingHands.psk')
    frame = Matrix(seat['EXPORT_FRAME'])
    moved = runtime / 'watch-move.json'
    if moved.exists():
        frame = Matrix(json.loads(moved.read_text())['export_frame'])
    seat['load_watch'].__globals__['EXPORT_FRAME'] = tuple(tuple(r) for r in frame)
    watch = seat['load_watch'](runtime / 'VRWristwatch.fbx')
    watch.data.calc_loop_triangles()
    watch_local = [v.co.copy() for v in watch.data.vertices]          # the left hand's own frame
    watch_faces = [tuple(t.vertices) for t in watch.data.loop_triangles]
    rows, skipped = {}, []
    for name, (rig, idle, degrees, axis_degrees) in GUNS.items():
        if not rig.exists() or not idle.exists():
            skipped.append(name)
            continue
        weapon = g.geometry(rig)
        tracks = g.idle_tracks(idle)
        wp, wq = g.pose(weapon['bones'], tracks)
        root = weapon['names'].index('RW_Weapon')
        inv = wq[root].inverted()
        weapon_points = [inv @ (p - wp[root]) for p in g.skin(weapon, (wp, wq))]
        weapon_faces = g.selected_faces(weapon, lambda n: n.startswith('RW_'))
        tree = BVHTree.FromPolygons(weapon_points, weapon_faces, all_triangles=True)
        hp, hq = g.pose(hand['bones'], tracks, reference_translation=True)
        skinned = g.skin(hand, (hp, hq))
        at = lambda bone: hand['names'].index(bone)
        hi, wi = at('LeftHand_1stP'), weapon['names'].index('LeftHand_1stP')
        correction = inv @ wq[wi] @ hq[hi].inverted()
        wrist = inv @ (wp[wi] - wp[root])
        place = lambda p: wrist + correction @ (p - hp[hi])
        points = [place(p) for p in skinned]
        faces = g.selected_faces(hand, lambda n: n.startswith('Left'))
        middle, index, pinky = (place(hp[at('LeftHand%s1_1stP' % f)]) for f in ('Middle', 'Index', 'Pinky'))
        forward = (middle - wrist).normalized()
        thumb = index - pinky
        thumb = (thumb - forward * thumb.dot(forward)).normalized()
        palm = forward.cross(thumb).normalized()
        # The watch is authored in the hand's frame: fingers, away from the thumb, back of the hand.
        back = -forward.cross(thumb).normalized()
        to_gun = lambda q: wrist + forward * q.x - thumb * q.y + back * q.z
        watch_points = [to_gun(q) for q in watch_local]
        cuff = {i for i, f in enumerate(faces) if sum((points[v] - wrist).dot(forward) for v in f) / 3 < -CUFF_BEHIND_WRIST_CM}
        cuff_vertices = sorted({v for i in cuff for v in faces[i]})

        def at_swing(deg):
            axis = thumb * math.cos(math.radians(axis_degrees)) + palm * math.sin(math.radians(axis_degrees))
            swing = Quaternion(axis, math.radians(deg))
            turn = lambda p: middle + swing @ (p - middle)
            hand_now, watch_now = [turn(p) for p in points], [turn(p) for p in watch_points]
            crossed = {a for a, _ in BVHTree.FromPolygons(hand_now, faces, all_triangles=True).overlap(tree) if a in cuff}
            watch_crossed = {a for a, _ in BVHTree.FromPolygons(watch_now, watch_faces, all_triangles=True).overlap(tree)}
            gap = min(tree.find_nearest(hand_now[v])[3] for v in cuff_vertices)
            watch_gap = min(tree.find_nearest(p)[3] for p in watch_now[::5])
            return {'degrees': deg, 'bracer_faces_crossing': len(crossed), 'watch_faces_crossing': len(watch_crossed),
                    'bracer_gap_cm': round(gap, 3), 'watch_gap_cm': round(watch_gap, 3)}
        now = at_swing(degrees)
        row = {'today': now}
        if now['bracer_faces_crossing'] or now['watch_faces_crossing']:
            for deg in range(degrees + 1, 37):
                trial = at_swing(deg)
                if not trial['bracer_faces_crossing'] and not trial['watch_faces_crossing'] \
                        and min(trial['bracer_gap_cm'], trial['watch_gap_cm']) >= CLEAR_CM:
                    row['clears_at'] = trial
                    break
            else:
                row['clears_at'] = None
        rows[name] = row
        print('GUN', name, json.dumps(row), flush=True)
    import bpy
    bpy.data.objects.remove(watch, do_unlink=True)
    return {'bracer_reaches_behind_wrist_cm': None, 'guns': rows, 'skipped': skipped}


if __name__ == '__main__':
    import bpy
    args = sys.argv[sys.argv.index('--') + 1:]
    output = Path(args[args.index('--output') + 1])
    runtimes = [Path(a) for a in args[:args.index('--output')]]
    sys.path[:0] = [str(ROOT / 'tools'), str(ROOT / 'tools/re')]
    import inspect_stock_grip_fit as g
    seat = runpy.run_path(str(ROOT / 'tools/seat_watch_keepers.py'), run_name='asset_source')
    bpy.context.scene.unit_settings.system = 'METRIC'
    bpy.context.scene.unit_settings.scale_length = 0.01
    report = {str(r): measure(r, g, seat) for r in runtimes}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=1))
    print('SUPPORT_CUFF_MEASURED', output)
