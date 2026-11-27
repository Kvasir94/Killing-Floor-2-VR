"""Blender review renders and contact sheets for the melee zone and grip data.

Three steps, all offline (no game):

  python -I tools/re/melee_zone_review.py export
      writes build/melee-zone-review/data/<slug>.json: the weapon mesh (game
      space), the fitted zones (melee_zones.json), the grip bands
      (melee_grips.json) and the Idle / Brace_loop rig pose in Root space.
  In Blender (MCP execute_blender_code, Blender 4+/5):
      ns = {"__file__": r"D:/KF2-VR/tools/re/melee_zone_review.py", "__name__": "review"}
      exec(open(ns["__file__"], encoding="utf-8").read(), ns); ns["render_all"]()
      builds a private scene (KF2VR_MeleeZoneReview), renders a side view and
      an eye view per weapon to build/melee-zone-review/renders/, then removes
      the scene and its data, leaving the user's scenes untouched.
  python tools/re/melee_zone_review.py sheet      (needs Pillow)
      writes one contact sheet per class to build/melee-zone-review/.

Game space is left-handed; the renders put it under a Y-mirrored empty so the
images are not mirrored. The eye camera sits at the rig Root looking along
game +Y (forward) with +Z up, so the right hand must appear on the right.
Colours: handle green, head red, edge dark red, guard yellow, collar/ricasso
teal, pommel purple, shaft cyan, point magenta; right-hand grip bands blue,
left-hand orange (thick ring p10-p90, thin rings min/max, ball = Idle).
"""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/melee-zone-review"
CLASSES = {
    "blades": ["edged-katana", "edged-zweihander", "edged-ionthruster", "edged-scythe"],
    "axes": ["edged-fireaxe", "edged-abominationaxe"],
    "blunt": ["crovel", "pulverizer", "blunt-chainbat", "blunt-medicbat"],
    "knives": ["knife-berserker", "knife-commando", "knife-demolitionist", "knife-fieldmedic",
               "knife-firebug", "knife-gunslinger", "knife-sharpshooter", "knife-support",
               "knife-survivalist", "knife-swat"],
    "gauntlets-shield": ["blunt-powergloves", "blastbrawlers", "blunt-maceandshield"],
}


def export():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from melee_rig import BUILD, Rig, Anim, anim_path, game, rotate, r
    (OUT / "data").mkdir(parents=True, exist_ok=True)
    for slugs in CLASSES.values():
        for slug in slugs:
            rig = Rig(slug)
            zones = json.loads((BUILD / f"{slug}-audit/melee_zones.json").read_text(encoding="utf-8"))
            grips = json.loads((BUILD / f"{slug}-audit/melee_grips.json").read_text(encoding="utf-8"))
            path, _ = anim_path(slug)
            anim = Anim(path)
            poses = {}
            for seq in ("Idle", "Brace_loop"):
                if seq not in anim.sequences:
                    continue
                pos, rot = anim.pose(rig, seq, 0)
                def frame(bone):
                    i = rig.index[bone]
                    cols = [game(rotate(rot[i], game(e))) for e in ((1, 0, 0), (0, 1, 0), (0, 0, 1))]
                    return dict(origin=r(game(pos[i])), x=r(cols[0], 4), y=r(cols[1], 4), z=r(cols[2], 4))
                chains = {s: [r(game(pos[rig.index[f"{s}{b}_1stP"]])) for b in ("Arm", "ForeArm", "Hand")]
                          + [r(game(pos[rig.index[f"{s}Hand{f}{j}_1stP"]])) for f in ("Middle",) for j in (1, 2, 3)]
                          for s in ("Right", "Left")}
                poses[seq] = dict(bones={p["bone"]: frame(p["bone"]) for p in zones["parts"]}, arms=chains)
            parts = []
            gparts = {g["bone"]: g for g in grips["parts"]}
            for p in zones["parts"]:
                seq = p["mesh_pose"].split()[0]
                pts = rig.weapon_points(p["bone"], pose=anim.pose(rig, seq, 0) if seq != "bind" else None)
                ids = {pid: n for n, (_, pid, _) in enumerate(pts)}
                tris = [[ids[a] for a in t] for t, _ in rig.weapon_triangles(set(ids))]
                g = gparts.get(p["bone"], {})
                parts.append(dict(bone=p["bone"], kind=p["kind"], long_axis=p["long_axis"],
                                  verts=[r(v, 2) for v, _, _ in pts], tris=tris, zones=p["zones"],
                                  profile=p["profile"], grip=g.get("summary"),
                                  guard=g.get("guard_pose")))
            (OUT / "data" / f"{slug}.json").write_text(json.dumps(dict(slug=slug, parts=parts, poses=poses)),
                                                       encoding="utf-8")
            print("exported", slug)


COLOURS = dict(handle=(0.1, 0.75, 0.2), head=(0.9, 0.1, 0.1), guard=(1.0, 0.85, 0.0),
               collar=(0.0, 0.6, 0.6), ricasso=(0.3, 0.9, 0.8), pommel=(0.6, 0.2, 0.9),
               shaft=(0.0, 0.8, 1.0), point=(1.0, 0.0, 0.9), edge=(0.5, 0.0, 0.0), top=(1.0, 0.5, 0.7),
               body=(0.6, 0.6, 0.6), face=(0.9, 0.1, 0.1), Right=(0.1, 0.3, 1.0), Left=(1.0, 0.5, 0.0))


def render_all(slugs=None, size=(900, 640)):
    import bpy
    import math
    from mathutils import Vector, Matrix
    data_dir, rend = OUT / "data", OUT / "renders"
    rend.mkdir(parents=True, exist_ok=True)
    win = bpy.context.window
    keep = win.scene if win else None
    scene = bpy.data.scenes.new("KF2VR_MeleeZoneReview")
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.render.resolution_x, scene.render.resolution_y = size
    scene.render.film_transparent = False
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "OBJECT"
    scene.display.shading.show_shadows = False
    scene.display.shading.show_cavity = True
    world = bpy.data.worlds.new("KF2VR_MeleeZoneReview")
    world.color = (0.08, 0.08, 0.09)
    scene.world = world
    made = []

    def link(obj):
        scene.collection.objects.link(obj)
        made.append(obj)
        return obj

    def colour(name):
        key = name.split("_")[0].rstrip("0123456789")
        return (*COLOURS.get(key, (0.8, 0.8, 0.8)), 1.0)

    def capsule(name, a, b, radius, parent, wire=True):
        a, b = Vector(a), Vector(b)
        d = b - a
        length = d.length
        bpy_mesh = bpy.data.meshes.new(name)
        import bmesh
        bm = bmesh.new()
        seg, rings = 20, 6
        # Hemisphere-capped cylinder along +Z from 0 to length.
        caps = [math.pi / 2 * i / rings for i in range(rings + 1)]
        rows = [(radius * math.cos(a - math.pi / 2), radius * math.sin(a - math.pi / 2)) for a in caps]
        rows += [(radius * math.cos(a), length + radius * math.sin(a)) for a in caps]
        rows = [(max(rr, 1e-3), zz) for rr, zz in rows]
        grid = []
        for rr, zz in rows:
            grid.append([bm.verts.new((rr * math.cos(2 * math.pi * k / seg), rr * math.sin(2 * math.pi * k / seg), zz))
                         for k in range(seg)])
        for i in range(len(grid) - 1):
            for k in range(seg):
                bm.faces.new((grid[i][k], grid[i][(k + 1) % seg], grid[i + 1][(k + 1) % seg], grid[i + 1][k]))
        bm.to_mesh(bpy_mesh); bm.free()
        obj = link(bpy.data.objects.new(name, bpy_mesh))
        z = d.normalized() if length > 1e-6 else Vector((0, 0, 1))
        rot = z.to_track_quat("Z", "Y").to_matrix().to_4x4()
        obj.matrix_basis = Matrix.Translation(a) @ rot
        obj.parent = parent
        obj.color = colour(name)
        if wire:
            m = obj.modifiers.new("wire", "WIREFRAME")
            m.thickness = max(0.08, min(0.25, radius * 0.06))
        return obj

    def ball(name, p, radius, parent, col=None):
        bpy_mesh = bpy.data.meshes.new(name)
        import bmesh
        bm = bmesh.new()
        bmesh.ops.create_uvsphere(bm, u_segments=12, v_segments=8, radius=radius)
        bm.to_mesh(bpy_mesh); bm.free()
        obj = link(bpy.data.objects.new(name, bpy_mesh))
        obj.location = p
        obj.parent = parent
        obj.color = col or colour(name)
        return obj

    def ring(name, centre, axis, radius, thick, parent, col):
        bpy_mesh = bpy.data.meshes.new(name)
        import bmesh
        bm = bmesh.new()
        seg, tube = 28, 6
        grid = []
        for i in range(seg):
            a = 2 * math.pi * i / seg
            row = []
            for j in range(tube):
                b = 2 * math.pi * j / tube
                rr = radius + thick * math.cos(b)
                row.append(bm.verts.new((rr * math.cos(a), rr * math.sin(a), thick * math.sin(b))))
            grid.append(row)
        for i in range(seg):
            for j in range(tube):
                bm.faces.new((grid[i][j], grid[(i + 1) % seg][j], grid[(i + 1) % seg][(j + 1) % tube], grid[i][(j + 1) % tube]))
        bm.to_mesh(bpy_mesh); bm.free()
        obj = link(bpy.data.objects.new(name, bpy_mesh))
        rot = Vector(axis).to_track_quat("Z", "Y").to_matrix().to_4x4()
        obj.matrix_basis = Matrix.Translation(Vector(centre)) @ rot
        obj.parent = parent
        obj.color = (*col, 1.0)
        return obj

    def weapon(part, parent, zones=True, grips=True):
        m = bpy.data.meshes.new(part["bone"])
        m.from_pydata([tuple(v) for v in part["verts"]], [], [tuple(t) for t in part["tris"]])
        obj = link(bpy.data.objects.new("mesh_" + part["bone"], m))
        obj.parent = parent
        obj.color = (0.72, 0.72, 0.7, 1.0)
        if not zones:
            return obj
        for name, z in part["zones"].items():
            if name == "reach":
                continue
            if "polyline" in z:
                line = z["polyline"]
                for n in range(len(line) - 1):
                    capsule(f"edge_line{n}", line[n], line[n + 1], z["radius"], parent, wire=False)
            elif "segments" in z and name in ("head", "handle"):
                for n, s in enumerate(z["segments"]):
                    capsule(f"{name}_seg{n}", s["start"], s["end"], s["radius"], parent)
            elif "at" in z:
                ball("top_pivot", z["at"], 1.2, parent)
            elif "start" in z:
                capsule(name if not name.startswith("edge") else "edge_" + name, z["start"], z["end"], z["radius"], parent)
            elif "tip" in z:
                ball("point_tip" if name == "point" else "point_" + name, z["tip"], 0.9, parent)
                tip, ax = Vector(z["tip"]), Vector(z["axis"])
                capsule("point_axis" if name == "point" else "point_ax_" + name, tip - ax * 10, tip, 0.25, parent, wire=False)
            elif "normal" in z:
                c, nrm = Vector(z["centre"]), Vector(z["normal"])
                ring("face_rim", c, nrm, z["radius"], 0.6, parent, COLOURS["face"])
                capsule("face_normal", c, c + nrm * 12, 0.4, parent, wire=False)
        g = part.get("grip") if grips else None
        if g and part["kind"] not in ("gauntlet", "shield"):
            axis = Vector(part["long_axis"])
            prof = part["profile"]
            def at(t):
                row = min(prof, key=lambda q: abs(q[0] - t))
                return Vector((row[3], row[4], row[5])), row[1] * 0.5
            for side in ("Right", "Left"):
                h = g[side]
                if h["along_min"] is None or h["on_weapon_fraction"] < 0.1:
                    continue
                col = COLOURS[side]
                for key, thick in (("along_min", 0.25), ("along_max", 0.25), ("along_p10", 0.6), ("along_p90", 0.6)):
                    c, rad = at(h[key])
                    ring(f"{side}_{key}", (c.x, c.y, h[key]), axis, rad + (1.6 if side == "Right" else 2.6), thick, parent, col)
                if h["idle_along"] is not None:
                    c, rad = at(h["idle_along"])
                    ball(f"{side}_idle", (c.x + rad + 1.5, c.y, h["idle_along"]), 1.0, parent, (*col, 1.0))
        return obj

    def mirror_root(name):
        e = link(bpy.data.objects.new(name, None))
        e.scale = (1, -1, 1)
        return e

    def render(path, cam):
        scene.camera = cam
        scene.render.filepath = str(path)
        bpy.ops.render.render(write_still=True, scene=scene.name)

    try:
        for slug in slugs or [s for v in CLASSES.values() for s in v]:
            data = json.loads((data_dir / f"{slug}.json").read_text(encoding="utf-8"))
            for o in list(made):
                bpy.data.objects.remove(o, do_unlink=True)
            made.clear()
            # Side view: each part in its own bone space, laid side by side.
            root = mirror_root("side_root")
            offset = 0.0
            allv = []
            for n, part in enumerate(data["parts"]):
                holder = link(bpy.data.objects.new("part_" + part["bone"], None))
                holder.parent = root
                xs = [v[0] for v in part["verts"]]
                holder.location = (offset - min(xs), 0, 0)
                weapon(part, holder)
                allv += [(v[0] + offset - min(xs), -v[1], v[2]) for v in part["verts"]]
                offset += (max(xs) - min(xs)) + 25
            lo = Vector([min(v[i] for v in allv) for i in range(3)])
            hi = Vector([max(v[i] for v in allv) for i in range(3)])
            ext = hi - lo
            cam = link(bpy.data.objects.new("cam_side", bpy.data.cameras.new("cam_side")))
            cam.data.type = "ORTHO"
            cam.data.clip_end = 2000
            centre = (lo + hi) / 2
            thin_y = ext.y <= ext.x or len(data["parts"]) > 1
            if thin_y:   # look along -Y (Blender) = +Y game: X across, Z up
                cam.location = centre + Vector((0, -300, 0))
                cam.rotation_euler = (math.pi / 2, 0, 0)
                span_w, span_h = ext.x, ext.z
            else:        # look along +X: Y across, Z up
                cam.location = centre + Vector((-300, 0, 0))
                cam.rotation_euler = (math.pi / 2, 0, -math.pi / 2)
                span_w, span_h = ext.y, ext.z
            aspect = size[0] / size[1]
            cam.data.ortho_scale = max(span_w, span_h * aspect) * 1.15 + 6
            if data["parts"][0]["kind"] == "gauntlet":
                cam.location = centre + Vector((0, 0, 300))
                cam.rotation_euler = (0, 0, 0)
                cam.data.ortho_scale = max(ext.x, ext.y * aspect) * 1.15 + 6
            render(rend / f"{slug}_side.png", cam)
            # Eye view: the Idle pose in rig Root space, camera at the root.
            for o in list(made):
                bpy.data.objects.remove(o, do_unlink=True)
            made.clear()
            for seq in ("Idle", "Brace_loop"):
                if seq not in data["poses"]:
                    continue
                pose = data["poses"][seq]
                root = mirror_root("eye_root")
                seen = set()
                for part in data["parts"]:
                    if part["bone"] in seen:   # the folded Scythe: eye views show unfolded
                        continue
                    seen.add(part["bone"])
                    f = pose["bones"][part["bone"]]
                    holder = link(bpy.data.objects.new("bone_" + part["bone"], None))
                    holder.parent = root
                    holder.matrix_basis = Matrix(((f["x"][0], f["y"][0], f["z"][0], f["origin"][0]),
                                                  (f["x"][1], f["y"][1], f["z"][1], f["origin"][1]),
                                                  (f["x"][2], f["y"][2], f["z"][2], f["origin"][2]),
                                                  (0, 0, 0, 1)))
                    weapon(part, holder, grips=False)
                for side, chain in pose["arms"].items():
                    for i in range(len(chain) - 1):
                        capsule(f"{side}_arm{i}", chain[i], chain[i + 1], 1.6 if i < 2 else 0.8, root, wire=False)
                cam = link(bpy.data.objects.new("cam_eye", bpy.data.cameras.new("cam_eye")))
                cam.data.lens_unit = "FOV"
                cam.data.angle = math.radians(100)
                cam.data.clip_start = 1
                cam.data.clip_end = 1000
                # Game forward +Y is Blender -Y under the mirror; up +Z; right
                # -X. Pulled 25 uu back and pitched 20 deg down so the whole
                # weapon and both hands are in frame.
                look = Matrix(((-1, 0, 0, 0), (0, 0, 1, 25), (0, 1, 0, 4), (0, 0, 0, 1)))
                cam.matrix_basis = look @ Matrix.Rotation(math.radians(-20), 4, "X")
                render(rend / f"{slug}_eye_{seq}.png", cam)
                for o in list(made):
                    bpy.data.objects.remove(o, do_unlink=True)
                made.clear()
    finally:
        for o in list(made):
            bpy.data.objects.remove(o, do_unlink=True)
        for coll in (bpy.data.meshes, bpy.data.cameras):
            for d in list(coll):
                if d.users == 0:
                    coll.remove(d)
        bpy.data.scenes.remove(scene)
        bpy.data.worlds.remove(world)
        if win and keep:
            win.scene = keep
    return sorted(p.name for p in rend.glob("*.png"))


def sheet():
    from PIL import Image, ImageDraw
    rend = OUT / "renders"
    for cls, slugs in CLASSES.items():
        cells = []
        for slug in slugs:
            row = [rend / f"{slug}_{v}.png" for v in ("side", "eye_Idle", "eye_Brace_loop")]
            cells.append((slug, [Image.open(p) if p.exists() else None for p in row]))
        w, h = 600, 427
        img = Image.new("RGB", (w * 3, (h + 24) * len(cells)), (20, 20, 22))
        d = ImageDraw.Draw(img)
        for i, (slug, row) in enumerate(cells):
            y = i * (h + 24)
            d.text((6, y + 5), f"{slug}   [side: bone space]   [eye: Idle]   [eye: Brace_loop]", fill=(230, 230, 230))
            for j, im in enumerate(row):
                if im:
                    img.paste(im.convert("RGB").resize((w, h)), (j * w, y + 24))
        path = OUT / f"contact-{cls}.png"
        img.save(path)
        print(path)


# ------------------------------------------------------------ blade edges
# Review of measure_melee_blades.py (build/melee-zone-review/blade-data/*.json):
#   ns = {"__file__": r"D:/KF2-VR/tools/re/melee_zone_review.py", "__name__": "review"}
#   exec(open(ns["__file__"], encoding="utf-8").read(), ns); ns["render_blades"]()
#   python tools/re/melee_zone_review.py blade_sheet
# The mesh carries its stock diffuse texture (exported with UModel -png into
# build/melee-blade-tex/<slug>) because edge bevels and saw teeth are often
# painted rather than modelled. Per segment: edge line red, spine line blue
# (red too when the spine is a second edge), flat normals green, segment
# boundaries and centreline white, points yellow (ball at the tip, rod along
# the axis). Views: side (along the main blade's flat normal), edge-on (from
# the edge toward the spine) and end-on (from the tip down the blade).
BLADE_CLASSES = {
    "blades": ["edged-katana", "edged-zweihander", "edged-ionthruster", "edged-scythe"],
    "axes-crovel": ["edged-fireaxe", "edged-abominationaxe", "crovel", "blunt-medicbat"],
    "knives": CLASSES["knives"],
}
BLADE_COLOURS = dict(edge=(0.95, 0.05, 0.05), spine=(0.1, 0.35, 1.0), flat=(0.1, 0.85, 0.2),
                     point=(1.0, 0.9, 0.0), node=(1.0, 1.0, 1.0), centre=(0.9, 0.9, 0.9),
                     plate=(0.1, 0.85, 0.2))


def blade_views(data, entry=None):
    """[(name, view direction, up)] in game space for the review cameras."""
    def u(v):
        n = sum(x * x for x in v) ** 0.5
        return tuple(x / n for x in v)
    blades = [e for e in data["entries"] if e["type"] == "blade" and (entry is None or e["name"] == entry)]
    plate = next((e for e in data["entries"] if e["type"] == "plate"), None)
    if blades:
        segs = blades[0]["segments"]
        main = max(segs, key=lambda s: s["length"])
        flat, edge = main["flat_normal"], main["edge_dir"]
        chord = u(tuple(b - a for a, b in zip(segs[0]["start"], segs[-1]["end"])))
    elif plate:
        flat, edge, chord = plate["normal"], plate["width_axis"], plate["length_axis"]
    else:
        flat, edge, chord = (0, 1, 0), (1, 0, 0), (0, 0, 1)
    # Long axis across the (landscape) frame; the edge-on view is tilted 30
    # degrees toward a flat so the bevel and the edge line both show.
    c30, s30 = 0.866, 0.5
    oblique = u(tuple(-c30 * e - s30 * f for e, f in zip(edge, flat)))
    return [("side", tuple(-x for x in flat), u(edge)),
            ("edge", oblique, u(tuple(s30 * e - c30 * f for e, f in zip(edge, flat))))]


def review_targets(data):
    """[(entry name or None for the whole head, file suffix)]: one review row
    per blade entry, plus a whole view when the weapon has points or plates."""
    blades = [e["name"] for e in data["entries"] if e["type"] == "blade"]
    out = [(n, "" if i == 0 else "_" + n) for i, n in enumerate(blades)]
    if data.get("kind") == "scythe" or any(e["type"] != "blade" and not (e["type"] == "point" and e["name"] == "tip")
                                           for e in data["entries"]):
        out.append((None, "_all" if out else ""))
    return out


def render_blades(slugs=None, size=(900, 640), closeups=None):
    """Review renders; with closeups=[(slug, tag, centre, view, up, ortho
    span)] (game space) only those close-ups, to blade-closeups/, for
    settling an edge side by eye."""
    import bpy
    import bmesh
    from mathutils import Vector, Matrix
    data_dir, rend = OUT / "blade-data", OUT / "blade-renders"
    rend.mkdir(parents=True, exist_ok=True)
    (OUT / "blade-closeups").mkdir(parents=True, exist_ok=True)
    if closeups:
        slugs = sorted({c[0] for c in closeups})
    win = bpy.context.window
    keep = win.scene if win else None
    scene = bpy.data.scenes.new("KF2VR_MeleeBladeReview")
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.render.resolution_x, scene.render.resolution_y = size
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "TEXTURE"
    scene.display.shading.show_shadows = False
    scene.display.shading.show_cavity = True
    world = bpy.data.worlds.new("KF2VR_MeleeBladeReview")
    world.color = (0.08, 0.08, 0.09)
    scene.world = world
    made, mats, imgs = [], [], []

    def link(obj):
        scene.collection.objects.link(obj)
        made.append(obj)
        return obj

    def material(name, col):
        m = bpy.data.materials.new("KF2VR_BR_" + name)
        m.diffuse_color = (*col, 1.0)
        mats.append(m)
        return m

    cols = {k: material(k, v) for k, v in BLADE_COLOURS.items()}

    def tube(name, a, b, radius, mat, parent):
        a, b = Vector(a), Vector(b)
        d = b - a
        if d.length < 1e-4:
            return
        m = bpy.data.meshes.new("KF2VR_BR_" + name)
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=True, segments=10, radius1=radius, radius2=radius, depth=d.length)
        bm.to_mesh(m); bm.free()
        o = link(bpy.data.objects.new(name, m))
        rot = d.normalized().to_track_quat("Z", "Y").to_matrix().to_4x4()
        o.matrix_basis = Matrix.Translation((a + b) / 2) @ rot
        o.data.materials.append(mat)
        o.parent = parent

    def ball(name, p, radius, mat, parent):
        m = bpy.data.meshes.new("KF2VR_BR_" + name)
        bm = bmesh.new()
        bmesh.ops.create_uvsphere(bm, u_segments=14, v_segments=8, radius=radius)
        bm.to_mesh(m); bm.free()
        o = link(bpy.data.objects.new(name, m))
        o.location = p
        o.data.materials.append(mat)
        o.parent = parent

    V = Vector
    try:
        for slug in slugs or [s for v in BLADE_CLASSES.values() for s in v]:
            data = json.loads((data_dir / f"{slug}.json").read_text(encoding="utf-8"))
            for o in list(made):
                bpy.data.objects.remove(o, do_unlink=True)
            made.clear()
            root = link(bpy.data.objects.new("mirror_root", None))
            root.scale = (1, -1, 1)   # game space is left-handed
            m = bpy.data.meshes.new("KF2VR_BR_weapon")
            m.from_pydata([tuple(v) for v in data["verts"]], [], [tuple(t) for t in data["tris"]])
            if data.get("uvs"):
                uv = m.uv_layers.new(name="UV")
                for poly, corners in zip(m.polygons, data["uvs"]):
                    for li, c in zip(poly.loop_indices, corners):
                        uv.data[li].uv = (c[0], 1.0 - c[1])
            wm = bpy.data.materials.new("KF2VR_BR_weapon")
            wm.diffuse_color = (0.7, 0.7, 0.68, 1.0)
            mats.append(wm)
            if data.get("texture"):
                img = bpy.data.images.load(data["texture"])
                img.alpha_mode = "NONE"   # some diffuse maps carry a mask in alpha
                imgs.append(img)
                wm.use_nodes = True
                nt = wm.node_tree
                node = nt.nodes.new("ShaderNodeTexImage")
                node.image = img
                nt.nodes.active = node
                bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
                if bsdf:
                    nt.links.new(node.outputs["Color"], bsdf.inputs["Base Color"])
            m.materials.append(wm)
            w = link(bpy.data.objects.new("weapon", m))
            w.parent = root
            focus = {}
            for e in data["entries"]:
                f = focus.setdefault(e["name"], [])
                if e["type"] == "blade":
                    tr = 0.08 if e["length"] < 40 else 0.25
                    for sg in e["segments"]:
                        a, b = V(sg["start"]), V(sg["end"])
                        ed, fn = V(sg["edge_dir"]), V(sg["flat_normal"])
                        ea, eb = a + ed * sg["edge_reach_start"], b + ed * sg["edge_reach_end"]
                        sa, sb = a - ed * sg["spine_reach_start"], b - ed * sg["spine_reach_end"]
                        tube("edge", ea, eb, tr, cols["edge"], root)
                        tube("spine", sa, sb, tr, cols["edge"] if sg["spine"] == "edge" else cols["spine"], root)
                        tube("centre", a, b, tr * 0.4, cols["centre"], root)
                        tube("node", sa, ea, tr * 0.5, cols["node"], root)
                        mid = (a + b) / 2
                        h = sg["half_thickness"] + 4 * tr
                        tube("flat", mid - fn * h, mid + fn * h, tr * 0.8, cols["flat"], root)
                        f += [ea, eb, sa, sb]
                    last = e["segments"][-1]
                    tube("node", V(last["end"]) - V(last["edge_dir"]) * last["spine_reach_end"],
                         V(last["end"]) + V(last["edge_dir"]) * last["edge_reach_end"], tr * 0.5, cols["node"], root)
                elif e["type"] == "point":
                    tip, ax = V(e["tip"]), V(e["axis"])
                    ball("point", tip, 0.5, cols["point"], root)
                    tube("point_axis", tip - ax * 8, tip + ax * 2, 0.15, cols["point"], root)
                    f += [tip, tip - ax * 6]
                elif e["type"] == "edge_line":
                    line = [V(p) for p in e["polyline"]]
                    for p, q in zip(line, line[1:]):
                        tube("edge", p, q, 0.3, cols["edge"], root)
                    f += line
                elif e["type"] == "plate":
                    c, n = V(e["centre"]), V(e["normal"])
                    tube("flat", c - n * 4, c + n * 4, 0.35, cols["plate"], root)

            def mirror(v):
                return Vector((v[0], -v[1], v[2]))
            def shoot(path, pts, view, up, span=None, persp=False):
                d = mirror(view).normalized()
                upv = mirror(up)
                upv = (upv - d * upv.dot(d)).normalized()
                right = d.cross(upv)
                centre = sum(pts, Vector()) / len(pts)
                xs = [(p - centre).dot(right) for p in pts]
                ys = [(p - centre).dot(upv) for p in pts]
                cam = link(bpy.data.objects.new("cam", bpy.data.cameras.new("KF2VR_BR_cam")))
                cam.data.type = "ORTHO"
                cam.data.clip_end = 1000
                aspect = size[0] / size[1]
                if span is None:
                    span = max(max(xs) - min(xs), (max(ys) - min(ys)) * aspect) * 1.15 + 2
                cam.data.ortho_scale = span
                off = right * (max(xs) + min(xs)) / 2 + upv * (max(ys) + min(ys)) / 2
                rot = Matrix((right, upv, -d)).transposed().to_4x4()
                cam.matrix_basis = Matrix.Translation(centre + off - d * 300) @ rot
                scene.camera = cam
                scene.render.filepath = str(path)
                bpy.ops.render.render(write_still=True, scene=scene.name)

            for target, suffix in (review_targets(data) if not closeups else []):
                pts = focus[target] if target else [p for v in focus.values() for p in v]
                pts = [mirror(p) for p in (pts or [V(v) for v in data["verts"]])]
                for name, view, up in blade_views(data, target):
                    shoot(rend / f"{slug}{suffix}_{name}.png", pts, view, up)
            for cs, tag, c, view, up, span in closeups or []:
                if cs == slug:
                    shoot(OUT / "blade-closeups" / f"{slug}_{tag}.png", [mirror(V(c))], view, up, span)
    finally:
        for o in list(made):
            bpy.data.objects.remove(o, do_unlink=True)
        for coll in (bpy.data.meshes, bpy.data.cameras):
            for d in list(coll):
                if d.users == 0 and d.name.startswith("KF2VR_BR_"):
                    coll.remove(d)
        for mt in mats:
            bpy.data.materials.remove(mt)
        for im in imgs:
            bpy.data.images.remove(im)
        bpy.data.scenes.remove(scene)
        bpy.data.worlds.remove(world)
        if win and keep:
            win.scene = keep
    return sorted(p.name for p in rend.glob("*.png"))


def draw_sections(entry, w, h):
    """Cross-section panel: the mid cut of each segment in (edge_dir,
    flat_normal) coordinates from the segment line, edge to the right. The
    thickness is drawn x3 so bevels show. Red tick = edge_reach, blue tick =
    spine_reach (red when the spine is a second edge)."""
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (w, h), (32, 32, 36))
    d = ImageDraw.Draw(img)
    segs = entry["segments"]
    n = len(segs)
    cols = 2 if n > 3 else 1
    rows = (n + cols - 1) // cols
    cw, ch = w // cols, (h - 16) // rows
    span = max(max(s["edge_reach"], s["spine_reach"]) for s in segs) * 1.15 + 0.1
    sx = (cw / 2 - 8) / span
    sy = min(sx * 3, (ch / 2 - 10) / max(max(s["half_thickness"] for s in segs) * 1.2, 0.05))
    d.text((4, 2), f"{entry['name']}: mid cut per segment, edge ->, thickness x{sy / sx:.1f}", fill=(220, 220, 220))
    for i, sg in enumerate(segs):
        x0, y0 = (i % cols) * cw, 16 + (i // cols) * ch
        cx, cy = x0 + cw / 2, y0 + ch / 2
        d.rectangle((x0 + 1, y0 + 1, x0 + cw - 2, y0 + ch - 2), outline=(70, 70, 76))
        d.line((cx - span * sx, cy, cx + span * sx, cy), fill=(70, 70, 76))
        for pw, pn in sg["_section"]["points"]:
            px, py = cx + pw * sx, cy - pn * sy
            d.ellipse((px - 1.5, py - 1.5, px + 1.5, py + 1.5), fill=(235, 235, 235))
        ex, spx = cx + sg["edge_reach"] * sx, cx - sg["spine_reach"] * sx
        d.line((ex, cy - 12, ex, cy + 12), fill=(240, 30, 30), width=2)
        d.line((spx, cy - 12, spx, cy + 12), fill=(240, 30, 30) if sg["spine"] == "edge" else (40, 110, 255), width=2)
        tag = f"#{sg['index']} t={sg['_section']['t']} {sg['edges']} spine={sg['spine']}"
        if sg.get("ambiguous"):
            tag += " AMBIG"
        d.text((x0 + 4, y0 + 3), tag, fill=(220, 220, 120) if sg.get("ambiguous") else (200, 200, 200))
    return img


def blade_sheet():
    from PIL import Image, ImageDraw
    rend, data_dir = OUT / "blade-renders", OUT / "blade-data"
    for cls, slugs in BLADE_CLASSES.items():
        rows = []
        for slug in slugs:
            data = json.loads((data_dir / f"{slug}.json").read_text(encoding="utf-8"))
            for target, suffix in review_targets(data):
                entry = next((e for e in data["entries"] if e["name"] == target), None)
                rows.append((slug, suffix, target, entry))
        w, h = 600, 427
        img = Image.new("RGB", (w * 3, (h + 24) * len(rows)), (20, 20, 22))
        d = ImageDraw.Draw(img)
        for i, (slug, suffix, target, entry) in enumerate(rows):
            y = i * (h + 24)
            d.text((6, y + 5), f"{slug} {target or 'all'}   [side: along the flat normal]   [edge-on, 30 deg toward "
                               f"a flat]   [sections]   red edge, blue spine, green flats, white centre and "
                               f"segment ends, yellow points", fill=(230, 230, 230))
            for j, v in enumerate(("side", "edge")):
                p = rend / f"{slug}{suffix}_{v}.png"
                if p.exists():
                    img.paste(Image.open(p).convert("RGB").resize((w, h)), (j * w, y + 24))
            if entry is not None and entry["type"] == "blade":
                img.paste(draw_sections(entry, w, h), (2 * w, y + 24))
        path = OUT / f"{cls}-blade-edges.png"
        img.save(path)
        print(path)


if __name__ == "__main__":
    {"export": export, "sheet": sheet, "blade_sheet": blade_sheet}[sys.argv[1]]()
