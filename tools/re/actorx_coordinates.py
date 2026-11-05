"""Convert reconstructed UModel ActorX poses to native UE3 coordinates.

UModel reflects Y when exporting positions. A composed ActorX rotation R maps
to native rotation S R S, where S = diag(1, -1, 1). These functions operate on
points and reconstructed rotations in the same frame, including weapon-root
local coordinates. They do not decode raw PSK/PSA quaternion conventions or
animation compression; those must be handled before composing the pose.

For a cooked socket, convert the exported bone position and composed rotation
first, then apply its native RelativeLocation with that native bone rotation.
Reflecting an already-composed mixed-frame socket does not repair its offset.
Native profile BoreRotation and native socket offsets need no conversion when
all geometry and bone poses have been converted to native coordinates.
"""
from collections.abc import Iterable


def native_point_from_actorx(point: Iterable[float]) -> tuple[float, float, float]:
    """Reflect an exported point/vector into the corresponding native frame."""
    x, y, z = point
    return x, -y, z


def native_rotation_from_actorx(
    rotation: Iterable[float],
) -> tuple[float, float, float, float]:
    """Convert a composed XYZW rotation; preserve its norm and quaternion sign."""
    x, y, z, w = rotation
    return -x, y, -z, w


def actorx_point_from_native(point: Iterable[float]) -> tuple[float, float, float]:
    """Inverse point/vector conversion; the reflection is its own inverse."""
    return native_point_from_actorx(point)


def actorx_rotation_from_native(
    rotation: Iterable[float],
) -> tuple[float, float, float, float]:
    """Inverse composed XYZW rotation conversion."""
    return native_rotation_from_actorx(rotation)
