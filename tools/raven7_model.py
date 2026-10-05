"""Authored RAVEN-7 interpretation. Grip origin; centimetres; blade +X, haft +Z.

Each run creates a separate Blender scene and exports only the joined weapon.
The deterministic texture sets are used by both review renders and KF2.
"""
from pathlib import Path
import hashlib, json, math, random, struct, sys
import bpy
import numpy as np
from mathutils import Vector

PREFIXES = ['Steel','Grip','Armor','Energy','Red','Marking','Blade','Ceramic']
LENGTH_CM = 46.8

def main():
    root=Path(__file__).resolve().parents[1]
    out=root/'build/hand-meshes'; review=root/'build/tomahawks/raven7'
    out.mkdir(parents=True,exist_ok=True); review.mkdir(parents=True,exist_ok=True)
    scene=bpy.data.scenes.new('RAVEN-7 concept')
    bpy.context.window.scene=scene
    scene.unit_settings.system='METRIC'; scene.unit_settings.scale_length=.01
    parts=[]; mats=[]; rng=random.Random(71)
    atlas_path=root/'assets/weapons/raven7/material-atlas-v2.png'
    atlas_image=bpy.data.images.load(str(atlas_path),check_existing=False)
    aw,ah=atlas_image.size
    atlas=np.array(atlas_image.pixels[:],dtype=np.float32).reshape(ah,aw,4)[:,:,:3]
    def source_tile(index,size):
        bounds={0:(aw//2,0),1:(0,ah//2),2:(aw//2,ah//2),6:(0,0)}
        x,y=bounds[index]
        tile=atlas[y:y+ah//2,x:x+aw//2]
        # Atlas extraction and format conversion for the engine, no geometry.
        return tile[np.linspace(0,len(tile)-1,size).astype(int)[:,None],np.linspace(0,len(tile[0])-1,size).astype(int)[None,:]]*255
    colors=[(171,176,179),(41,38,35),(50,55,58),(15,183,222),(130,24,16),(194,195,180),(150,158,161),(6,7,8)]
    for index,(suffix,rgb) in enumerate(zip(PREFIXES,colors)):
        size=512
        noise=np.random.default_rng(91+index)
        yy,xx=np.mgrid[:size,:size]
        fine=noise.normal(0,.065,(size,size))
        grain=np.sin(xx*.15+np.sin(yy*.033)*2)*np.sin(yy*.087)+np.sin(xx*.051+yy*.063)
        tint=1+fine+grain*.023
        if index==1:
            tint+=.68*np.sin((xx+yy)*math.tau/11)*np.sin((xx-yy)*math.tau/13)
            tint+=noise.normal(0,.24,(size,size))
            tint+=(noise.random((size,size))>.94)*1.0
        rgb_map=np.clip(np.array(rgb)[None,None,:]*tint[:,:,None],0,255)
        if index in (0,1,2,6):rgb_map=source_tile(index,size)
        if index==0:
            steel_source=rgb_map.copy()
            rgb_map=np.clip(rgb_map*.64+8,0,255)
            structural=(yy>size*.60)&(yy<size*.78)
            # Neck, pommel and recall frames read as worn silver, not gunmetal.
            quiet=130+(steel_source-110)*.42
            quiet=np.where((np.mean(steel_source,axis=2)<65)[:,:,None],steel_source*.9,quiet)
            rgb_map[structural]=np.clip(quiet[structural],0,255)
            # Reserve the upper UV band for exposed, polished bevels. Faces
            # and edges share one engine material and one texture draw call.
            wear=.32+.68*np.clip((np.sin(xx*.073)+np.sin(xx*.019+yy*.051))*.8+.45,0,1)
            exposed=np.clip(steel_source*1.55+42,0,255)*wear[:,:,None]
            rgb_map[yy>size*.80]=exposed[yy>size*.80]
        elif index==6:
            # Polished cool steel. Stains thin out to streaks and spatter that
            # sit translucently on the metal instead of opaque blotches.
            metal=np.mean(rgb_map,axis=2)
            stain=(rgb_map[:,:,0]>rgb_map[:,:,1]*1.18)&(rgb_map[:,:,1]<100)
            streak=np.clip(np.sin(xx*.021+yy*.057+2.2*np.sin(yy*.011))*.7+noise.normal(0,.35,(size,size)),0,1)
            blade_stain=stain&(streak>.08)
            smooth=(metal+np.roll(metal,1,0)+np.roll(metal,-1,0)+np.roll(metal,1,1)+np.roll(metal,-1,1))/5
            clean=np.clip(np.stack((smooth*.97,smooth,smooth*1.05),axis=2)*1.55+18,0,255)
            blood=np.clip(rgb_map*np.array([1.45,.8,.75])+np.array([26,0,0]),0,255)
            rgb_map=np.where(blade_stain[:,:,None],clean*.25+blood*.75,clean)
        if index==2:rgb_map*=.85
        if index==3:
            core=np.exp(-((yy/size-.52)/.095)**2)[:,:,None]
            rgb_map=(np.array(rgb)*(1-core)+np.array([205,255,255])*core)
            rgb_map*= (.89+.11*np.sin(xx*.041+np.sin(xx*.013)))[:,:,None]
        if index==1:
            # UVs are physical X/Z, 0.22 repeats per cm. The upper cuff uses a
            # separately mapped area of this same material, with a worn print.
            # Upper wrap is mapped to this strip; the rest avoids it.
            # Broken angular stencil within one upper-cuff island.
            px=(xx/size-.36);py=(yy/size-.87)
            printmask=(np.abs(px-.6*py)<.022)&(np.abs(py)<.065)
            printmask |= (np.abs(px+.6*py-.09)<.024)&(py>-.04)&(py<.035)
            printmask |= (np.abs(py+.043)<.009)&(px>-.06)&(px<.045)
            printmask &= noise.random((size,size))>.3
            rgb_map*=.75
            # Coarse tape: deeper weave contrast with pale rubbed ridges.
            mean=np.mean(rgb_map)
            rgb_map=np.clip((rgb_map-mean)*1.45+mean*.9,0,255)
            rgb_map[printmask]=np.array([127,27,17])*(tint[printmask,None]*.5+.5)
        # The TGA is top-origin while atlas coordinates are bottom-origin UVs.
        pixels=np.uint8(np.clip(rgb_map,0,255))[::-1,:,::-1].tobytes()
        normal_noise=noise.integers(-5,6,(size,size))
        if index==1: normal_noise=np.int16(38*np.sin((xx+yy)*math.tau/11)*np.sin((xx-yy)*math.tau/13))
        if index in (0,1,2,6):
            heightmap=np.mean(source_tile(index,size),axis=2)/255
            gy,gx=np.gradient(heightmap)
            strength=3.0 if index==1 else .04 if index==6 else .10
            nn=np.stack((-gx*strength,-gy*strength,np.ones_like(gx)),axis=2)
            nn/=np.linalg.norm(nn,axis=2)[:,:,None]
            normals=np.uint8(np.clip((nn[:,:,::-1]*.5+.5)*255,0,255))[::-1].tobytes()
        else:normals=np.stack((np.full((size,size),252),128-normal_noise,128+normal_noise),axis=2).astype(np.uint8)[::-1].tobytes()
        spec=np.full((size,size,3),{1:44,6:205,0:165}.get(index,155),dtype=np.uint8)
        if index==0:spec[yy>size*.80]=225
        if index==6:
            # Thin dried stains dull the polish; they are only texture data.
            spec[blade_stain]=70
        for kind in ['D','N','S']:
            data=pixels if kind=='D' else normals if kind=='N' else spec[::-1].tobytes()
            (out/('VRTomahawk'+suffix+'_'+kind+'.tga')).write_bytes(struct.pack('<BBBHHBHHHHBB',0,0,2,0,0,0,0,0,size,size,24,32)+data)
        mat=bpy.data.materials.new('RAVEN '+suffix); mat.use_nodes=True
        mat.diffuse_color=tuple((c/255)**2.2 for c in rgb)+(1,)
        bs=mat.node_tree.nodes.get('Principled BSDF')
        bs.inputs['Metallic'].default_value=.90 if index in (0,6) else .62 if index==2 else .05
        bs.inputs['Roughness'].default_value=.9 if index==1 else .22 if index==6 else .29 if index==0 else .59
        if index==7:
            bs.inputs['Metallic'].default_value=0
            bs.inputs['Roughness'].default_value=.88
            bs.inputs['Specular IOR Level'].default_value=.08
        normal_tex=mat.node_tree.nodes.new('ShaderNodeTexImage')
        normal_tex.image=bpy.data.images.load(str(out/('VRTomahawk'+suffix+'_N.tga')))
        normal_tex.image.colorspace_settings.name='Non-Color'
        normal_map=mat.node_tree.nodes.new('ShaderNodeNormalMap')
        mat.node_tree.links.new(normal_tex.outputs['Color'],normal_map.inputs['Color'])
        mat.node_tree.links.new(normal_map.outputs['Normal'],bs.inputs['Normal'])
        tex=mat.node_tree.nodes.new('ShaderNodeTexImage')
        tex.image=bpy.data.images.load(str(out/('VRTomahawk'+suffix+'_D.tga')))
        mat.node_tree.links.new(tex.outputs['Color'],bs.inputs['Base Color'])
        if index in (0,6):
            st=mat.node_tree.nodes.new('ShaderNodeTexImage')
            st.image=bpy.data.images.load(str(out/('VRTomahawk'+suffix+'_S.tga')))
            st.image.colorspace_settings.name='Non-Color'
            rough=mat.node_tree.nodes.new('ShaderNodeMapRange')
            rough.inputs['From Min'].default_value=0;rough.inputs['From Max'].default_value=1
            rough.inputs['To Min'].default_value=.65;rough.inputs['To Max'].default_value=.19
            mat.node_tree.links.new(st.outputs['Color'],rough.inputs['Value'])
            mat.node_tree.links.new(rough.outputs['Result'],bs.inputs['Roughness'])
        if index==3:
            mat.node_tree.links.new(tex.outputs['Color'],bs.inputs['Emission Color'])
            bs.inputs['Emission Strength'].default_value=6.0
        mats.append(mat)
    edge_mat=mats[0].copy();edge_mat.name='RAVEN exposed steel bevel UV'
    structure_mat=mats[0].copy();structure_mat.name='RAVEN structural titanium UV'
    energy_core_mat=mats[3].copy();energy_core_mat.name='RAVEN luminous core UV'
    def active(ob):
        bpy.ops.object.select_all(action='DESELECT'); ob.select_set(True); bpy.context.view_layer.objects.active=ob
    def prism(name,points,half=.4,slot=2,y=0,bevel=.045):
        n=len(points); me=bpy.data.meshes.new(name)
        me.from_pydata([(x,y+d,z) for d in (-half,half) for x,z in points],[],
            [tuple(reversed(range(n))),tuple(range(n,2*n))]+[(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)])
        me.update(); ob=bpy.data.objects.new(name,me); scene.collection.objects.link(ob)
        structural=slot==0 and any(s in name.lower() for s in ('neck','pommel','recall structural','recall offset'))
        me.materials.append(energy_core_mat if name=='Blade energy luminous core' else structure_mat if structural else mats[slot]); parts.append(ob)
        active(ob)
        bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.mesh.normals_make_consistent(inside=False); bpy.ops.object.mode_set(mode='OBJECT')
        if bevel:
            active(ob); mod=ob.modifiers.new('Machined edge','BEVEL'); mod.width=bevel; mod.segments=1
            if slot in (0,2,7):
                me.materials.append(edge_mat); mod.affect='EDGES'; mod.material=1
            bpy.ops.object.modifier_apply(modifier=mod.name)
        return ob
    def cut(ob,points):
        cutter=prism('Opening tool',points,3,bevel=0); active(ob)
        mod=ob.modifiers.new('Through opening','BOOLEAN'); mod.operation='DIFFERENCE'; mod.solver='EXACT'; mod.object=cutter
        bpy.ops.object.modifier_apply(modifier=mod.name)
        parts.remove(cutter); bpy.data.objects.remove(cutter,do_unlink=True)
    def strip(name,points,width,slot=0,y=0,half=.04):
        # Mitered continuous rails have connected shoulders, rather than
        # overlapping rectangular caps at every bend of the traced outline.
        if len(points)>2 and points[0]!=points[-1]:
            normals=[]
            for a,b in zip(points,points[1:]):
                dx,dz=b[0]-a[0],b[1]-a[1]; d=math.hypot(dx,dz)
                normals.append((-dz/d,dx/d))
            left=[];right=[]
            for i,(x,z) in enumerate(points):
                n0=normals[max(0,i-1)]; n1=normals[min(i,len(normals)-1)]
                nx,nz=n0[0]+n1[0],n0[1]+n1[1]; d=math.hypot(nx,nz)
                nx,nz=nx/d,nz/d
                extent=min(width,width*.5/max(.5,nx*n1[0]+nz*n1[1]))
                left.append((x+nx*extent,z+nz*extent));right.append((x-nx*extent,z-nz*extent))
            return prism(name,left+right[::-1],half,slot,y,min(.02,half*.45) if slot==0 else 0)
        for a,b in zip(points,points[1:]):
            dx,dz=b[0]-a[0],b[1]-a[1]; d=math.hypot(dx,dz); nx,nz=-dz/d*width/2,dx/d*width/2
            prism(name,[(a[0]+nx,a[1]+nz),(b[0]+nx,b[1]+nz),(b[0]-nx,b[1]-nz),(a[0]-nx,a[1]-nz)],half,slot,y,0)
    def bolt(x,z,y=.86,r=.13):
        points=[(x+r*math.cos(i*math.tau/6),z+r*math.sin(i*math.tau/6)) for i in range(6)]
        for side in (-1,1):
            prism('Recessed hex fastener',points,.065,0,side*y,.015)
            strip('Fastener slot',[(x-r*.45,z),(x+r*.45,z)],.035,2,side*(y+.07),.006)
    from raven7_hero import build
    xy=build(prism,cut,strip,bolt,mats,scene,parts,rng)
    bpy.context.view_layer.update(); bpy.ops.object.select_all(action='DESELECT')
    for ob in parts: ob.select_set(True)
    bpy.context.view_layer.objects.active=parts[0]; bpy.ops.object.join(); ob=bpy.context.object; ob.name='VRTomahawk_RAVEN7'
    # Preserve the traced proportions; uniformly scale to the sheet's 312 mm.
    zs=[v.co.z for v in ob.data.vertices]
    unit_scale=31.2/(max(zs)-min(zs))
    for v in ob.data.vertices:v.co*=unit_scale
    old=list(ob.data.materials)
    edge_faces=[old[p.material_index]==edge_mat for p in ob.data.polygons]
    structure_faces=[old[p.material_index]==structure_mat for p in ob.data.polygons]
    energy_core_faces=[old[p.material_index]==energy_core_mat for p in ob.data.polygons]
    indices=[3 if energy_core_faces[p.index] else 0 if edge_faces[p.index] or structure_faces[p.index] else mats.index(old[p.material_index]) for p in ob.data.polygons]
    ob.data.materials.clear()
    for m in mats: ob.data.materials.append(m)
    for p,i in zip(ob.data.polygons,indices): p.material_index=i
    bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT'); bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.uv.smart_project(island_margin=.02); bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(35),keep_sharp_edges=True)
    for p in ob.data.polygons:
        if structure_faces[p.index]:p.use_smooth=False
    wnmod=ob.modifiers.new('Area weighted machined normals','WEIGHTED_NORMAL')
    wnmod.keep_sharp=True;wnmod.weight=50
    bpy.ops.object.modifier_apply(modifier=wnmod.name)
    # Tile material detail at a physical scale; avoid packing a whole weapon's
    # tiny faces into a single low-resolution texture and losing all grain.
    uv=ob.data.uv_layers.active.data
    for p in ob.data.polygons:
        axis=max(range(3),key=lambda a:abs(p.normal[a]))
        axes=[a for a in range(3) if a!=axis]
        for li in p.loop_indices:
            co=ob.data.vertices[ob.data.loops[li].vertex_index].co
            if energy_core_faces[p.index]:
                uv[li].uv=(co.z*.2,.52)
            elif p.material_index==3:
                uv[li].uv=(co.z*.2,.12)
            elif edge_faces[p.index]:
                uv[li].uv=(co[axes[0]]*.22,.88+.035*math.sin(co[axes[1]]))
            elif structure_faces[p.index]:
                # Map each structural region continuously into its atlas band.
                # Modulo per vertex folds large polygons across the band and
                # smears a handful of texels over the entire metal surface.
                midz=p.center.z
                z0,zspan=(-13,7) if midz<0 else (10,9) if midz>12 else (5,7)
                uv[li].uv=(co[axes[0]]*.32,.62+.14*max(0,min(1,(co.z-z0)/zspan)))
            elif p.material_index==0:
                uv[li].uv=(co[axes[0]]*.48,(co[axes[1]]*.31)% .55)
            elif p.material_index==6:
                uv[li].uv=(1-(co.x-4.5)/5,(co.z-6)/13)
            elif p.material_index==1:
                # Dedicated upper cuff print; no repeated red marks down grip.
                if co.z>3.1:uv[li].uv=(.42+co.x*.19,.80+(co.z-3.1)*.055)
                else:uv[li].uv=(co.x*.32,(co.z*.32)%0.70)
            else:uv[li].uv=(co[axes[0]]*.22,co[axes[1]]*.22)
    # UV tiling above is authored at the reference sheet's 312 mm. The weapon
    # itself is 1.5x that: between the stock Berserker knife (36.7 cm) and Fire
    # Axe (92.5 cm) first-person rigs, with a handle as thick as a stock haft.
    for v in ob.data.vertices:v.co*=LENGTH_CM/31.2
    sys.path.insert(0,str(root/'tools'))
    import raven7_rig
    report=raven7_rig.export_prop(ob,out/'VRTomahawk.fbx')
    report.update(raven7_rig.build(ob,out,review))
    report.update(generator_sha256=hashlib.sha256((root/'tools/generate_tomahawk.py').read_bytes()).hexdigest().upper(),
        model_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest().upper(),
        hero_sha256=hashlib.sha256((root/'tools/raven7_hero.py').read_bytes()).hexdigest().upper(),
        texture_source_sha256=hashlib.sha256(atlas_path.read_bytes()).hexdigest().upper(),
        license='Original geometry interpreting the user-supplied RAVEN-7 reference.',grip_origin_cm=[0,0,0],material_slots=PREFIXES,length_cm=LENGTH_CM,
        rig_sha256=hashlib.sha256((root/'tools/raven7_rig.py').read_bytes()).hexdigest().upper(),
        grip_sha256=hashlib.sha256((root/'tools/raven7_grip.py').read_bytes()).hexdigest().upper())
    (out/'VRTomahawk.json').write_text(json.dumps(report,indent=2))
    scene.render.engine='CYCLES'; scene.cycles.samples=96; scene.cycles.use_denoising=True
    scene.world=bpy.data.worlds.new('Charcoal studio'); scene.world.use_nodes=True
    scene.world.node_tree.nodes['Background'].inputs[0].default_value=(.025,.032,.038,1)
    scene.world.node_tree.nodes['Background'].inputs[1].default_value=.35
    # Neutral studio reflections illuminate metals independently of the dark
    # camera backdrop, avoiding a black-metal preview in a black environment.
    wn=scene.world.node_tree.nodes;wl=scene.world.node_tree.links
    ambient=wn.new('ShaderNodeBackground');ambient.inputs[0].default_value=(.24,.26,.28,1);ambient.inputs[1].default_value=.8
    rays=wn.new('ShaderNodeLightPath');wmix=wn.new('ShaderNodeMixShader')
    wl.new(rays.outputs['Is Camera Ray'],wmix.inputs[0]);wl.new(ambient.outputs[0],wmix.inputs[1])
    wl.new(wn['Background'].outputs[0],wmix.inputs[2]);wl.new(wmix.outputs[0],wn['World Output'].inputs['Surface'])
    def point(ob,at): ob.rotation_euler=(Vector(at)-ob.location).to_track_quat('-Z','Y').to_euler()
    k=LENGTH_CM/31.2  # Review staging was framed for the 312 mm sheet.
    for name,loc,power,size in [('Key',(-15,25,35),22000,22),('Rim',(18,-18,25),26000,18),('Fill',(-20,-10,5),16000,15),('Front',(5,45,5),4000,26)]:
        data=bpy.data.lights.new(name,'AREA'); data.energy=power*k*k; data.shape='DISK'; data.size=size*k
        light=bpy.data.objects.new(name,data); scene.collection.objects.link(light); light.location=Vector(loc)*k; point(light,(0,0,8*k))
    cam=bpy.data.objects.new('Review camera',bpy.data.cameras.new('Review camera')); scene.collection.objects.link(cam)
    cam.location=Vector((30,85,18))*k; point(cam,(0,0,4*k)); cam.rotation_euler.rotate_axis('Z',.284); cam.data.type='ORTHO'; cam.data.ortho_scale=37*k; scene.camera=cam
    scene.render.resolution_x=1000; scene.render.resolution_y=1200; scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG'; scene.view_settings.view_transform='AgX'; scene.render.filepath=str(review/'hero.png')
    # Camera bloom is a preview of the active edge, not baked into textures.
    comp=bpy.data.node_groups.new('RAVEN restrained optical glow','CompositorNodeTree')
    comp.interface.new_socket(name='Image',in_out='OUTPUT',socket_type='NodeSocketColor')
    src=comp.nodes.new('CompositorNodeRLayers');src.scene=scene
    glow=comp.nodes.new('CompositorNodeGlare')
    glow.inputs['Type'].default_value='Fog Glow';glow.inputs['Quality'].default_value='High'
    glow.inputs['Threshold'].default_value=.8;glow.inputs['Strength'].default_value=.45;glow.inputs['Size'].default_value=.075
    dest=comp.nodes.new('NodeGroupOutput')
    comp.links.new(src.outputs['Image'],glow.inputs['Image']);comp.links.new(glow.outputs['Image'],dest.inputs['Image'])
    scene.compositing_node_group=comp
    for area in bpy.context.screen.areas if bpy.context.screen else []:
        if area.type=='VIEW_3D':
            area.spaces.active.region_3d.view_perspective='CAMERA'
            area.spaces.active.shading.type='MATERIAL'
    bpy.ops.wm.save_as_mainfile(filepath=str(out/'VRTomahawk-RAVEN7.blend'))
    return report
