# p104-unlock-v3 — GP104 (P104-100) PCIe Gen2 x4 live-unlock: analysis & TU102 port notes

Source: https://github.com/skbskhud/p104-unlock-v3 (README + `src/P104Gen2x4.cs`,
v3.3 / tool v1.2, fetched 2026-11-01, user-provided pointer). Windows/BYOVD
tool (WinRing0 for PCI config, ThrottleStop for BAR0 page mapping). Target is
the **P104-100** mining card (**GP104 Pascal, `10DE:1B87`**): factory
Gen1 x4 (0.78 GB/s) → **Gen2 x4 (1.55 / 1.69 GB/s measured)**, plus an x16
*declaration* (physical x16 not achieved — board/PHY strap).

We analyze it here because its Gen2 path is a **candidate lever for the CMP
50HX Gen2 gap** documented in `README` §"615 EFI-only" and
`.scratch/615-port` ticket 11: on the 615 pre-OS-EFI-only boot there is no
in-kernel compute exploit, so the XP3G privilege gate (`0x8E1B0`) never opens,
and our `native/gen2.c` refuses to write *anything* past that gate → 50HX stays
Gen1. P104's tool reaches Gen2 **without ever writing XP3G**, so it does not
need the gate. The open question is whether that survives the GP104→TU102
generation jump (see §Risks — it is unverified, and our own GA102 data is a
caution).

## Register cross-map (P104 names → our `common/cmp50hx_regs.h`)

The PCIe **XVE / XP_PL** port block (`0x88000`–`0x8CFFF`) is byte-for-byte
shared across Pascal→Turing in this family, so most offsets match directly:

| P104 (`P104Gen2x4.cs`) | offset | our macro | have it? |
|---|---|---|---|
| `OFF_LTSSM` (kick = 6) | `0x8872C` | `CMP50_REG_PCIE_LTSSM` | yes |
| `OFF_PRIV_MISC1` (`NV_XVE_PRIV_MISC_1`) | `0x8841C` | `CMP50_REG_PCIE_MISC1` | yes |
| `OFF_LINKCFG0` (`SPEED[19:18]`, width bit31) | `0x8C040` | `CMP50_REG_PCIE_CFG0` | yes |
| `OFF_LCTRL2` (target speed `[19:16]`) | `0x8C1C0` | `CMP50_REG_PCIE_PL_RATE` | yes |
| `OFF_CYA0` (`NV_XP_PL_CYA_0` bit2=0) | `0x8C2C0` | `CMP50_REG_PCIE_CYA0` | yes |
| `OFF_XP3G_OVR0/VAL0/PLM0` | `0x8E11x/0x8E1B0` | `CMP50_REG_PCIE_XP3G_*` | yes |
| **`OFF_PTOP_FS4` (`NV_PTOP_FS4` bits[0],[7]=1)** | **`0x2241C`** | — | **NEW — not in our map/corpus** |
| **`OFF_CYA1` (`NV_XP_PL_CYA_1` bit4=0)** | **`0x8C300`** | — | **NEW** |
| **`OFF_VSEC_HIER` (clear bit12, set bit0)** | **`0x88610`** | — | seen as `VSEC_DEVICE 0x8860c` sibling (§Risks) |
| `OFF_LCAP2_MIRROR` (read-only lock verdict) | `0x880A4` | (XVE mirror) | read path exists in tooling |

`0x2241C` sits in the `0x020000–0x022FFF` **PTOP** (privileged-top) page
(`_vaFuse2 = MapPage(bar + 0x022000)`), *not* the XVE block. It is the register
this corpus has never touched, and the P104 author names it a **"live
declaration switch"**: with bits[0],[7] set, "the PCIe core rewrites the
declaration to Gen2 in real time" (LNKCAP2 `0x02→0x06`, sub-second, **no reset**,
held 29 min) — the v1.0 bug (which never wrote `0x2241C` and inverted MISC1
bit13) is what forced the flaky "reset-and-pray" path (9/61 = 14.8 % latch).

## The working live write-group (`ApplyLiveGroup`, order matters)

```
0x8872C LTSSM            ← 6
0x2241C NV_PTOP_FS4      |= bits[0],[7]      (0x81)   ← the live-declaration switch
0x8841C NV_XVE_PRIV_MISC_1  bits[14:13] → 0          (mask 0x6000 → 0; GEN2_DIS off)
0x8C2C0 NV_XP_PL_CYA_0   bit2 → 0
0x8C300 NV_XP_PL_CYA_1   bit4 → 0
0x8C040 NV_..LINKCFG0    SPEED[19:18] → 1  (Pascal enc: 1=5GT)   [mask 0xC0000]
0x8C1C0 NV_XP_PL_LCTRL2  [19:16] → 2 (target 5GT)                [mask 0xF0000]
0x88610 VSEC_HIER        bit12 → 0, bit0 → 1                     [mask 0x1001]
# then, over PCI config, BOTH ends:
LNKCTL2.TLS = 2 (endpoint + upstream root port)   +  LNKCTL.Retrain=1 (root port)
```

Key properties for our use:
- **No XP3G write on the live path** — it does not need `0x8E1B0` to open.
- Verdict is raw `LNKSTA` on **both** endpoint and root port (`SPD[3:0]==2`),
  never the driver-reported `nvidia-smi pcie.link.gen` (the author flags
  driver-reported speed as unreliable on these headless miners — same trap as
  our `verify-615.sh` link check, which reads sysfs, and our `pcie.link.gen`
  caution).
- Volatile on Pascal: NVIDIA driver rewrites the set on init / wake / CUDA
  context, so a **20 ms watchdog** re-applies on deviation. On **Turing this is
  one-shot** (our 610 Gen2 latched and stayed — `README` records ~1.70 GB/s
  stable), so a resident watchdog is a Pascal-ism we likely do not need.
- **x16 declaration** (`0x8C040 = (cur & ~0xF8000000) | 0x80000000`) has hard
  safety rules the author measured the hard way: writing `bit31=0 & bit29=0`
  **drops the card 2/2**; `bit31=1 & bit29=1` drops 1/1; rollback is always a
  **whole-word** write `0x20085800`, never a masked single-bit clear. Physical
  x16 needs AC-coupling caps / board straps — software only moves the
  *declaration* (`LNKCAP maxwidth=16`), link still trains x4 without hardware.

## Applicability to CMP 50HX (TU102) — the real question

Our 610 Gen2 path (`native/gen2.c`) proves the XVE write-group *lands on
TU102*, but only **after** `XP3G_PLM0 == 0xFFFFFFFF` (opened by the compute
exploit). Our 615-EFI live probe measured: **CFG0 / PL_RATE writes ACCEPTED,
OVR0 (XP3G) REJECTED, LTSSM kick no-op** → so TU102's PCIe port is *not*
uniformly PLM-armed the way GA102 is, and accepts the speed-set writes even
with the XP3G gate closed. That is the crack P104 lives in.

The untested hypothesis was: on TU102, `0x2241C=0x81` + `0x88610` (bit12=0,bit0=1)
+ `0x8C300` bit4=0 + MISC1 bits[14:13]=0, then TLS=2 both ends + root-port
retrain — **skipping XP3G entirely** — latches Gen2 without a compute exploit.

### TU102 snapshot (read-only probe on llm2, 2026-11-01) — hypothesis largely PRE-EMPTED

`sudo bash probe-p104-gen2.sh` on both 50HX (`01:00.0`, `04:00.0`), identical:

```
0x88FE8 = 0xbadf5040   0x88610 VSEC_HIER = 0x00000001   0x8C300 CYA1 = 0x204a00c0
0x8841C MISC1 = 0xe0b42d00   0x880A4 LCAP2_mirror = 0x00000006   0x2241C FS4 = 0x00000081
0x8E110 OVR0 = 0x00000000    0x8E1B0 PLM0 = 0xffffff8f  (XP3G CLOSED)
endpoint LNKCAP=0x00453d02  LNKCAP2=0x00000006  LNKCTL2=0x2  LNKSTA=0x00001041 (SPD=1,x4)
rootport LNKCAP2=0x0000000e LNKCTL2=0x3         LNKSTA=0x00003041 (SPD=1,x4)
```

Reading it against P104's own verdicts: the **declaration side is already in
the "Gen2-unlocked" state** — `0x2241C=0x81` (target), `0x88610=0x1` (target:
bit0=1, bit12=0), `0x880A4` LCAP2-mirror `=0x6` (P104's `J1` "latched" test is
**already true**), endpoint `LNKCAP2=0x6` (Gen1+Gen2 supported), `LNKCAP`
maxspeed=Gen2 **and maxwidth=16 already declared**, `LNKCTL2 TLS=2`. Both cards.

**And yet `LNKSTA` reads SPD=1 (Gen1) on both ends.** The link is *not* running
Gen2 despite every declaration bit the P104 live-group sets already being set.
Interpretation: on **Turing** the speed declaration is not the binding
constraint (GSP-RM already leaves it Gen2-capable); the actual link is held at
Gen1 by the **locked-compute training clamp**, released only via the XP3G
policy the compute unlock opens (`XP3G_PLM0=0xffffff8f` closed, `OVR0=0` —
and our earlier `OVR0=1` write was rejected, confirming the gate is the wall).

So the P104 live-group is **inert on the 615-EFI 50HX**: it targets exactly the
bits that are *already* set. This is the opposite of the P104 case, where the
factory `LNKCAP2=0x2` (Gen1-only) genuinely needed the write-group to flip it to
`0x6`. The remaining *untested* sub-step shrinks to a bare **root-port retrain**
(both-end TLS is already ≥2). But the endpoint LTSSM kick we already fired today
(plus the CFG0/PL_RATE writes) produced no Gen2 latch, so a retrain is expected
to fall back to Gen1 — a clean confirmation, not a fix.

**Net:** Gen2 on the 50HX remains gated on the **XP3G / compute unlock**, i.e.
the same H2 in-driver path — P104 does not provide a shortcut for *this* silicon.
It remains a valuable *negative* datapoint and the TU102-vs-GP104-vs-GA102
contrast (Pascal re-latches Gen2 on the declaration write; Turing needs
XP3G-open; GA102 is PLM-armed and cannot reach Gen2 in software at all).

## Risks / cautions (why this is a probe, not a port)

1. **GP104 ≠ TU102 field semantics.** The target-speed field is *already* at
   different bits: P104 uses `0x8C1C0[19:16]`; our verified Turing code uses
   `[18:17]` (`| 0x00040000`). Pascal `0x8C040` SPEED encoding is
   `1=5GT/2=2.5GT`; our Turing uses `2` for Gen2. **Port the *lever* (write
   `0x8C1C0` target-speed, bypass XP3G); keep our Turing field values** — do
   not copy Pascal encodings.
2. **Our GA102/90HX data was the negative control — now resolved on TU102.**
   `docs/cmp90hx/gen-feasibility.md` / `upstream/wildflash-linux/STATUS.md`
   concluded the 0x88xxxx XVE block is PLM-armed on **GA102** (`0x88fe8 =
   0xffffffcf`, `VSEC_DEVICE 0x8860c` / `OPT_GEN23 0x82057c` fuse-shadowed).
   The read-only probe (§TU102 snapshot) shows **TU102 differs**: `0x88fe8`
   reads `0xbadf5040` (the privileged-*denied* sentinel P104 treats as a
   dead-link marker, not GA102's `0xffffffcf`), and `0x2241C` **exists and is
   readable** (`=0x81`). So TU102 is neither fully armed (GA102) nor needing the
   write (P104 factory) — it is *already declaration-unlocked but training-clamped*.
3. **`0x88610` sits next to the fuse-shadowed `0x8860c`.** On TU102 it already
   reads `0x00000001` (P104's target), so it is neither the blocker nor a lever
   here.
4. **Card-drop risk.** A bad `0x8C040` value drops the card off the bus; the
   author's own recovery is a **30 s AC power-off**. llm2 has **no BMC** → that
   is a *manual, gated* recovery. So: never write `0x8C040` width bits here; on
   a stall, the cold-cycle escape is the button.

## Reproducible probe (built; read-only by default)

`.scratch/615-port/kit/probe-p104-gen2.sh` (git-ignored working kit; mirrored to
`llm2:/root/615-port/kit/`):
- default **read-only**: snapshots `0x88FE8` (PLM-armed indicator),
  `0x8841C/0x88610/0x880A4/0x8872C/0x8C040/0x8C1C0/0x8C2C0/0x8C300/0x8E110/
  0x8E1B0`, and `0x2241C` on the fuse page, for both 50HX + endpoint/root-port
  `LNKCAP/LNKCAP2/LNKSTA/LNKCTL2`. Answers risk #2 up front (does the field
  exist on TU102, is `0x88FE8` armed?).
- `--write <bdf>` (explicit, single idle card, serving must be down): the TU102
  live group with our Turing speed-field encodings + XP3G omitted, both-end TLS +
  retrain, then 2 s of `LNKSTA` polling for `SPD[3:0]==2`; volatile, power-cycle
  reverts. Only run after the read-only pass looks promising and serving is
  stopped.
