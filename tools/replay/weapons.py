"""Weapon selection uses canonical identities from the real production registry."""
import json
from pathlib import Path
import re


def weapon_path(weapon):
    from ammo_prepare import FAMILIES
    if weapon in FAMILIES:
        return 'KFGameContent.'+FAMILIES[weapon]
    if re.fullmatch(r'(?:KFGameContent\.KFWeap_|KF2VR\.VRWeap_)[A-Za-z0-9_]+', weapon, re.I):
        package, name = weapon.split('.', 1)
        return ('KFGameContent' if package.lower() == 'kfgamecontent' else 'KF2VR')+'.'+name
    raise ValueError('Use a known alias or a canonical weapon path from the runtime registry: '+weapon)


def read_catalog(path):
    value = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    if value.get('schema') != 'kf2vr/replay-weapon-catalog/1' or not value.get('complete'):
        raise ValueError('Require a complete runtime weapon catalog')
    return value['weapons']


def select_weapons(items, catalog=None):
    from ammo_prepare import FAMILIES
    selected, identities = [], set()
    aliases = {('KFGameContent.'+name).lower(): alias for alias, name in FAMILIES.items()}
    for token in (v for item in items for v in item.split(',') if v):
        values = [r['weapon'] for r in catalog] if token == 'all' and catalog else list(FAMILIES) if token == 'all' else [token]
        for value in values:
            identity = weapon_path(value).lower()
            if identity not in identities:
                identities.add(identity); selected.append(aliases.get(identity, value))
    return selected


def hold_candidate(weapon, catalog=None):
    path = weapon_path(weapon)
    if catalog is not None:
        row = next((r for r in catalog if r['weapon'].lower() == path.lower()), None)
        return bool(row and row['hold'])
    # Canonical paths are admitted by the real registry and instance recipe at
    # runtime. This is permission to try the contract, never prior coverage.
    return weapon in ('9mm', 'deagle', 'ar15', 'thompson') or '.' in weapon


def catalog_from_log(text):
    rows, errors, terminal = [], [], None
    for line in text.splitlines():
        if 'KF2VR_REPLAY_CATALOG_SUMMARY ' in line:
            if terminal is not None: errors.append('Duplicate catalog completion')
            terminal = dict(re.findall(r'(\w+)=([^\s]+)', line.split('KF2VR_REPLAY_CATALOG_SUMMARY ',1)[1]))
            continue
        if 'KF2VR_REPLAY_CATALOG ' not in line: continue
        payload = line.split('KF2VR_REPLAY_CATALOG ', 1)[1]
        pairs = re.findall(r'(\w+)=([^\s]+)', payload); row = dict(pairs)
        if len(row) != len(pairs): errors.append('Duplicate catalog field')
        if row.get('phase') == 'complete':
            if terminal is not None: errors.append('Duplicate catalog completion')
            terminal = row; continue
        try:
            if row.get('index') != str(len(rows)+1): raise ValueError('Missing catalog sequence')
            weapon_path(row['weapon'])
            if row['hold'] not in ('True','False') or row['dual'] not in ('True','False'):
                raise ValueError('Invalid catalog capability')
            rows.append(dict(row, hold=row['hold']=='True', dual=row['dual']=='True', executed=False))
        except (KeyError, ValueError) as error: errors.append(str(error))
    if not rows or terminal is None or terminal.get('count') != str(len(rows)) or terminal.get('missing') != '0':
        errors.append('Incomplete production registry catalog')
    return dict(schema='kf2vr/replay-weapon-catalog/1', complete=not errors, errors=errors,
                weapons=rows, execution_accepted=False)
