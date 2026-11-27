"""
Resolve UnrealScript native functions in KFGame.exe to their code addresses.

UE3 registers every native with a table of {const ANSICHAR* Name, Native Ptr}
pairs, where Name is the class name glued to "exec" + the function name, e.g.
"UKFMeleeHelperBaseexecTickHitboxCollisionDetection". This finds each name,
finds the 8-byte pointer to it, and prints the function pointer stored next to
it as an RVA. The exec thunk it returns usually unpacks the script parameters
and calls a vtable slot; decompile it (tools/re/DecompileAt.java) to see which.

Usage:
    python -I tools/re/native_lookup.py UKFMeleeHelperBaseexecTickHitboxCollisionDetection
    python -I tools/re/native_lookup.py AKFWeaponexecServerRegisterImpact1 AActorexecTraceAllPhysicsAssetInteractions
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pe import PE  # noqa: E402

TARGET = r"D:/SteamLibrary/steamapps/common/killingfloor2/Binaries/Win64/KFGame.exe"
IMAGE_BASE = 0x140000000


def main(names):
    pe = PE(TARGET)
    data = open(TARGET, "rb").read()
    for name in names:
        found = False
        for m in re.finditer(re.escape(name.encode()) + b"\x00", data):
            if data[m.start() - 1] != 0:
                continue
            va = IMAGE_BASE + pe.off_to_rva(m.start())
            for r in re.finditer(re.escape(struct.pack("<Q", va)), data):
                fn = struct.unpack("<Q", data[r.start() + 8:r.start() + 16])[0]
                print(f"{name} exec_rva={fn - IMAGE_BASE:#x}")
                found = True
        if not found:
            print(f"{name} not found")


if __name__ == "__main__":
    main(sys.argv[1:])
