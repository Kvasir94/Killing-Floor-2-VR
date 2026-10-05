"""Write the editor import config from verified local conversion receipts.

This imports the original geometry and decoded assets, not the complete Source
renderer. Outstanding animation/shader/audio differences stay in the report.
"""
from pathlib import Path
import hashlib
import json
import struct
from prepare_engineer_model_data import generate

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/engineer-meshes'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def ini(value):
    if isinstance(value, dict):
        return '(' + ','.join(f'{k}={ini(v)}' for k, v in value.items()) + ')'
    if isinstance(value, (list, tuple)):
        return '(' + ','.join(ini(v) for v in value) + ')'
    if isinstance(value, bool):
        return 'True' if value else 'False'
    if isinstance(value, str):
        if any(c in value for c in ('"', '\r', '\n')):
            raise ValueError('Unsafe config string')
        return '"' + value.replace('\\', '/') + '"'
    return str(value)


def prepare_wave(path):
    """Losslessly expand TF2's unsigned 8-bit PCM for UE3's 16-bit importer.

    Sample rate, channels, sample count and ancillary RIFF chunks are kept.
    No resampling, loudness normalization or lossy codec is involved.
    """
    raw = path.read_bytes()
    if raw[:4] != b'RIFF' or raw[8:12] != b'WAVE' or len(raw) != struct.unpack_from('<I', raw, 4)[0] + 8:
        raise ValueError(f'Invalid RIFF/WAVE: {path}')
    chunks, offset = [], 12
    while offset < len(raw):
        tag, size = struct.unpack_from('<4sI', raw, offset)
        content = raw[offset + 8:offset + 8 + size]
        if len(content) != size:
            raise ValueError(f'Truncated WAV chunk: {path}')
        chunks.append((tag, content))
        offset += 8 + size + (size & 1)
    formats = [body for tag, body in chunks if tag == b'fmt ']
    data_chunks = [body for tag, body in chunks if tag == b'data']
    if len(formats) != 1 or len(data_chunks) != 1 or len(formats[0]) < 16:
        raise ValueError(f'Unsupported WAV layout: {path}')
    codec, channels, rate, byte_rate, alignment, bits = struct.unpack_from('<HHIIHH', formats[0])
    if codec != 1 or channels not in (1, 2) or bits not in (8, 16) or alignment != channels * bits // 8:
        raise ValueError(f'Unsupported original PCM format: {path}')
    if byte_rate != rate * alignment or len(data_chunks[0]) % alignment:
        raise ValueError(f'Invalid PCM sample framing: {path}')
    if bits == 8:
        converted = []
        for tag, body in chunks:
            if tag == b'fmt ':
                body = bytearray(body)
                struct.pack_into('<IHH', body, 8, rate * channels * 2, channels * 2, 16)
                body = bytes(body)
            elif tag == b'data':
                body = b''.join(struct.pack('<h', (value - 128) * 256) for value in body)
            converted.append(struct.pack('<4sI', tag, len(body)) + body + b'\0' * (len(body) & 1))
        payload = b'WAVE' + b''.join(converted)
        cooked_input = b'RIFF' + struct.pack('<I', len(payload)) + payload
    else:
        cooked_input = raw
    output = OUT / 'sounds' / path.name
    output.parent.mkdir(exist_ok=True)
    output.write_bytes(cooked_input)
    return output, {'source': str(path), 'source_sha256': sha(path), 'file': str(output), 'sha256': sha(output),
                    'channels': channels, 'sample_rate': rate, 'sample_frames': len(data_chunks[0]) // alignment,
                    'source_bits': bits, 'import_bits': 16, 'conversion': 'u8-to-s16-exact' if bits == 8 else 'byte-identical'}


def main():
    report = json.loads((OUT / 'manifest.json').read_text())
    if report['generator_sha256'] != sha(ROOT / 'tools/build_engineer_meshes.py'):
        raise ValueError('Engineer mesh generator changed; regenerate the models')
    if report['extract_sha256'] != sha(ROOT / 'extract/engineer/manifest.json'):
        raise ValueError('Original extraction changed; regenerate the models')
    originals = json.loads((ROOT / 'extract/engineer/manifest.json').read_text())['files']
    materials, meshes, sockets, sounds, audio = [], [], [], [], []
    for entry in report['materials'].values():
        props = entry['properties']
        for field in ('diffuse', 'normal', 'lightwarp'):
            if entry[field] and not Path(entry[field]).is_file():
                raise FileNotFoundError(entry[field])
        materials.append(dict(AssetName=entry['name'], TextureFile=entry['diffuse'], NormalFile=entry['normal'],
            bUnlit=entry['shader'].lower() == 'unlitgeneric', bTranslucent=props.get('$translucent') == '1',
            bAdditive=props.get('$additive') == '1', bTwoSided=props.get('$nocull') == '1',
            bSelfIllum=props.get('$selfillum') == '1', PhongPower=float(props.get('$phongexponent', 32))))
    for name, entry in report['models'].items():
        if sha(entry['fbx']) != entry['sha256']:
            raise ValueError(f'Modified converted mesh: {name}')
        meshes.append(dict(AssetName=name, MeshFile=entry['fbx'], MaterialNames=entry['materials'],
                           bStatic=entry['kind'] == 'static', bAnimations=bool(entry['animations']),
                           Animations=[dict(TakeName=a['take'], Frames=a['frames'], FPS=a['fps'])
                                       for a in entry['animations']]))
        if entry['kind'] != 'static':
            sockets.extend(dict(MeshName=name, SocketName=s['name'], BoneName=s['bone']) for s in entry['sockets'])
    for path in sorted((ROOT / 'extract/engineer/sound').rglob('*.wav')):
        relative = path.relative_to(ROOT / 'extract/engineer').as_posix()
        if relative not in originals or sha(path) != originals[relative]['sha256']:
            raise ValueError(f'Original audio changed: {path}')
        if any(entry['AssetName'] == path.stem for entry in sounds):
            raise ValueError(f'Duplicate sound asset name: {path}')
        prepared, receipt = prepare_wave(path)
        sounds.append(dict(AssetName=path.stem, WaveFile=str(prepared)))
        audio.append(receipt)
    lines = ['[EngineerAssetTools.VREngineerAssetCommandlet]']
    for key, entries in [('Materials', materials), ('Meshes', meshes), ('Sockets', sockets), ('Sounds', sounds)]:
        lines.extend(key + '=' + ini(entry) for entry in entries)
    (OUT / 'assets.ini').write_text('\n'.join(lines) + '\n')
    pending = report['parity_pending'] + ['Source audio randomization, volume/pitch and distance attenuation',
                                         'Source blueprint rejection rendering']
    summary = dict(materials=len(materials), meshes=len(meshes), sockets=len(sockets), sounds=len(sounds),
                   parity_pending=pending, audio=audio)
    summary['model_runtime_data'] = generate(report, ROOT / 'script/EngineerStaging/Classes/VREngineerModelData.uc')
    (OUT / 'conversion-report.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps({key: value for key, value in summary.items() if key != 'audio'}))


if __name__ == '__main__':
    main()
