# NeithOS (neithos.ru) — survey & adoptables (2026-11-24)

Investigated on user request. Scope read: homepage, /features (capability map
1.0.39), /features2 (full 24-section spec), /docs, guides (start, launch,
gpu, troubleshooting), /blog (full release history 1.0.0->1.0.39 incl. the
CMP 50HX/CMP 170HX posts), plus upstream identification of their engines.

## What it is
Closed-source self-hosted AI panel ("AI Server Manager" -> rebrand NeithOS,
v1.0.39 as of 2026-11-24, ~weekly releases since 2026-03) orchestrating
Docker + open/proprietary inference engines behind one web UI, users/roles,
OpenAI-compatible API, MCP, Telegram, monitoring. Pricing per SERVER
(start free <=8 GPUs / 3000 RUB / 9990 RUB), local-data pitch to RU SMBs.

## Why it matters to THIS repo
They treat **CMP cards as first-class hardware**: dedicated **vLLM
CMP50/SM75 branch**, hardware profiles **CMP50/CMP170/RTX/AMD** (CMP170
presets shipped 1.0.35; SDNQ landed same release), and published how-to
posts for exactly our boards. Third-party production validation that an
unlocked CMP 50HX (Turing SM75) is a viable local-LLM tier — with concrete
guidance: FP16 not BF16 on Turing; FA2 NOT assumed (unlike Ampere-based
CMP 170HX); SDPA/xFormers per-pipeline; "2x20 GB != one 40 GB" (no pooling
without a supported multi-GPU mode); re-verify full memory exposure +
container GPU visibility after EVERY driver/kernel update; record
image+engine+weights+context+GPU ids per run; double-run before measuring
(warmup). They also run modified **20 GB CMP 50HX** (stock MSI spec is
10 GB — our cards' actual VRAM is an open TODO: nvidia-smi
--query-gpu=memory.total on a CMP host).

## Engines behind the panel (adoption targets, license matters)
| Engine | Nature | CMP relevance |
|---|---|---|
| vLLM (their CMP50/SM75 build line) | open | server inference on SM75 |
| llama.cpp (GGUF) | open | universal fallback |
| **QEngine** (bpx03/QEngine, MIT, C++/CUDA) | open | RTX 3000-class focus, Qwen3.8-Flash-Next ~1000 tok/s 8 agents on 3x3090, INT4 experts split across cards, verify-head pinned-RAM trick; SM75/80/86 profiles incl. CMP50/CMP170 |
| qengine for sm_70 (Haru-neo/qengine, Apache-2.0) | open | "GPU-poor's vLLM" — tuned for CMP 100-210/V100 mining cards, DP4A path |
| hipfire (warpfront/hipfire) | open | AMD RDNA/CDNA (MI50 community tier) — relevant only if AMD enters the fleet |
| SDNQ (Disty0/sdnq, GPL-3.0) | open | INT8 quantized matmul works on Turing -> 50HX OK; FP8 needs Ada (not our cards) |
| Strata / Avalon / Hipfire integrations, Voice Agent V3 (Go), AiSharkOCR, GPU Lab Hub | their IP (closed) | patterns only |

## Adoptable (ranked)
1. **`cmp50hx doctor`** — their pre-flight discipline (driver exposes full
   VRAM / GPU visible to containers / stable alloc under load / re-check
   after every driver or kernel update) is exactly our primitives: SS-pair
   readback, LnkSta, Xid scan, gate5/claim journal, reBAR. One command +
   exit code for install gating and fleet intake. Directly justifiable by
   the bump we are shipping right now (gsp firmware generation changed).
2. **Card-capability sheet for the fleet docs** — consolidate: SM75 facts
   (FP16 baseline, no BF16, INT8 matmul via SDNQ/vLLM-INT8 OK, FP8 not,
   GPTQ/AWQ/Marlin-W4A16 on Turing per vLLM hw matrix, GGUF always) +
   our measured Gen1<->Gen2 H2D/D2H deltas + VRAM truth per card. Nobody
   publishes this for unlocked CMPs; NeithOS's blog is close and is
   AI-generated ("not a benchmark result" disclaimer) — we have receipts.
3. **Updater pattern** (their 1.0.36 "updater"): layered download ->
   unpack -> health-check -> boot-fail auto-rollback, "fix with same
   version number" support. Our EFI/BootNext discipline already matches;
   the health-check-before-commit idea maps to the fleet rollout runbook.
4. **GPU Lab Hub**: opt-in outbound-only hub — time/GPU/action-boxed
   remote diagnosis, scoped controlled probes, isolated experiments, no
   chat/keys in the export. Template for our fleet telemetry without a
   pull agent.
5. **Pearl Mining** (idle-cycle mining co-tenant under inference, 1.0.34):
   the exact economic model our unlocked CMP fleet came from — a legit
   "what the card does between tensor jobs" reference.
6. **Ops phrasing worth lifting into the boot runbook**: "find the FIRST
   error, not the final stopped-line"; "unknown result != rejected — check
   state before re-issuing"; "file size != VRAM peak"; "% frozen != hang —
   check the phase"; support-bundle format with secrets stripped.

## Not adoptable
Panel source (proprietary, docker images); their engine forks remain to be
re-checked for license obligations if we lift QEngine (MIT/Apache-2.0 =
fine; SDNQ GPL-3.0 = runtime use only is fine, forking into the deb needs
license review). The driver layer is entirely THEIR blind spot — a locked
50HX under their panel silently runs locked at Gen1; that gap is precisely
this repo's product.

## Business frame
Free-to-8-GPU + per-server pricing + local-data compliance story = the
market unlocked 24 GB-tier boxes (50HX/90HX/3090-class) undercut. NeithOS
+ this unlock stack = turnkey; our differentiators: unlock pre-OS (they
never touch it), Gen2 link, fleet attestation (ATTEST/PROM gates).
