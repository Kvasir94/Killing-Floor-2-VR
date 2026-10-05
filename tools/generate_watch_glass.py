"""Deterministic Canvas backing: low-contrast glass tint and display matrix.

One texture draw keeps the wrist HUD independent of hundreds of decorative
Canvas calls. No text or live values are baked into this image.
"""
import math
import struct
import random
from pathlib import Path

def generate(path):
    width,height=1024,512
    pixels=bytearray()
    for y in range(height):
        for x in range(width):
            sheen=max(0,1-abs(y-150)/255)*16
            reflected=max(0,1-abs(x*.23+y-160)/74)*22
            reflected+=math.exp(-((x*.37+y-235)/26)**2)*8
            # Soft, interrupted reflections suggest a laminated lens above the
            # display matrix. Keep them below the telemetry's lightest strokes.
            reflected+=math.exp(-((x*.29+y-92)/9)**2)*8*(.65+.35*math.sin(x*.007)**2)
            vignette=min(1,min(x,width-1-x,y,height-1-y)/38)
            grain=((x*73+y*151+x*y*3)%19)/19-0.5
            scan=1.8 if y%4==0 else 0
            grid=-1.2 if x%8==4 else 0
            tone=sheen+reflected+grain*2+scan+grid
            color=[int((v+tone)*(.64+.36*vignette)) for v in (9,24,25)]
            edge_distance=min(x,width-1-x,y,height-1-y)
            fleck=((x*191+y*953+x*y*11)%997)/997
            if fleck>.958 and edge_distance<34:
                strength=(1-edge_distance/34)*(fleck-.958)/.042
                color=[c+int(strength*v) for c,v in zip(color,(52,43,26))]
            pixels.extend(bytes(reversed([max(0,min(255,c)) for c in color])))
    rng=random.Random(360924)
    for i in range(17):
        x=rng.randrange(12,width-55);y=rng.choice([rng.randrange(9,30),rng.randrange(475,501)])
        length=rng.randrange(9,38);slope=rng.uniform(-.26,.26)
        for step in range(length):
            xx=x+step;yy=round(y+step*slope)
            if not 0<=yy<height:continue
            strength=.32*math.sin(math.pi*step/length)
            offset=(yy*width+xx)*3
            for channel,target in enumerate((70,73,60)):
                pixels[offset+channel]=int(pixels[offset+channel]*(1-strength)+target*strength)
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    header=struct.pack('<BBBHHBHHHHBB',0,0,2,0,0,0,0,0,width,height,24,0x20)
    data=header+pixels
    if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)
    return path

def generate_glow(path):
    """Two exact-size clipped-frame masks, tinted dynamically by the Canvas."""
    width=height=1024
    pixels=bytearray(width*height*4)
    for w,h,oy in [(448,88,0),(472,480,128)]:
        xy=[(20,8),(w-4,8),(w+8,20),(w+8,h-4),(w-4,h+8),(20,h+8),(8,h-4),(8,20)]
        for y in range(h+16):
            for x in range(w+16):
                if 24<x<w-8 and 24<y<h-8:continue
                distance=1e9
                for i,(ax,ay) in enumerate(xy):
                    bx,by=xy[(i+1)%len(xy)];dx=bx-ax;dy=by-ay
                    t=max(0,min(1,((x-ax)*dx+(y-ay)*dy)/(dx*dx+dy*dy)))
                    distance=min(distance,(x-ax-dx*t)**2+(y-ay-dy*t)**2)
                alpha=int(86*math.exp(-distance/(2*2.4**2)))
                index=((y+oy)*width+x)*4;pixels[index:index+4]=bytes((255,255,255,alpha))
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    data=struct.pack('<BBBHHBHHHHBB',0,0,2,0,0,0,0,0,width,height,32,0x28)+pixels
    if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)
    return path

if __name__=='__main__':
    import sys
    path=generate(sys.argv[1] if len(sys.argv)>1 else Path(__file__).resolve().parents[1]/'build/hand-meshes/VRHorzineWatchGlass.tga')
    generate_glow(path.with_name('VRHorzineWatchGlow.tga'))
    print(path)
