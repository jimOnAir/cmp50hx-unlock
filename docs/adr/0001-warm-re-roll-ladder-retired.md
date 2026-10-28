# ADR-0001: The warm re-roll ladder is retired; boot must be deterministic

Date: 2026-10-28
Status: Accepted
Supersedes: `.scratch/warm-multi-unlock/issues/04-production-boot-flow.md` ladder mechanism (its verdict/policy questions stay answered)

## Context

Ticket-04 shipped a boot-time "warm re-roll ladder": on a degraded unlock verdict
(`UNLOCKED (SS0` count < installed 1e09 count) the boot unit warm-rebooted the host
up to 3 times per episode to re-roll the pre-OS booter-window lottery, since the
bench has no PDU. It demonstrably worked (2026-10-27 18:0x episode: 3 rolls →
ALL-UNLOCKED; recovery data across 126 archived boots).

Same-day debugging on `llm2` produced two rounds of "smart" retry policy, both wrong:

1. A **stop-on-identical-failure-signature** rule was added after a 4-boot episode
   showed byte-identical booter rejects (`returned 0x8000000000000007`) — the rejects
   were assumed deterministic. The 2026-10-27 archive refuted it within hours:
   cards recovered from identical-reject streaks of up to **8 consecutive warm boots**
   (u4 19:49→20:29), and repeatedly after 2–3 — the reject is a biased lottery
   (~15–20% success per warm boot), not a stuck state. Reverted same day
   (`tools/smoke-test-boot-verdict.sh` H-suite keeps the lesson).
2. The churn itself (4 boots / ~4 min per doomed episode, docker held behind a
   `Before=` ordering edge each time) exposed the deeper problem: a service that
   **reboots its own host at boot** makes boot timing, journal forensics, and
   operator expectations nondeterministic by construction.

## Decision

- **Remove the ladder entirely.** The boot unit never reboots the host, under any
  configuration key (`CMP_BOOT_RELLADDER`/`CMP_BOOT_MAX_ROLLS` deleted).
- A degraded boot **accepts loudly**: `DEGRADED win=N/M` + explicit advice — reboot
  once per new lottery ticket, or ~10 s power cycle (always curative) — and the
  two-hour-lottery truth stays documented in the message.
- The unit instead **proves readiness**: every card the ESP unlocker *promised*
  (fresh `UNLOCKED (SS0` log) must reach Gen2 `PASS` within 180 s, counted as
  `PASS lines >= promised`. `READY: n/n` on success. Locked cards are terminal
  this power cycle and are **never waited on**.
- If a **promised** card fails to PASS (driver/GSP flake on an unlocked card),
  the unit **exits 1** — a red, auditable boot — while docker still starts
  (`Before=` is ordering, not a requirement edge): serve on healthy cards,
  scream about the failed promise.
- `Before=docker.service multi-user.target` is kept: dependents must not allocate
  before GPUs are fully initialized.

## Consequences

- Unattended degraded boots now stay degraded until a human reboots or power-cycles.
  We knowingly trade the ladder's measured auto-recovery rate for determinism;
  if that ever flips back, revisit with a PDU (cold power control), not a warm-reboot loop.
- Degraded-boot docker wait drops from ~130 s (locked-card polling) to ~15 s
  (`promised=0` → gen2 skipped) and healthy boots assert readiness instead of hoping.
- Driver-load concurrency note: with `CMP_BOOT_COLLECT=1`, the collect phase's
  `nvidia-smi` loads `nvidia.ko` ~0.3 s into the unit (setuid `nvidia-modprobe`
  bypasses `modprobe.blacklist=`) and GSP init runs concurrently with our phases.
  Benign and intentional: the readiness gate is sysfs/BAR0-MMIO-only, so it can
  never deadlock on driver enumeration — including the public default
  (`COLLECT=0`) where the boot path loads no modules at all. The old OS-side
  modprobe gate (50hx-gate) serialized the *retired* OS unlock era and stays dead.
- Forensics: `cmp50hx explain` keeps decoding historical ladder lines (roll=N/M,
  `Ladder stopped`) even though no new boot emits them.

## Postscript (same day)

Issue 15 removed the root cause the ladder was compensating for: EFI now
defers (never burns SEC2's RESET_PLM latch on a failed attempt) and the
kernel V551 stockflow — proven live rescuing armed-but-EFI-missed cards —
takes the unlock at driver probe. If that combination validates after a
power cycle, an EFI-window miss costs zero reboots and zero operator action.
