"""Read-only checks for the cooked material/mesh used by the spatial HUD.

Checks the actual owned assets, not source-code patterns. No game/editor launch.
Run: python -B tools/tests/hud-assets.tests.py [KF2 game root]
"""
from pathlib import Path
import hashlib
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.ue3.upkg import Reader, read_header


def props(data, names):
    r = Reader(data)
    result = {}
    while True:
        name = r.fname(names)
        if name == 'None':
            return result
        kind = r.fname(names)
        size, index = r.i32(), r.i32()
        extra = None
        if kind in ('StructProperty', 'ByteProperty'):
            extra = r.fname(names)
        elif kind == 'BoolProperty':
            extra = r.raw(1) != b'\0'
        result[name] = (kind, extra, r.raw(size))


def exports(path):
    """Read this installed UE3 export layout, retaining object ownership."""
    info, names, imports, _ = read_header(path)
    data = path.read_bytes()
    r = Reader(data)
    r.p = info['export_offset']
    result = []
    for _ in range(info['export_count']):
        cls, _, outer = r.i32(), r.i32(), r.i32()
        name = r.fname(names)
        r.i32(); r.u64()
        size, offset = r.i32(), r.i32()
        r.u32()
        r.raw(r.i32() * 4)
        r.raw(16)
        r.u32()
        result.append(dict(name=name, cls=imports[-cls - 1]['name'] if cls < 0 else '',
                           outer=outer, size=size, offset=offset))
    return data, names, result


def check(game_root):
    root = game_root / 'KFGame/BrewedPC'
    mesh = (root / 'EngineMeshes.upk').read_bytes()
    assert hashlib.sha256(mesh).hexdigest() == 'd638da65d15f5a4b38dd8fe692c2108c17973d3512c4eff5c395286be0ed96ea', 'Mesh differs from pinned asset'
    # Cube export 8: native position buffer begins at 148347. Buffer metadata
    # immediately before it records 12-byte stride and 24 vertices.
    positions = 143534 + 4813
    assert struct.unpack_from('<4I', mesh, positions - 16) == (12, 24, 12, 24)
    points = [struct.unpack_from('<fff', mesh, positions + i * 12) for i in range(24)]
    assert all(abs(c) == 128 for p in points for c in p), 'Unexpected cube dimensions'
    vertices = positions + 288
    assert struct.unpack_from('<6I', mesh, vertices) == (4, 24, 24, 0, 24, 24)
    for i in range(20, 24):
        x, y, z = points[i]
        u, v = struct.unpack_from('<ee', mesh, vertices + 24 + i * 24 + 8)
        assert x == -128 and abs(u - (y + 128) / 256) < .002 and abs(v - (128 - z) / 256) < .002, 'Front face UV would mirror or invert text'

    path = root / 'Packages/Environment/ENV_Sanitarium/ENV_Sanitarium_MAT.upk'
    material, names, objects = exports(path)
    assert hashlib.sha256(material).hexdigest() == '98273412804cc8a39b3915453539e5a2f4723dd5820c225f0a882ff4c9315c08', 'Material differs from pinned asset'

    def object_props(obj):
        return props(material[obj['offset'] + 4:obj['offset'] + obj['size']], names)

    def input_node(owner, field):
        link = props(owner[field][2], names)
        return objects[struct.unpack('<i', link['Expression'][2])[0] - 1], link

    parent = next(o for o in objects if o['name'] == 'ENV_Sanitarium__Emmisive_Translucent_Decal' and o['cls'] == 'Material')
    fields = object_props(parent)
    assert Reader(fields['LightingModel'][2]).fname(names) == 'MLM_Unlit'
    assert Reader(fields['BlendMode'][2]).fname(names) == 'BLEND_Translucent'
    assert not fields.get('bDisableDepthTest', (None, False))[1]
    assert not fields.get('TwoSided', (None, False))[1], 'Thin cube must not double-composite both faces'
    assert 'WorldPositionOffset' not in fields and 'Distortion' not in fields
    emissive_node, _ = input_node(fields, 'EmissiveColor')
    assert emissive_node['cls'] == 'MaterialExpressionMultiply'
    emissive = object_props(emissive_node)
    color_node, _ = input_node(emissive, 'A')
    intensity_node, _ = input_node(emissive, 'B')
    assert intensity_node['cls'] == 'MaterialExpressionScalarParameter'
    assert Reader(object_props(intensity_node)['ParameterName'][2]).fname(names) == 'Scalar_Glow_Intensity'
    assert color_node['cls'] == 'MaterialExpressionMultiply'
    color = object_props(color_node)
    sample_node, rgb = input_node(color, 'A')
    tint_node, _ = input_node(color, 'B')
    assert tint_node['cls'] == 'MaterialExpressionVectorParameter'
    assert Reader(object_props(tint_node)['ParameterName'][2]).fname(names) == 'Vector_Glow_Color'
    assert sample_node['cls'] == 'MaterialExpressionTextureSampleParameter2D'
    sample = object_props(sample_node)
    assert Reader(sample['ParameterName'][2]).fname(names) == 'Texture_D'
    assert 'Coordinates' not in sample, 'Expected default UV0 sampling'
    assert all(struct.unpack('<i', rgb[c][2])[0] == 1 for c in ('MaskR', 'MaskG', 'MaskB'))
    opacity_node, _ = input_node(fields, 'Opacity')
    assert opacity_node['cls'] == 'MaterialExpressionMultiply'
    alpha_sample, mask = input_node(object_props(opacity_node), 'A')
    alpha_scale, _ = input_node(object_props(opacity_node), 'B')
    assert alpha_sample == sample_node
    assert struct.unpack('<i', mask['MaskA'][2])[0] == 1, 'Opacity must read the display alpha channel'
    assert alpha_scale['cls'] == 'MaterialExpressionScalarParameter'
    assert Reader(object_props(alpha_scale)['ParameterName'][2]).fname(names) == 'Scalar_Opacity'
    # No mesh/particle vertex tint, flipbook coordinates, depth fade, or
    # constant opacity can change the intended panel colors and transparency.
    parent_index = objects.index(parent) + 1
    assert not any(('VertexColor' in o['cls'] or 'Particle' in o['cls'])
                   for o in objects if o['outer'] == parent_index)
    font_path = root / 'Packages/UserInterface/UI_Canvas_Fonts.upk'
    font, _, font_objects = exports(font_path)
    assert hashlib.sha256(font).hexdigest() == '99ac63bfc120d95df177afcd5a87cce58ef8f367768f0ba1718e2673952acce9'
    assert any(o['name'] == 'Font_Main' and o['cls'] == 'Font' for o in font_objects)
    # Verify the actual cooked sprite exports used by the spatial layout.
    # Their identities were established by decoding/viewing their first mips;
    # the provenance/contact-sheet recipe is in docs/re/HUD_STOCK_ART_2026-09-13.md.
    for relative, sha, expected, srgb in (
        ('GFx/UI_HUD.upk', '0217b2345c1d07e5ac853d5f434567bb7adead9caae02123aaea35c0f30f59db', {
            'InGameHUD_SWF_I22C': (512, 512),  # armor shield
            'InGameHUD_SWF_I214': (512, 512),  # healing syringe
            'InGameHUD_SWF_I13F': (256, 256),  # dosh
            'InGameHUD_SWF_I1DD': (256, 256),  # carry weight
            'InGameHUD_SWF_I1B1': (512, 512),  # flashlight battery
            'InGameHUD_SWF_I2F': (512, 512),   # grenade fallback
            'InGameHUD_SWF_I16A': (512, 512),  # trader clock
            'InGameHUD_SWF_I188': (512, 512),  # biohazard / zeds
            'InGameHUD_SWF_I7E': (1024, 512),  # blood splash
        }, False),
        ('Packages/UserInterface/HUD/UI_Objective_Tex.upk',
         '047156f7b9c828b086dfa5ff67fa853eae10c240b4cab2a293b0e766ab738641', {
             'UI_Obj_Background_Short': (512, 256),
             'UI_Obj_Healing_Loc': (256, 256),
         }, True),
    ):
        data, sprite_names, sprite_objects = exports(root / relative)
        assert hashlib.sha256(data).hexdigest() == sha, f'Stock HUD artwork package changed: {relative}'
        for name, dimensions in expected.items():
            obj = next(o for o in sprite_objects if o['name'] == name and o['cls'] == 'Texture2D')
            fields = props(data[obj['offset'] + 4:obj['offset'] + obj['size']], sprite_names)
            actual = tuple(struct.unpack('<i', fields[field][2])[0] for field in ('SizeX', 'SizeY'))
            assert actual == dimensions, f'{name}: unexpected dimensions {actual}'
            assert fields.get('SRGB', (None, True))[1] == srgb, f'{name}: sampling color policy changed'
            fmt = Reader(fields['Format'][2]).fname(sprite_names)
            assert fmt == ('PF_DXT1' if name == 'UI_Obj_Background_Short' else 'PF_DXT5'), name
    print('PASS: pinned cube/front UV, KF2 Canvas font, stock HUD/scanline artwork, depth-tested unlit material RGB/alpha graph')


if __name__ == '__main__':
    check(Path(sys.argv[1]) if len(sys.argv) > 1 else Path('D:/SteamLibrary/steamapps/common/killingfloor2'))
