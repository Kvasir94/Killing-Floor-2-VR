"""
Write MEAT alternate bone weights into an editor-saved KF2 package.

The pinned SDK's FBX commandlet path imports a gore skeletal mesh with its normal
weights only. This tool adds the alternate-weight set in stock's serialized layout
(docs/re/ZED_GORE_MESH_ALT_WEIGHTS.md): the SkeletalMesh export is rewritten with
the influence block inserted, appended at the end of the file, and the export
table entry is pointed at the new copy. Nothing else in the package moves.

    python tools/gore/patch_altweights.py <in.upk> <MeshName> <sidecar.json> <bones.gltf> <out.upk>

sidecar.json comes from the Blender export (per vertex: co, uv, alt, member).
bones.gltf is a UModel export of the imported mesh (bone order only).
"""
import json, os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'ue3'))
import gore_altweights as G


def main():
    pkg, mesh, sidecar, gltf, out = sys.argv[1:6]
    data = bytearray(open(pkg, 'rb').read())
    base, size = G.export_span(pkg, mesh, G.DEFAULT_UMODEL)
    blob = bytes(data[base:base + size])
    nv = G.find_vertex_count(blob, base)
    chunks = G.find_chunks(blob, nv)
    vb, stride = G.find_vertex_buffer(blob, nv)
    g = json.load(open(gltf))
    bones = [g['nodes'][j]['name'] for j in g['skins'][0]['joints']]
    bidx = {n: i for i, n in enumerate(bones)}
    side = json.load(open(sidecar))

    # 1. Match every imported vertex to a sidecar vertex by position, UV and base weights.
    grid = {}
    for i, v in enumerate(side['vertices']):
        x, y, z = v['co']
        key = (round(x * 10), round(-y * 10), round(z * 10))       # Blender scene -> UE (y flipped)
        grid.setdefault(key, []).append(i)

    def chunk_of(v):
        for c in chunks:
            if c['base'] <= v < c['base'] + c['count']:
                return c

    match = [None] * nv
    unmatched = 0
    for v in range(nv):
        o = vb + stride * v
        px, py, pz = struct.unpack_from('<3f', blob, o + 16)
        u, w = struct.unpack_from('<2e', blob, o + 28)
        best = None
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    for i in grid.get((round(px * 10) + dx, round(py * 10) + dy, round(pz * 10) + dz), ()):
                        s = side['vertices'][i]
                        d = abs(s['co'][0] - px) + abs(-s['co'][1] - py) + abs(s['co'][2] - pz)
                        if d > 0.02:
                            continue
                        duv = abs(s['uv'][0] - u) + abs((1 - s['uv'][1]) - w)
                        score = d + duv
                        if best is None or score < best[0]:
                            best = (score, i, duv)
        if best is None or best[2] > 0.01:
            unmatched += 1
        else:
            match[v] = best[1]
    print(f'{mesh}: {nv} vertices, {len(chunks)} chunks, {unmatched} unmatched')

    # 2. Alternate influences (chunk-local bones) and the per-break vertex lists.
    infl = bytearray()
    lists = {}
    dropped = 0
    for v in range(nv):
        w = [255, 0, 0, 0]; b = [0, 0, 0, 0]
        s = side['vertices'][match[v]] if match[v] is not None else None
        if s and s.get('alt'):
            local = {bone: k for k, bone in enumerate(chunk_of(v)['bonemap'])}
            pairs = [(local.get(bidx.get(n, -1)), wt) for n, wt in s['alt']]
            if any(k is None for k, _ in pairs):
                dropped += 1
            else:
                pairs = sorted(pairs, key=lambda p: -p[1])[:4]
                w = [p[1] for p in pairs] + [0] * (4 - len(pairs))
                b = [p[0] for p in pairs] + [0] * (4 - len(pairs))
                w[0] += 255 - sum(w)
                for j in s['member']:
                    lists.setdefault(j, []).append(v)
        infl += bytes(w) + bytes(b)
    print(f'alternate influences on {sum(len(x) for x in lists.values())} list entries, {dropped} vertices dropped (bone not in chunk)')

    parent = dict(side.get('parents', {}))
    block = struct.pack('<ii', 1, nv) + bytes(infl) + struct.pack('<i', len(lists))
    for j, vs in lists.items():
        block += struct.pack('<iii', bidx[j], bidx[parent[j]], len(vs)) + struct.pack('<%di' % len(vs), *vs)
    block += struct.pack('<iii', 0, 0, 0) + b'\x00'       # Sections, Chunks, RequiredBones empty; IWU_PartialSwap

    # 3. Insert after the GPU vertex buffer, where the saved mesh has an empty influence array.
    at = vb + stride * nv
    if struct.unpack_from('<i', blob, at)[0] != 0:
        raise SystemExit('expected an empty influence array after the vertex buffer')
    new = bytearray(blob[:at] + block + blob[at + 4:])
    delta = len(new) - len(blob)
    new_base = len(data)

    # 4. Bulk data inside the export stores absolute file offsets: flags, count, size, offset.
    fixed = 0
    for o in range(0, len(blob) - 16):
        flags, cnt, sz, off = struct.unpack_from('<iiii', blob, o)
        if cnt > 0 and sz > 0 and off == base + o + 16 and o + 16 + sz <= len(blob) and 0 <= flags < 0x200:
            no = o + (delta if o >= at else 0)
            struct.pack_into('<i', new, no + 12, new_base + no + 16)
            fixed += 1
    print(f'bulk offsets rebased: {fixed}')

    # 5. Point the export table entry (size, offset) at the appended copy.
    header_end = struct.unpack_from('<i', data, 8)[0]
    hits = [o for o in range(0, header_end - 8) if struct.unpack_from('<ii', data, o) == (size, base)]
    if len(hits) != 1:
        raise SystemExit(f'export table entry not found exactly once ({len(hits)})')
    struct.pack_into('<ii', data, hits[0], len(new), new_base)
    data += new
    open(out, 'wb').write(data)
    print(f'wrote {out}: export moved {hex(base)} -> {hex(new_base)}, +{delta} bytes')


if __name__ == '__main__':
    main()
