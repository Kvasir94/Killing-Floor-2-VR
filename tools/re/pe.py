"""
Minimal PE64 reader: section map, RVA<->file-offset translation, imports and
delay-load descriptors.

Exists so every address this project records is an RVA (and a default-base VA)
rather than a file offset. A file offset is useless the moment you attach a
debugger; an RVA survives, and with the image base it is what a signature scan
and a hook actually need.

Pinned target: KFGame.exe v1.0.8767.0,
SHA256 77AB9C2CF43AEAA3038274FFF3822064815A3EA02A1B3C81870CDC12A885C994.
Anything read out of a different binary is meaningless here -- fail closed.
"""
import struct
from dataclasses import dataclass
from typing import Optional


@dataclass
class Section:
    name: str
    vaddr: int          # RVA
    vsize: int
    raw_ptr: int        # file offset
    raw_size: int
    characteristics: int

    @property
    def readable(self) -> bool:   return bool(self.characteristics & 0x40000000)
    @property
    def writable(self) -> bool:   return bool(self.characteristics & 0x80000000)
    @property
    def executable(self) -> bool: return bool(self.characteristics & 0x20000000)

    def flags(self) -> str:
        return ('r' if self.readable else '-') + \
               ('w' if self.writable else '-') + \
               ('x' if self.executable else '-')


class PE:
    def __init__(self, path: str):
        self.path = path
        with open(path, 'rb') as f:
            self.data = f.read()
        d = self.data
        if d[:2] != b'MZ':
            raise ValueError('not a PE')
        pe = struct.unpack_from('<I', d, 0x3C)[0]
        if d[pe:pe + 4] != b'PE\0\0':
            raise ValueError('bad PE signature')

        self.machine, nsec, _, _, _, opt_size, self.characteristics = \
            struct.unpack_from('<HHIIIHH', d, pe + 4)
        opt = pe + 24
        magic = struct.unpack_from('<H', d, opt)[0]
        if magic != 0x20B:
            raise ValueError('not PE32+ (x64)')

        self.entry_rva = struct.unpack_from('<I', d, opt + 16)[0]
        self.image_base = struct.unpack_from('<Q', d, opt + 24)[0]
        self.dll_characteristics = struct.unpack_from('<H', d, opt + 70)[0]
        nrva = struct.unpack_from('<I', d, opt + 108)[0]
        dd = opt + 112
        self.dirs = [struct.unpack_from('<II', d, dd + i * 8) for i in range(nrva)]

        sec_off = opt + opt_size
        self.sections = []
        for i in range(nsec):
            o = sec_off + i * 40
            name = d[o:o + 8].rstrip(b'\0').decode('latin-1')
            vsize, vaddr, raw_size, raw_ptr = struct.unpack_from('<IIII', d, o + 8)
            ch = struct.unpack_from('<I', d, o + 36)[0]
            self.sections.append(Section(name, vaddr, vsize, raw_ptr, raw_size, ch))

    # -- address translation ------------------------------------------------
    def sec_for_rva(self, rva: int) -> Optional[Section]:
        for s in self.sections:
            if s.vaddr <= rva < s.vaddr + max(s.vsize, s.raw_size):
                return s
        return None

    def rva_to_off(self, rva: int) -> Optional[int]:
        s = self.sec_for_rva(rva)
        if not s or rva - s.vaddr >= s.raw_size:
            return None                      # uninitialised (.bss-like) data
        return s.raw_ptr + (rva - s.vaddr)

    def off_to_rva(self, off: int) -> Optional[int]:
        for s in self.sections:
            if s.raw_ptr <= off < s.raw_ptr + s.raw_size:
                return s.vaddr + (off - s.raw_ptr)
        return None

    def va(self, rva: int) -> int:
        return self.image_base + rva

    def read(self, rva: int, n: int) -> Optional[bytes]:
        o = self.rva_to_off(rva)
        return None if o is None else self.data[o:o + n]

    def cstr(self, rva: int, limit: int = 512) -> str:
        o = self.rva_to_off(rva)
        if o is None:
            return ''
        end = self.data.find(b'\0', o, o + limit)
        return self.data[o:end if end >= 0 else o + limit].decode('latin-1')

    # -- directories --------------------------------------------------------
    def _dir(self, i: int):
        return self.dirs[i] if i < len(self.dirs) else (0, 0)

    def imports(self):
        """[(dll, [symbol, ...])] from the normal import directory."""
        rva, _ = self._dir(1)
        if not rva:
            return []
        out = []
        i = 0
        while True:
            e = self.read(rva + i * 20, 20)
            if not e or len(e) < 20 or e == b'\0' * 20:
                break
            oft, _, _, name_rva, first = struct.unpack('<IIIII', e)
            dll = self.cstr(name_rva)
            syms = []
            thunk = oft or first
            j = 0
            while True:
                v = self.read(thunk + j * 8, 8)
                if not v or len(v) < 8:
                    break
                val = struct.unpack('<Q', v)[0]
                if val == 0:
                    break
                if val & (1 << 63):
                    syms.append(f'Ordinal#{val & 0xFFFF}')
                else:
                    syms.append(self.cstr(val + 2))   # skip the 2-byte hint
                j += 1
            out.append((dll, syms))
            i += 1
        return out

    def delay_imports(self):
        """
        [(dll, iat_rva, [(symbol, iat_slot_rva), ...])] from the delay-load
        directory.

        The IAT slot RVA is the actionable part: it is the pointer the game
        calls through once the delay-load helper has resolved it, so it is both
        where a hook can be installed and where a hook can be verified.
        """
        rva, _ = self._dir(13)
        if not rva:
            return []
        out = []
        i = 0
        while True:
            e = self.read(rva + i * 32, 32)
            if not e or len(e) < 32 or e == b'\0' * 32:
                break
            attrs, name_rva, mod_rva, iat_rva, int_rva, _, _, _ = struct.unpack('<8I', e)
            dll = self.cstr(name_rva)
            syms = []
            j = 0
            while True:
                v = self.read(int_rva + j * 8, 8)
                if not v or len(v) < 8:
                    break
                val = struct.unpack('<Q', v)[0]
                if val == 0:
                    break
                nm = (f'Ordinal#{val & 0xFFFF}' if val & (1 << 63)
                      else self.cstr((val & 0xFFFFFFFF) + 2))
                syms.append((nm, iat_rva + j * 8))
                j += 1
            out.append((dll, iat_rva, syms))
            i += 1
        return out


# ---------------------------------------------------------------------------
# .pdata / RUNTIME_FUNCTION
#
# x64 requires unwind data for every non-leaf function, so the exception
# directory is a near-complete function table -- start and end address for the
# whole of .text, with no symbols needed. On a binary with no PDB and no RTTI
# this is the single most useful structure present: it turns "an address" into
# "a function", which is what makes disassembly and attribution possible at all.
def runtime_functions(pe):
    """[(begin_rva, end_rva, unwind_rva)], sorted by begin."""
    rva, size = pe._dir(3)
    if not rva:
        return []
    out = []
    for i in range(size // 12):
        e = pe.read(rva + i * 12, 12)
        if not e or len(e) < 12:
            break
        b, en, u = struct.unpack('<III', e)
        if b == 0 and en == 0:
            continue
        out.append((b, en, u))
    out.sort()
    return out


def function_at(funcs, rva):
    """The (begin, end, unwind) entry containing rva, or None."""
    lo, hi = 0, len(funcs) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        b, e, u = funcs[mid]
        if rva < b:
            hi = mid - 1
        elif rva >= e:
            lo = mid + 1
        else:
            return funcs[mid]
    return None
