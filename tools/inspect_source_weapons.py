"""Blender inspection of local MDLs; records bones/materials/attachments."""
import json
from pathlib import Path
import sys

import bpy

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'third_party'))
from SourceIO.blender_bindings.models import import_model
from SourceIO.blender_bindings.models.common import put_into_collections
from SourceIO.blender_bindings.operators.import_settings_base import ModelOptions
from SourceIO.library.shared.content_manager import ContentManager
from SourceIO.library.shared.content_manager.providers.loose_files import LooseFilesContentProvider
from SourceIO.library.utils import FileBuffer, TinyPath

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
reports = {}
for kind, relative in [('gravity', 'models/weapons/v_superphyscannon.mdl'),
                       ('sticky', 'models/weapons/c_models/c_stickybomb_launcher/c_stickybomb_launcher.mdl'),
                       ('bomb', 'models/weapons/w_models/w_stickybomb.mdl')]:
    root = ROOT / 'extract/source-weapons' / ('sticky' if kind == 'bomb' else kind)
    cm = ContentManager()
    cm.children.clear()
    cm.children.add(LooseFilesContentProvider(TinyPath(str(root))))
    options = ModelOptions.default()
    options.scale = 2.54
    options.import_textures = True
    path = TinyPath(str(root / relative))
    with FileBuffer(path) as f:
        container = import_model(path, f, cm, options)
    put_into_collections(container, kind, bodygroup_grouping=False)
    arm = container.armature
    reports[kind] = {
        'objects': [{'name': o.name, 'vertices': len(o.data.vertices), 'materials': [m.name for m in o.data.materials],
                     'skins': {k: list(v) for k, v in o.get('skin_groups', {}).items()}, 'bounds': [list(v) for v in o.bound_box]} for o in container.objects],
        'bones': {b.name: {'head': list(b.head_local), 'matrix': [list(row) for row in b.matrix_local]} for b in arm.data.bones} if arm else {},
        'attachments': {a.name: {'matrix': [list(row) for row in a.matrix_world], 'bone': a.parent_bone,
                                'local': [list(row) for row in a.matrix_basis]} for a in container.attachments},
    }
out = ROOT / 'build/source-weapons'
out.mkdir(parents=True, exist_ok=True)
(out / 'inspection.json').write_text(json.dumps(reports, indent=2, default=str))
bpy.ops.wm.save_as_mainfile(filepath=str(out / 'source-inspection.blend'))
print('SOURCE_WEAPONS_INSPECTED', json.dumps({k: r['objects'] for k, r in reports.items()}, default=str))
