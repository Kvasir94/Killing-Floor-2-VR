"""Transfer source surface attributes by connected shell, without cross-layer rays."""
from collections import Counter, defaultdict
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import barycentric_transform, closest_point_on_tri


def transfer(target, source, face_owners, owner_names):
    source.calc_loop_triangles()
    triangles=list(source.loop_triangles)
    positions=[v.co for v in source.vertices]
    all_tree=BVHTree.FromPolygons(positions,[tuple(t.vertices) for t in triangles],all_triangles=True)
    by_owner=defaultdict(list)
    for i,t in enumerate(triangles):by_owner[face_owners[t.polygon_index]].append(i)
    trees={k:BVHTree.FromPolygons(positions,[tuple(triangles[i].vertices) for i in ids],all_triangles=True)
           for k,ids in by_owner.items()}
    parent=list(range(len(target.vertices)))
    def root(i):
        while parent[i]!=i:parent[i]=parent[parent[i]];i=parent[i]
        return i
    for e in target.edges:parent[root(e.vertices[1])]=root(e.vertices[0])
    groups=defaultdict(list)
    for v in target.vertices:groups[root(v.index)].append(v.index)
    owners={};diagnostics=[]
    for key,ids in groups.items():
        votes=Counter()
        for vi in ids[::max(1,len(ids)//150)]:
            hit=all_tree.find_nearest(target.vertices[vi].co)
            votes[face_owners[triangles[hit[2]].polygon_index]]+=1
        owner=votes.most_common(1)[0][0];owners[key]=owner
        diagnostics.append({'vertices':len(ids),'source':owner_names[owner],
                            'agreement':votes[owner]/sum(votes.values())})
    attrs={}
    for name in ('SourceObjectCoordinates','SourceGeneratedCoordinates','ContactWear','DriedBlood','HealedScar'):
        src=source.attributes[name]
        dst=target.attributes.new(name,src.data_type,'CORNER');attrs[name]=(src,dst)
    source_uv=source.uv_layers['SourceUV'];uv=target.uv_layers.new(name='SourceUV')
    high_normal=target.attributes.new('HighSurfaceNormal','FLOAT_VECTOR','CORNER')
    for p in target.polygons:
        owner=owners[root(p.vertices[0])];tree=trees[owner];ids=by_owner[owner]
        center=sum((target.vertices[i].co for i in p.vertices),Vector())/len(p.vertices)
        nearest=tree.find_nearest(center);tri=triangles[ids[nearest[2]]]
        p.material_index=source.polygons[tri.polygon_index].material_index
        for li in p.loop_indices:
            co=target.vertices[target.loops[li].vertex_index].co
            # Coincident corners on opposite sides of a source UV seam have
            # different texture coordinates. Query just inside this face so
            # BVH ties do not select an unrelated chart for one of its corners.
            # Evaluate the attribute at the actual corner after choosing a side.
            hit=tree.find_nearest(co.lerp(center, .001));tri=triangles[ids[hit[2]]]
            surface=closest_point_on_tri(co,*(positions[i] for i in tri.vertices))
            weights=barycentric_transform(surface,*(positions[i] for i in tri.vertices),
                Vector((1,0,0)),Vector((0,1,0)),Vector((0,0,1)))
            uv.data[li].uv=sum((source_uv.data[l].uv*w for l,w in zip(tri.loops,weights)),Vector((0,0)))
            high_normal.data[li].vector=sum((source.corner_normals[l].vector*w for l,w in zip(tri.loops,weights)),Vector()).normalized()
            for name,(src,dst) in attrs.items():
                if src.data_type=='FLOAT':dst.data[li].value=sum(src.data[i].value*w for i,w in zip(tri.vertices,weights))
                else:dst.data[li].vector=sum((src.data[i].vector*w for i,w in zip(tri.vertices,weights)),Vector())
    target.uv_layers.active=target.uv_layers['RuntimeUV']
    target.uv_layers.active.active_render=True
    return sorted(diagnostics,key=lambda x:-x['vertices'])
