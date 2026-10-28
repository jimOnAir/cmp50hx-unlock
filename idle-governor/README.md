# Idle P-state governor

Enabled by default at install. Cuts idle power roughly in half. It is **not**
part of the unlock and nothing else depends on it.

The active service is one C ELF: `cmp-governor`. It loads NVML and the private
NVAPI entry point directly. The runtime path has no Bash, Python, or
`nvidia-smi` helper.

## Why it is needed

The card does not lower its own P-state request. Measured on a CMP 50HX
(`10de:1e09`, driver `610.43.03`, 2026-08-24):

| Condition | P-state | SM / Mem | Power |
|---|---|---|---|
| Idle, 0 % utilisation, no processes | P0 | 1920 / 7000 MHz | 62–64 W |
| Same, 60 s after a load ended | P0 | 1905 MHz | 63 W |
| `nvidia-smi -lgc 300,1920` (range allowed) | P0 | 1905 MHz | 63 W |
| `nvidia-smi -lgc 300` (hard ceiling) | **P3** | **300 / 5000 MHz** | **32.3 W** |
| Private NVAPI force request | **P8** | **645 / 405 MHz** | **1.8 W** |

`Clocks Event Reasons → Idle` reads *Not Active* the whole time. Given a
permitted clock *range*, the arbiter always resolves it to the maximum and
never issues a downward request on its own. The governor uses the private
NVAPI `NvAPI_GPU_SetForcePstate` entry point (`0x025BFB10`), the same control
used by `nvidia-pstated`: P8 is an explicit low-state request and P16 returns
control to the card's normal policy.

P16 does not make this CMP card auto-step down: after the request it returns
to P0. That is why the governor is still needed. The forced P-state call is a
driver API path, not a clock-curve workaround; the policy that would normally
choose P8 remains in the signed GSP/VBIOS path and is still not active on this
SKU.

## Measured result

| | Idle | Under load |
|---|---|---|
| without the governor | 62–64 W | full clocks |
| with the governor | **1.8 W (P8)** | full clocks, restored within one poll |

About **−61 W per idle card**. Verified live end to end: 30 s idle → forced to
P8/1.8 W; a load released it within one poll to P0/full clocks; the load
ending forced P8 again; stopping the unit released it to P16 cleanly.

Fleet re-verification 2026-10-28 (three CMP 50HX in one chassis, same driver,
load profile restored by a drop-in): idle **73–78 W per card** without the
governor → **17–20 W per card at P8** with it; load release at 2010 MHz,
64–69 W. NVML power on a multi-card board reads above the single-card 1.8 W
floor (shared rails); the P8 clock state is identical (645/405 MHz). A
resident llama server quantified the trade-off: after a gap >30 s the first
prefill ran at 143 tok/s (steady 2872) and the first decode at 9.5 tok/s
(steady 93) before the release landed; `verify/pstate-trace` captured the
cycle.

## Install

Enabled by default: both `install.sh` and the `.deb` enable the unit. Opt out
at install time with `--no-idle-governor`, or enable a host that skipped it:

```sh
sudo systemctl enable --now cmp-idle-governor
```

Status and log:

```sh
systemctl status cmp-idle-governor
journalctl -u cmp-idle-governor -f
```

## Remove

```sh
sudo systemctl disable --now cmp-idle-governor
```

The unit releases the clamp on stop, and clock locks are runtime state that a
reboot clears anyway. A later installer run re-enables the unit unless it gets
`--no-idle-governor`.

## Tuning

Defaults are conservative. Override with a systemd drop-in
(`systemctl edit cmp-idle-governor`):

| Variable | Default | Meaning |
|---|---|---|
| `CMP_POLL` | `5` | seconds between samples; also the worst-case delay before a new job gets full clocks |
| `CMP_IDLE_AFTER` | `6` | consecutive idle polls before clamping (6 × 5 s = 30 s) |
| `CMP_UTIL` | `5` | utilisation percent still treated as idle |
| `CMP_FLAP_WINDOW` | `60` | a clamp released within this many seconds of being forced counts as a flap and doubles that card's idle window |
| `CMP_IDLE_AFTER_MAX` | `600` | the maximum idle window (seconds) flap adaptation may reach |
| `CMP_BUSY_RESET` | `300` | sustained busy seconds after which the idle window returns to `CMP_IDLE_AFTER` (0 disables reset) |
| `CMP_LOAD_CORE_OFFSET` | unset | core VF offset to restore on load; while idle the offset is set to 0 so the card can reach P8. Written by `cmp-tune apply` |
| `CMP_LOAD_MEM_OFFSET` | unset | memory VF offset applied by the C governor at start |
| `CMP_LOAD_POWER_W` | unset | power limit in watts applied by the C governor at start |
| `CMP_LOAD_CLOCK` | unset | optional NVML clock range to restore on load; it is cleared before forcing P8 |

Example — clamp sooner, react faster:

```ini
[Service]
Environment=CMP_POLL=2
Environment=CMP_IDLE_AFTER=5
```

## Interaction with `cmp50-vfctl` (undervolt / overclock)

`cmp50-vfctl` sets four independent things. The governor temporarily clears
the GPU clock lock while forcing P8, then restores it on load if
`CMP_LOAD_CLOCK` is set.

| vfctl sets | NVML call | Governor effect |
|---|---|---|
| power limit | `nvmlDeviceSetPowerManagementLimit` | untouched, survives |
| core VF offset | `nvmlDeviceSetGpcClkVfOffset` | untouched, survives |
| memory VF offset | `nvmlDeviceSetMemClkVfOffset` | untouched, survives |
| **locked GPU clock** | **`nvmlDeviceSetGpuLockedClocks`** | cleared while P8 is forced; restored on load when configured |

The clock lock is still the same control as `nvidia-smi -lgc/-rgc` and vfctl's
`set` / `set-range` clock argument. The governor clears it before P8 so the
private P-state request is not pinned by a profile.

Measured with `cmp50-vfctl set 170 225 2100 1000` (170 W, VF +225, locked
2100 MHz, memory +1000):

| Step | SM clock | Memory | Power limit | Mem offset |
|---|---|---|---|---|
| profile applied | 2100 MHz | 7500 MHz | 170 W | +1000 |
| governor forces P8 (idle) | **645 MHz** | **405 MHz** | 170 W | +1000 |
| released with `-rgc` (default) | **P0/full clocks** | profile-dependent | 170 W | +1000 |
| released with `CMP_LOAD_CLOCK=2100` | **2100 MHz** | 7500 MHz | 170 W | +1000 |

Two things to note:

1. **Your undervolt/overclock is not lost.** Power limit and both VF offsets
   survive a P8/P16 cycle untouched.
2. **A clock lock is cleared only for idle.** If the profile uses a locked
   clock, `cmp-tune` writes `CMP_LOAD_CLOCK` for the governor automatically,
   so the same lock is restored when work appears.

**So if you use vfctl clock locking, tell the governor what to restore:**

```sh
sudo systemctl edit cmp-idle-governor
```

```ini
[Service]
Environment=CMP_LOAD_CLOCK=2100
```

Then the card goes 2100 MHz under load → P8/645 MHz idle → back to exactly
2100 MHz, with the power limit and both offsets untouched throughout.
`CMP_LOAD_CLOCK` also accepts a range, e.g. `1700,1980` to match
`vfctl set-range`.

### Why the core offset is dropped while idle

A non-zero **core** VF offset pins the card in P0, and in P0 the memory clock
never steps down — so a tuned card would idle at ~40 W instead of ~1.8 W even
with P8 requested. Measured, core offset cleared before the P8 request:

| core offset | mem offset | P-state | memory | power |
|---|---|---|---|---|
| +225 | +1000 | P0 | 7500 MHz | 40.0 W |
| **0** | +1000 | **P8** | **405 MHz** | **1.8 W** |
| +225 | 0 | P0 | 7000 MHz | 39.6 W |
| +225 | −2000 | P0 | 6801 MHz | 39.5 W |
| **0** | −2000 | **P3** | **5000 MHz** | **32.6 W** |

The memory offset makes no difference to this; the core offset must be dropped
before the P8 request. The governor restores `CMP_LOAD_CORE_OFFSET` on release.
Your memory tuning is never touched. NVML has no P-state setter, but the
private NVAPI entry point does provide one, which is what this governor calls.

Apply the vfctl profile before or after starting the governor. If the profile
sets a locked core clock, let `cmp-tune` create the `CMP_LOAD_CLOCK` drop-in so
the lock is restored on load.

## Trade-off and limits

- A job that starts while the card is in P8 runs at the idle clock for up to
  one poll interval (5 s by default). Lower `CMP_POLL` if that matters.
- Utilisation-based, so a workload that leaves the GPU at 0 % between bursts
  (short, widely spaced kernels — measured on a resident llama server: the
  first request after a >30 s gap ran entirely at P8, prefill 143 vs steady
  2872 tok/s) used to clamp and release repeatedly. The governor now adapts:
  a clamp released within `CMP_FLAP_WINDOW` (60 s) doubles that card's idle
  window (30 → 60 → 120 s …, capped at `CMP_IDLE_AFTER_MAX`, 10 min), and
  `CMP_BUSY_RESET` (5 min) of sustained busy returns it to the base. The log
  prints every change (`flap in 60s, idle-after now 60s`).
- Multi-GPU aware: each card is tracked and forced independently by PCI bus ID.
- Measured on CMP 50HX only. The private NVAPI entry point is shared by the
  50HX and 90HX driver path, but CMP 90HX still needs a separate live check.

## Verification

`verify/verify-governor.sh` runs as a periodic fleet gate
(`cmp-governor-check.timer`, 2 min after boot, then every 6 h). The verdict
stays in the journal and never gates a boot:

```sh
journalctl -u cmp-governor-check -b --no-pager | grep CMP_GOVERNOR
```

`PASS_CMP_GOVERNOR` requires the unit enabled, active, and running the
`cmp-governor` ELF; the line carries opportunistic P8 proof (journal entry
this boot, or a supported card currently at P8). `WARN_CMP_GOVERNOR_DISABLED`
marks an opted-out host; `FAIL_CMP_GOVERNOR` means enabled but not running.
