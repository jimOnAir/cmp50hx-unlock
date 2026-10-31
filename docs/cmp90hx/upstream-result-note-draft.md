# DRAFT — upstream result-note (NOT POSTED)

Internal draft for the user to post **only if they choose**. Per the
upstream rules recorded in ticket 11: a working-unlock result belongs as a
**comment on `Zagitta/gpu-unlock` discussions/238**, never as a
success-report issue; a pure failure would go through the issue template.
This is success-with-bounds, so: discussion comment. Nothing in this file
leaves the repo until the user posts it themselves. Strip any local paths
before posting (none included below by design).

---

## Draft comment text (paste-ready)

**CMP 90HX (GA102, `10de:220d`) — standalone-ko unlock: one privileged
launch per boot, measured both directions**

Running the gpu-unlock kernel module (Zagitta line, plus a local patch
adding a `gu_window=START:LEN` parameter so a single launch can be
confined to a window of the GA102 V67 privileged table) on a production
inference host: CMP 90HX behind an Intel root port, driver 610.43.03,
kernel 6.x/7.x Ubuntu, pre-driver claim from initramfs `local-top`
(`targets=… resume=0`) before the stock driver binds at multi-user.

**What works, reproducibly.** One launch with a 6-entry window
(opener + FEAT `0x823804` + XVE `0x88fe8/8fec/8ff0/8ff4`) landed
`0xffffffff` on all five masks with strict persistence — surviving a
post-launch FLR **and** the later production driver bind — on **seven
consecutive boots**, byte-identical (`before=0x4cb8f → after=0xffffffff`
each time). The `stage=flr` checkpoint line (`plm=0xffffffff`) confirms
the frame rides out an FLR. For this class of write the ko path is solid.

**The law we hit, measured with intent to refute it.** A second claim in
a *later module load within the same boot* is refused at the GFW stage
(`stage=handoff ret=-114`), and no amount of interleaving fixes it:

- pure waiting with a healthy device (chip-id `0xb72000a1` from t0,
  config space alive, BARs bit-exact): `-114` ×2;
- the full reload interleave used by rejoin16-style bench cycles —
  unload stack, re-lock SS0/SS1 (`0x82381c/0x823820 = 0`, mmap-verified),
  `modprobe nvidia`, wait for the driver's serialized GSP-RM init to
  complete for every GPU, unload again, re-lock, reload the ko: still
  `-114` ×2.

So on this host the V67 chain fires exactly **once per boot**, on the
first claim after firmware init. My working assumption is that
multi-cycle reload benches that report 34/34 rides **driver-embedded**
spec consumption (the patched driver's own canary path per load), not
repeated standalone launches — is that the right reading? Does the ko
support multi-launch re-arming on any platform, and if so, what is
supposed to re-arm the GFW between loads? Answers would settle whether
multi-target unlock on this box must go the one-crafted-write-per-boot
route (~34 boots) or can be compressed.

**Persistence.** Warm reboot **resets** all landed masks to the locked
`0x4cb8f` (7/7 boots re-read locked at first pre-write read although the
previous boot ended open; checkpoint reads `0xffffffff` every time). A
"skip if sample masks read open" warm-boot fast path would never fire on
this hardware. Re-apply must run every boot. (Cold power-cycle reset now
also measured: masks re-read at the locked/production-partial baseline on
a cold boot that followed an unlocked one.)

**Not achieved here:** Gen2 (`5.0 GT/s`) on the 90HX. With FEAT+XVE×4
landed pre-driver, production init still logs `retrain completed without
Gen2` and `LnkSta` stays 2.5 GT/s x4 — so the remaining delta is the
unlanded ladder targets (XP3G/OPTB/more XVE + `0x823b04`) and/or the
retrain lever, not these five masks. Root-port-side retrain itself works
on this host (same-generation cards reach 5.0 GT/s every boot through the
upstream-bridge TLS+retrain flow).

**Hardware hazard worth documenting for anyone reload-cycling the ko
next to the stock driver:** the driver's per-GPU RM init is serialized,
and unloading the stack as soon as *one* GPU answers nvidia-smi orphans
the other GPUs' GSP boots mid-flight — they then fail
`RmInitAdapter: Cannot initialize GSP firmware RM (0x62:0x40:2119)` for
the entire boot and **only recover on a cold reset**. Any reload loop
must gate on *all* GPUs enumerated before unloading. We learned this the
expensive way (two cards down for a boot until power-cycle).

Method notes: every privileged-write attempt logged as one JSON line
(`landed=true` only on readback match + survival through FLR + production
bind); accessor is a 16 MiB `mmap` on `resource0` (sysfs `pread` returns
silent EIO-filtered garbage on recent kernels — worth a line in the
README too).

---

## Pre-post checklist (user, at post time)

- [ ] Read through; remove anything you don't want public (host details
      are already generic — no hostname/IP/paths).
- [ ] Confirm the discussion is still open:
      `Zagitta/gpu-unlock` → Discussions → #238.
- [ ] Post as a **comment**, not an issue (upstream rule).
- [ ] If posting later than one session away, re-verify the recipe §2/§3
      claims against `docs/cmp90hx/evidence/` before posting.
