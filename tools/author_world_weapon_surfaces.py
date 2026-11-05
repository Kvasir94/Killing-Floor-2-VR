"""Build exact world-contact surfaces from installed stock pickup meshes.

Uses the validated cooked StaticMesh reader and original material sections.
Sharp annotations classify a confirmed surface hit; they do not expand geometry.
Prepare knife PSKs with tools/generate_world_knives.py --prepare first.
"""
import argparse, hashlib, json, re, struct, sys
from pathlib import Path
import numpy as np
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'AGENTS.md').is_file())
sys.path[:0]=[str(ROOT/'tools'),str(ROOT/'tools/re')]
from inspect_grenade_grips import extract
from audit_source_assets import read_package
from generate_floating_hands import bone_data,decode_geometry
from generate_reload_props import read_psk
from generate_world_knives import MESHES
from audit_m14_assets import mul,conj,rotate

def sections(v,f,axis,at):
 edges=np.unique(np.sort(np.concatenate([f[:,[0,1]],f[:,[1,2]],f[:,[2,0]]]),axis=1),axis=0)
 a=v[edges[:,0]];b=v[edges[:,1]]
 found=[]
 for t in at:
  mask=(np.minimum(a[:,axis],b[:,axis])<=t+1e-7)&(np.maximum(a[:,axis],b[:,axis])>=t-1e-7)
  aa=a[mask];bb=b[mask];delta=bb[:,axis]-aa[:,axis]
  same=np.abs(delta)<1e-7
  q=aa[~same]+(bb-aa)[~same]*((t-aa[:,axis])[~same]/delta[~same])[:,None]
  q=np.concatenate([q,aa[same],bb[same]])
  found.append(q)
 return found

def unit(v):return v/max(np.linalg.norm(v),1e-9)

def outline(v,f,along,across,low,high,side):
 at=sorted(set([low,high]+[float(t) for t in v[:,along] if low<t<high]))
 points=[]
 for q in sections(v,f,along,at):
  if len(q):points.append(q[np.argmin(q[:,across]) if side<0 else np.argmax(q[:,across])])
 # Exact triangle cross-sections include every original vertex event, so no
 # curved boundary is replaced by a chord across a skipped mesh corner.
 points=np.array(points);axes=[]
 center=points.mean(0);_,_,vh=np.linalg.svd(v[f].reshape(-1,3)-center,full_matrices=False);normal=vh[-1]
 for a,b in zip(points,points[1:]):
  axis=unit(np.cross(b-a,normal))
  if axis[across]*side<0:axis=-axis
  axes.append(axis.tolist())
 return dict(points=points.tolist(),axes=axes)

def material_sections(mesh):
    meta=mesh['metadata'];data,_,imports,objects=read_package(Path(meta['source']))
    end=meta['vertex_buffer_offset'];faces=mesh['triangles'];candidates=[]
    # UE3 FStaticMeshSection: material object, three flags, index/face/vertex
    # ranges, section index, fragment pairs; KF2 adds one byte per section.
    # Admit only a unique adjacent section array that partitions the complete
    # original index buffer and reproduces every section's used vertex bounds.
    for begin in range(max(0,end-8192),end-40):
        count=struct.unpack_from('<i',data,begin)[0]
        if not 1<=count<=64:continue
        cur=begin+4;slots=[];materials=[-1]*len(faces);good=True
        try:
            for slot in range(count):
                mat,c1,c2,shadow,first,total,vmin,vmax,index,pairs=struct.unpack_from('<10i',data,cur);cur+=40
                if c1 not in (0,1) or c2 not in (0,1) or shadow not in (0,1) or first%3 or first<0 or total<=0 or first//3+total>len(faces) or index!=slot or not 0<=pairs<=64:
                    good=False;break
                if cur+pairs*8>=end:good=False;break
                fragments=[struct.unpack_from('<2i',data,cur+i*8) for i in range(pairs)];cur+=pairs*8
                if any(a<0 or a%3 or b<=0 or a//3+b>len(faces) for a,b in fragments) or data[cur] not in (0,1):good=False;break
                cur+=1;used=[v for f in faces[first//3:first//3+total] for v in f]
                if min(used)!=vmin or max(used)!=vmax or any(m!=-1 for m in materials[first//3:first//3+total]):good=False;break
                materials[first//3:first//3+total]=[slot]*total
                if mat<0 and -mat<=len(imports):material=imports[-mat-1]
                elif mat>0 and mat<=len(objects):material=objects[mat-1]
                elif mat==0:material=None
                else:good=False;break
                slots.append(dict(slot=slot,object_index=mat,object=material,first_index=first,face_count=total))
            if good and cur==end and -1 not in materials:candidates.append((begin,slots,materials))
        except (struct.error,ValueError):pass
    if len(candidates)!=1:raise ValueError(f'No unique original material section array: {meta["world_mesh"]}')
    begin,slots,materials=candidates[0]
    meta.update(section_offset=begin,material_slots=slots,material_status='validated original LOD sections')
    mesh['face_materials']=materials

def static_surface(weapon,path,mesh):
    _,_,_,objects=read_package(path);model=mesh.split('.')[-1]
    model=next(o['name'] for o in objects if o['cls']=='StaticMesh' and o['name'].casefold()==model.casefold())
    raw=extract(path,model);count=len(raw['triangles'])
    meta=dict(weapon=weapon,mesh=mesh,world_mesh=mesh,frame='pickup',source=str(path.resolve()),
              sha256=raw['package_sha256'],selected_points=len(raw['vertices']),selected_triangles=count,
              vertex_buffer_offset=raw['vertex_buffer_offset'],approximation='none; full original static render LOD')
    result=dict(metadata=meta,vertices=raw['vertices'],triangles=raw['triangles'],original_faces=list(range(count)),face_regions=[0]*count)
    material_sections(result);return result

def author_sharp(mesh,config):
    v=np.array(mesh['vertices']);f=np.array(mesh['triangles']);name=mesh['metadata']['weapon']
    if 'material' in config:f=f[np.array(mesh['face_materials'])==config['material']]
    if 'maximum_y' in config:f=f[np.all(v[f,1]<config['maximum_y'],axis=1)]
    for axis,low,high in config.get('face_bounds',[]):
        f=f[np.all((v[f,axis]>=low)&(v[f,axis]<=high),axis=1)]
    along,across=config['along'],config['across']
    lines=[outline(v,f,along,across,config['low'],config['high'],side) for side in config['sides']]
    mode=config['tip_mode']
    if mode=='tip_only':tip=v[np.argmax(v[:,along])];axis=np.array(config['tip_axis'])
    elif mode=='none':tip=np.zeros(3);axis=np.array(config['tip_axis'])
    elif mode=='pick':tip=v[np.argmin(v[:,0])];axis=np.array([-1,0,0])
    elif mode=='scythe':
        tip=v[np.argmin(np.linalg.norm(v-np.array(config['tip_seed']),axis=1))]
        q=np.array(lines[0]['points']);far=q[np.argmin(np.abs(q[:,0]-(tip[0]+5)))];axis=unit(np.array([tip[0]-far[0],tip[1]-far[1],0]))
    elif mode=='min_x':
        tip=v[np.argmin(v[:,0])];axis=unit(tip-np.mean([l['points'][min(10,len(l['points'])-1)] for l in lines],axis=0))
    else:
        tip=v[np.argmax(v[:,along])];axis=unit(tip-np.mean([l['points'][-min(10,len(l['points']))] for l in lines],axis=0))
    mesh['metadata']['sharp_regions']=dict(tip=tip.tolist(),tip_axis=axis.tolist(),tip_radius=0 if mode=='none' else .75,
        edge_radius=.25,edge_min_z=-10000,edge_polylines=lines)
    if mode=='none':
        mesh['metadata']['sharp_regions'].pop('tip')
        mesh['metadata']['sharp_regions']['edge_min_z']=config.get('edge_min_z',-10000)
    mesh['metadata']['sharp_authoring']='Original triangle cross-section outline at every vertex event; tracked cutting-side/guard annotations.'

def knife_surface(perk,mesh,path,regions):
    chunks=read_psk(path);bones,names=bone_data(chunks);points,wedges,faces,weights=decode_geometry(chunks)
    root=names.index('RW_Weapon');positions=[];rotations=[]
    if any(abs(w.get(root,0)-1)>.0001 or sum(v for b,v in w.items() if b!=root)>.0001 for w in weights):
        raise ValueError(f'Knife contains non-root geometry: {mesh}')
    for i,b in enumerate(bones):
        p,q=b[8:11],b[4:8]
        if i:p=tuple(a+c for a,c in zip(positions[b[3]],rotate(rotations[b[3]],p)));q=mul(rotations[b[3]],conj(q))
        positions.append(p);rotations.append(q)
    v=np.array([rotate(conj(rotations[root]),tuple(a-b for a,b in zip(p,positions[root]))) for p in points])
    triangles=[[wedges[j][0] for j in f[:3][::-1]] for f in faces];f=np.array(triangles);config=regions['profiles'][perk]
    zs=np.unique(np.r_[config['blade_min_z'],v[v[:,2]>=config['blade_min_z'],2]])
    t=v[f]
    def cross(z):
        points=[]
        for a,b in ((t[:,0],t[:,1]),(t[:,1],t[:,2]),(t[:,2],t[:,0])):
            mask=((a[:,2]-z)*(b[:,2]-z)<=0)&(np.abs(a[:,2]-b[:,2])>1e-8)
            q=a[mask]+(b[mask]-a[mask])*((z-a[mask,2])/(b[mask,2]-a[mask,2]))[:,None]
            points.extend(q)
        points.extend(v[np.abs(v[:,2]-z)<1e-7])
        return np.array(points)
    cut=[]
    for z in zs:
        q=cross(z)
        if len(q):cut.append([float(z),float(q[:,0].min()),float(q[:,0].max())])
    tip=v[v[:,2].argmax()];q=cross(float(tip[2]-.75));axis=unit(tip-(q.min(0)+q.max(0))*.5)
    count=len(faces);meta=dict(weapon='KFWeap_Knife_'+perk,mesh=mesh,world_mesh='KF2VRHands.VRWorldKnife'+perk,
        frame='pickup',source=str(path.resolve()),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),selected_points=len(v),selected_triangles=count,
        sharp_regions=dict(tip=tip.tolist(),tip_axis=axis.tolist(),tip_radius=regions['tip_radius'],edge_radius=regions['edge_radius'],
        edge_min_z=config['blade_min_z'],edge_sides=config['edge_sides'],edge_sections=cut))
    return dict(metadata=meta,vertices=v.tolist(),triangles=triangles,original_faces=list(range(count)),face_regions=[0]*count,
                face_materials=[f[3] for f in faces],material_slots=[r[:64].split(b'\0')[0].decode() for r in chunks['MATT0000'].rows])

def main():
    parser=argparse.ArgumentParser(__doc__)
    parser.add_argument('--game-root',type=Path,default=Path('D:/SteamLibrary/steamapps/common/killingfloor2'))
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--knife-exports',type=Path,default=ROOT/'build/world-weapon-assets/export')
    parser.add_argument('--hand-package',type=Path,default=ROOT/'build/hand-assets/KF2VRHands.upk')
    parser.add_argument('--regions',type=Path,default=ROOT/'tools/world-weapon-regions.json')
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    regions=json.loads(args.regions.read_text());knife_regions=json.loads((ROOT/'tools/world-knife-regions.json').read_text())
    rows=[]
    for perk,mesh in MESHES.items():
        package,name=mesh.split('.');rows.append(knife_surface(perk,mesh,args.knife_exports/package/'SkeletalMesh3'/(name+'.psk'),knife_regions))
    classes={p.stem:p.read_text(errors='replace') for p in (args.game_root/'Development/Src/KFGameContent/Classes').glob('KFWeap_*.uc')}
    def pickup(name,seen=None):
        seen=set() if seen is None else seen
        if name in seen or name not in classes:return None
        seen.add(name);text=classes[name];match=re.search(r'PickupMeshName\s*=\s*"([^"]+)"',text,re.I)
        if match:return match[1]
        parent=re.search(r'\bextends\s+(\w+)',text,re.I)
        return pickup(parent[1],seen) if parent else None
    packages={p.stem.casefold():p for p in (args.game_root/'KFGame/BrewedPC/Packages/Weapons').rglob('*.upk')}
    profiles=(ROOT/'script/KF2VR/Classes/VRHandsBridge.uc').read_text()
    names=[m[0] for m in re.findall(r'WeaponProfiles\(\d+\)=\(WeaponClassName=(\w+),([^\n]+)',profiles) if 'bFirearm=true' in m[1]]
    names+=re.findall(r'WeaponClassName="?(\w+)',(ROOT/'script/KF2VR/Classes/VRMeleeTraits.uc').read_text())
    seen=set();unsupported=[]
    for name in dict.fromkeys(names):
        if 'Knife' in name or name=='VRWeap_Tomahawk':continue
        mesh=pickup(name)
        if not mesh:unsupported.append(name);continue
        if mesh.casefold() in seen:continue
        seen.add(mesh.casefold());package=packages[mesh.split('.')[0].casefold()]
        result=static_surface(name,package,mesh)
        if name in regions['profiles']:author_sharp(result,regions['profiles'][name])
        rows.append(result);print(name,len(result['triangles']),flush=True)
    tomahawk=static_surface('VRWeap_Tomahawk',args.hand_package,'KF2VRHands.VRTomahawk')
    author_sharp(tomahawk,regions['profiles']['VRWeap_Tomahawk']);rows.append(tomahawk)
    for row in rows:(args.output/(row['metadata']['weapon']+'.json')).write_text(json.dumps(row,separators=(',',':'))+'\n')
    (args.output/'summary.json').write_text(json.dumps([r['metadata'] for r in rows],indent=2)+'\n')
    (args.output/'unsupported.json').write_text(json.dumps(unsupported,indent=2)+'\n')
    print('Original world meshes:',len(rows),'unsupported:',unsupported)

if __name__=='__main__':main()
