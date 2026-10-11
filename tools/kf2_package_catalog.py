"""List the objects inside cooked KF2 packages (.upk) without the editor.

Reads the UE3 package summary, name, import and export tables and prints one
line per export as  <Package>.<Outer...>.<Name>  <Class>, so effect, material
and mesh paths can be looked up for DynamicLoadObject without opening the SDK.
Compressed chunk tables are reported but not decompressed (KF2's PC packages
keep their tables uncompressed).

    python tools/kf2_package_catalog.py <package.upk | folder> [--class ParticleSystem,Material] [--grep text]
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

MAGIC = 0x9E2A83C1


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def u8(self):
        v = self.data[self.pos]; self.pos += 1; return v

    def u16(self):
        v = struct.unpack_from("<H", self.data, self.pos)[0]; self.pos += 2; return v

    def i32(self):
        v = struct.unpack_from("<i", self.data, self.pos)[0]; self.pos += 4; return v

    def u32(self):
        v = struct.unpack_from("<I", self.data, self.pos)[0]; self.pos += 4; return v

    def u64(self):
        v = struct.unpack_from("<Q", self.data, self.pos)[0]; self.pos += 8; return v

    def fstring(self):
        n = self.i32()
        if n == 0:
            return ""
        if n < 0:
            raw = self.data[self.pos:self.pos + (-n) * 2]; self.pos += (-n) * 2
            return raw.decode("utf-16-le", errors="replace").rstrip("\0")
        raw = self.data[self.pos:self.pos + n]; self.pos += n
        return raw.decode("latin-1").rstrip("\0")

    def name(self, names):
        idx = self.i32(); number = self.i32()
        base = names[idx] if 0 <= idx < len(names) else f"<bad name {idx}>"
        return f"{base}_{number - 1}" if number else base


def read_package(path: Path):
    data = path.read_bytes()
    r = Reader(data)
    if r.u32() != MAGIC:
        raise ValueError("not an Unreal package")
    version = r.u16(); licensee = r.u16()
    r.u32()  # header size
    r.fstring()  # folder
    r.u32()  # package flags
    name_count, name_offset = r.i32(), r.i32()
    export_count, export_offset = r.i32(), r.i32()
    import_count, import_offset = r.i32(), r.i32()
    r.i32()  # depends offset
    if version >= 623:
        r.i32(); r.i32(); r.i32()  # import/export guid table
    if version >= 584:
        r.i32()  # thumbnail table
    r.pos += 16  # guid
    for _ in range(r.i32()):
        r.i32(); r.i32(); r.i32()
    r.u32(); r.u32()  # engine, cooker
    compression = r.u32()
    chunks = [(r.i32(), r.i32(), r.i32(), r.i32()) for _ in range(r.i32())]
    if chunks and any(c[2] <= name_offset < c[2] + c[3] for c in chunks):
        raise ValueError(f"name table is inside a compressed chunk (flags {compression})")

    r.pos = name_offset
    names = []
    for _ in range(name_count):
        names.append(r.fstring())
        r.u64()  # flags
    r.pos = import_offset
    imports = []
    for _ in range(import_count):
        r.name(names)  # package
        cls = r.name(names)
        outer = r.i32()
        obj = r.name(names)
        imports.append((obj, cls, outer))
    r.pos = export_offset
    exports = []
    for _ in range(export_count):
        cls_idx = r.i32(); r.i32(); outer = r.i32()
        obj = r.name(names)
        r.i32()  # archetype
        r.u64()  # object flags
        r.i32(); r.i32(); r.i32()  # serial size, offset, export flags
        net = r.i32(); r.pos += 4 * net
        r.pos += 16  # guid
        r.i32()  # package flags
        exports.append((obj, cls_idx, outer))

    def ref_name(idx):
        if idx > 0:
            return exports[idx - 1][0]
        if idx < 0:
            return imports[-idx - 1][0]
        return ""

    def ref_outer(idx):
        if idx > 0:
            return exports[idx - 1][2]
        if idx < 0:
            return imports[-idx - 1][2]
        return 0

    def full_path(idx):
        parts = []
        guard = 0
        while idx and guard < 32:
            parts.append(ref_name(idx)); idx = ref_outer(idx); guard += 1
        return ".".join(reversed(parts))

    rows = []
    for i, (obj, cls_idx, outer) in enumerate(exports, start=1):
        cls = ref_name(cls_idx) or "Package"
        rows.append((path.stem + "." + full_path(i), cls))
    return version, licensee, rows


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", help="a .upk or a folder searched recursively")
    ap.add_argument("--class", dest="classes", help="comma-separated class filter, e.g. ParticleSystem,Material,MaterialInstanceConstant")
    ap.add_argument("--grep", help="case-insensitive substring on the object path")
    ap.add_argument("--summary", action="store_true", help="per-package class counts only")
    args = ap.parse_args(argv)
    target = Path(args.target)
    files = [target] if target.is_file() else sorted(target.rglob("*.upk"))
    classes = {c.strip().lower() for c in args.classes.split(",")} if args.classes else None
    grep = args.grep.lower() if args.grep else None
    for file in files:
        try:
            version, licensee, rows = read_package(file)
        except Exception as error:  # noqa: BLE001 - report and continue over a folder
            print(f"# {file.name}: {error}", file=sys.stderr)
            continue
        if args.summary:
            counts = {}
            for _, cls in rows:
                counts[cls] = counts.get(cls, 0) + 1
            top = ", ".join(f"{c}={n}" for c, n in sorted(counts.items(), key=lambda kv: -kv[1])[:8])
            print(f"{file.name} (v{version}/{licensee}, {len(rows)} exports): {top}")
            continue
        for path, cls in rows:
            if classes and cls.lower() not in classes:
                continue
            if grep and grep not in path.lower():
                continue
            print(f"{path}\t{cls}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
