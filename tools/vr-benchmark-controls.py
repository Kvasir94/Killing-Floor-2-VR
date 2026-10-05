"""Read-only fingerprint of host VR controls; headset-side settings are unverified."""
import argparse
import hashlib
import json
import os
from pathlib import Path


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def snapshot():
    import winreg
    paths = json.loads((Path(os.environ['LOCALAPPDATA'])/'openvr/openvrpaths.vrpath').read_text())
    config = Path(paths['config'][0])/'steamvr.vrsettings'
    settings = json.loads(config.read_text())
    # UI/history/audio preferences do not control this rendering experiment.
    controls = {k: v for k, v in settings.items() if k not in
                ('DesktopUI', 'DismissedWarnings', 'GpuSpeed', 'LastKnown', 'audio', 'dashboard')}
    if 'steamvr' in controls:
        controls['steamvr'] = {k: v for k, v in controls['steamvr'].items() if
            not k.startswith('guidedTourPopup_') and k not in
            ('installID', 'lastVersionNotice', 'lastVersionNoticeDate', 'showAdvancedSettings',
             'haveStartedTutorialForNativeChaperoneDriver')}
    if 'driver_vrlink' in controls:
        controls['driver_vrlink'] = {k: v for k, v in controls['driver_vrlink'].items() if k not in
            ('micVolumeHasBeenInitialized', 'requestedDashboardTutorialForHands')}
    runtime = Path(paths['runtime'][0])
    defaults = runtime/'resources/settings/default.vrsettings'
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\Khronos\OpenXR\1',
                        0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as key:
        active = Path(winreg.QueryValueEx(key, 'ActiveRuntime')[0])
    files = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (defaults, active)}
    return dict(schema='kf2vr/benchmark-controls/1',
                effective_controls_sha256=digest(dict(settings=controls, files=files)),
                settings_path=str(config), runtime_manifest=str(active), files_sha256=files,
                preferred_refresh_rate=settings.get('steamvr', {}).get('preferredRefreshRate'),
                headset_streaming_settings_verified=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(json.dumps(snapshot(), indent=2)+'\n')
