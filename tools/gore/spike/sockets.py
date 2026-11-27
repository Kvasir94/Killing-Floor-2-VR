import struct,subprocess,re,sys,json
sys.path.insert(0,r'D:/KF2-VR/tools/ue3'); import upkg
P=sys.argv[1]
info,names,imports,exports=upkg.read_header(P)
out=subprocess.run([r'umodel.exe','-list',P],capture_output=True,text=True).stdout
d=open(P,'rb').read()
def objname(i):
    if i<0: return imports[-i-1]['name']
    return 'export%d'%i
res=[]
for line in out.splitlines():
    m=re.match(r'\s*(\d+)\s+([0-9A-F]+)\s+([0-9A-F]+)\s+SkeletalMeshSocket\s+(\S+)$',line)
    if not m: continue
    off=int(m.group(2),16); size=int(m.group(3),16); b=d[off:off+size]
    p=4  # netindex
    props={}
    while p<len(b)-8:
        ni,nn=struct.unpack_from('<ii',b,p); name=names[ni]; p+=8
        if name=='None': break
        ti,_=struct.unpack_from('<ii',b,p); typ=names[ti]; p+=8
        sz,ai=struct.unpack_from('<ii',b,p); p+=8
        if typ=='StructProperty':
            si,_=struct.unpack_from('<ii',b,p); sname=names[si]; p+=8
            if sname=='Vector': props[name]=struct.unpack_from('<3f',b,p)
            elif sname=='Rotator': props[name]=struct.unpack_from('<3i',b,p)
            p+=sz
        elif typ=='NameProperty':
            props[name]=names[struct.unpack_from('<i',b,p)[0]]; p+=sz
        elif typ=='ObjectProperty':
            props[name]=objname(struct.unpack_from('<i',b,p)[0]); p+=sz
        elif typ=='BoolProperty':
            props[name]=b[p]; p+=1
        else: p+=sz
    res.append(props)
for r in res: print(r)
json.dump(res,open(sys.argv[2],'w'),indent=1)
