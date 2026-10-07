"""Read the nine stock perk grenade surfaces from locally owned cooked packages.

The pinned legacy UModel cannot decode KF2 StaticMesh buffers. This reader uses
our existing UE3 package parser, finds a duplicated PositionVertexBuffer header,
then validates the adjacent UV, colour and index buffers and cooked bounds.
Writes derived vertices only to an explicit ignored output folder.
Usage: python tools/inspect_grenade_grips.py --output build/grenade-grips
"""
import argparse
import hashlib
import json
import math
import struct
from pathlib import Path
from audit_source_assets import read_package, properties

MESHES = {
    'Freeze': ('LN2_Grenade/WEP_1P_LN2_Grenade_MESH.upk','Wep_1stP_LN2_Grenade'),
    'Frag': ('MKII/WEP_3P_MKII_MESH.upk','Wep_3rdP_MKII_Grenade'),
    'HE': ('MK3/WEP_3P_MK3_MESH.upk','Wep_3rdP_MK3'),
    'Medic': ('Medic_Grenade/WEP_1P_Medic_Grenade_MESH.upk','Wep_1stp_Medic_Grenade'),
    'Dynamite': ('Dynamite/WEP_3P_Dynamite_MESH.upk','Dynamite_STTest'),
    'EMP': ('EMP/WEP_3P_EMP_MESH.upk','Wep_1stP_EMP'),
    'Molotov': ('Molotov/WEP_3P_Molotov_MESH.upk','Wep_1stP_Molotov'),
    'NailBomb': ('NailBomb/WEP_3P_Nailbomb_MESH.upk','WEP_1stP_Nailbomb'),
    'FlashBang': ('M84/WEP_3P_M84_MESH.upk','Wep_1stP_M84_STATICTEST'),
}

def decode_lod(data, cursor, end, bounds):
    """Decode one validated KF2 render LOD, preserving its actual triangle list."""
    def take(fmt):
        nonlocal cursor
        size=struct.calcsize(fmt)
        if cursor+size>end: raise ValueError('Truncated static-mesh buffer')
        result=struct.unpack_from(fmt,data,cursor);cursor+=size
        return result
    stride,count,item_size,array_count=take('<4I')
    if stride!=12 or item_size!=12 or count!=array_count or not 3<=count<=100000:
        raise ValueError('Invalid position buffer header')
    vertices=[take('<3f') for _ in range(count)]
    if not all(math.isfinite(c) and abs(c-bounds[j])<=bounds[j+3]+.02 for v in vertices for j,c in enumerate(v)):
        raise ValueError('Positions outside cooked bounds')
    texcoords,stride,uv_count,full_precision,item_size,uv_array_count=take('<6I')
    expected=8+texcoords*(8 if full_precision else 4)
    if not 1<=texcoords<=8 or full_precision not in (0,1) or stride!=item_size or stride!=expected or uv_count!=count or uv_array_count!=count:
        raise ValueError('Invalid static-mesh tangent/UV buffer')
    cursor+=stride*count
    color_stride,color_count=take('<2I')
    if color_stride:
        color_size,color_array_count=take('<2I')
        if color_stride!=4 or color_size!=4 or color_count!=count or color_array_count!=count:
            raise ValueError('Invalid static-mesh colour buffer')
        cursor+=4*count
    elif color_count: raise ValueError('Invalid empty colour buffer')
    vertex_count,index_size,index_count=take('<3I')
    if vertex_count!=count or index_size not in (2,4) or not 3<=index_count<=1000000 or index_count%3:
        raise ValueError('Invalid static-mesh index header')
    indices=take('<'+str(index_count)+('H' if index_size==2 else 'I'))
    if max(indices)>=count: raise ValueError('Triangle references missing vertex')
    triangles=[indices[i:i+3] for i in range(0,index_count,3)]
    if any(len(set(t))!=3 for t in triangles): raise ValueError('Degenerate indexed triangle')
    # The first LOD must reproduce every cooked axis extent; this rejects false
    # byte-pattern matches inside collision data and unrelated payloads.
    if any(abs(min(v[j] for v in vertices)-(bounds[j]-bounds[j+3]))>.02 or abs(max(v[j] for v in vertices)-(bounds[j]+bounds[j+3]))>.02 for j in range(3)):
        raise ValueError('LOD extents differ from cooked bounds')
    return vertices,triangles

def extract(path, name):
    data,names,_,objects=read_package(path)
    obj=next(o for o in objects if o['cls']=='StaticMesh' and o['name']==name)
    _,tag=properties(data[obj['offset']+4:obj['offset']+obj['size']],names)
    start,end=obj['offset']+4+tag,obj['offset']+obj['size']
    bounds=struct.unpack_from('<7f',data,start)
    for cursor in range(start,end-16):
        if data[cursor:cursor+4]!=b'\x0c\0\0\0':continue
        stride,count,item_size,array_count=struct.unpack_from('<4I',data,cursor)
        if item_size!=12 or count!=array_count or not 3<=count<=100000:continue
        try: vertices,triangles=decode_lod(data,cursor,end,bounds)
        except (ValueError,struct.error):continue
        return dict(package=str(path),package_sha256=hashlib.sha256(data).hexdigest(),name=name,bounds=bounds,vertices=vertices,triangles=triangles,vertex_buffer_offset=cursor)
    raise ValueError('No validated render LOD: '+str(path)+' '+name)

def self_test():
    """Parser checks against a tiny explicit buffer, including malformed inputs."""
    bounds=(0,0,0,1,1,0,2)
    raw=struct.pack('<4I',12,3,12,3)+struct.pack('<9f',-1,-1,0,1,-1,0,0,1,0)
    raw+=struct.pack('<6I',1,12,3,0,12,3)+bytes(36)+struct.pack('<2I',0,0)+struct.pack('<3I3H',3,2,3,0,1,2)
    v,t=decode_lod(raw,0,len(raw),bounds)
    assert len(v)==3 and t==[(0,1,2)]
    bad=bytearray(raw);struct.pack_into('<H',bad,len(raw)-2,3)
    for b in (raw[:-1],bytes(bad),bytes(16)+raw[16:]):
        try:decode_lod(b,0,len(b),bounds)
        except ValueError:pass
        else:raise AssertionError('Malformed buffer accepted')
    print('Static mesh parser checks passed (valid, truncated, invalid index/header).')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-root',type=Path,default=Path('D:/SteamLibrary/steamapps/common/killingfloor2'))
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--self-test',action='store_true');args=p.parse_args()
    if args.self_test:self_test()
    results=[]
    for label,(rel,name) in MESHES.items():
        m=extract(args.game_root/'KFGame/BrewedPC/Packages/Weapons'/rel,name);m['label']=label;results.append(m)
        print(label,len(m['vertices']),len(m['triangles']))
    args.output.mkdir(parents=True,exist_ok=True)
    (args.output/'meshes.json').write_text(json.dumps(results))
