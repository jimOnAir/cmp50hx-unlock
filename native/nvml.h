/* nvml.h — shared NVML access layer for the merged cmp50hx binary.
 *
 * dlopen("libnvidia-ml.so.1") + dlsym, no headers, no link-time dependency
 * (the driver ships the library; the package must not depend on its ABI).
 * Symbols the governor needs are mandatory; getters cmp-tune needs are
 * optional (NULL when absent) so a missing optional control degrades to a
 * clear runtime error instead of a failed load.
 */
#ifndef CMP50HX_NVML_H
#define CMP50HX_NVML_H

#include <stdbool.h>
#include <stdint.h>

#define NVML_SUCCESS 0
#define NVML_CLOCK_GRAPHICS 0
#define NVML_CLOCK_MEM 2

#define MAX_GPUS 64U

typedef int nvmlReturn_t;
typedef void *nvmlDevice_t;

typedef struct {
    unsigned int gpu;
    unsigned int memory;
} NvmlUtilization;

typedef struct {
    char bus_id_legacy[16];
    unsigned int domain;
    unsigned int bus;
    unsigned int device;
    unsigned int pci_device_id;
    unsigned int pci_subsystem_id;
    char bus_id[32];
} NvmlPciInfo;

typedef nvmlReturn_t (*NvmlInitFn)(void);
typedef nvmlReturn_t (*NvmlShutdownFn)(void);
typedef nvmlReturn_t (*NvmlDeviceGetCountFn)(unsigned int *);
typedef nvmlReturn_t (*NvmlDeviceGetHandleByIndexFn)(unsigned int,
                                                     nvmlDevice_t *);
typedef nvmlReturn_t (*NvmlDeviceGetNameFn)(nvmlDevice_t, char *, unsigned int);
typedef nvmlReturn_t (*NvmlDeviceGetPciInfoFn)(nvmlDevice_t, NvmlPciInfo *);
typedef nvmlReturn_t (*NvmlDeviceGetUtilizationRatesFn)(nvmlDevice_t,
                                                        NvmlUtilization *);
typedef nvmlReturn_t (*NvmlDeviceSetPersistenceModeFn)(nvmlDevice_t,
                                                       unsigned int);
typedef nvmlReturn_t (*NvmlDeviceSetPowerLimitFn)(nvmlDevice_t, unsigned int);
typedef nvmlReturn_t (*NvmlDeviceSetLockedClocksFn)(nvmlDevice_t, unsigned int,
                                                    unsigned int);
typedef nvmlReturn_t (*NvmlDeviceResetLockedClocksFn)(nvmlDevice_t);
typedef nvmlReturn_t (*NvmlDeviceSetCoreOffsetFn)(nvmlDevice_t, int);
typedef nvmlReturn_t (*NvmlDeviceSetMemoryOffsetFn)(nvmlDevice_t, int);
typedef const char *(*NvmlErrorStringFn)(nvmlReturn_t);
typedef nvmlReturn_t (*NvmlDeviceGetClockFn)(nvmlDevice_t, int, unsigned int *);
typedef nvmlReturn_t (*NvmlDeviceGetSupportedClocksCountFn)(nvmlDevice_t,
                                                            unsigned int *);
typedef nvmlReturn_t (*NvmlDeviceGetSupportedMemoryClocksFn)(nvmlDevice_t,
                                                             unsigned int *,
                                                             unsigned int *);
typedef nvmlReturn_t (*NvmlDeviceGetSupportedGraphicsClocksFn)(nvmlDevice_t,
                                                               unsigned int,
                                                               unsigned int *,
                                                               unsigned int *);
typedef nvmlReturn_t (*NvmlDeviceGetPowerLimitFn)(nvmlDevice_t, unsigned int *);
typedef nvmlReturn_t (*NvmlDeviceGetPowerConstraintsFn)(nvmlDevice_t,
                                                        unsigned int *,
                                                        unsigned int *);
typedef nvmlReturn_t (*NvmlDeviceGetVfOffsetFn)(nvmlDevice_t, int *);
typedef nvmlReturn_t (*NvmlDeviceGetVfOffsetRangeFn)(nvmlDevice_t, int *,
                                                     int *);

typedef struct {
    void *library;
    /* mandatory */
    NvmlInitFn init;
    NvmlShutdownFn shutdown;
    NvmlDeviceGetCountFn device_get_count;
    NvmlDeviceGetHandleByIndexFn device_get_handle;
    NvmlDeviceGetNameFn device_get_name;
    NvmlDeviceGetPciInfoFn device_get_pci_info;
    NvmlDeviceGetUtilizationRatesFn device_get_utilization;
    NvmlDeviceSetPersistenceModeFn device_set_persistence;
    NvmlDeviceSetPowerLimitFn device_set_power_limit;
    NvmlDeviceSetLockedClocksFn device_set_locked_clocks;
    NvmlDeviceResetLockedClocksFn device_reset_locked_clocks;
    NvmlDeviceSetCoreOffsetFn device_set_core_offset;
    NvmlDeviceSetMemoryOffsetFn device_set_memory_offset;
    NvmlErrorStringFn error_string;
    /* optional (cmp-tune) */
    NvmlDeviceGetClockFn device_get_clock;            /* GetClockInfo */
    NvmlDeviceGetClockFn device_get_max_clock;        /* GetMaxClockInfo */
    NvmlDeviceGetSupportedMemoryClocksFn device_get_mem_clocks;
    NvmlDeviceGetSupportedGraphicsClocksFn device_get_gfx_clocks;
    NvmlDeviceGetPowerLimitFn device_get_power_limit;
    NvmlDeviceGetPowerConstraintsFn device_get_power_constraints;
    NvmlDeviceGetVfOffsetFn device_get_core_offset;
    NvmlDeviceGetVfOffsetRangeFn device_get_core_offset_range;
    NvmlDeviceGetVfOffsetFn device_get_mem_offset;
    NvmlDeviceGetVfOffsetRangeFn device_get_mem_offset_range;
} NvmlApi;

/* Load library + mandatory symbols; optional getters resolved when present.
 * Prints a diagnostic on failure. */
bool nvml_load(NvmlApi *api);
void nvml_unload(NvmlApi *api, bool initialized);
bool nvml_ok(const NvmlApi *api, const char *operation, nvmlReturn_t status);

#endif /* CMP50HX_NVML_H */
