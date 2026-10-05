"""Synthetic geometry regressions: Blender is required for the cut tests.

Run in Blender's Python with unittest discovery or run this file directly with
  blender --background --python tools/tests/test_floating_hands.py
The fixtures contain no game assets.
"""

import importlib.util
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('floating_hands', Path(__file__).resolve().parents[1] / 'generate_floating_hands.py')
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

try:
    import bmesh
    HAS_BLENDER = True
except ImportError:
    HAS_BLENDER = False


def fixture():
    bones = [('Root',0,(0,0,0)), ('LeftArm_1stP',0,(-5,-2,0)), ('LeftHand_1stP',1,(0,2,0)),
             ('LeftHandMiddle1_1stP',2,(0,2,0)), ('RightArm_1stP',0,(5,-2,0)),
             ('RightHand_1stP',4,(0,2,0)), ('RightHandMiddle1_1stP',5,(0,2,0))]
    rows = {'ACTRHEAD':[], 'PNTS0000':[], 'VTXW0000':[], 'FACE0000':[], 'MATT0000':[b'TestSkin' + b'\0'*80],
            'REFSKELT':[mod.BONE.pack(n.encode(),0,0,p,0,0,0,1,*loc,0,0,0,0) for n,p,loc in bones], 'RAWWEIGHTS':[]}
    cube_faces = [(0,2,1),(0,3,2),(4,5,6),(4,6,7),(0,1,5),(0,5,4),
                  (1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
    for side, x in enumerate((-5,5)):
        base = len(rows['PNTS0000'])
        coords = [(x-1,-2,-1),(x+1,-2,-1),(x+1,-2,1),(x-1,-2,1),
                  (x-1,2,-1),(x+1,2,-1),(x+1,2,1),(x-1,2,1)]
        for i, coord in enumerate(coords):
            rows['PNTS0000'].append(struct.pack('<3f',*coord))
            skin = [(0.25,1+3*side),(0.5,2+3*side),(0.25,3+3*side)] if i >= 4 else [(0.75,1+3*side),(0.25,2+3*side)]
            rows['RAWWEIGHTS'].extend(mod.WEIGHT.pack(w,base+i,b) for w,b in skin)
        for face in cube_faces:
            wedges = []
            for p in face:
                wedges.append(len(rows['VTXW0000']))
                rows['VTXW0000'].append(mod.WEDGE.pack(base+p,p/8,0.25,0,0,0))
            rows['FACE0000'].append(mod.FACE.pack(*wedges,0,0,1))
    sizes = [0,12,16,12,88,120,12]
    return {n:mod.Chunk(n,1999801,s,rows[n]) for n,s in zip(rows,sizes)}


class PskValidationTests(unittest.TestCase):
    def test_round_trip_retains_all_chunk_bytes(self):
        source = fixture()
        raw = b''.join(c.encode() for c in source.values())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'source.psk'
            path.write_bytes(raw)
            parsed = mod.read_psk(path)
        self.assertEqual(raw,b''.join(c.encode() for c in parsed.values()))
        self.assertEqual(16,len(mod.decode_geometry(parsed)[0]))

    def test_unknown_indexed_chunk_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'unknown.psk'
            path.write_bytes(mod.Chunk('EXTRAUVS0',0,8,[b'\0'*8]).encode())
            with self.assertRaisesRegex(ValueError,'Unsupported chunk'):
                mod.read_psk(path)

    def test_corrupt_weight_rejected(self):
        source = fixture()
        source['RAWWEIGHTS'].rows[0] = mod.WEIGHT.pack(0.25,999,0)
        with self.assertRaisesRegex(ValueError,'Invalid skin weight'):
            mod.decode_geometry(source)


@unittest.skipUnless(HAS_BLENDER,'Blender Python is required')
class BlenderCutTests(unittest.TestCase):
    def test_closed_wrist_and_original_rig_finger_weights(self):
        source = fixture()
        output, report = mod.cut_hands(source)
        self.assertEqual(source['REFSKELT'].encode(),output['REFSKELT'].encode())
        self.assertEqual(source['MATT0000'].encode(),output['MATT0000'].encode())
        points, wedges, faces, weights = mod.decode_geometry(output)
        self.assertTrue(all(p[1] >= -0.00001 for p in points))
        self.assertTrue(all(h['cap_boundaries'] == 1 for h in report['hands']))
        edge_counts = {}
        for face in faces:
            indices = [wedges[w][0] for w in face[:3]]
            for a,b in zip(indices,indices[1:]+indices[:1]):
                edge = tuple(sorted((a,b)))
                edge_counts[edge] = edge_counts.get(edge,0)+1
        self.assertEqual({2},set(edge_counts.values()))
        for point, skin in zip(points,weights):
            side = int(point[0] > 0)
            self.assertTrue(set(skin).issubset({2+3*side,3+3*side}))
            if point[1] == 2:
                self.assertAlmostEqual(0.25,skin[3+3*side])
                self.assertAlmostEqual(0.75,skin[2+3*side])
        source_points = mod.decode_geometry(source)[0]
        for face in faces:
            if all(points[wedges[w][0]][1] == 0 for w in face[:3]):
                continue  # New wrist caps intentionally receive new UVs.
            for wedge_id in face[:3]:
                wedge = wedges[wedge_id]
                point = points[wedge[0]]
                if point[1] == 2:
                    self.assertAlmostEqual((source_points.index(point) % 8) / 8,wedge[1])
                    self.assertAlmostEqual(0.25,wedge[2])

    def test_optional_original_weights_and_determinism(self):
        source = fixture()
        first, _ = mod.cut_hands(source, preserve_proximal_weights=True)
        second, _ = mod.cut_hands(source, preserve_proximal_weights=True)
        self.assertEqual(b''.join(c.encode() for c in first.values()),b''.join(c.encode() for c in second.values()))
        points, _, _, weights = mod.decode_geometry(first)
        for point, skin in zip(points,weights):
            if point[1] == 2:
                side = int(point[0] > 0)
                self.assertAlmostEqual(0.25,skin[1+3*side])
                self.assertAlmostEqual(0.5,skin[2+3*side])
                self.assertAlmostEqual(0.25,skin[3+3*side])

    def test_float32_source_weight_drift_does_not_exceed_one(self):
        source = fixture()
        source['RAWWEIGHTS'].rows = [r for r in source['RAWWEIGHTS'].rows if mod.WEIGHT.unpack(r)[1] != 4]
        source['RAWWEIGHTS'].rows += [mod.WEIGHT.pack(0.7,4,1),mod.WEIGHT.pack(0.3000001,4,2)]
        output, _ = mod.cut_hands(source)
        points, _, _, weights = mod.decode_geometry(output)
        self.assertEqual({2:1.0},weights[points.index((-6.0,2.0,-1.0))])

    def test_fbx_contains_only_cut_mesh_original_bones_and_centimetres(self):
        import bpy
        import math
        import numpy as np
        from io_scene_fbx import parse_fbx
        if not hasattr(bpy.ops.psk, 'import_file'):
            self.skipTest('PSK importer addon is required for FBX export')
        source = fixture()
        output, _ = mod.cut_hands(source)
        root_bone = list(mod.BONE.unpack(output['REFSKELT'].rows[0]))
        root_bone[4:8] = [0.0,0.0,math.sin(0.23),math.cos(0.23)]
        output['REFSKELT'].rows[0] = mod.BONE.pack(*root_bone)
        previous_scene = bpy.context.window.scene
        with tempfile.TemporaryDirectory() as directory:
            psk = Path(directory)/'test_hands.psk'
            fbx = Path(directory)/'test_hands.fbx'
            psk.write_bytes(b''.join(c.encode() for c in output.values()))
            report = mod.export_fbx(psk,fbx)
            root,version = parse_fbx.parse(str(fbx))
        self.assertIs(previous_scene,bpy.context.window.scene)
        self.assertEqual(7400,version)
        self.assertEqual(7,report['fbx_bones'])
        objects = next(e for e in root.elems if e.id == b'Objects')
        models = [e for e in objects.elems if e.id == b'Model']
        bone_names = [e.props[1].split(b'\0')[0].decode() for e in models if e.props[2] == b'LimbNode']
        self.assertEqual(mod.bone_data(source)[1],bone_names)
        self.assertEqual(1,sum(e.props[2] == b'Mesh' for e in models))
        self.assertEqual(0,sum(e.props[2] == b'Null' for e in models))
        root_id = next(e.props[0] for e in models if e.props[1].split(b'\0')[0] == b'Root')
        connections = next(e for e in root.elems if e.id == b'Connections')
        self.assertTrue(any(e.props[:3] == [b'OO',root_id,0] for e in connections.elems))
        pose = next(e for e in objects.elems if e.id == b'Pose')
        pose_count = next(e.props[0] for e in pose.elems if e.id == b'NbPoseNodes')
        self.assertEqual(8,pose_count)  # Seven original bones and the mesh.
        self.assertEqual(pose_count,sum(e.id == b'PoseNode' for e in pose.elems))
        settings = next(e for e in root.elems if e.id == b'GlobalSettings')
        properties = next(e for e in settings.elems if e.id == b'Properties70')
        units = next(e.props[-1] for e in properties.elems if e.props[0] == b'UnitScaleFactor')
        self.assertEqual(1.0,units)
        for model in models:
            properties = next(e for e in model.elems if e.id == b'Properties70')
            for prop in properties.elems:
                if prop.props[0] == b'Lcl Scaling':
                    self.assertEqual([1.0,1.0,1.0],prop.props[4:])
        for entry in [e for e in pose.elems if e.id == b'PoseNode']:
            transform = np.array(next(e.props[0] for e in entry.elems if e.id == b'Matrix')).reshape((4,4)).T
            np.testing.assert_allclose(transform[:3,:3].T@transform[:3,:3],np.eye(3),atol=1e-12)
        root_pose = next(e for e in pose.elems if e.id == b'PoseNode' and next(c.props[0] for c in e.elems if c.id == b'Node') == root_id)
        root_matrix = np.array(next(e.props[0] for e in root_pose.elems if e.id == b'Matrix')).reshape((4,4)).T
        self.assertAlmostEqual(math.cos(0.46),root_matrix[0,0],places=6)
        self.assertAlmostEqual(math.sin(0.46),root_matrix[1,0],places=6)
        geometry = next(e for e in objects.elems if e.id == b'Geometry')
        coords = next(e.props[0] for e in geometry.elems if e.id == b'Vertices')
        expected = [value for point in mod.decode_geometry(output)[0] for value in point]
        self.assertEqual(expected,list(coords))


def run_tests():
    stream = io.StringIO()
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(stream=stream,verbosity=2).run(suite)
    print(stream.getvalue())
    if not result.wasSuccessful():
        raise RuntimeError('Floating hand geometry tests failed')
    return {'tests':result.testsRun,'skipped':len(result.skipped),'successful':True}


if __name__ == '__main__':
    run_tests()
