/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Aperture-removal feature detection.
 *
 * Provenance: ported from GPU-Tensor-Unlock-Universal @ 1d6a508
 * kernel/gpu_unlock/aperture_compat.h (row K17 of
 * docs/gtuu-mining/source-eval.md). Replaces LINUX_VERSION_CODE
 * gating with __has_include so a kernel that moves the header cannot
 * compile the wrong branch silently (the failure mode this repo
 * already documented for kbuild flag handling).
 *
 * Branch semantics:
 * - <linux/aperture.h> present (>= 5.9): use the aperture API directly.
 * - absent (Ubuntu 5.15 build trees without the header export, and
 *   anything 5.15+ that keeps the helper DRM-only): name-only DRM
 *   descriptor supplies the requesting-driver label; it is never
 *   registered as a DRM driver and never binds a device.
 * Pre-5.15 kernels have neither branch here — out of fleet scope
 * (Ubuntu 22.04+); the old fbdev fallback is dropped with the version
 * gate. The owner string "gpu_unlock" is unchanged, so the sysfs
 * owner label on real removals is byte-identical to the old code.
 */
#ifndef GPU_UNLOCK_APERTURE_COMPAT_H
#define GPU_UNLOCK_APERTURE_COMPAT_H

#include <linux/pci.h>

#if __has_include(<linux/aperture.h>)
#include <linux/aperture.h>
static inline int gpu_unlock_remove_apertures(struct pci_dev *pdev)
{
	return aperture_remove_conflicting_pci_devices(pdev, "gpu_unlock");
}
#else
#include <drm/drm_aperture.h>
#include <drm/drm_drv.h>
static inline int gpu_unlock_remove_apertures(struct pci_dev *pdev)
{
	static const struct drm_driver requester = { .name = "gpu_unlock" };

	return drm_aperture_remove_conflicting_pci_framebuffers(pdev, &requester);
}
#endif

#endif /* GPU_UNLOCK_APERTURE_COMPAT_H */
