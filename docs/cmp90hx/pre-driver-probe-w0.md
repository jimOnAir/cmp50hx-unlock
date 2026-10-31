# W0 pre-driver probe record (2026-11-01, boot 49066f2d-ce5a-4e58-95cf-db6a17714766)

First window of ticket-11 cycle; fully read-only (ROM-window reads via
BAR0 mmap; zero config-space or register writes; no insmod; no initramfs
touch). Verdict: **#5a pre-driver lane GATE = PASS — proceed to W2.**

## 1. Platform posture (Zagitta claim preconditions)

| Item | Value | Note |
|---|---|---|
| Secure Boot | **disabled** (Setup Mode) | `mokutil --sb-state` |
| iommu | `iommu=pt`; all card groups + bridge `type=identity` | groups 45/47/48/33 |
| FLReset on 03:00.0 | **DevCap FLReset+** | hard precondition ✓ |
| Boot bind order | `modprobe.blacklist=nvidia,…` holds through initramfs; card bound only by `cmp50hx-boot.service` (explicit `modprobe nvidia` via `50hx-gate`, 10:01:47) | pre-driver claim window in initramfs is CLEAN |
| LnkCap endpoint | 2.5 GT/s x16 | VBIOS-level cap — confirms speed must be opened card-side (Gen2 patch path), bridge root port capable 8 GT/s x16 |
| LnkSta | 2.5 GT/s x4 (downgraded) | unchanged behavior |

## 2. ROM / FWSEC gate — THE decision item: PASS

The PCI **expansion ROM BAR is zeroed by firmware** (no sysfs `rom` attr,
`setpci 0x30=0`) — but that is IRRELEVANT: Zagitta reads the SPI PROM via
BAR0 `0x300000` (`GU_PROM_DATA_OFFSET`, `memcpy_fromio`, mirroring RM's
`kgspExtractVbiosFromRom_TU102`), which we can read too.

Parsed the 1 MiB PROM window (md5 `ac0752e8283bc42464540c692b136dae`,
cached `cache/90hx-prom-0x300000.bin`) with a faithful Python port of
their `vbios_610.c` (`tools/parse-prom-fwsec.py`, Zagitta @`7eb51bcc`):

```
ROM chain: 0x0 type=0x0 (base) | 0xfe00 type=0x3 | 0x24600 type=0xe0 | 0x29c00 type=0xe0 last
adjust=0x14800; BIT @0x1b0 (18 tokens); ucode table @0x87461 (16 entries)
FWSEC descriptor @0x41208: version=3 engine_mask=0x400 ucode=9
  sigs=3 (sigver 0x7), image=0xea00 @0x416b4, dmem=0x800, pkc=0x5a4
```

Matches the GA102 family entry expectations exactly (`fwsec_version=3`,
GSP `engine_mask==0x400`) ⇒ their `unlock_transaction_fwsec` will find and
hash-verify FWSEC on llm2's card. **#5a stays primary; W2 goes.**

## 3. State-register baseline (read-only BAR0, serving state)

| Reg | Value | Reading |
|---|---|---|
| `0x8c2c0` CYA_0 | `0x00802005` | **bit2 DIS_G2 = 1** — direct register-level proof of the Gen1 disable |
| `0x8c040` LINK_CONFIG_0 | `0x805c5800` | MAX_RATE field = 3 (native) — cap is NOT here |
| `0x8c1c0` PL_LINK_RATE | `0x00120000` | pre-write baseline (target `0x240036`) |
| `0x8872c` LTSSM | `0x00000000` | no override |
| `0x8841c` PRIV_MISC_1 | `0xe0b60500` | bits(11\|13) clear (target set) |
| `0x823804` FEAT | `0xffffffff` | **already FULLY OPEN at production boot** — the production V67 canary opens it every boot |
| `0x82381c/0x823820` SS0/SS1 | `0x88888888` / `0x00000008` | compute unlock holding post-boot |
| `0x823800`, `0x823b04` | `0xffffff8f` | locked bits 0–3 (payload target `0xffffffff`) |
| `0x88fe8` XVE | `0xffffffcf` | locked bits 4–5 |
| `0x88ff4` XVE / `0x8e1b0` XP3G / `0x8200d0` OPTB | `0xffffff8f` | locked bits 0–3 |
| `0x820040` / `0x820084` (L1b pair) | `0x00000001` / `0x00000001` | **MAPPED on GA102, readable** — L1b premise survives; its micro-window stays gated separately |
| `0x820520` / `0x82057c` / `0x820580` | `0x16e80000` / 1 / 1 | readable, baseline logged |
| `0x820504` | `0x00000000` | zero (not badf) |

**Consequence for #6 viability:** window #9's CPU-relock inertness was
observed with FEAT in a different state; TODAY FEAT is open in production
boot — the author's "CPU-writable while FEAT_OVR_PLM is open" condition is
satisfied as stock behavior. The relock preflight (write 0 to
`0x82381c/20` + readback) now has materially better odds than the #9
observation implied.

## 4. D3 / persistence posture

`power_state D0`, runtime `active`, `d3cold_allowed` **absent** (journal:
`PME# supported from D0 D3hot` only — no _PR3 ⇒ no D3cold; #251-class
selector loss via D3cold unlikely here). No rtkit/cooldown units. Fleet
actor found: **`cmp-idle-governor.service`** (P8-forced-when-idle governor,
runtime-state only) — W4 freeze-list candidate #1. Journal D-state hits: 1
(the PME# line above).

## 5. Zagitta build (stock, inert)

`/root/zagitta-build` @ `7eb51bccae0a0b7e599e084d971170e9a1e82d0c`:
`make inputs` + `make firmware` (17 assets incl. `booter_load_ga102.bin`,
`gsp_ga10x.bin`) + `make -C kernel/gpu_unlock` clean
(`gpu_unlock.ko` v2.0.0, **srcversion `BB06AF434D07BE745BD8240`**, vermagic
`7.0.0-38-generic SMP preempt mod_unload modversions`; only
compiler-diff warning). **Never insmod'd** — `lsmod` guard "not-loaded OK".
No initramfs rebuilt, no cmdline change, nothing installed.

## 6. Artifacts

llm2 scratch mirror `/tmp/90hx-gen2-p2p-scratch/w0/` (PROM bin, build
log, srcversion; md5s printed in probe session). Local:
`cache/90hx-prom-0x300000.bin`. Tool: `tools/parse-prom-fwsec.py`.

No success-recipe §2 entries (nothing landed — read-only by design).
§1 preconditions table filled from this window.
