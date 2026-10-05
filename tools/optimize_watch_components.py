"""Runtime-only reductions; authoring objects are never modified.

Keep frame/plate outlines and working clearances. Surface markings are baked;
sample curves and small chamfers according to their physical size. Projection
groups isolate neighbouring layers so a reduced bevel cannot hit another part.
"""
import math
import bpy

YARNS=('Case | roller woven','Case | keeper woven','Case | keeper compressed',
       'Case | webbing short','Case | keeper short frayed')
WOVEN=('Case | textured webbing roller','Case | rounded compressed nylon keeper',
       'Case | inset keeper webbing','Case | woven latch feed')
MARKS=('Horzine ','Case | chipped finish','Case | localized oxide pit','Case | badge lower lip wear')

def projection_group(name):
    if name.startswith(YARNS+WOVEN):return 'woven assembly'
    if name.startswith('Horzine '):return 'Case | badge recessed face'
    if name.startswith('Case | badge lower lip wear'):return 'Case | badge bevel perimeter'
    if name.startswith(('Case | chipped finish','Case | localized oxide pit')):return 'Watch | six level bevel housing'
    return name

def omitted(name):return name.startswith(YARNS+MARKS)

def simplify_copy(ob):
    """Reduce construction sampling, not arbitrary silhouette decimation."""
    if ob.type=='CURVE':
        ob.data.bevel_resolution=1
        ob.data.resolution_u=6 if ob.name.startswith('Conduit |') else 4
        for sp in list(ob.data.splines):
            if sp.type!='POLY' or len(sp.points)<40:continue
            points=[p.co.copy() for p in sp.points]
            cyclic=sp.use_cyclic_u
            # A 0.7 mm binding needs fewer angular samples than the strap itself.
            target=32 if len(points)>70 else 24
            if ob.name.startswith('Cuff | webbing band') and len(points)==96:
                # Match the ribbon stations exactly so a binding chord cannot
                # sink through a different ribbon chord between sample points.
                indices=list(range(0,96,2))
                if not cyclic:indices.append(95)
            else:
                indices=sorted(set(round(i*(len(points) if cyclic else len(points)-1)/
                                         (target if cyclic else target-1))%len(points) for i in range(target)))
            ob.data.splines.remove(sp)
            sp=ob.data.splines.new('POLY');sp.points.add(len(indices)-1);sp.use_cyclic_u=cyclic
            for p,i in zip(sp.points,indices):p.co=points[i]
    for mod in ob.modifiers:
        if mod.type=='BEVEL':mod.segments=1
    if ob.type!='MESH':return
    me=ob.data
    # Cylinders are authored as two rings and two caps. Reduce only verified
    # primitive topology; leave shaped clasp and housing outlines untouched.
    caps=[p for p in me.polygons if len(p.vertices)>=20]
    if len(caps)==2 and len(caps[0].vertices)==len(caps[1].vertices) and len(me.vertices)==2*len(caps[0].vertices):
        count=len(caps[0].vertices)
        if len(me.polygons)==count+2:
            keep=range(0,count,2)
            # Blender cylinder storage alternates bottom/top vertices.
            rings=sorted({round(v.co.z,6) for v in me.vertices})
            radii=[math.hypot(v.co.x,v.co.y) for v in me.vertices]
            centered=abs(sum(v.co.x for v in me.vertices))<1e-5 and abs(sum(v.co.y for v in me.vertices))<1e-5
            circular=max(radii)-min(radii)<1e-5
            if len(rings)==2 and centered and circular:
                bottom=sorted([v for v in me.vertices if abs(v.co.z-rings[0])<1e-5],key=lambda v:math.atan2(v.co.y,v.co.x))
                top=sorted([v for v in me.vertices if abs(v.co.z-rings[1])<1e-5],key=lambda v:math.atan2(v.co.y,v.co.x))
                verts=[v.co.copy() for ring in (bottom,top) for i,v in enumerate(ring) if i in keep]
                n=len(verts)//2;faces=[tuple(reversed(range(n))),tuple(range(n,2*n))]
                faces += [(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
                new=bpy.data.meshes.new(me.name+' runtime rings');new.from_pydata(verts,[],faces)
                for ma in me.materials:new.materials.append(ma)
                for p in new.polygons:p.use_smooth=True
                ob.data=new
    # Straps use 48 instead of 96 stations. Keep the saddle's sampled contour:
    # chords across its raised lips can protrude into otherwise clear bands and
    # folded feeds. Its chamfers are still reduced above (1552 vs 2380 triangles).
    me=ob.data
    if ob.name.startswith('Cuff | webbing band') and len(me.vertices)==192 and len(me.polygons) in (95,96):
        cyclic=len(me.polygons)==96
        ids=list(range(0,96,2))
        if not cyclic:ids.append(95)
        n=len(ids);verts=[me.vertices[r*96+i].co.copy() for r in range(2) for i in ids]
        faces=[(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n if cyclic else n-1)]
        # Reflected authoring meshes reverse their faces. Reusing a fixed index
        # order would invert the cloth and its solidify direction, burying the
        # binding and making high-to-low projection miss the outside surface.
        a,b,c=(verts[i] for i in faces[0][:3])
        if (b-a).cross(c-a).dot(me.polygons[0].normal)<0:
            faces=[tuple(reversed(f)) for f in faces]
        new=bpy.data.meshes.new(me.name+' runtime stations');new.from_pydata(verts,[],faces)
        for ma in me.materials:new.materials.append(ma)
        for p in new.polygons:p.use_smooth=True
        ob.data=new

def buried_face(name, normal, triangle):
    # These inward caps are completely enclosed by neighbouring solid layers.
    return (name.startswith(('Case | badge recessed face','Case | badge bevel perimeter','Case | badge isolated gasket')) and normal.z<-.99) or (name.startswith('Watch | layered armor foundation') and normal.z>.99) or (name.startswith('Case | selector thumbwheel') and max(v.z for v in triangle)<4.055)
