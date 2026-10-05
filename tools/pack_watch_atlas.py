"""Reserve real texel space for the maker plaque and woven hardware.

Pack UV islands into dedicated pixel rectangles without stretching their
aspect ratio. Auto-packing the whole cuff left the plaque only ~230 pixels wide
even in a 4K atlas, turning its fine relief into conspicuous coarse dots.
"""
def pack_watch_atlas(mesh, groups, size):
    uv=mesh.uv_layers.active
    original=[tuple(t.uv) for t in uv.data]
    parent=list(range(len(mesh.polygons)))
    def root(i):
        while parent[i]!=i:
            parent[i]=parent[parent[i]];i=parent[i]
        return i
    seen={}
    for p in mesh.polygons:
        for li in p.loop_indices:
            u,v=original[li];key=(mesh.loops[li].vertex_index,round(u,6),round(v,6),groups[p.index])
            if key in seen:parent[root(p.index)]=root(seen[key])
            else:seen[key]=p.index
    islands={}
    for p in mesh.polygons:
        key=root(p.index)
        if key not in islands:islands[key]={'group':groups[p.index],'loops':[]}
        islands[key]['loops'].extend(p.loop_indices)
    for key,chart in islands.items():
        coords=[original[i] for i in chart['loops']]
        chart['key']=key;chart['lo']=(min(v[0] for v in coords),min(v[1] for v in coords))
        chart['extent']=(max(v[0] for v in coords)-chart['lo'][0],max(v[1] for v in coords)-chart['lo'][1])
        chart['rotate']=chart['extent'][1]>chart['extent'][0]
        chart['width']=max(chart['extent']);chart['height']=min(chart['extent'])
    regions={'badge':(0,0,.55,.25),'woven':(.55,0,1,.25),
             'focal':(0,.25,.40,.50),'fascia':(.40,.25,1,.55),
             'hardware':(0,.50,.40,.75),'wrap':(.40,.55,1,.75),
             'strap':(0,.75,.80,1),'hidden':(.80,.75,1,.90),
             'fabric':(.80,.90,1,1)}
    padding=10;receipt={}
    for group,rect in regions.items():
        charts=sorted((c for c in islands.values() if c['group']==group),key=lambda c:(-c['height'],-c['width'],c['key']))
        x0,y0,x1,y1=(round(v*size) for v in rect)
        width=x1-x0;height=y1-y0
        def shelves(scale):
            x=y=row=0;placed=[]
            for c in charts:
                w=max(1,c['width']*scale)+padding*2;h=max(1,c['height']*scale)+padding*2
                if w>width:return None
                if x+w>width:x=0;y+=row;row=0
                if y+h>height:return None
                placed.append((c,x+padding,y+padding));x+=w;row=max(row,h)
            return placed
        def guillotine(scale):
            # Fill the gaps under short charts instead of discarding the rest
            # of a tall shelf. Free rectangles remain disjoint by construction.
            free=[(0,0,width,height)];placed=[]
            for c in charts:
                w=max(1,c['width']*scale)+padding*2;h=max(1,c['height']*scale)+padding*2
                choices=[(min(fw-w,fh-h),max(fw-w,fh-h),i) for i,(x,y,fw,fh) in enumerate(free) if w<=fw and h<=fh]
                if not choices:return None
                _,_,index=min(choices);x,y,fw,fh=free.pop(index)
                placed.append((c,x+padding,y+padding))
                dw=fw-w;dh=fh-h
                if dw>dh:
                    remainder=[(x+w,y,dw,fh),(x,y+h,w,dh)]
                else:remainder=[(x+w,y,dw,h),(x,y+h,fw,dh)]
                free.extend(r for r in remainder if r[2]>0 and r[3]>0)
            return placed
        def place(scale):return shelves(scale) or guillotine(scale)
        low=0.;high=float(size)*128
        for _ in range(28):
            mid=(low+high)*.5
            if place(mid) is None:high=mid
            else:low=mid
        placed=place(low)
        if placed is None:raise RuntimeError('UV charts do not fit '+group)
        for c,x,y in placed:
            for li in c['loops']:
                u=original[li][0]-c['lo'][0];v=original[li][1]-c['lo'][1]
                if c['rotate']:u,v=v,c['extent'][0]-u
                uv.data[li].uv=((x0+x+u*low)/size,(y0+y+v*low)/size)
        receipt[group]={'islands':len(charts),'pixel_rectangle':[x0,y0,x1,y1],'scale':low}
    mesh.update()
    assert all(-1e-6<=c<=1.000001 for loop in uv.data for c in loop.uv)
    return receipt
