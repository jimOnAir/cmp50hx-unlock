# llm2 boot-proof runbook — gtuu-mining batch (write 2026-11-12, host down)

All code landed offline (commits 88a8270..47c210d, 18 commits, `nothing
pushed`). ONE planned session closes every pending boot box. Host: llm2
(192.168.3.58, ssh user dmitry, passwordless sudo). Baseline captured
2026-11-11: rev .28, kernel 7.0.0-38, GPU0/GPU2 50HX + GPU1 90HX, all
5.0 GT/s, 170 W x3 — diff everything against that.

## Stage 0 — artifacts
- Build the deb from HEAD — PREFERRED path since 2026-11-13:
  `CMP_DEB_REV=<rev> bash tools/docker-deb.sh --out DIR` (pre-baked
  cmp50hx-build/smoke images + bind-mounted cache/ => warm full build
  +smoke ~53 s, zero network, SOURCE_DATE_EPOCH -> byte-identical deb;
  see docker/README.md). Historical ad-hoc recipe:
  (container recipe proven this session:
  fresh efi-unlock/build.sh -> tools/build-deb.sh -> smoke green incl.
  banner/peek/rtd3 assertions; deb lives at
  /tmp/opencode/t20b/cmp50hx-unlock_610.43.03-20261112.gtuu3_amd64.deb —
  rebuild if HEAD moved).
- Stage to llm2:/var/tmp, verify sha256, apt install (conffiles unedited
  expected -> silent upgrade path).
- ESP EFI: deploy new 50HXUNLK.EFI per tools/50hx-deploy.sh AFTER backing
  up the current ESP file (keep both old ESP copy and old deb).

## Stage 1 — warm boot (batch 1: t04,05,08,09,10,14,15,16,17,19,20)
Checklist on the fresh 50hx_log.txt (+ journal for claim side):
(GATE4 BOOT 2026-11-13 DONE: banner/canary/preflight/attest/prom-observe/
 cold-clean/FWSEC-gate@7ms/BAND-HIGH/UNLOCKED/final-gate-RELOCKED/canary-ARM
 all captured; OS verified UNLOCKED x2 via resource0 read-only.)
- [2a] [CANARY] line: verdict matches inter-boot reality (power cycle vs
  warm — t16 matrix rows).
- [2b] PREFLIGHT ok: pm=… pcie=… steps=N (t08).
- [2c] ATTEST ok: 9 embedded assets (t09) + PROM gate OBSERVE line with
  sha256=… bytes=0x40000 (t09 — record digests per card; THESE VALUES
  become the 50hx_prom_pin.sha256 files when the fleet opts in).
- PMC_BOOT_0 line: "matches RM constant" expected on these cards (t05).
- cold-state: CLEAN — proceed (t04).
- FWSEC gate lines all-four PASS compact (t14); booter [BAND-HIGH]
  attempt#1 + no [9b] firing (t15 ladder idle on good hosts — decision
  path must look byte-identical).
- FLR line: issued+verified cap=… wait=…ms — RECORD timing vs old flat
  200 ms (t18 watch); [TP]/[IDENTITY] absence noted.
- *** UNLOCKED *** then FINAL-GATE ok (t19) — the new last-before-
  StartImage line.
- EVERY log line carries [+NNNNms] stamps (t20); collect CSV gains
  canary column populated.
- lsmod/kmod: gpu_unlock loads as before; dmesg riscv/boot snapshot lines
  ABSENT on happy path (t07/t17 — failure-path only); claim script
  gen2-claim canary line for GPU1 (t16); cmp-tune status: 170 W x3
  unchanged; cmp-peek <BDF> once against… cards are bound (driver loads
  at boot) — peek proof needs an unbound card: use GPU1 skip window OR
  defer peek live box with note (wrapper refuses bound: expected refusal
  line IS the negative proof).
- t13 digest line: the shipped .EFI must be
  eff516f56ecfa85ca02427b9c8c7ba9197265db6fef10686c06723d50c1d3b27 if the
  ESP file came from this generation-gated pipeline (proves the
  generated-asset build IS the field-proven artifact).
- serving stack up, Xid 0, LnkSta 5.0 GT/s x3 (t18: 'pm: forced D0'
  should NOT appear on this fleet — if it does, capture + log the case).

## Stage 2 — negative proofs (same session, batch 2)
- t09 ENFORCE: write one card's OBSERVE digest into
  /boot/efi/…/50hx_prom_pin.sha256 -> warm boot -> ENFORCE ok; then flip
  one hex digit -> warm boot -> "PROM GATE REFUSE", 50hx_prom_fail.bin on
  ESP, chainload still works, boot locked (revert pin file, warm boot
  back). This is the failure-path-proves-the-fix drill.
- t10: with a card unbound (temporarily mask the alias conffile OR use
  cmp90hx-claim's bound-guard refusal as documented), sudo cmp-peek
  0000:04:00.0 -> verdict line sane vs native/verify.c reading.
- t16: one power cycle (owner) -> canary verdict power-cycle row; one warm
  reboot -> canary no-event row (AON witness = SS pair).
- t04 PARTIAL / t15 LOW-retry / t17 halt render: ONLY if a natural
  occurrence shows; else mark "harness-only, live n/a" in findings.md —
  do NOT force-inject on a serving host.

## Stage 3 — 01 tensor cells (owner window, separable)
- Unlocked cell: tensor_bench on GPU2 (idle-guard, CUDA_VISIBLE_DEVICES
  =GPU2, snapshot/restore caps, --bdf stamp) -> run doc matrix.
- Locked cell: ONE unlock-skipped boot (ESP EFI renamed aside / boot
  entry bypass per efi-unlock README rollback) -> measure -> restore +
  verify green normal boot. Owner-gated per ticket.
- t13/t11/t12 (phase-2 infra) unaffected by this runbook.

## FIELD-TEST DISCIPLINE (lesson 2026-11-12: debug EFI wedged boot)
- A debug/diagnostic EFI goes on the ESP as its OWN filename and is
  booted ONCE via `efibootmgr -n <newid>` (BootNext) — NEVER by making it
  the BootOrder-first path to the production filename. A bad artifact may
  hang the boot entry; one-shot guarantees the next boot is clean.
- After ANY EFI replacement, the ESP rollback one-liner must be known-good
  BEFORE reboot: `sudo cp /var/tmp/rollback-20261112/50HXUNLK.EFI.28
  /boot/efi/EFI/50HX/50HXUNLK.EFI` (and boot menu entry "Ubuntu" bypasses
  the unlocker entirely).
- The per-line ESP log (50hx_log.txt) survives a hung boot: after
  recovering, READ IT — the last line names the step that hung.

## Rollbacks ready before ANY of it
- old ESP EFI path recorded; old .deb staged; `apt purge` full-removal
  contract already fleet-proven (.22+); bench dir cmp50hx-gtuu holds a
  buildable tree for diffs.
