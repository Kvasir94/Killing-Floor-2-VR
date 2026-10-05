"""Stage a verified SDK art candidate, preserving the prior local art files."""
import argparse, hashlib, json, shutil
from datetime import datetime, timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest().upper()

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('revision',type=int)
    args=parser.parse_args();base=ROOT/'build/watch-detail-20260924'/str(args.revision)
    runtime=base/'runtime';package=base/'package';receipt=json.loads((package/'build.json').read_text(encoding='utf-8-sig'))
    assert receipt['success'] and digest(package/'KF2VRHands.upk')==receipt['package_sha256'].upper()
    assert digest(runtime/'VRFloatingHands.fbx')==receipt['input_sha256'].upper()
    assert digest(runtime/'VRWristwatch.fbx')==receipt['wristwatch_sha256'].upper()
    # Prop textures (tomahawk) are imported from build/hand-meshes, not the candidate.
    for name,value in receipt['textures_sha256'].items():
        assert digest((ROOT/'build/hand-meshes' if name.startswith('VRTomahawk') else runtime)/name)==value.upper(),name
    assert json.loads((runtime/'fbx-roundtrip.json').read_text())['passed']
    surface=json.loads((runtime/'hand-surface-report.json').read_text())
    if surface.get('uv_repack'):assert json.loads((runtime/'hand-fbx-roundtrip.json').read_text())['passed']
    backup=base/('before-staging-'+datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S'))
    mesh_root=ROOT/'build/hand-meshes';asset_root=ROOT/'build/hand-assets'
    inputs=[p for p in runtime.iterdir() if p.suffix in {'.fbx','.psk','.tga'} and p.name.startswith(('VRFloatingHands','VRWristwatch','VRHorzine'))]
    changes=[(p,mesh_root/p.name) for p in inputs]+[(package/name,asset_root/name) for name in ('KF2VRHands.upk','build.json')]
    for _,destination in changes+[(None,mesh_root/'VRFloatingHands.json')]:
        if destination.exists():
            saved=backup/destination.relative_to(ROOT/'build');saved.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(destination,saved)
    shutil.copy2(ROOT/'build/multiplayer/current-release.json',backup/'current-release.json')
    for source,destination in changes:shutil.copy2(source,destination)
    dependencies={str(p.relative_to(ROOT)).replace('\\','/'):digest(p) for p in inputs+[runtime/'hand-surface-report.json',runtime/'asset-report.json']}
    generation={'schema':'kf2vr/staged-reference-art/1','concept_revision':args.revision,
                'generator_relative':'tools/stage_watch_candidate.py','generator_sha256':digest(Path(__file__)),
                'source':str(runtime/'asset-report.json'),'source_sha256':digest(runtime/'asset-report.json'),
                'fbx_sha256':digest(runtime/'VRFloatingHands.fbx'),'dependencies_sha256':dependencies,
                'hand_surface_report':str(runtime/'hand-surface-report.json'),'visual_acceptance':False,
                'purpose':'User-requested in-game review; not final visual or FPS acceptance.'}
    (mesh_root/'VRFloatingHands.json').write_text(json.dumps(generation,indent=2))
    (base/'staging.json').write_text(json.dumps({'backup':str(backup),'sdk_receipt':str(package/'build.json'),'generation':generation},indent=2))
    print(json.dumps({'staged_revision':args.revision,'backup':str(backup)}))

if __name__=='__main__':main()
