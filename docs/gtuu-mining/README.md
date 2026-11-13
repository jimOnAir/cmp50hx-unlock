# gtuu-mining — archived evaluation & ticket stream (2026-11-11…13)

Frozen git copy of the completed "GPU-Tensor-Unlock-Universal mining"
stream (upstreams B1 = MindAllik/GPU-Tensor-Unlock-Universal, B2 =
physicsdolphin/nv-uefi-unlocker — both evaluated static-read-only, never
executed; see `source-eval.md` for what we adopted, rejected, and why).

Why two copies: this repo's working tracker lives git-excluded under
`.scratch/<feature-slug>/` (see `docs/agents/issue-tracker.md`) — safe
for in-flight work, but `findings.md`, `CREDITS` and several source
headers *cite* those paths, and a tracker directory is one disk failure
from taking the provenance trail with it. This archive is the durable
canonical copy; the `.scratch/gtuu-mining/` tree remains the original
working tracker (identical contents at archive time 2026-11-13). The
stream is CLOSED — update the archive side of any future correction.

Contents:
- `source-eval.md` — the B1 + B2 evaluation tables (row IDs K/U/X/T/S
  and P1–P42) every ticket cites.
- `boot-runbook.md` — the llm2 boot-proof procedure incl. the
  one-shot-BootNext discipline learned the hard way (and the fleet
  BIOS-baseline items: VT-d off, Above-4G on, RTC battery).
- `issues/01..22-*.md` — the full ticket ledger with final statuses:
  21/22 closed (21 wontfix-by-owner), 3 live rows awaiting natural
  events (t17 halt decode, t18 FLR watch-line, t10 peek-positive), 1
  owner-scheduled cell (t01 locked tensor measurement).

Field-validated outcome: tickets 04/05/08/09/14/15/16/19/20 carry LIVE
silicon evidence (2026-11-13, eleven bench boots, llm2 permanent path =
gate5 `8237b24b`); the extraction-harness suite (8 selftests + claim
host harness + ASan gate + memmap walker) runs in CI on every push.
