#!/usr/bin/env python3
# Faithful Python port of Zagitta/gpu-unlock kernel/gpu_unlock/vbios_610.c
# (gpu_unlock_vbios_fwsec + expansion + descriptor) at pinned HEAD 7eb51bcc,
# for OFFLINE analysis of the llm2 BAR0 PROM dump (W0.3 gate).
# READ-ONLY analysis tool: parses a bytes image, trusts no pointer as host ptr.
import sys
from dataclasses import dataclass

APP_FWSEC = 0x85

def r8(b, o): return b[o]
def r16(b, o): return b[o] | (b[o+1] << 8)
def r32(b, o): return b[o] | (b[o+1] << 8) | (b[o+2] << 16) | (b[o+3] << 24)

def rng(length, off, nbytes):
    return 1 if (off > length or nbytes > length - off) else 0

def rom_sig(s): return s in (0xaa55, 0x4e56, 0xbb77)
def data_sig(s): return s in (0x52494350, 0x5344504e, 0x53494752)

@dataclass
class Fwsec:
    version: int = 0; image_off: int = 0; image_size: int = 0
    pkc_off: int = 0; interface_off: int = 0
    imem_pa: int = 0; imem_size: int = 0; imem_va: int = 0
    imem_sec_pa: int = 0; imem_sec_size: int = 0; imem_ns_size: int = 0
    dmem_pa: int = 0; dmem_size: int = 0; data_off: int = 0
    engine_mask: int = 0; ucode_id: int = 0; sig_count: int = 0
    sig_versions: int = 0; sig_off: int = 0; sig_bytes: int = 0

def expansion(rom, length, notes):
    pos, base, ext, images = 0, 0, 0, 0
    if length < 2 or not rom_sig(r16(rom, 0)):
        raise ValueError("expansion: bad root sig")
    while True:
        images += 1
        if images > 8 or rng(length, pos, 0x1a) or not rom_sig(r16(rom, pos)):
            raise ValueError(f"expansion: chain fail pos={pos:#x}")
        pcir = pos + r16(rom, pos + 0x18)
        if rng(length, pcir, 0x16): raise ValueError("pcir range")
        sig = r32(rom, pcir)
        if not data_sig(sig): raise ValueError(f"pcir data sig {sig:#x}")
        nbytes = r16(rom, pcir + 0x10) * 512
        last = r8(rom, pcir + 0x15) & 0x80
        npde = (pcir + r16(rom, pcir + 0x0a) + 15) & ~15
        if not rng(length, npde, 4) and r32(rom, npde) == 0x4544504e:
            if rng(length, npde, 10): raise ValueError("npde range")
            ext_rev, ext_len = r16(rom, npde + 4), r16(rom, npde + 6)
            if ext_rev in (0x100, 0x101):
                sub = r16(rom, npde + 8) * 512
                if ext_len < 10 or rng(length, npde, ext_len): raise ValueError("npde ext")
                if ext_len > 10: last = r8(rom, npde + 10) & 0x80
                elif sub < nbytes: last = 0
                nbytes = sub
        typ = r8(rom, pcir + 0x14)
        notes.append(f"ROM chain: pos={pos:#x} data={sig:#x} bytes={nbytes} type={typ:#x} last={last}")
        if not nbytes or rng(length, pos, nbytes): raise ValueError("image size")
        if not base and typ == 0: base = nbytes
        if not ext and typ == 0xe0: ext = pos
        if last: break
        pos += nbytes
    if ext and base and ext < base: raise ValueError("ext<base")
    adjust = (ext - base) if (ext and base) else 0
    notes.append(f"ROM expansion: base={base:#x} ext={ext:#x} adjust={adjust:#x}")
    return adjust

def descriptor_v3(rom, length, off, notes):
    fw = Fwsec()
    if rng(length, off, 44): raise ValueError("desc hdr range")
    hdr = r32(rom, off); size = hdr >> 16
    fw.version = (hdr >> 8) & 0xff
    notes.append(f"FWSEC descriptor: offset={off:#x} header={hdr:#x}")
    if (hdr & 1) and fw.version == 2:
        notes.append("v2 generic-loader descriptor (not GA102 expectation)")
        raise ValueError("v2 descriptor — GA102 family wants v3")
    if not (hdr & 1) or fw.version != 3 or size < 44:
        raise ValueError(f"unsupported descriptor ver={fw.version} size={size}")
    if rng(length, off, size): raise ValueError("desc body range")
    stored = r32(rom, off + 4)
    if not stored or stored > 0xffffffff - 255: raise ValueError("stored size")
    fw.image_size = (stored + 255) & ~255
    if rng(length, off + size, fw.image_size): raise ValueError("image range")
    fw.image_off = off + size
    fw.pkc_off = r32(rom, off + 8)
    fw.interface_off = r32(rom, off + 12)
    fw.imem_pa = r32(rom, off + 16)
    fw.imem_size = r32(rom, off + 20)
    fw.imem_va = r32(rom, off + 24)
    fw.dmem_pa = r32(rom, off + 28)
    fw.dmem_size = r32(rom, off + 32)
    fw.data_off = fw.imem_size
    fw.engine_mask = r16(rom, off + 36)
    fw.ucode_id = r8(rom, off + 38)
    fw.sig_count = r8(rom, off + 39)
    fw.sig_versions = r16(rom, off + 40)
    fw.sig_off = off + 44
    fw.sig_bytes = size - 44
    count = bin(fw.sig_versions).count("1")
    ok = (fw.ucode_id and fw.ucode_id <= 16 and fw.engine_mask and count
          and count == fw.sig_count and fw.sig_bytes == count * 384
          and fw.imem_size and fw.dmem_size
          and not rng(fw.image_size, fw.data_off, fw.dmem_size)
          and not rng(fw.image_size, fw.data_off, (fw.dmem_size + 255) & ~255)
          and not rng(fw.dmem_size, fw.pkc_off, 384)
          and not rng(fw.dmem_size, fw.interface_off, 4))
    if not ok: raise ValueError("descriptor geometry invalid")
    notes.append(f"FWSEC geometry: image_off={fw.image_off:#x} size={fw.image_size:#x} "
                 f"imem={fw.imem_size:#x} dmem={fw.dmem_size:#x} pkc={fw.pkc_off:#x} "
                 f"engine={fw.engine_mask:#x} ucode={fw.ucode_id} sigs={fw.sig_count} "
                 f"sigver={fw.sig_versions:#x}")
    return fw

def parse(rom, length, notes):
    image = 0
    if length >= 12 and r32(rom, 0) == 0x4947564e:  # NVGI container
        version = (r32(rom, 4) >> 8) & 0xff
        if version != 3: raise ValueError("NVGI ver != 3")
        total = r32(rom, 8) & 0xfffff
        if rng(length, total, 4): raise ValueError("total range")
        flash = r32(rom, total); dir_ = flash + 0x1000
        if rng(length, dir_, 12) or r32(rom, dir_) != 0x44524652:
            raise ValueError("FRDD dir missing")
        image = r32(rom, dir_ + 8)
        if not image or (image & 3) or rng(length, image, 2) or r16(rom, image) != 0xaa55:
            raise ValueError("bad NVGI image ptr")
        notes.append(f"ROM image: container NVGI version 3 image={image:#x}")
        rom = rom[image:]; length -= image
    adjust = expansion(rom, length, notes)
    for bit in range(0, length - 12 + 1):
        if r16(rom, bit) != 0xb8ff or r32(rom, bit + 2) != 0x00544942:
            continue
        size, stride, tokens = r8(rom, bit + 8), r8(rom, bit + 9), r8(rom, bit + 10)
        if size < 12 or stride < 6 or rng(length, bit, size):
            raise ValueError("BIT header invalid")
        if (sum(rom[bit + i] for i in range(size))) & 0xff:
            continue  # checksum fail: not a BIT, keep scanning
        notes.append(f"ROM BIT: offset={bit:#x} size={size} stride={stride} tokens={tokens}")
        if rng(length, bit + size, tokens * stride): raise ValueError("BIT tokens range")
        for i in range(tokens):
            tok = bit + size + i * stride
            if r8(rom, tok) != 0x70 or r8(rom, tok + 1) != 2 or r16(rom, tok + 2) < 4:
                continue
            ptr = r32(rom, tok + 4) if stride >= 8 else r16(rom, tok + 4)
            if rng(length, ptr, r16(rom, tok + 2)): raise ValueError("token deref range")
            table = (adjust + r32(rom, ptr)) & 0xffffffffffffffff
            if rng(length, table, 6): raise ValueError("table range")
            notes.append(f"ROM ucode table: offset={table:#x} ver={r8(rom,table)} "
                         f"hdr={r8(rom,table+1)} stride={r8(rom,table+2)} entries={r8(rom,table+3)}")
            if r8(rom, table) != 1 or r8(rom, table + 1) < 6 or r8(rom, table + 2) < 6:
                raise ValueError("ucode table unsupported")
            esz, estr, estride, ecount = r8(rom,table), r8(rom,table+1), r8(rom,table+2), r8(rom,table+3)
            if rng(length, table + estr, estride * ecount): raise ValueError("entries range")
            for j in range(ecount):
                entry = table + estr + j * estride
                if r8(rom, entry) == APP_FWSEC:
                    doff = (adjust + r32(rom, entry + 2)) & 0xffffffffffffffff
                    fw = descriptor_v3(rom, length, doff, notes)
                    fw.image_off += image
                    if fw.sig_off: fw.sig_off += image
                    return fw
    raise ValueError("ENOENT: no FWSEC app (0x85) in BIT tables")

if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    notes = []
    try:
        fw = parse(bytearray(data), len(data), notes)
        for n in notes: print(n)
        print("=== FWSEC FOUND ===")
        print(f"version={fw.version} engine_mask={fw.engine_mask:#x} ucode={fw.ucode_id}")
        print(f"image_off={fw.image_off:#x} image_size={fw.image_size:#x} sigs={fw.sig_count}")
        gate_v = (fw.version == 3)
        gate_e = (fw.version != 3 or fw.engine_mask == 0x400)
        print(f"GA102 gate: fwsec_version==3 {gate_v}; engine_mask==0x400 {gate_e}")
        print("VERDICT:", "PASS" if (gate_v and gate_e) else "FAIL")
        sys.exit(0 if (gate_v and gate_e) else 3)
    except ValueError as e:
        for n in notes: print(n)
        print("PARSE FAIL:", e)
        sys.exit(1)
