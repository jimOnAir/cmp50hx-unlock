# CMP 50HX unlock — one-shot local release (mirrors .github/workflows/release.yml)
#
#   make release       build the Linux .deb + the Windows zip locally
#   make deb           build just the Linux .deb (needs the EFI binary)
#   make efi           build just the Linux EFI binary
#   make win           build just the Windows Go tools + zip
#   make clean         remove all build outputs
#
# The .deb is the single self-contained Linux artifact: embedded NVIDIA
# 610.43.03 .run + patched DKMS module tree + UEFI ESP unlock + services.

WIN_ZIP         := cmp50hx-unlock-windows.zip
DEB_GLOB        := cmp50hx-unlock_*_amd64.deb
VERSION         ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.PHONY: all release efi deb win clean

all: release

# ------------------------------------------------------------------
# Linux side: EFI binary, then the self-contained .deb
# ------------------------------------------------------------------
efi:
	cd efi-unlock && ./build.sh

deb: efi
	CMP_DEB_REV=$(VERSION) bash tools/build-deb.sh

# ------------------------------------------------------------------
# Windows side (requires Go 1.23+ on PATH; PowerShell for the zip)
# ------------------------------------------------------------------
win:
	@command -v go >/dev/null 2>&1 || (echo "need go 1.23+ on PATH" && exit 2)
	@command -v pwsh >/dev/null 2>&1 || (echo "need pwsh on PATH" && exit 2)
	./tools/build-windows.ps1 -Version $(VERSION) -Source . -Out $(WIN_ZIP)

# ------------------------------------------------------------------
# Aggregate
# ------------------------------------------------------------------
release: deb win
	@echo
	@echo "===== Linux installer ====="
	ls -la $(DEB_GLOB) $(DEB_GLOB).sha256
	@echo
	@echo "===== Windows bundle ====="
	ls -la $(WIN_ZIP) 2>/dev/null || echo "(Windows build skipped — install Go + pwsh)"
	@echo
	@echo "User install (Linux):   sudo apt install ./$(DEB_GLOB)"
	@echo "User install (Win):    unzip and run 50HXInstaller.exe as admin"

clean:
	rm -f efi-unlock/50HXUNLK.EFI efi-unlock/*.o efi-unlock/*.so
	rm -rf .deb-stage
	rm -f $(DEB_GLOB) $(DEB_GLOB).sha256 $(WIN_ZIP)
	rm -rf artifacts/
