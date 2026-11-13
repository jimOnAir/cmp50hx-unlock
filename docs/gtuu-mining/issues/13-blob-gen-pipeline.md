# 13 — Build-time firmware generation: retire the committed EFI blobs

Type: build (packaging pipeline)
Status: resolved-partial (2026-11-12) — generation gate landed & digest
proof recorded; keep-set justified by preservation (see box 2); guinea-pig
boot row awaits llm2
Source row: X5 (gap remainder — the deb already extracts boot/GSP assets
deterministically at build from the pinned NVIDIA tree; this closes the
last committed-blob set on the EFI side)

## What to build

The remaining committed binary assets in the EFI unlock directory
(pre-extracted FWSEC payloads and friends) stop being committed and start
being *generated* at package build from the pinned driver source —
mirroring the pattern already proven for the claim module's firmware
assets — so the repo is blob-free for unlock payloads, every binary in a
release is reproducible from a recorded input hash, and the same pipeline
regenerates assets for the 615.x branch when that line moves.

Three generation surfaces, following the upstream pattern but with the
supply-chain rule from source-eval.md (fetch **download.nvidia.com only**
— never the third-party distro mirrors their packaging uses):

1. Artifact fetch: HTTPS-only, redirect re-verified, pinned SHA-256,
   size cap, `--offline` mode that only verifies a warm cache (CI runs
   offline; the cache lives where the existing driver tarball cache
   lives).
2. V67 canary payload: regenerated from the pinned driver's own bindata
   with byte-pins recorded in a manifest (the derivation is documented
   research, not a magic blob).
3. FWSEC/booter/descriptor extraction per chip variant with a per-chip
   JSON manifest (digests, source rev) — consumed by the deb and by the
   EFI build exactly like today's staged assets.

## Acceptance criteria

- [x] `make release` from a clean checkout (no blobs, warm cache)
      produces an EFI payload byte-identical to the currently shipped,
      proven one — digest equality recorded in the PR; if any byte
      differs, the ticket is not done. (PROVEN 2026-11-12: fresh tree
      minus the three GENERATED-class blobs -> gen-efi-assets.sh --write
      (pinned cache only) -> container efi-unlock/build.sh ->
      sha256(50HXUNLK.EFI)=eff516f56ecfa85ca02427b9c8c7ba9197265db6fef10686c06723d50c1d3b27,
      byte-identical to the build from committed blobs.)
- [ ] Committed binary assets for unlock payloads are gone; manifests +
      generation scripts replace them; `.gitignore`/`git ls-files` audit
      in the PR shows zero new blobs. (PARTIAL BY DISCOVERY — the sweep
      of reality: 4 of the 10 committed assets CANNOT be regenerated
      offline: v67_payload.bin + booter_ucode_dbg.bin are the only
      surviving copies of the DELETED CMP40HX-Unlock upstream (v67
      builder comparison: byte-diff at offset 0 — see NOTICE-ASSETS.md),
      fwsec_50hx_* + sec2_ucode_vbios_* derive from card VBIOS ROM
      captures (generator extract_fwsec.py ships; input is card-owned).
      Removing them = data loss; keeping them committed = the
      preservation copy. GENERATED-class (3 files) remain committed for
      blobless dev checkouts but are now BUILD-GATED against generation
      (byte-equality enforced in build-deb). Gitignore-for-generated
      is a follow-up call for the maintainer, not a safe auto.)
- [x] Offline CI packaging job green (cache-only path); an intentionally
      corrupted cache entry fails loudly with the expected-digest
      message. (gen --check embedded in build-deb.sh after the claim-fw
      extract — runs in the existing package:linux job; corrupt-cache
      fixture: rc=5 naming expected 9df87d75…; flipped blob byte:
      MISMATCH + MANIFEST-FAIL, both proven.)
- [x] Existing deb smoke gate extended: asset manifest present, digests
      verified inside the package, install/postinst unchanged. (six new
      asserts: manifest present/10 entries/well-formed 64-hex lines,
      NOTICE carries the zero-badge text, packaged .EFI.sha256 matches
      the packaged binary's recomputed digest — gtuu5 PASS.)
- [x] NVIDIA license handling mirrors the upstream split pattern (assets
       ship under the driver license with the license text alongside);
       provenance headers on new scripts (row X5). (NOTICE-ASSETS.md
       documents per-file license routing; deb embeds the driver package
       with its license verbatim.)
- [ ] findings.md line recording the digest-equality proof boot
      (one guinea-pig warm boot with the generated payload). (awaiting
      llm2; digest-equality proof itself recorded in findings.md — a
      byte-identical binary makes this boot a formality, same artifact.)

## B2 fold-in (2026-11-12 sweep, rows P27+P28+P29/P30/P22)

- P27: manifest must be CONTENT-DERIVED (timestamp-free, byte-idempotent
  double-run) and the release record gains the hash of the exact EFI binary
  a physical card accepted (field-proven), beside the rebuild claim.
- P29/P30: B2's first-principles payload generator independently annotates
  the V67 frame geometry + golden byte-repro standards
  (b0ec9029/2a0aa1f8/44c36b2d) — use as acceptance cross-check for the
  generated payload; their booter-RE boundary applies: no debug plaintext,
  no generator input.
- P22: the embedded BL blob is currently the all-zero placeholder that
  third parties already byte-pin as a "bootloader" — this ticket either
  generates a real BL from pinned kernel source or documents the
  zero-badge explicitly in NOTICE (payload-mode non-consumption proven by
  two independent lineages).
