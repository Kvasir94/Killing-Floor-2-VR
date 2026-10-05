"""Use a physical left hand in the reference view without mirroring the dial face.

The legacy construction frame reflects the stock left hand. Restore anatomy,
then fit the unchanged display layout to that wrist. Production hand assets are
separate and are not rebuilt by this authoring correction.
"""
import bpy,bmesh
from mathutils import Matrix,Vector
from mathutils.bvhtree import BVHTree

WATCH=('Watch |','Case |','Horzine ','ID plate','Conduit |','Cuff |','Buckle ','Folded webbing','UI ')

def orient_left(g):
    scene=g['scene'];reflection=Matrix.Diagonal((1,-1,1,1))
    def tree(ob):
        bpy.context.view_layer.update();ev=ob.evaluated_get(bpy.context.evaluated_depsgraph_get())
        me=ev.to_mesh();me.calc_loop_triangles()
        result=BVHTree.FromPolygons([ob.matrix_world@v.co for v in me.vertices],
            [tuple(t.vertices) for t in me.loop_triangles],all_triangles=True)
        ev.to_mesh_clear();return result
    skin=next(o for o in scene.objects if o.name.startswith('LEFT | anatomical'))
    saddle=next(o for o in scene.objects if o.name=='Cuff | padded leather saddle')
    old_trees=(tree(skin),tree(saddle))
    def front(trees,x,z):
        hits=[t.ray_cast(Vector((x,-20,z)),Vector((0,1,0))) for t in trees]
        return min((h for h in hits if h[0] is not None),key=lambda h:h[3],default=None)
    for ob in scene.objects:
        anatomy=not ob.name.startswith(WATCH+('Review |',))
        wrap=ob.name.startswith(('Cuff | padded leather','Cuff | webbing band','Buckle ','Folded webbing'))
        if not (anatomy or wrap) or ob.type not in {'MESH','CURVE'}:continue
        local=ob.matrix_world.inverted()@reflection@ob.matrix_world
        if ob.type=='MESH':
            ob.data.transform(local)
            bm=bmesh.new();bm.from_mesh(ob.data);bmesh.ops.reverse_faces(bm,faces=list(bm.faces));bm.to_mesh(ob.data);bm.free()
        else:
            for sp in ob.data.splines:
                for p in sp.points:p.co=(*(local@p.co.xyz),1)
                for p in sp.bezier_points:
                    p.co=local@p.co;p.handle_left=local@p.handle_left;p.handle_right=local@p.handle_right
    new_trees=(tree(skin),tree(saddle))
    def delta(x,z):
        old=front(old_trees,x,z);new=front(new_trees,x,z)
        return new[0].y-old[0].y if old and new else 0
    shifts={x:delta(x,.5) for x in [-6.8344,-.988]}
    for ob in scene.objects:
        if ob.name.startswith('Cuff |') and not ob.name.startswith(('Cuff | padded leather','Cuff | webbing band')):
            xs=[(ob.matrix_world@Vector(p)).x for p in ob.bound_box];x=-6.8344 if (min(xs)+max(xs))*.5<-3 else -.988
            ob.location.y+=shifts[x]
        elif ob.name.startswith('Conduit |'):
            points=[ob.matrix_world@Vector(p) for p in ob.bound_box]
            if max(p.y for p in points)>=0:continue
            inv=ob.matrix_world.inverted()
            def routed(p):
                weight=max(0,min(1,(3.05-p.z)/2.0))
                return p+Vector((0,delta(p.x,p.z)*weight,0))
            if ob.type=='CURVE':
                for sp in ob.data.splines:
                    for p in sp.points:p.co=(*(inv@routed(ob.matrix_world@p.co.xyz)),1)
                    for p in sp.bezier_points:
                        for key in ['co','handle_left','handle_right']:setattr(p,key,inv@routed(ob.matrix_world@getattr(p,key)))
            else:
                center=sum(points,Vector())/len(points);ob.location.y+=routed(center).y-center.y
    bpy.context.view_layer.update()
    # Keep both surfaces of the folded feed outside the new cuff profile.
    for ob in scene.objects:
        if not ob.name.startswith('Cuff | adjuster webbing feed'):continue
        inv=ob.matrix_world.inverted();columns={}
        for v in ob.data.vertices:
            p=ob.matrix_world@v.co;columns.setdefault((round(p.x,5),round(p.z,5)),[]).append((v,p))
        for column in columns.values():
            p=column[0][1];hit=front(new_trees,p.x,p.z)
            if not hit:continue
            shift=min(0,hit[0].y-.045-max(p.y for v,p in column))
            for v,p in column:v.co=inv@(p+Vector((0,shift,0)))
        ob.data.update()
    scene['authoring_handedness']='left; thumb toward -Y, dorsal +Z, fingers +X'
    scene['handedness_correction']='Legacy reflected anatomy restored; display text and hardware layout retained.'
