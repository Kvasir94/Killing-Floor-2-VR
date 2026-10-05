"""Read binary FBX animation graphs without Blender, the SDK, or the game.

This checks exported input structure; it does not certify native imported tracks.
Run with one or more FBX paths and optionally --output for a JSON receipt.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import struct
import zlib

TICKS_PER_SECOND = 46_186_158_000


@dataclass
class Node:
    name: bytes
    props: list
    children: list["Node"]


def read_binary_fbx(data: bytes) -> tuple[int, list[Node]]:
    if data[:23] != b"Kaydara FBX Binary  \x00\x1a\x00":
        raise ValueError("Expected binary FBX")
    version = struct.unpack_from("<I", data, 23)[0]
    header = struct.Struct("<QQQB" if version >= 7500 else "<IIIB")
    position = 27

    def take(size):
        nonlocal position
        if size < 0 or position + size > len(data):
            raise ValueError("Truncated FBX")
        result = data[position:position + size]
        position += size
        return result

    def prop():
        kind = take(1)
        scalars = {b"Y": "h", b"C": "?", b"I": "i", b"F": "f", b"D": "d", b"L": "q"}
        arrays = {b"f": "f", b"d": "d", b"l": "q", b"i": "i", b"b": "?", b"c": "b"}
        if kind in scalars:
            fmt = "<" + scalars[kind]
            return struct.unpack(fmt, take(struct.calcsize(fmt)))[0]
        if kind in (b"S", b"R"):
            return take(struct.unpack("<I", take(4))[0])
        if kind in arrays:
            count, encoding, size = struct.unpack("<III", take(12))
            raw = take(size)
            if encoding == 1:
                raw = zlib.decompress(raw)
            elif encoding != 0:
                raise ValueError(f"Unsupported FBX array encoding {encoding}")
            if len(raw) != count * struct.calcsize(arrays[kind]):
                raise ValueError("FBX array length mismatch")
            return list(struct.unpack("<" + str(count) + arrays[kind], raw))
        raise ValueError(f"Unsupported FBX property {kind!r}")

    def node(parent_end):
        nonlocal position
        end, count, props_size, name_size = header.unpack(take(header.size))
        if end == count == props_size == name_size == 0:
            return None
        if not position <= end <= parent_end:
            raise ValueError("Invalid FBX node bounds")
        name = take(name_size)
        prop_start = position
        props = [prop() for _ in range(count)]
        if position - prop_start != props_size or position > end:
            raise ValueError("FBX property list length mismatch")
        children = []
        while position < end:
            child = node(end)
            if child is None:
                break
            children.append(child)
        if position != end:
            raise ValueError("FBX node length mismatch")
        return Node(name, props, children)

    roots = []
    while position < len(data):
        item = node(len(data))
        if item is None:
            break
        roots.append(item)
    return version, roots


def node_name(node):
    return node.props[1].split(b"\x00", 1)[0].decode("utf-8", errors="replace")


def child_value(node, name):
    return next((c.props[0] for c in node.children if c.name == name), None)


def audit_graph(roots: list[Node]) -> dict:
    objects = next(n for n in roots if n.name == b"Objects").children
    links = next(n for n in roots if n.name == b"Connections").children
    by_id = {n.props[0]: n for n in objects}
    if len(by_id) != len(objects):
        raise ValueError("Duplicate FBX object IDs")
    errors = []
    incoming = defaultdict(list)
    outgoing = defaultdict(list)
    for link in links:
        kind, source, target, *property_name = link.props
        if source not in by_id or (target != 0 and target not in by_id):
            errors.append(f"Dangling connection {source}->{target}")
        incoming[target].append((kind, source, property_name))
        outgoing[source].append((kind, target, property_name))
    bones = {n.props[0]: n for n in objects if n.name == b"Model" and n.props[2] == b"LimbNode"}
    if not bones:
        errors.append("No skeletal bone models")
    bone_roots = [key for key in bones if not any(kind == b"OO" and target in bones
                  for kind, target, _ in outgoing[key])]
    reports = []
    for stack in (n for n in objects if n.name == b"AnimationStack"):
        layers = [source for kind, source, _ in incoming[stack.props[0]]
                  if kind == b"OO" and source in by_id and by_id[source].name == b"AnimationLayer"]
        if not layers:
            errors.append(f"{node_name(stack)}: no connected animation layers")
        curve_nodes = {source for layer in layers for kind, source, _ in incoming[layer]
                       if kind == b"OO" and source in by_id and by_id[source].name == b"AnimationCurveNode"}
        channels = defaultdict(dict)
        spans = []
        key_counts = Counter()
        for node_id in curve_nodes:
            targets = [(target, prop_name[0]) for kind, target, prop_name in outgoing[node_id]
                       if kind == b"OP" and target in bones and prop_name]
            curves = [(source, prop_name[0]) for kind, source, prop_name in incoming[node_id]
                      if kind == b"OP" and source in by_id and by_id[source].name == b"AnimationCurve" and prop_name]
            for curve_id, axis in curves:
                curve = by_id[curve_id]
                times = child_value(curve, b"KeyTime")
                values = child_value(curve, b"KeyValueFloat")
                if not times or values is None or len(times) != len(values):
                    errors.append(f"Missing/mismatched keys in curve {curve_id}")
                    continue
                if any(a >= b for a, b in zip(times, times[1:])):
                    errors.append(f"Unordered keys in curve {curve_id}")
                key_counts[len(times)] += 1
                spans.append((times[0], times[-1]))
                for bone_id, property_name in targets:
                    channel_key = (property_name, axis)
                    if channel_key in channels[bone_id]:
                        errors.append(f"Duplicate channel for {node_name(bones[bone_id])} in {node_name(stack)}")
                    channels[bone_id][channel_key] = curve_id
        expected = {(p, axis) for p in (b"Lcl Translation", b"Lcl Rotation", b"Lcl Scaling")
                    for axis in (b"d|X", b"d|Y", b"d|Z")}
        for bone_id, bone in bones.items():
            missing = expected - channels[bone_id].keys()
            if missing:
                errors.append(f"{node_name(stack)}: {node_name(bone)} lacks {len(missing)} transform channels")
        interval = [min(s[0] for s in spans), max(s[1] for s in spans)] if spans else None
        reports.append(dict(name=node_name(stack), layers=len(layers), curve_nodes=len(curve_nodes),
                            animated_bones=sum(bool(channels[key]) for key in bones),
                            curve_key_counts=dict(sorted(key_counts.items())), key_interval_ticks=interval,
                            key_interval_seconds=[v / TICKS_PER_SECOND for v in interval] if interval else None))
    if not reports:
        errors.append("No animation stacks")
    return dict(bones=len(bones), bone_roots=[node_name(bones[key]) for key in bone_roots],
                blend_shapes=sum(n.name == b"Deformer" and n.props[2] == b"BlendShape" for n in objects),
                stacks=reports, errors=errors,
                scope="Exported graph only; native interval, evaluator, compression and playback are not executed.")


def audit_file(path: Path):
    data = path.read_bytes()
    version, roots = read_binary_fbx(data)
    return dict(path=str(path.resolve()), sha256=hashlib.sha256(data).hexdigest(),
                fbx_version=version, **audit_graph(roots))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fbx", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = [audit_file(path) for path in args.fbx]
    rendered = json.dumps(result, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return int(any(item["errors"] or not item["stacks"] for item in result))


if __name__ == "__main__":
    raise SystemExit(main())
