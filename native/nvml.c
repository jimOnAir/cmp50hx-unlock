/* nvml.c — shared NVML dlopen layer (see nvml.h). Ported verbatim from the
 * single-file cmp-governor ELF when the tools merged into one binary. */
#define _GNU_SOURCE

#include "nvml.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

/* one dlsym per symbol name; the first name found wins */
static void *load_symbol_any(void *library, const char *const *names,
                             bool required, const char *label) {
    for (int i = 0; names[i] != NULL; ++i) {
        void *symbol = dlsym(library, names[i]);
        if (symbol != NULL) {
            return symbol;
        }
    }
    if (required) {
        fprintf(stderr, "cmp50hx: missing NVML symbol (%s)\n", label);
    }
    return NULL;
}

bool nvml_load(NvmlApi *api) {
    static const char *const count_names[] = {"nvmlDeviceGetCount_v2",
                                              "nvmlDeviceGetCount", NULL};
    static const char *const handle_names[] = {"nvmlDeviceGetHandleByIndex_v2",
                                               NULL};
    static const char *const pci_names[] = {"nvmlDeviceGetPciInfo_v3",
                                            "nvmlDeviceGetPciInfo_v2",
                                            "nvmlDeviceGetPciInfo", NULL};
    static const char *const init_names[] = {"nvmlInit_v2", "nvmlInit", NULL};

    memset(api, 0, sizeof(*api));
    api->library = dlopen("libnvidia-ml.so.1", RTLD_LAZY | RTLD_LOCAL);
    if (api->library == NULL) {
        api->library = dlopen("libnvidia-ml.so", RTLD_LAZY | RTLD_LOCAL);
    }
    if (api->library == NULL) {
        fprintf(stderr, "cmp50hx: cannot load libnvidia-ml.so.1 (is the "
                        "NVIDIA driver installed?): %s\n", dlerror());
        return false;
    }

    api->init = (NvmlInitFn)load_symbol_any(api->library, init_names, true,
                                            "nvmlInit");
    api->shutdown =
        (NvmlShutdownFn)load_symbol_any(api->library,
                                        (const char *const[]){
                                            "nvmlShutdown", NULL},
                                        true, "nvmlShutdown");
    api->device_get_count = (NvmlDeviceGetCountFn)load_symbol_any(
        api->library, count_names, true, "nvmlDeviceGetCount");
    api->device_get_handle = (NvmlDeviceGetHandleByIndexFn)load_symbol_any(
        api->library, handle_names, true, "nvmlDeviceGetHandleByIndex_v2");
    api->device_get_name = (NvmlDeviceGetNameFn)load_symbol_any(
        api->library, (const char *const[]){"nvmlDeviceGetName", NULL}, true,
        "nvmlDeviceGetName");
    api->device_get_pci_info = (NvmlDeviceGetPciInfoFn)load_symbol_any(
        api->library, pci_names, true, "nvmlDeviceGetPciInfo");
    api->device_get_utilization =
        (NvmlDeviceGetUtilizationRatesFn)load_symbol_any(
            api->library,
            (const char *const[]){"nvmlDeviceGetUtilizationRates", NULL}, true,
            "nvmlDeviceGetUtilizationRates");
    api->device_set_persistence = (NvmlDeviceSetPersistenceModeFn)load_symbol_any(
        api->library,
        (const char *const[]){"nvmlDeviceSetPersistenceMode", NULL}, true,
        "nvmlDeviceSetPersistenceMode");
    api->device_set_power_limit = (NvmlDeviceSetPowerLimitFn)load_symbol_any(
        api->library,
        (const char *const[]){"nvmlDeviceSetPowerManagementLimit", NULL}, true,
        "nvmlDeviceSetPowerManagementLimit");
    api->device_set_locked_clocks =
        (NvmlDeviceSetLockedClocksFn)load_symbol_any(
            api->library,
            (const char *const[]){"nvmlDeviceSetGpuLockedClocks", NULL}, true,
            "nvmlDeviceSetGpuLockedClocks");
    api->device_reset_locked_clocks =
        (NvmlDeviceResetLockedClocksFn)load_symbol_any(
            api->library,
            (const char *const[]){"nvmlDeviceResetGpuLockedClocks", NULL}, true,
            "nvmlDeviceResetGpuLockedClocks");
    api->device_set_core_offset = (NvmlDeviceSetCoreOffsetFn)load_symbol_any(
        api->library,
        (const char *const[]){"nvmlDeviceSetGpcClkVfOffset", NULL}, true,
        "nvmlDeviceSetGpcClkVfOffset");
    api->device_set_memory_offset = (NvmlDeviceSetMemoryOffsetFn)load_symbol_any(
        api->library,
        (const char *const[]){"nvmlDeviceSetMemClkVfOffset", NULL}, true,
        "nvmlDeviceSetMemClkVfOffset");
    api->error_string = (NvmlErrorStringFn)load_symbol_any(
        api->library, (const char *const[]){"nvmlErrorString", NULL}, false,
        "nvmlErrorString");

    /* optional getters (cmp-tune) */
    api->device_get_clock = (NvmlDeviceGetClockFn)load_symbol_any(
        api->library, (const char *const[]){"nvmlDeviceGetClockInfo", NULL},
        false, "nvmlDeviceGetClockInfo");
    api->device_get_max_clock = (NvmlDeviceGetClockFn)load_symbol_any(
        api->library, (const char *const[]){"nvmlDeviceGetMaxClockInfo", NULL},
        false, "nvmlDeviceGetMaxClockInfo");
    api->device_get_mem_clocks =
        (NvmlDeviceGetSupportedMemoryClocksFn)load_symbol_any(
            api->library,
            (const char *const[]){"nvmlDeviceGetSupportedMemoryClocks", NULL},
            false, "nvmlDeviceGetSupportedMemoryClocks");
    api->device_get_gfx_clocks =
        (NvmlDeviceGetSupportedGraphicsClocksFn)load_symbol_any(
            api->library,
            (const char *const[]){"nvmlDeviceGetSupportedGraphicsClocks", NULL},
            false, "nvmlDeviceGetSupportedGraphicsClocks");
    api->device_get_power_limit = (NvmlDeviceGetPowerLimitFn)load_symbol_any(
        api->library,
        (const char *const[]){"nvmlDeviceGetPowerManagementLimit", NULL}, false,
        "nvmlDeviceGetPowerManagementLimit");
    api->device_get_power_constraints =
        (NvmlDeviceGetPowerConstraintsFn)load_symbol_any(
            api->library,
            (const char *const[]){"nvmlDeviceGetPowerManagementLimitConstraints",
                                  NULL},
            false, "nvmlDeviceGetPowerManagementLimitConstraints");
    api->device_get_core_offset = (NvmlDeviceGetVfOffsetFn)load_symbol_any(
        api->library,
        (const char *const[]){"nvmlDeviceGetGpcClkVfOffset", NULL}, false,
        "nvmlDeviceGetGpcClkVfOffset");
    api->device_get_core_offset_range =
        (NvmlDeviceGetVfOffsetRangeFn)load_symbol_any(
            api->library,
            (const char *const[]){"nvmlDeviceGetGpcClkMinMaxVfOffset", NULL},
            false, "nvmlDeviceGetGpcClkMinMaxVfOffset");
    api->device_get_mem_offset = (NvmlDeviceGetVfOffsetFn)load_symbol_any(
        api->library,
        (const char *const[]){"nvmlDeviceGetMemClkVfOffset", NULL}, false,
        "nvmlDeviceGetMemClkVfOffset");
    api->device_get_mem_offset_range =
        (NvmlDeviceGetVfOffsetRangeFn)load_symbol_any(
            api->library,
            (const char *const[]){"nvmlDeviceGetMemClkMinMaxVfOffset", NULL},
            false, "nvmlDeviceGetMemClkMinMaxVfOffset");

    return api->init != NULL && api->shutdown != NULL &&
           api->device_get_count != NULL && api->device_get_handle != NULL &&
           api->device_get_name != NULL && api->device_get_pci_info != NULL &&
           api->device_get_utilization != NULL &&
           api->device_set_persistence != NULL &&
           api->device_set_power_limit != NULL &&
           api->device_set_locked_clocks != NULL &&
           api->device_reset_locked_clocks != NULL &&
           api->device_set_core_offset != NULL &&
           api->device_set_memory_offset != NULL;
}

void nvml_unload(NvmlApi *api, bool initialized) {
    if (initialized && api->shutdown != NULL) {
        api->shutdown();
    }
    if (api->library != NULL) {
        dlclose(api->library);
    }
    memset(api, 0, sizeof(*api));
}

bool nvml_ok(const NvmlApi *api, const char *operation, nvmlReturn_t status) {
    if (status == NVML_SUCCESS) {
        return true;
    }
    fprintf(stderr, "cmp50hx: %s failed: %s (%d)\n", operation,
            api->error_string != NULL ? api->error_string(status)
                                      : "NVML error",
            status);
    return false;
}
