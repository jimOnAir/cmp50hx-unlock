# claim-90hx host test harness (gtuu-mining ticket 11)

The claim module's transaction logic, compiled **on the host** and run
against a fake Linux — no card, no reboot, no kernel. Rows X1/X2 of
`docs/gtuu-mining/source-eval.md`: method ported from
GPU-Tensor-Unlock-Universal @ `ab7bfc0` (`tests/unlock_shim`,
`test_unlock_adapter.c` — analyzed READ-ONLY, never executed) with the
named-fault-axis + reverse-assertion discipline from nv-uefi-unlocker
`sim/` (row B2-P23). Both sources GPL-2.0-only; everything here is
GPL-2.0-only.

## Run

```
bash claim-90hx/tests/run-host-harness.sh        # gcc + libc, nothing else
```

CI runs it as its own gate job (`test:host-harness`, ubuntu:24.04).

## How it stays honest

* **Two-build pattern, same source.** `test_claim.c` `#include`s the
  production `unlock_610.c` **verbatim** (the extraction-selftests' trick,
  whole-file), and the runner compiles the sibling production `.c` files
  directly. There is no forked copy and no `#ifdef TEST` in production:
  the only fake is the kernel API surface under `tests/shim/`.
* **Named fault axes** (`shim_impl.c`): `k_pmcsr_stuck` (rail-woken dead
  card), `k_cmd_allf` (config wedge / lost identity), `k_fail_alloc_at`
  (allocation failure at the Nth call), `k_x2_req_busy` /
   `k_x2_resize_fail` + `fix_rebar_sizes` (X2 aperture claim), plus
   `k_flr_ret`, `k_flr_identity_gone`, `k_bme_stuck_off`, `k_fw_name_fail`
   — the last three exist for the booter/fwsec scenarios (see Scope).
 * **Call-sequence pins**: the Resizable-BAR stubs
   (`pci_resize_resource`, `pci_request/release_selected_regions`) and the
   legacy `aperture_remove_conflicting` record into `fix_seq[]`, so the X2
   scenarios assert the exact ordered contract (release -> resize ->
   request, plus the resize-back rollback on a busy window).
* **Reverse assertions**: the happy claim path asserts the log ring
  contains **zero** `dev_err`/`dev_warn` lines (`dev_err` is tagged
  `[E] ` by the shim, so the needle is exact); the cold-GFW pass asserts
  the "power off first" line does NOT appear; quiesced unwind asserts no
  "handover refused".
* **Containment counters**: `dma_live` tracks every
  `dma_alloc_coherent`/free pair — the S7 scenario proves the sacred
  invariant that once firmware has started and the state is unquiesced,
  unwind REFUSES (`-EBUSY`), sets `retained`, and frees **nothing**
  (`dma_live` stays 1).

## Adding a scenario

Fixture: `fix_reset()` (16 MiB BAR array + faked 256 B config with the
PM@0x40/PCIe@0x50 capability walk the module's guards consume),
`pdev_reset()`, `claim_ready()` for a claim-success card. Write BAR
registers with `bar_w32(GU_*, value)` — register names come from the
production `registers.h`, so a renamed offset breaks the harness, not
silently passes it. Log checks: `log_has("[E] <line you expect>")`.

## Scope (as landed)

Covered: entry guards (no-recipe `-ENODEV`, `kzalloc` failure), the whole
`unlock_transaction_claim` gate stack (D0 gate incl. the t18 force-D0
recovery and its still-refuses failure, NO_FLR, wedged config, firmware
BME handoff, region/mapping/bookkeeping), the GFW cold-entry
classification (`-EBUSY` power-off-first / `-EALREADY` open-PLM / accept,
pairing with ticket 04's verdicts), and unwind containment in both
directions.

Added in phase-2 (2026-11-13): the `unlock_transaction_reset` gauntlet
integration (selector-gate ordering pin + a run that reaches the X2 claim
point inside the transaction, legacy aperture removal first) and the X2
aperture claim itself (S11-S17: picker, exact contract sequence, busy-
window rollback, flags guard, derived-state carry for the resume pass,
capped-capability downsize, resize failure).

Still open (knobs already stubbed): fwsec/booter-phase scenarios need the
fixture to feed staged images (`request_firmware` currently fails by
design — real asset fixtures belong there), and the X2 orchestration
layer (module-init, multi-card targets parsing, bound-driver skip,
resume re-claim) lives in `main.c`, whose shim needs sysfs/kobject/
kthread surfaces not yet modeled.
