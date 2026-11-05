"""Build conservative bone spheres from the hand mesh's actual skin weights.

Each sphere contains every reference vertex with a positive weight on its bone.
After posing, the union's AABB therefore contains the weighted skin too. Centers
are bone origins, so FBX axis conversion and mesh Origin/RotOrigin cannot change
the radius. The importer checks reference bone lengths to reject a unit mismatch.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from generate_floating_hands import bone_data, decode_geometry, read_psk


def multiply(a, b):
    x, y, z, w = a
    X, Y, Z, W = b
    return (w*X+x*W+y*Z-z*Y, w*Y-x*Z+y*W+z*X,
            w*Z+x*Y-y*X+z*W, w*W-x*X-y*Y-z*Z)


def reference_positions(bones):
    positions, rotations = [], []
    for i, bone in enumerate(bones):
        q = tuple(bone[4:8])
        length = math.sqrt(sum(x*x for x in q))
        if not math.isfinite(length) or abs(length-1) > .002:
            raise ValueError('Invalid reference quaternion')
        q = tuple(x/length for x in q)
        p = tuple(bone[8:11])
        if i:
            parent = bone[3]
            r = rotations[parent]
            rotated = multiply(multiply(r, (*p, 0)), (-r[0], -r[1], -r[2], r[3]))
            p = tuple(positions[parent][j]+rotated[j] for j in range(3))
            q = multiply(r, (-q[0], -q[1], -q[2], q[3]))
        positions.append(p)
        rotations.append(q)
    return positions


def spheres(chunks):
    bones, names = bone_data(chunks)
    points, _, _, weights = decode_geometry(chunks)
    positions = reference_positions(bones)
    radii = {}
    for point, influences in zip(points, weights):
        if not all(math.isfinite(v) for v in point):
            raise ValueError('Invalid hand vertex')
        for bone, weight in influences.items():
            if weight <= 0:
                continue
            radius = math.dist(point, positions[bone])
            radii[bone] = max(radii.get(bone, 0), radius)
    if not radii or len(radii) > 128:
        raise ValueError('Invalid hand skin bone count')
    return [dict(bone=names[i], radius=max(radius, .0001) * 1.00001,
                 reference_length=math.sqrt(sum(x*x for x in bones[i][8:11])))
            for i, radius in sorted(radii.items())]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mesh', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(spheres(read_psk(args.mesh)), indent=2)+'\n')


if __name__ == '__main__':
    main()
