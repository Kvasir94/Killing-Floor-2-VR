"""Read VTF particle-sheet resources and preserve original pixel bytes in TGA.

VTF resource 0x10 contains a sized versioned sheet: sequence number, clamp flag,
frame count, duration, then each frame's duration and one (v0) or four (v1) UV
rectangles. The two stock TF2 sheets used here have static one-frame sequences.
"""
import struct


def read_sheet(data):
    if data[:4] != b'VTF\0':
        raise ValueError('Not a VTF texture')
    if struct.unpack_from('<2I', data, 4) < (7, 3):
        return []
    count, = struct.unpack_from('<I', data, 68)
    for i in range(count):
        tag, offset = struct.unpack_from('<2I', data, 80 + i * 8)
        if tag & 0xffffff != 0x10:
            continue
        if tag >> 24 & 2:
            raise ValueError('Sheet data cannot be inline')
        length, version, sequences = struct.unpack_from('<3I', data, offset)
        if version not in (0, 1) or offset + 4 + length > len(data):
            raise ValueError('Invalid particle-sheet resource')
        pos, result = offset + 12, []
        for _ in range(sequences):
            number, clamp, frames, duration = struct.unpack_from('<3If', data, pos)
            pos += 16
            sequence = dict(number=number, clamp=bool(clamp), duration=duration, frames=[])
            for _ in range(frames):
                frame_duration, = struct.unpack_from('<f', data, pos)
                pos += 4
                rects = []
                for _ in range(4 if version else 1):
                    rects.append(list(struct.unpack_from('<4f', data, pos)))
                    pos += 16
                sequence['frames'].append(dict(duration=frame_duration, rectangles=rects))
            result.append(sequence)
        if pos != offset + 4 + length:
            raise ValueError('Particle-sheet resource size mismatch')
        return result
    return []


def write_tga(path, pixels):
    # Avoid Blender's linear-to-sRGB save conversion and vertical image-origin
    # change: these are already decoded original sRGB/normal-map byte values.
    import numpy as np
    height, width, channels = pixels.shape
    assert channels == 4 and 0 < width <= 65535 and 0 < height <= 65535
    rgba = np.clip(np.rint(pixels * 255), 0, 255).astype(np.uint8)
    header = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 0x28)
    path.write_bytes(header + rgba[:, :, [2, 1, 0, 3]].tobytes())


def repack_sheet(pixels, sequences):
    import numpy as np
    height, width, _ = pixels.shape
    tiles, mapping = [], []
    for sequence in sequences:
        if len(sequence['frames']) != 1:
            raise ValueError('Animated sheet requires explicit frame timing support')
        rect = sequence['frames'][0]['rectangles'][0]
        # Source sheet rectangles include a half-texel inset on each edge.
        left, top = round(rect[0]*width-.5), round(rect[1]*height-.5)
        right, bottom = round(rect[2]*width+.5), round(rect[3]*height+.5)
        if not (0 <= left < right <= width and 0 <= top < bottom <= height):
            raise ValueError('Particle-sheet rectangle outside its texture')
        tiles.append(pixels[top:bottom, left:right].copy())
        mapping.append(dict(sequence=sequence['number'], tile=len(tiles)-1, rectangle=rect))
    def power_of_two(n): return 1 << (n-1).bit_length()
    tile_width = power_of_two(max(p.shape[1] for p in tiles))
    tile_height = power_of_two(max(p.shape[0] for p in tiles))
    columns, rows = power_of_two(len(tiles)), 1
    atlas = np.zeros((tile_height*rows, tile_width*columns, 4), dtype=np.float32)
    for i, tile in enumerate(tiles):
        # These original stock sequences have equal dimensions; reject a lossy
        # resize rather than silently changing their artwork or aspect ratio.
        if tile.shape[:2] != (tile_height, tile_width):
            raise ValueError('Nonuniform particle sheet needs explicit padding/UV support')
        atlas[:, i*tile_width:(i+1)*tile_width] = tile
    return atlas, dict(grid=dict(TilesX=columns, TilesY=rows), sequences=mapping, tile_count=len(tiles))
