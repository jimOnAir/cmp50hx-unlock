# CMP 50HX unlock — one-shot local release (mirrors .github/workflows/release.yml)
#
#   make release       build the Linux .deb locally
#   make deb           build just the Linux .deb (needs the EFI binary)
#   make efi           build just the Linux EFI binary
#   make native        build the merged cmp50hx multi-call binary (native/)
#   make clean         remove all build outputs
#
# The .deb is the single self-contained Linux artifact: embedded NVIDIA
# 610.43.03 .run + patched DKMS module tree + UEFI ESP unlock + services.

DEB_GLOB        := cmp50hx-unlock_*_amd64.deb
VERSION         ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.PHONY: all release efi deb native clean

all: release

# ------------------------------------------------------------------
# Linux side: EFI binary, then the self-contained .deb
# ------------------------------------------------------------------
efi:
	cd efi-unlock && ./build.sh

native:
	cd native && make

deb: efi
	CMP_DEB_REV=$(VERSION) bash tools/build-deb.sh

# ------------------------------------------------------------------
# Aggregate
# ------------------------------------------------------------------
release: deb
	@echo
	@echo "===== Linux installer ====="
	ls -la $(DEB_GLOB) $(DEB_GLOB).sha256
	@echo
	@echo "User install (Linux):   sudo apt install ./$(DEB_GLOB)"

clean:
	rm -f efi-unlock/50HXUNLK.EFI efi-unlock/*.o efi-unlock/*.so
	rm -f native/cmp50hx native/*.o
	rm -rf .deb-stage
	rm -f $(DEB_GLOB) $(DEB_GLOB).sha256
	rm -rf artifacts/
