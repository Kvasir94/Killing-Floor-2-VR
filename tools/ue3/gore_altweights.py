"""
Read a KF2 gore skeletal mesh's alternate bone weights (the data MEAT swaps in
when a joint breaks) straight from a cooked package. UModel drops this data.

Format and method: docs/re/ZED_GORE_MESH_ALT_WEIGHTS.md.

    python tools/ue3/gore_altweights.py <package.upk> <SkeletalMeshName> \
        [--gltf <UModel export of the same mesh, for bone names>] [--out file.json]

Output JSON: vertex count, chunk bone maps, and per breakable joint the parent,
the vertex list (stock GPU vertex order) and each vertex's alternate influences.
Use --geometry to also write positions (cm, stock axes), triangles and base
weights in the same vertex order, so a mesh can be rebuilt without UModel's
reordering.
"""
import argparse, json, os, re, struct, subprocess, sys

DEFAULT_UMODEL = r'umodel.exe'


def export_span(pkg, mesh, umodel):
    out = subprocess.run([umodel, '-list', pkg], capture_output=True, text=True,
                         cwd=os.path.dirname(pkg) or '.').stdout
    for line in out.splitlines():
        m = re.match(r'\s*\d+\s+([0-9A-F]+)\s+([0-9A-F]+)\s+SkeletalMesh\s+(\S+)$', line)
        if m and m.group(3) == mesh:
            return int(m.group(1), 16), int(m.group(2), 16)
    raise SystemExit(f'{mesh}: no SkeletalMesh export of that name in {pkg}')


def i32(b, o): return struct.unpack_from('<i', b, o)[0]


def find_vertex_count(blob, base):
    """RawPointIndices is bulk data: flags, count, size=4*count, absolute file offset."""
    for o in range(0, len(blob) - 16):
        flags, cnt, size, off = struct.unpack_from('<iiii', blob, o)
        if flags == 0 and 16 < cnt < 200000 and size == 4 * cnt and off == base + o + 16:
            return cnt
    raise SystemExit('vertex count (RawPointIndices) not found')


def find_chunks(blob, nv):
    """Skeletal chunks: BoneMap (count + uint16[]), NumRigid, NumSoft, MaxInfluences."""
    chunks, total = [], 0
    for o in range(0, len(blob) - 8):
        n = i32(blob, o)
        if not 3 <= n <= 255 or o + 4 + 2 * n + 12 > len(blob):
            continue
        bm = struct.unpack_from('<%dH' % n, blob, o + 4)
        if max(bm) >= 1024 or len(set(bm)) != n:
            continue
        nr, ns, mx = struct.unpack_from('<3i', blob, o + 4 + 2 * n)
        if 0 <= nr and 0 <= ns and 0 < nr + ns <= nv - total and 1 <= mx <= 4:
            chunks.append(dict(offset=o, base=total, count=nr + ns, bonemap=list(bm)))
            total += nr + ns
            if total == nv:
                return chunks
    raise SystemExit(f'chunks cover {total} of {nv} vertices')


def find_vertex_buffer(blob, nv):
    for o in range(0, len(blob) - 8):
        stride, cnt = struct.unpack_from('<ii', blob, o)
        if cnt == nv and stride in (32, 36, 40, 44, 48) and o + 8 + stride * nv <= len(blob):
            # Position floats sit at +16 in KF2's GPU skin vertex; sanity check a few.
            ok = all(abs(struct.unpack_from('<f', blob, o + 8 + stride * v + 16 + 4 * k)[0]) < 1e5
                     for v in range(0, nv, max(1, nv // 50)) for k in range(3))
            if ok:
                return o + 8, stride
    raise SystemExit('GPU vertex buffer not found')


def find_index_buffer(blob, nv):
    best = None
    for o in range(0, len(blob) - 8):
        size, cnt = struct.unpack_from('<ii', blob, o)
        if size in (2, 4) and cnt >= 3 and cnt % 3 == 0 and o + 8 + size * cnt <= len(blob):
            fmt = 'H' if size == 2 else 'I'
            idx = struct.unpack_from('<%d%s' % (cnt, fmt), blob, o + 8)
            if max(idx) == nv - 1 and (best is None or cnt > best[1]):
                best = (o + 8, cnt, fmt)
    if not best:
        raise SystemExit('index buffer not found')
    return best


def valid_influences(blob, off, pairs, chunks):
    """Every listed vertex's alternate influence must be a full weight over bones in its chunk."""
    for _, _, vs in pairs:
        for v in vs:
            c = next(c for c in chunks if c['base'] <= v < c['base'] + c['count'])
            w = blob[off + 8 * v: off + 8 * v + 4]; b = blob[off + 8 * v + 4: off + 8 * v + 8]
            if abs(sum(w) - 255) > 3 or any(w[k] and b[k] >= len(c['bonemap']) for k in range(4)):
                return False
    return True


def find_influences(blob, nv, chunks):
    """FSkeletalMeshVertexInfluences: TArray count, then Influences (count NV, 8 bytes each:
    4 weights, 4 chunk-local bones), then TMap<(bone,parent) -> TArray<vertex>>."""
    for o in range(0, len(blob) - 12):
        if i32(blob, o + 4) != nv or not 1 <= i32(blob, o) <= 8:
            continue
        m = o + 8 + 8 * nv
        if m + 4 > len(blob):
            continue
        n = i32(blob, m)
        if not 1 <= n <= 255:
            continue
        p, ok, pairs = m + 4, True, []
        for _ in range(n):
            a, b, c = struct.unpack_from('<iii', blob, p)
            if not (0 <= a < 1024 and 0 <= b < 1024 and 0 < c <= nv):
                ok = False; break
            vs = struct.unpack_from('<%di' % c, blob, p + 12)
            if max(vs) >= nv or min(vs) < 0:
                ok = False; break
            pairs.append((a, b, list(vs))); p += 12 + 4 * c
        if ok and valid_influences(blob, o + 8, pairs, chunks):
            return o + 8, pairs, i32(blob, o)
    raise SystemExit('alternate influences not found (not a gore mesh?)')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('package'); ap.add_argument('mesh')
    ap.add_argument('--gltf'); ap.add_argument('--out'); ap.add_argument('--geometry', action='store_true')
    ap.add_argument('--umodel', default=DEFAULT_UMODEL)
    a = ap.parse_args()
    base, size = export_span(a.package, a.mesh, a.umodel)
    blob = open(a.package, 'rb').read()[base:base + size]
    nv = find_vertex_count(blob, base)
    chunks = find_chunks(blob, nv)
    infl_off, pairs, sets = find_influences(blob, nv, chunks)
    names = None
    if a.gltf:
        g = json.load(open(a.gltf))
        names = [g['nodes'][j]['name'] for j in g['skins'][0]['joints']]
    nm = (lambda i: names[i]) if names else (lambda i: i)

    def chunk_of(v):
        for c in chunks:
            if c['base'] <= v < c['base'] + c['count']:
                return c

    def alt(v):
        w = blob[infl_off + 8 * v: infl_off + 8 * v + 4]
        b = blob[infl_off + 8 * v + 4: infl_off + 8 * v + 8]
        bm = chunk_of(v)['bonemap']
        return [[nm(bm[b[k]]), w[k]] for k in range(4) if w[k]]

    joints = {}
    for bone, parent, vs in pairs:
        joints[str(nm(bone))] = dict(parent=nm(parent), vertices=vs, alt={str(v): alt(v) for v in vs})
    out = dict(package=os.path.basename(a.package), mesh=a.mesh, vertices=nv, influence_sets=sets,
               chunks=[dict(base=c['base'], count=c['count'], bones=[nm(x) for x in c['bonemap']]) for c in chunks],
               joints=joints)
    if a.geometry:
        vb, stride = find_vertex_buffer(blob, nv)
        ib, ni, fmt = find_index_buffer(blob, nv)
        out['positions_cm'] = [list(struct.unpack_from('<3f', blob, vb + stride * v + 16)) for v in range(nv)]
        idx = struct.unpack_from('<%d%s' % (ni, fmt), blob, ib)
        out['triangles'] = [list(idx[k:k + 3]) for k in range(0, ni, 3)]
        bw = []
        for v in range(nv):
            b = blob[vb + stride * v + 8: vb + stride * v + 12]; w = blob[vb + stride * v + 12: vb + stride * v + 16]
            bm = chunk_of(v)['bonemap']
            bw.append([[nm(bm[b[k]]), w[k]] for k in range(4) if w[k]])
        out['base_weights'] = bw
    text = json.dumps(out, separators=(',', ':'))
    if a.out:
        open(a.out, 'w', encoding='utf-8').write(text)
    else:
        sys.stdout.write(text)
    print(f'{a.mesh}: {nv} vertices, {len(chunks)} chunks, {len(joints)} breakable joints', file=sys.stderr)
    for k, j in joints.items():
        print(f'  {k:<16} <- {j["parent"]:<16} {len(j["vertices"])} vertices', file=sys.stderr)


if __name__ == '__main__':
    main()
