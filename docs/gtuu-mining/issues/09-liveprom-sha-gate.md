# 09 — Live-PROM SHA-256 gate + per-asset hash attestation in the boot log

Type: build (EFI)
Status: resolved (code+LIVE llm2 2026-11-13; residual sub-rows noted in boxes) (code landed + build/vector/selftest gates; ENFORCE proof boot pending)
Blocked by: 08 (same pre-flight region; the config walker runs first in
the sequence this ticket extends)
Source rows: U5 + U6 (+ X6 check folded below)

## What to build

The EFI app stops trusting its embedded FWSEC blobs blindly: it reads the
**live card's** VBIOS PROM window (BAR0 + 0x300000 region), hashes it, and
compares against the pinned expected digest before applying the
FRTS-style patch — a card whose VBIOS drifted (someone reflashed, a
service-center update) is refused explicitly, with the observed PROM
dumped to the ESP for later desk analysis, instead of failing as an
opaque Booter halt mid-transaction.

Additionally (U6): every firmware asset the app consumes gets a SHA-256
logged into the existing ESP run log, with the asset table carrying
expected digests — post-boot, the log proves *which* blobs ran on *this*
machine. On a pass, the verified FWSEC span digest is latched and
re-checked before Bus Master is enabled (the safety mechanism that
prompted this ticket; see source-eval.md safety-diff row).

## Acceptance criteria

- [ ] Digest mismatch → refusal path: no Booter load, reason + observed
      digest in the log, PROM dump file written to the ESP, chainload
      proceeds; normal boots unchanged (proven on guinea-pig host, one
      warm boot, rollback via purge path).
- [ ] A mismatch is *provable in practice* before close: either the
      pinned digest is temporarily flipped on a test build and the refusal
      observed on the real card, or the live PROM digest is verified equal
      against the existing offline parser (tools/parse-prom-fwsec.py
      reading the dump) — record which.
- [ ] (boot-pending) Log gains per-asset `SHA256 <name> <digest>` lines and the
      re-verify-before-Bus-Master latch line.
- [x] X6 check verdict: our design asserts the same guarantee differently —
      install-initramfs.sh die/rolls back on a wrong module inside the
      initramfs and REQUIRES 'blacklist nvidia' when nvidia.ko is present
      (coldplug-before-claim guard, :107-108); B1's '?'-suffix ordering
      concern does not apply to this model. No change needed.
- [x] efi-unlock/sha256.{c,h} ported (row U6); host vector gate 4/4:
      FIPS 'abc' + empty digests match, wrong digest rejected, malformed
      hex fails closed. Bench-toolchain link BUILD_OK, 9 warnings ==
      HEAD baseline, zero new; walker selftest still 13/13.
- [ ] findings.md line; provenance headers (rows U5/U6/X6).

## Notes

Firmware pins remain the deb-shipped blobs + manifest; this ticket does
not change where assets come from (that's ticket 13), only that the live
card is checked against them before they're used.
