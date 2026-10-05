"""Dump Arizona Sunshine 2's gameplay settings (JSON TextAssets) for reference.

Run: python tools/re/as2_config_dump.py OUT_DIR [--assets PATH]

Vertigo ships every *TO settings table (GameSettings, UserSettings,
LocomotionSettings, RecoilModel, ...) as a plain JSON TextAsset inside
resources.assets. Each is stored as <int32 length><json>, the name as a
length-prefixed string just before it. This carves them out and writes both
the raw JSON and a compact text view without $type/$value wrappers.
Read-only against the game install. See docs/re/ARIZONA_SUNSHINE_2_RIG.md.
"""
import argparse
import json
import mmap
import os
import re
import struct

DEFAULT_ASSETS = (r"D:\SteamLibrary\steamapps\common\Arizona Sunshine 2"
                  r"\ArizonaSunshine2_Data\resources.assets")
START = re.compile(rb'\{\r?\n\s*"\$(?:id|type|object|value)"')


def carve(assets):
    with open(assets, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
        for match in START.finditer(m):
            start = match.start()
            length = struct.unpack_from("<I", m, start - 4)[0]
            if not 10 <= length <= 200_000_000 or start + length > len(m):
                continue
            body = m[start:start + length]
            if not body.rstrip().endswith(b"}"):
                continue
            name = None
            for size in range(1, 300):
                begin = start - 4 - (-size % 4) - size
                if begin < 4:
                    break
                if struct.unpack_from("<I", m, begin - 4)[0] == size:
                    raw = m[begin:begin + size]
                    if all(32 <= c < 127 for c in raw):
                        name = raw.decode()
                        break
            yield name or f"offset{start}", body


def compact(value):
    if isinstance(value, dict):
        plain = [k for k in value if not k.startswith("$")]
        if "$value" in value and not plain:
            return compact(value["$value"])
        if "$object" in value and len(value) == 1:
            return compact(value["$object"])
        out = {k: compact(v) for k, v in value.items()
               if not k.startswith("$") and not k.endswith("WasDeserialized")}
        if set(out) == {"x", "y", "z"}:
            return [out["x"], out["y"], out["z"]]
        return out
    if isinstance(value, list):
        return [compact(v) for v in value]
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--assets", default=DEFAULT_ASSETS)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    seen = {}
    for name, body in carve(args.assets):
        stem = re.sub(r"[^\w.-]", "_", name)
        seen[stem] = seen.get(stem, 0) + 1
        if seen[stem] > 1:
            stem += f"_{seen[stem] - 1}"
        with open(os.path.join(args.out, stem + ".json"), "wb") as f:
            f.write(body)
        try:
            text = json.dumps(compact(json.loads(body.decode("utf-8-sig"))), indent=1)
        except ValueError:
            continue
        with open(os.path.join(args.out, stem + ".txt"), "w", encoding="utf-8") as f:
            f.write(text)
        print(stem)


if __name__ == "__main__":
    main()
