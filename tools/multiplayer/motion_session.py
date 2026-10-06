"""Explicit live player motion recording, scoped to the current local session."""
from datetime import datetime, timezone
from pathlib import Path
import re
import uuid

UUID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z')


def configure(roles, enabled):
    for role in roles:
        for key in ('record_motion', 'motion_session_dir', 'capture_session_id', 'capture_session_started_utc'):
            role.pop(key, None)
    promo_ids = {role['promo_session'] for role in roles if role.get('promo_session')}
    if not enabled and not promo_ids:
        return None
    if len(promo_ids) > 1:
        raise ValueError('Capture roles have different highlight session IDs')
    session = next(iter(promo_ids)) if promo_ids else str(uuid.uuid4())
    if not UUID.fullmatch(session):
        raise ValueError('Invalid capture session ID')
    started = datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    drivers = [role for role in roles if role['role'] == 'driver' and role.get('native_adapter')
               and '-kf2vr-stereo' in role['args']]
    if enabled and len(drivers) != 1:
        raise ValueError('Motion recording requires one live VR player')
    for role in roles:
        if role in drivers or role.get('promo_session'):
            role.update(capture_session_id=session, capture_session_started_utc=started)
    motion_dir = None
    if enabled:
        motion_dir = str(Path(drivers[0]['log']).parent / 'motion')
        drivers[0].update(record_motion=True, motion_session_dir=motion_dir)
    return dict(capture_session_id=session, capture_session_started_utc=started,
                record_motion=bool(enabled), motion_session_dir=motion_dir)


def environment(role):
    session = role.get('capture_session_id')
    if session is None:
        return {}
    if not isinstance(session, str) or not UUID.fullmatch(session):
        raise ValueError('Invalid capture session ID')
    started = role.get('capture_session_started_utc', '')
    if not isinstance(started, str) or not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z', started):
        raise ValueError('Invalid capture session UTC start')
    result = dict(KF2VR_CAPTURE_SESSION_ID=session, KF2VR_CAPTURE_SESSION_STARTED_UTC=started)
    if role.get('record_motion'):
        if role['role'] != 'driver' or not role.get('native_adapter') or '-kf2vr-stereo' not in role['args']:
            raise ValueError('Motion recording requires live VR player input')
        directory = str(Path(role['log']).parent / 'motion')
        if role.get('motion_session_dir') != directory:
            raise ValueError('Motion output must stay inside the current player session')
        result.update(KF2VR_RECORD_MOTION='1', KF2VR_MOTION_SESSION_DIR=directory)
    return result
