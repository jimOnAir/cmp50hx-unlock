# 01 — PTX tensor-core benchmark: complete the 50HX lock profile (locked vs unlocked)

Type: build + bench
Status: ready-for-agent (code landed)
Blocked by: — (can start immediately)

## What to build

A one-shot tensor-MMA throughput benchmark that measures the currently
unmeasured branch of the 50HX lock profile: whether the tensor-core
FP16→FP32 accumulate path (`FMLA32`) is clamped like FFMA/DP4A in the
locked state, and by how much. Run once locked (one owner-gated
unlock-skipped boot) and once unlocked on the same guinea-pig card; the
result lands as a new dated A/B run document alongside the 2026-09-10
stock-vs-EFI matrix and a README results row, updating that document's
finding #3 ("FFMA-FP32 and DP4A are clamped… FP16 half2 FMA and INT32
are NOT") with the tensor-MMA verdict. A clean 2.00× is a nice-to-have,
not the expectation — the goal is to name the ratio whatever it is.

## Method port (row T3 of the source-eval sweep)

From GPU-Tensor-Unlock-Universal @ 1d6a508 port only the *method*, never
their Python scaffolding: a single CUDA `.cu` tool built like the existing
`tools/p2pbench.cu`, targeting sm_75 with inline-PTX `mma.sync.aligned`
measuring FP16→FP16, FP16→FP32, INT8→INT32, and scalar FFMA as control
(BF16/TF32/FP8 kernels from theirs are dropped — sm_80+ silicon, absent on
TU102). Runtime-randomized fragments (anti-constant-folding, their
key non-obvious idea vs naive mmapeak) and finite non-zero IEEE-754
accumulator verification on every run. Output follows the established
`-> X TF/s` parse idiom so it is greppable like the autotune perf lines.

## Runtime discipline (agreed, Q9)

- Autotune-grade guards: idle-guard on the chosen card (util ≤5%/10s),
  single-GPU scoping (plain host run so CUDA device pinning is honored),
  power/cap/offset snapshot-restore verified against baseline diff.
- The unlock-skipped BEFORE boot is owner-gated: it is a planned reboot of
  a serving-class host; schedule and confirm with the owner first.
- Teardown leaves the host byte-clean (governor restarted if touched,
  baseline caps verified, cmp50hx-boot flow unmodified).

## Acceptance criteria

- [x] Tool builds in the noble container gate with zero warnings; `--help`
      lists kernels; run stamps GPU UUID + LnkSta into output.
- [ ] Unlocked run on the guinea-pig card records all four kernels with
      verified finite non-zero accumulators.
- [ ] Locked-state cell measured during one planned unlock-skipped boot;
      the doc records exactly how the skipped state was entered and exited
      (rollback = normal boot, per existing EFI README).
- [ ] New run doc under the EFI runs directory: per-kernel locked/unlocked
      TF/s table, the FP16→FP32 / FP16→FP16 ratio named as the FMLA32
      verdict, and an explicit statement of which card/boot revs produced
      the numbers.
- [ ] README + README.RU results row added; the 2026-09-10 doc's finding #3
      cross-referenced (not edited — add a pointer note).
- [ ] Host left byte-clean: baseline caps/offsets verified, no residual
      boot-order or unit changes; cleanup evidence appended to findings.md.

Hardware/boot-gated boxes: awaiting owner-gated llm2 session.

## Notes

Guinea-pig boot proofs in this work stream (tickets 01, 08, 09, 10) contend
for the same host — coordinate with the owner and piggyback adjacent tickets'
proofs on the same boot where the states are compatible (e.g. the locked
BEFORE boot is also the natural place to capture a cold-state verdict line
from ticket 04 if it has landed).

## Comments

2026-11-12 (agent, code landed): `tools/tensor_bench.cu` builds zero-warning
for sm_75 (CUDA 13.4 nvcc) and passed a correctness-only self-check via
compute_75 PTX JIT on the dev box's RTX 5070 (all four kernels, verifier
green every run; no fleet numbers). Run-doc skeleton at
`efi-unlock/runs/2026-11-12-tensor-ab.md`. Deviations: (1) shapes are
m16n8k8 f16 / m8n8k16 s8 — ptxas rejects m16n8k16/m16n8k32 on sm_75
(sm_80+ only), and the reference's own Turing branch uses these; (2) no
`.cu` container gate exists in CI to extend (nvcc absent from both CI
configs — the header-documented build command is the wiring, same posture as
`tools/p2pbench.cu`); (3) CUDA 13.x runtime API dropped the device-UUID
call, so UUID/BDF stamping uses dlopen'd driver-API query entry points
(`cuDeviceGetUuid_v2`/`cuDeviceGetPCIBusId`) with a procfs/sysfs fallback —
still zero JIT/module loading, kernels run from the compiled sm_75 cubin.
