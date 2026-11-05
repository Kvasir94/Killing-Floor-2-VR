"""Reject incomplete range packages before the launcher can select them."""
from collections import Counter
from pathlib import Path
import argparse
import json

from kf2_package_catalog import read_package
from ue3.upkg import read_header


def validate(path: Path) -> dict:
    version, licensee, objects = read_package(path)
    header, _, imports, _ = read_header(str(path))
    counts = Counter(cls for _, cls in objects)
    if (version, licensee) != (871, 1117):
        raise ValueError('Range package is not from the pinned KF2 package format.')
    if not header['flags'] & 0x20000:
        raise ValueError('Range package is not marked as a map.')
    for cls, minimum in [('World', 1), ('Level', 1), ('Model', 1), ('Brush', 60),
                         ('KFPlayerStart', 6), ('KFTraderTrigger', 1),
                         ('SkeletalMeshActor', 1), ('KFPathnode', 60), ('PointLightMovable', 9),
                         ('KFPawnBlockingVolume', 4)]:
        if counts[cls] < minimum:
            raise ValueError(f'Incomplete range: {cls} exports {counts[cls]} < {minimum}.')
    paths = sum(count for cls, count in counts.items() if cls.endswith('ReachSpec'))
    if paths < 20:
        raise ValueError(f'Range navigation was not built ({paths} reach specs).')
    imported_names = {entry['name'] for entry in imports}
    for material in ('ENV_BioticsLab_Floor1_MIC', 'ENV_BioticsLab_Wall2_Tiled_MIC',
                     'ENV_BioticsLab_LabMetal_MIC', 'ENV_BioticsLab_Ceiling1_MIC',
                     'Env_BioticsLab_Red_Emissive_Bright_MIC'):
        if material not in imported_names:
            raise ValueError('Range lost stock material dependency: ' + material)
    if 'RangeMapTools' in imported_names:
        raise ValueError('Editor-only builder leaked into playable map dependencies.')
    return {'exports': len(objects), 'brushes': counts['Brush'],
            'path_nodes': counts['KFPathnode'], 'reach_specs': paths,
            'player_starts': counts['KFPlayerStart'], 'stock_materials': 5,
            'zed_blocking_volumes': counts['KFPawnBlockingVolume']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('map', type=Path)
    args = parser.parse_args()
    print(json.dumps(validate(args.map), sort_keys=True))
