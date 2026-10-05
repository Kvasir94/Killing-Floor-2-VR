"""Rebuild the local, self-contained watch iteration review index."""
from pathlib import Path
import json
import html

ROOT=Path(__file__).resolve().parents[1]/'build/watch-detail-20260924'
esc=html.escape
cards=[]
navigation=[]
for p in sorted((p for p in ROOT.iterdir() if p.is_dir() and p.name.isdigit()),key=lambda p:int(p.name)):
    review=json.loads((p/'review.json').read_text()) if (p/'review.json').exists() else {}
    runtime=json.loads((p/'runtime-review.json').read_text()) if (p/'runtime-review.json').exists() else {}
    iteration=json.loads((p/'iteration.json').read_text(encoding='utf-8-sig')) if (p/'iteration.json').exists() else {}
    export_status=json.loads((p/'runtime/export-status.json').read_text(encoding='utf-8-sig')) if (p/'runtime/export-status.json').exists() else {}
    owner=ROOT/str(iteration.get('authoring_revision',p.name))
    user_path=p/'user-review.json' if (p/'user-review.json').exists() else owner/'user-review.json'
    user_review=json.loads(user_path.read_text()) if user_path.exists() else {}
    hand_review=json.loads((p/'hand-review.json').read_text()) if (p/'hand-review.json').exists() else {}
    game_review=json.loads((p/'game-review.json').read_text()) if (p/'game-review.json').exists() else {}
    score=review.get('score','Pending')
    author_review=(p/'self-review.txt').read_text(encoding='utf-8-sig').strip() if (p/'self-review.txt').exists() else ''
    asset=json.loads((p/'runtime/asset-report.json').read_text()) if (p/'runtime/asset-report.json').exists() else {}
    navigation.append(f'<a href="#iteration-{p.name}">{p.name}</a>')
    images=''.join(f'<figure><a href="{p.name}/{name}.png"><img loading="lazy" src="{p.name}/{name}.png" alt="Iteration {p.name} {name}"></a><figcaption>{"Baked asset preview" if name.startswith("runtime-") else "Source render"} · {name.removeprefix("runtime-")}</figcaption></figure>'
                   for name in ['hand-context','front','oblique','badge','alignment','fit-rear','fit-overhead','fit-forearm','runtime-hand-context','runtime-glove','runtime-skin','runtime-palm','runtime-front','runtime-oblique','runtime-badge','runtime-dial','runtime-rear','runtime-wireframe','runtime-detail'] if (p/(name+'.png')).exists())
    import os
    for value in game_review.get('images_reviewed',[]):
        image_path=Path(value)
        if image_path.exists():
            relative=Path(os.path.relpath(image_path,ROOT)).as_posix()
            images+=f'<figure><a href="{esc(relative)}"><img loading="lazy" src="{esc(relative)}" alt="Actual KF2 capture {p.name}"></a><figcaption>Actual KF2 · {esc(image_path.name)}</figcaption></figure>'
    cards.append(f'<section id="iteration-{p.name}"><h2>Iteration {p.name} <span>Source: {score} / 100</span></h2><p>{esc(review.get("critique",review.get("summary","Awaiting independent review.")))}</p>'
                 +(f'<p>Authoring revision {esc(str(iteration.get("authoring_revision",p.name)))}. {esc(iteration.get("change",""))}</p>' if iteration else '')
                 +(f'<p><strong>Export status:</strong> {esc(export_status.get("status",""))}. {esc(export_status.get("reason",""))}</p>' if export_status else '')
                 +(f'<p><strong>Author review:</strong> {esc(author_review)}</p>' if author_review else '')
                 +(f'<p><strong>Hand surface review: {hand_review.get("score","Pending")}/100.</strong> {esc(hand_review.get("critique",hand_review.get("summary","")))}</p>' if hand_review else '')
                 +(f'<p><strong>Actual KF2 review: {game_review.get("score","Pending")}/100.</strong> {esc(game_review.get("critique",""))}</p>' if game_review else '')
                 +(f'<p>Runtime geometry: {asset["watch_triangles"]:,} triangles · {asset["watch_vertices"]:,} shared points · {asset.get("material_slots",1)} material.</p>' if 'watch_triangles' in asset and 'watch_vertices' in asset else '')
                 +(f'<p><strong>User correction supersedes this source pass:</strong> {esc(user_review["finding"])}</p>' if user_review else '')
                 +f'<p>{esc("Export review"+(" ("+str(runtime["score"])+"/100)" if "score" in runtime else "")+": "+runtime.get("critique",runtime.get("summary",""))) if runtime else ""}</p>'
                 f'<p><a href="{p.name}/watch-source.blend">Editable Blender version</a> · <a href="{p.name}/source/">Source snapshot</a> · <a href="{p.name}/review.json">Review</a>'
                 +(f' · <a href="{p.name}/self-review.txt">Author review</a>' if (p/'self-review.txt').exists() else '')
                 +(f' · <a href="{p.name}/strap-fit.json">Strap clearance audit</a>' if (p/'strap-fit.json').exists() else '')
                 +(f' · <a href="{p.name}/handedness-audit.json">Hand orientation audit</a>' if (p/'handedness-audit.json').exists() else '')
                 +(f' · <a href="{p.name}/runtime/watch-runtime-preview.blend">Exported asset scene</a> · <a href="{p.name}/runtime/asset-report.json">Asset receipt</a> · <a href="{p.name}/runtime/fbx-roundtrip.json">FBX audit</a>' if (p/'runtime/asset-report.json').exists() else '')
                 +f'</p><div class="grid">{images}</div></section>')
refs=''.join(f'<a href="references/{esc(p.name)}"><img src="references/{esc(p.name)}"></a>' for p in (ROOT/'references').iterdir())
(ROOT/'review.html').write_text('''<!doctype html><meta charset="utf-8"><title>Horzine wrist panel — detail iterations</title>
<style>body{margin:0 auto;padding:36px;max-width:1560px;background:#141819;color:#e0e6e3;font:16px/1.5 system-ui}h1{font-size:32px}h2{margin-top:0}a{color:#83d1cd}section{padding:24px;margin:28px 0;background:#1e2425;border:1px solid #3a4647;border-radius:12px}span{float:right;color:#dfbd77}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}img{width:100%;display:block;border-radius:5px}.refs{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}p{max-width:1050px}</style>
<h1>Horzine wrist panel · detail review</h1><p>Every saved iteration and the original references. Scores are the independent visual reviewer's judgment; only 100 meets the requested pass threshold. Authoring previews use sample telemetry and do not establish headset or runtime acceptance.</p>
<p>Iterations (newest first below): '''+' · '.join(navigation)+'''</p>
<section><h2>User references</h2><div class="refs">'''+refs+'''</div></section>
<section><h2>Baseline · revision 26</h2><p>Preserved before this task.</p><div class="grid"><img src="baseline-26/26-runtime-detail.png"><img src="baseline-26/26-runtime-baked.png"></div><p><a href="baseline-26/26-horzine-study.blend">Original Blender version</a></p></section>'''+''.join(reversed(cards)),encoding='utf-8')
print(ROOT/'review.html')
