import copy
import struct
import unittest
import zlib

from audit_fbx_animation_inputs import Node, audit_graph, read_binary_fbx


def graph():
    objects = [Node(b"Model", [1, b"Root", b"LimbNode"], []),
               Node(b"AnimationStack", [2, b"Pose", b""], []),
               Node(b"AnimationLayer", [3, b"Layer", b""], [])]
    links = [Node(b"C", [b"OO", 1, 0], []), Node(b"C", [b"OO", 3, 2], [])]
    ident = 4
    for prop in (b"Lcl Translation", b"Lcl Rotation", b"Lcl Scaling"):
        curve_node = ident
        ident += 1
        objects.append(Node(b"AnimationCurveNode", [curve_node, prop, b""], []))
        links.extend([Node(b"C", [b"OO", curve_node, 3], []), Node(b"C", [b"OP", curve_node, 1, prop], [])])
        for axis in (b"d|X", b"d|Y", b"d|Z"):
            objects.append(Node(b"AnimationCurve", [ident, axis, b""], [Node(b"KeyTime", [[0]], []), Node(b"KeyValueFloat", [[1.0]], [])]))
            links.append(Node(b"C", [b"OP", ident, curve_node, axis], []))
            ident += 1
    return [Node(b"Objects", [], objects), Node(b"Connections", [], links)]


class GraphTests(unittest.TestCase):
    def test_stack_without_skeleton_is_rejected(self):
        roots = [Node(b"Objects", [], [Node(b"AnimationStack", [2, b"Empty", b""], [])]),
                 Node(b"Connections", [], [])]
        result = audit_graph(roots)
        self.assertIn("No skeletal bone models", result["errors"])
        self.assertIn("Empty: no connected animation layers", result["errors"])

    def test_skeleton_without_takes_is_rejected(self):
        roots = [Node(b"Objects", [], [Node(b"Model", [1, b"Root", b"LimbNode"], [])]),
                 Node(b"Connections", [], [Node(b"C", [b"OO", 1, 0], [])])]
        self.assertIn("No animation stacks", audit_graph(roots)["errors"])

    def test_single_pose_with_nine_constant_channels_is_valid(self):
        result = audit_graph(graph())
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["stacks"][0]["key_interval_ticks"], [0, 0])
        self.assertEqual(result["stacks"][0]["curve_key_counts"], {1: 9})

    def test_disconnected_layer_is_not_counted_as_valid_animation(self):
        roots = graph()
        roots[1].children.pop(1)
        self.assertTrue(audit_graph(roots)["errors"])

    def test_missing_channel_is_rejected(self):
        roots = graph()
        roots[1].children.pop()
        self.assertTrue(any("lacks 1" in e for e in audit_graph(roots)["errors"]))

    def test_dangling_connection_is_rejected(self):
        roots = graph()
        roots[1].children.append(Node(b"C", [b"OO", 999, 2], []))
        self.assertTrue(any("Dangling" in e for e in audit_graph(roots)["errors"]))

    def test_empty_key_arrays_are_rejected(self):
        roots = graph()
        curve = next(n for n in roots[0].children if n.name == b"AnimationCurve")
        curve.children[0].props[0] = []
        self.assertTrue(any("Missing/mismatched" in e for e in audit_graph(roots)["errors"]))

    def test_duplicate_key_times_are_rejected(self):
        roots = graph()
        curve = next(n for n in roots[0].children if n.name == b"AnimationCurve")
        curve.children[0].props[0] = [0, 0]
        curve.children[1].props[0] = [1.0, 1.0]
        self.assertTrue(any("Unordered" in e for e in audit_graph(roots)["errors"]))

    def test_duplicate_object_ids_are_rejected(self):
        roots = graph()
        roots[0].children.append(copy.deepcopy(roots[0].children[0]))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            audit_graph(roots)


class BinaryTests(unittest.TestCase):
    @staticmethod
    def binary(version, encoding):
        header = struct.Struct("<QQQB" if version >= 7500 else "<IIIB")
        raw = struct.pack("<2q", 0, 46_186_158_000)
        payload = zlib.compress(raw) if encoding else raw
        prop = b"l" + struct.pack("<III", 2, encoding, len(payload)) + payload
        name = b"KeyTime"
        end = 27 + header.size + len(name) + len(prop)
        return b"Kaydara FBX Binary  \x00\x1a\x00" + struct.pack("<I", version) + header.pack(end, 1, len(prop), len(name)) + name + prop + bytes(header.size)

    def test_compressed_and_raw_arrays_in_both_header_versions(self):
        for version in (7400, 7500):
            for encoding in (0, 1):
                with self.subTest(version=version, encoding=encoding):
                    actual_version, roots = read_binary_fbx(self.binary(version, encoding))
                    self.assertEqual(actual_version, version)
                    self.assertEqual(roots[0].props[0], [0, 46_186_158_000])

    def test_truncated_binary_is_rejected(self):
        with self.assertRaises(ValueError):
            read_binary_fbx(self.binary(7400, 0)[:-15])


if __name__ == "__main__":
    unittest.main()
