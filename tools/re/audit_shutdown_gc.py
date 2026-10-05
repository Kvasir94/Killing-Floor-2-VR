"""Recover the scanned reference from the pinned Engineer shutdown minidump.

Reads saved files only; never opens a process or modifies the game/dump. The
register interpretation is specific to the recorded KFGame fault, so both
input hashes and the fault location are checked before decoding anything.
See docs/re/ENGINEER_SHUTDOWN_2026-09-13.md for the disassembly evidence.
"""

import argparse
import hashlib
import json
import struct
from pathlib import Path


DUMP_SHA256 = "CA1EA63909451F2D10BF71C137D5704F6ED560BB0B170793C7F3AC6255ABD926"
GAME_SHA256 = "77AB9C2CF43AEAA3038274FFF3822064815A3EA02A1B3C81870CDC12A885C994"
FAULT_RVA = 0x1052B7


class SavedDump:
    """Read only bytes actually included in a Windows minidump."""

    def __init__(self, data):
        self.data = data
        if data[:4] != b"MDMP":
            raise ValueError("Not a Windows minidump")
        count, directory = self.unpack("<II", 8)
        self.streams = {}
        for i in range(count):
            kind, size, offset = self.unpack("<III", directory + 12 * i)
            self.slice(offset, size)
            self.streams[kind] = (offset, size)
        self.memory = []
        if 5 in self.streams:  # MemoryListStream
            p, _ = self.streams[5]
            for i in range(self.unpack("<I", p)[0]):
                self.add_memory(*self.unpack("<QII", p + 4 + i * 16))
        if 9 in self.streams:  # Memory64ListStream
            p, _ = self.streams[9]
            count, offset = self.unpack("<QQ", p)
            for i in range(count):
                address, size = self.unpack("<QQ", p + 16 + i * 16)
                self.add_memory(address, size, offset)
                offset += size
        if 3 in self.streams:  # ThreadListStream includes captured stacks
            p, _ = self.streams[3]
            for i in range(self.unpack("<I", p)[0]):
                self.add_memory(*self.unpack("<QII", p + 4 + i * 48 + 24))

    def slice(self, offset, size):
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise ValueError("Truncated minidump")
        return self.data[offset:offset + size]

    def unpack(self, fmt, offset):
        return struct.unpack(fmt, self.slice(offset, struct.calcsize(fmt)))

    def add_memory(self, address, size, offset):
        self.slice(offset, size)
        self.memory.append((address, size, offset))

    def read(self, address, size):
        for start, length, offset in self.memory:
            if start <= address and address + size <= start + length:
                return self.slice(offset + address - start, size)
        return None  # Missing bytes are unknown, never zero-filled.

    def value(self, address, fmt="<Q"):
        data = self.read(address, struct.calcsize(fmt))
        return None if data is None else struct.unpack(fmt, data)[0]

    def required(self, address, fmt="<Q"):
        value = self.value(address, fmt)
        if value is None:
            raise ValueError(f"Required memory is absent at {address:#x}")
        return value

    def modules(self):
        p, _ = self.streams[4]
        for i in range(self.unpack("<I", p)[0]):
            entry = p + 4 + i * 108
            base, size = self.unpack("<QI", entry)
            name_offset = self.unpack("<I", entry + 20)[0]
            length = self.unpack("<I", name_offset)[0]
            name = self.slice(name_offset + 4, length).decode("utf-16-le")
            yield {"base": base, "size": size, "name": name}

    def exception(self):
        p, _ = self.streams[6]
        context_size, context = self.unpack("<II", p + 160)
        self.slice(context, context_size)
        if context_size < 256:
            raise ValueError("Missing x64 exception context")
        registers = {
            name: self.unpack("<Q", context + offset)[0]
            for name, offset in (("rax", 120), ("rdx", 136), ("rbx", 144),
                                 ("rsp", 152), ("rdi", 176), ("r12", 216),
                                 ("r13", 224), ("r14", 232), ("r15", 240),
                                 ("rip", 248))
        }
        return self.unpack("<I", p + 8)[0], registers


def checked_file(path, expected):
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest().upper()
    if actual != expected:
        raise ValueError(f"Unrecognized evidence file: {path} (SHA256 {actual})")
    return data


def audit(dump_path, game_path):
    data = checked_file(dump_path, DUMP_SHA256)
    checked_file(game_path, GAME_SHA256)
    dump = SavedDump(data)
    modules = list(dump.modules())
    game = next(m for m in modules if m["name"].replace("\\", "/").split("/")[-1].lower() == "kfgame.exe")
    code, r = dump.exception()
    if code != 0xC0000005 or r["rip"] - game["base"] != FAULT_RVA:
        raise ValueError("Unrecognized fault context")

    # 104b16..104b5f retain the scanned object at [r12+10] and its class in
    # [rsp+28]. The token interpreter decodes type bits 8..11 and offset >>12.
    owner = dump.required(r["r12"] + 0x10)
    scan_base = dump.required(r["rsp"] + 0x30)
    owner_class = dump.required(owner + 0x50)
    token = dump.required(r["r15"] + r["r14"], "<I")
    token_count = dump.required(owner_class + 0x268, "<I")
    offset, kind = token >> 12, (token >> 8) & 0xF
    slot_value = dump.required(r["rdi"])
    invariants = {
        "class_matches_scan": owner_class == r["rdx"] == dump.required(r["rsp"] + 0x28),
        "token_stream_matches_class": dump.required(owner_class + 0x260) == r["r15"],
        "token_index_matches": r["r14"] == r["rbx"] * 4 and r["rbx"] < token_count,
        "scan_base_is_owner": scan_base == owner,
        "slot_matches_token": scan_base + offset == r["rdi"],
        "slot_matches_fault_target": slot_value == r["rax"],
        "outer_reference_token": kind == 2 and offset == 0x40,
    }
    if not all(invariants.values()):
        raise ValueError(f"Unexpected GC reference interpretation: {invariants}")
    return {
        "schema": "kf2vr/saved-shutdown-gc-reference/1",
        "dump": str(dump_path.resolve()), "dump_sha256": DUMP_SHA256,
        "game": str(game_path.resolve()), "game_sha256": GAME_SHA256,
        "exception_code": hex(code), "fault_rva": hex(FAULT_RVA),
        "owner": hex(owner), "owner_class": hex(owner_class),
        "owner_name_index": dump.required(owner + 0x48, "<I"),
        "owner_name_number": dump.required(owner + 0x4C, "<I"),
        "class_name_index": dump.required(owner_class + 0x48, "<I"),
        "token_index": r["rbx"], "token_count": token_count, "token": hex(token),
        "field": "UObject.Outer", "field_offset": hex(offset),
        "reference_slot": hex(r["rdi"]), "reference_value": hex(slot_value),
        "outer_header_captured": dump.read(slot_value, 0x58) is not None,
        "invariants": invariants,
        "limits": [
            "Name indices are runtime IDs, not resolved object or class names.",
            "Absent memory is not proof of a freed allocation.",
            "The invalid Outer reference is identified; its origin and a fix are not.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dump", required=True, type=Path)
    parser.add_argument("--game", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.dump, args.game), indent=2))


if __name__ == "__main__":
    main()
