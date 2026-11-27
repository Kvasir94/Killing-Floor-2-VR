import struct,subprocess,re,sys,json
P=sys.argv[1]; want=sys.argv[2:-1]; outp=sys.argv[-1]
out=subprocess.run([r'umodel.exe','-list',P],capture_output=True,text=True).stdout
d=open(P,'rb').read()
res={}
for line in out.splitlines():
    m=re.match(r'\s*\d+\s+([0-9A-F]+)\s+([0-9A-F]+)\s+StaticMesh\s+(\S+)$',line)
    if not m or m.group(3) not in want: continue
    off=int(m.group(1),16); b=d[off:off+int(m.group(2),16)]
    cands=[]
    for o in range(0,len(b)-8):
        es,n=struct.unpack_from('<ii',b,o)
        if es==12 and 8<n<200000 and o+8+12*n<=len(b):
            ok=all(abs(x)<2000 and x==x for v in range(0,n,max(1,n//40)) for x in struct.unpack_from('<3f',b,o+8+12*v))
            if ok: cands.append((o+8,n))
    idxs=[]
    for o in range(0,len(b)-8):
        es,c=struct.unpack_from('<ii',b,o)
        if es==2 and c>=3 and c%3==0 and o+8+2*c<=len(b):
            idxs.append((o+8,c))
    pick=None
    for po,n in cands:
        for io,c in idxs:
            I=struct.unpack_from('<%dH'%c,b,io)
            if max(I)==n-1 and (pick is None or n>pick[1] or (n==pick[1] and po>pick[0])): pick=(po,n,I)
    if not pick: print('none',m.group(3),len(cands),len(idxs)); continue
    po,n,idx=pick
    pos=[struct.unpack_from('<3f',b,po+12*v) for v in range(n)]
    uv=None
    for o in range(po+12*n,len(b)-20):
        st,nn,fp,es,cc=struct.unpack_from('<5i',b,o)
        if nn==n and cc==n and st==es and fp in(0,1) and 16<=st<=64:
            d0=o+20
            if fp==0: uv=[struct.unpack_from('<2e',b,d0+st*v+8) for v in range(n)]
            else: uv=[struct.unpack_from('<2f',b,d0+st*v+8) for v in range(n)]
            break
    res[m.group(3)]={'positions':pos,'uv':uv,'triangles':[idx[k:k+3] for k in range(0,len(idx),3)]}
    print('  uv',None if uv is None else (min(u for u,_ in uv),max(u for u,_ in uv),min(v_ for _,v_ in uv),max(v_ for _,v_ in uv)))
    xs=list(zip(*pos)); print(m.group(3),n,'verts',len(idx)//3,'tris','bounds',[ (round(min(a),1),round(max(a),1)) for a in xs])
json.dump(res,open(outp,'w'))
