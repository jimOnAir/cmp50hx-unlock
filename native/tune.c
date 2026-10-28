/* tune.c — profile-driven tuning for unlocked CMP cards. C port of the
 * cmp-tune Python tool (merged into cmp50hx 2026-10-28; the cmp-tune name
 * lives on as an argv[0] symlink to this binary).
 *
 * Sets power limit, core/memory VF offsets and the locked core-clock range
 * from named profiles. Every value is checked against the limits the card
 * itself reports, so a profile can never ask for a clock or power level
 * outside the card's own range.
 *
 * nvidia-smi cannot set VF offsets, so this talks to NVML directly through
 * the shared dlopen layer (native/nvml.c) — no headers, no link-time driver
 * dependency.
 */
#define _GNU_SOURCE

#include <ctype.h>
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nvml.h"

#define MAX_PROFILES 64
#define MAX_KEYS 5
static const char *KEY_NAMES[MAX_KEYS] = {"power_w", "core_offset",
                                          "mem_offset", "clock_min",
                                          "clock_max"};
enum { K_POWER_W, K_CORE_OFFSET, K_MEM_OFFSET, K_CLOCK_MIN, K_CLOCK_MAX };

typedef struct {
    char name[64];
    int present[MAX_KEYS];
    int value[MAX_KEYS];
    char unknown[64];      /* first unknown key, empty if none */
} Profile;

static Profile profiles[MAX_PROFILES];
static int profile_count;
static char config_path[PATH_MAX + 64];

typedef struct {
    int clock_min;
    int clock_max;
    unsigned int power_min_mw;
    unsigned int power_max_mw;
    int core_off_lo, core_off_hi;
    bool has_core_off;
    int mem_off_lo, mem_off_hi;
    bool has_mem_off;
} Limits;

typedef struct {
    bool has_power;
    unsigned int power_mw;
    bool has_core_offset;
    int core_offset;
    bool has_mem_offset;
    int mem_offset;
    int clock_mode;      /* 0 = leave, 1 = clear, 2 = lock */
    int clock_min, clock_max;
    bool defaulted_min, defaulted_max;
} Plan;

static void die(const char *fmt, ...) {
    va_list ap;
    fprintf(stderr, "cmp-tune: ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    exit(1);
}

/* --- config ---------------------------------------------------------------- */

static char *trim(char *s) {
    char *end;
    while (isspace((unsigned char)*s)) {
        ++s;
    }
    end = s + strlen(s);
    while (end > s && isspace((unsigned char)end[-1])) {
        --end;
    }
    *end = '\0';
    return s;
}

static int key_index(const char *name) {
    for (int i = 0; i < MAX_KEYS; ++i) {
        if (strcmp(name, KEY_NAMES[i]) == 0) {
            return i;
        }
    }
    return -1;
}

static void lowercase(char *s) {
    for (; *s; ++s) {
        *s = (char)tolower((unsigned char)*s);
    }
}

static void load_config(void) {
    FILE *f = NULL;
    char line[512];
    Profile *cur = NULL;

    config_path[0] = '\0';
    f = fopen("/etc/cmp-tune.conf", "r");
    if (f != NULL) {
        snprintf(config_path, sizeof config_path, "/etc/cmp-tune.conf");
    } else {
        /* fallbacks next to the executable: installed layout ships
         * profiles.conf beside the binary; repo dev builds find
         * ../tuning/profiles.conf (the Python tool's script-dir lookup) */
        char exe[PATH_MAX];
        ssize_t len = readlink("/proc/self/exe", exe, sizeof exe - 1);
        if (len > 0) {
            exe[len] = '\0';
            char dirbuf[PATH_MAX];
            snprintf(dirbuf, sizeof dirbuf, "%s", dirname(exe));
            snprintf(config_path, sizeof config_path, "%s/profiles.conf",
                     dirbuf);
            f = fopen(config_path, "r");
            if (f == NULL) {
                snprintf(config_path, sizeof config_path,
                         "%s/../tuning/profiles.conf", dirbuf);
                f = fopen(config_path, "r");
            }
        }
    }
    if (f == NULL) {
        die("no config found; looked in: /etc/cmp-tune.conf and the "
            "executable directory");
    }
    while (fgets(line, sizeof line, f) != NULL) {
        char *text = trim(line);
        if (*text == '\0' || *text == '#' || *text == ';') {
            continue;
        }
        if (*text == '[') {
            char *close = strchr(text, ']');
            if (close == NULL) {
                continue;
            }
            *close = '\0';
            if (profile_count >= MAX_PROFILES) {
                die("too many profiles (max %d)", MAX_PROFILES);
            }
            cur = &profiles[profile_count++];
            memset(cur, 0, sizeof(*cur));
            snprintf(cur->name, sizeof cur->name, "%s", trim(text + 1));
            continue;
        }
        if (cur == NULL) {
            continue;
        }
        char *eq = strchr(text, '=');
        if (eq == NULL) {
            continue;
        }
        *eq = '\0';
        char *name = trim(text);
        char *raw = trim(eq + 1);
        lowercase(name);
        int idx = key_index(name);
        if (idx < 0) {
            if (cur->unknown[0] == '\0') {
                snprintf(cur->unknown, sizeof cur->unknown, "%s", name);
            }
            continue;
        }
        if (*raw == '\0') {
            continue;
        }
        char *end = NULL;
        errno = 0;
        long v = strtol(raw, &end, 10);
        if (errno != 0 || end == raw || *end != '\0' || v > INT_MAX ||
            v < INT_MIN) {
            snprintf(cur->unknown, sizeof cur->unknown, "!%s=%s", name, raw);
            cur->present[idx] = 0;
            continue;
        }
        cur->present[idx] = 1;
        cur->value[idx] = (int)v;
    }
    fclose(f);
}

static Profile *find_profile(const char *name) {
    for (int i = 0; i < profile_count; ++i) {
        if (strcmp(profiles[i].name, name) == 0) {
            return &profiles[i];
        }
    }
    return NULL;
}

static void validate_profile(Profile *profile) {
    if (profile->unknown[0] != '\0') {
        if (profile->unknown[0] == '!') {
            die("profile %s: %s must be a whole number", profile->name,
                profile->unknown + 1);
        }
        die("profile %s: unknown key: %s (valid: %s, %s, %s, %s, %s)",
            profile->name, profile->unknown, KEY_NAMES[0], KEY_NAMES[1],
            KEY_NAMES[2], KEY_NAMES[3], KEY_NAMES[4]);
    }
}

/* --- limits ---------------------------------------------------------------- */

static int cmp_desc(const void *a, const void *b) {
    unsigned int x = *(const unsigned int *)a, y = *(const unsigned int *)b;
    return x < y ? 1 : (x > y ? -1 : 0);
}

/* Full list of graphics clocks the card advertises, descending (deduped).
 * The NULL-count probe calls legitimately return INSUFFICIENT_SIZE (they
 * still set the count) — mirror the Python tool, which reads the count and
 * ignores the probe return. */
static int supported_graphics_clocks(const NvmlApi *nvml, nvmlDevice_t h,
                                     unsigned int *out, int max) {
    unsigned int mem_count = 0, count = 0;
    if (!nvml->device_get_mem_clocks) {
        return 0;
    }
    nvml->device_get_mem_clocks(h, &mem_count, NULL);
    if (mem_count == 0) {
        return 0;
    }
    unsigned int *mems = calloc(mem_count, sizeof *mems);
    if (mems == NULL ||
        nvml->device_get_mem_clocks(h, &mem_count, mems) != NVML_SUCCESS) {
        free(mems);
        return 0;
    }
    for (unsigned int m = 0; m < mem_count; ++m) {
        unsigned int n = 0;
        nvml->device_get_gfx_clocks(h, mems[m], &n, NULL);
        if (n == 0) {
            continue;
        }
        unsigned int *clocks = calloc(n, sizeof *clocks);
        if (clocks == NULL) {
            continue;
        }
        if (nvml->device_get_gfx_clocks(h, mems[m], &n, clocks) ==
            NVML_SUCCESS) {
            for (unsigned int i = 0; i < n && (int)count < max; ++i) {
                if (clocks[i] != 0) {
                    out[count++] = clocks[i];
                }
            }
        }
        free(clocks);
    }
    free(mems);
    qsort(out, count, sizeof *out, cmp_desc);
    /* dedupe in place */
    int unique = 0;
    for (int i = 0; i < (int)count; ++i) {
        if (unique == 0 || out[(unsigned)unique - 1] != out[(unsigned)i]) {
            out[unique++] = out[(unsigned)i];
        }
    }
    return unique;
}

static void read_limits(NvmlApi *nvml, nvmlDevice_t h, Limits *lim) {
    static unsigned int clocks[1024];
    memset(lim, 0, sizeof(*lim));
    int n = supported_graphics_clocks(nvml, h, clocks,
                                      (int)(sizeof clocks / sizeof clocks[0]));
    if (n > 0) {
        lim->clock_max = (int)clocks[0];
        lim->clock_min = (int)clocks[n - 1];
    } else if (nvml->device_get_max_clock) {
        unsigned int v = 0;
        if (nvml_ok(nvml, "nvmlDeviceGetMaxClockInfo",
                    nvml->device_get_max_clock(h, NVML_CLOCK_GRAPHICS, &v))) {
            lim->clock_max = (int)v;
            lim->clock_min = (int)v;
        } else {
            die("cannot read the card's supported clocks");
        }
    } else {
        die("this driver's NVML has no nvmlDeviceGetSupportedGraphicsClocks");
    }
    if (!nvml->device_get_power_constraints ||
        !nvml_ok(nvml, "nvmlDeviceGetPowerManagementLimitConstraints",
                 nvml->device_get_power_constraints(h, &lim->power_min_mw,
                                                    &lim->power_max_mw))) {
        die("cannot read the card's power constraints");
    }
    if (nvml->device_get_core_offset_range &&
        nvml->device_get_core_offset_range(h, &lim->core_off_lo,
                                           &lim->core_off_hi) == NVML_SUCCESS) {
        lim->has_core_off = true;
    }
    if (nvml->device_get_mem_offset_range &&
        nvml->device_get_mem_offset_range(h, &lim->mem_off_lo,
                                          &lim->mem_off_hi) == NVML_SUCCESS) {
        lim->has_mem_off = true;
    }
}

/* --- resolve --------------------------------------------------------------- */

static void resolve(Profile *profile, const Limits *lim, Plan *plan,
                    unsigned int device_index) {
    char fail[512];
    memset(plan, 0, sizeof(*plan));
    fail[0] = '\0';
    #define FAIL_ADD(...)                                                    \
        do {                                                                 \
            if (fail[0] != '\0') strncat(fail, "\n  - ", sizeof fail - strlen(fail) - 1); \
            strncat(fail, "\0", 0);                                          \
            char _tmp[256];                                                  \
            snprintf(_tmp, sizeof _tmp, __VA_ARGS__);                        \
            strncat(fail, _tmp, sizeof fail - strlen(fail) - 1);             \
        } while (0)

    if (profile->present[K_POWER_W]) {
        int w = profile->value[K_POWER_W];
        if (!(w * 1000 >= (int)lim->power_min_mw &&
              w * 1000 <= (int)lim->power_max_mw)) {
            FAIL_ADD("power_w %d is outside the card's %.0f..%.0f W", w,
                     lim->power_min_mw / 1000.0, lim->power_max_mw / 1000.0);
        } else {
            plan->has_power = true;
            plan->power_mw = (unsigned int)(w * 1000);
        }
    }

    if (profile->present[K_CORE_OFFSET]) {
        int v = profile->value[K_CORE_OFFSET];
        if (!lim->has_core_off) {
            FAIL_ADD("core_offset: this driver/card does not expose a core "
                     "VF offset");
        } else if (v < lim->core_off_lo || v > lim->core_off_hi) {
            FAIL_ADD("core_offset %+d is outside the card's %+d..%+d MHz", v,
                     lim->core_off_lo, lim->core_off_hi);
        } else {
            plan->has_core_offset = true;
            plan->core_offset = v;
        }
    }
    if (profile->present[K_MEM_OFFSET]) {
        int v = profile->value[K_MEM_OFFSET];
        if (!lim->has_mem_off) {
            FAIL_ADD("mem_offset: this driver/card does not expose a memory "
                     "VF offset");
        } else if (v < lim->mem_off_lo || v > lim->mem_off_hi) {
            FAIL_ADD("mem_offset %+d is outside the card's %+d..%+d MHz", v,
                     lim->mem_off_lo, lim->mem_off_hi);
        } else {
            plan->has_mem_offset = true;
            plan->mem_offset = v;
        }
    }

    bool wants_lock = profile->present[K_CLOCK_MIN] ||
                      profile->present[K_CLOCK_MAX];
    if (wants_lock) {
        /* a bound the profile leaves out is taken from the card, so the
         * lock always sits inside its own range */
        int lo = profile->present[K_CLOCK_MIN] ? profile->value[K_CLOCK_MIN]
                                               : lim->clock_min;
        int hi = profile->present[K_CLOCK_MAX] ? profile->value[K_CLOCK_MAX]
                                               : lim->clock_max;
        bool bad = false;
        if (!(lo >= lim->clock_min && lo <= lim->clock_max)) {
            FAIL_ADD("clock_min %d is outside the card's %d..%d MHz", lo,
                     lim->clock_min, lim->clock_max);
            bad = true;
        }
        if (!(hi >= lim->clock_min && hi <= lim->clock_max)) {
            FAIL_ADD("clock_max %d is outside the card's %d..%d MHz", hi,
                     lim->clock_min, lim->clock_max);
            bad = true;
        }
        if (lo > hi) {
            FAIL_ADD("clock_min %d is above clock_max %d", lo, hi);
            bad = true;
        }
        if (!bad) {
            plan->clock_mode = 2;
            plan->clock_min = lo;
            plan->clock_max = hi;
            plan->defaulted_min = !profile->present[K_CLOCK_MIN];
            plan->defaulted_max = !profile->present[K_CLOCK_MAX];
        }
    } else {
        plan->clock_mode = 1;    /* set neither -> clear any existing lock */
    }

    if (fail[0] != '\0') {
        die("profile '%s' cannot be applied to GPU %u:\n  - %s",
            profile->name, device_index, fail);
    }
    #undef FAIL_ADD
}

static void describe(const Plan *plan, char *out, size_t out_len) {
    size_t used = 0;
    bool first = true;
    out[0] = '\0';
    #define NOTE(...)                                                        \
        do {                                                                 \
            char _tmp[200];                                                  \
            snprintf(_tmp, sizeof _tmp, "%s", first ? "" : "; ");           \
            first = false;                                                   \
            snprintf(_tmp + strlen(_tmp), sizeof _tmp - strlen(_tmp),       \
                     __VA_ARGS__);                                           \
            strncat(out, _tmp, out_len - strlen(out) - 1);                   \
            used = strlen(out); (void)used;                                  \
        } while (0)
    if (plan->has_power) {
        NOTE("power %u W", plan->power_mw / 1000U);
    }
    if (plan->has_core_offset) {
        NOTE("core offset %+d MHz", plan->core_offset);
    }
    if (plan->has_mem_offset) {
        NOTE("memory offset %+d MHz", plan->mem_offset);
    }
    if (plan->clock_mode == 2) {
        char note[96] = "";
        if (plan->defaulted_min && plan->defaulted_max) {
            snprintf(note, sizeof note, " (min and max from card)");
        } else if (plan->defaulted_min) {
            snprintf(note, sizeof note, " (min from card)");
        } else if (plan->defaulted_max) {
            snprintf(note, sizeof note, " (max from card)");
        }
        NOTE("clock %d..%d MHz%s", plan->clock_min, plan->clock_max, note);
    } else if (plan->clock_mode == 1) {
        NOTE("clock lock cleared");
    }
    if (out[0] == '\0') {
        snprintf(out, out_len, "nothing to change");
    }
    #undef NOTE
}

/* --- device targets --------------------------------------------------------- */

static const char *model_for(unsigned int pci_id) {
    if (pci_id == 0x1E0910DE) return "CMP 50HX";
    if (pci_id == 0x220D10DE) return "CMP 90HX";
    return NULL;
}

typedef struct {
    unsigned int index;
    nvmlDevice_t handle;
    char name[96];
    const char *model;
} Target;

static int scan_targets(NvmlApi *nvml, int index, bool quiet, Target *out,
                        int max) {
    unsigned int count = 0;
    int n = 0;
    Target *supported = calloc((size_t)(count + 1), sizeof(Target));
    if (!nvml_ok(nvml, "nvmlDeviceGetCount_v2",
                 nvml->device_get_count(&count))) {
        die("nvmlDeviceGetCount failed");
    }
    for (unsigned int i = 0; i < count; ++i) {
        nvmlDevice_t h = NULL;
        NvmlPciInfo pci;
        const char *model;
        if (!nvml_ok(nvml, "nvmlDeviceGetHandleByIndex_v2",
                     nvml->device_get_handle(i, &h)) ||
            !nvml_ok(nvml, "nvmlDeviceGetPciInfo",
                     nvml->device_get_pci_info(h, &pci))) {
            continue;
        }
        model = model_for(pci.pci_device_id);
        if (model == NULL) {
            char name[96] = "GPU";
            if (!quiet) {
                if (nvml->device_get_name(h, name, sizeof name) !=
                    NVML_SUCCESS) {
                    name[0] = '\0';
                }
                printf("skipping GPU %u (%s, pci %04x:%04x): not a supported "
                       "CMP card\n",
                       i, name, pci.pci_device_id & 0xFFFF,
                       pci.pci_device_id >> 16);
            }
            continue;
        }
        if (n < max) {
            supported[n].index = i;
            supported[n].handle = h;
            supported[n].model = model;
            if (nvml->device_get_name(h, supported[n].name,
                                      sizeof supported[n].name) !=
                NVML_SUCCESS) {
                snprintf(supported[n].name, sizeof supported[n].name, "GPU");
            }
            ++n;
        }
    }
    if (index >= 0) {
        for (int i = 0; i < n; ++i) {
            if ((int)supported[i].index == index) {
                out[0] = supported[i];
                free(supported);
                return 1;
            }
        }
        if ((unsigned int)index < count) {
            free(supported);
            die("GPU %d is not a supported CMP card; supported: CMP 50HX, "
                "CMP 90HX",
                index);
        }
        free(supported);
        die("no GPU with index %d", index);
    }
    if (n == 0) {
        free(supported);
        die("no supported CMP card found (looking for: CMP 50HX, CMP 90HX)");
    }
    memcpy(out, supported, (size_t)n * sizeof(Target));
    free(supported);
    return n;
}

static void need_root(void) {
    if (geteuid() != 0) {
        die("this needs root (sudo)");
    }
}

/* --- idle governor sync (identical contract to the Python tool) ------------- */

#define GOV_UNIT "cmp-idle-governor"
#define GOV_DROPIN_DIR "/etc/systemd/system/" GOV_UNIT ".service.d"
#define GOV_DROPIN GOV_DROPIN_DIR "/10-cmp-tune.conf"

static bool governor_present(void) {
    FILE *f = popen("systemctl is-enabled " GOV_UNIT " 2>/dev/null", "r");
    char token[64] = "";
    bool present = false;
    if (f != NULL) {
        if (fgets(token, sizeof token, f) != NULL) {
            token[strcspn(token, "\n")] = '\0';
        }
        pclose(f);
        present = strcmp(token, "enabled") == 0 ||
                  strcmp(token, "enabled-runtime") == 0 ||
                  strcmp(token, "static") == 0;
    }
    return present;
}

/* Returns 1 when something was written/removed (caller prints the line). */
static int sync_governor(const Plan *plan /*NULL=clear*/){
    FILE *fh;
    if (!governor_present()) {
        return 0;
    }
    if (plan == NULL) {
        if (remove(GOV_DROPIN) != 0) {
            return 0;   /* absent: nothing to clear */
        }
        printf("idle governor: governor overrides cleared\n");
    } else {
        char dir_cmd[512];
        snprintf(dir_cmd, sizeof dir_cmd, "mkdir -p '" GOV_DROPIN_DIR "'");
        if (system(dir_cmd) != 0) {
            return 0;
        }
        fh = fopen(GOV_DROPIN, "w");
        if (fh == NULL) {
            printf("  warning: could not sync the idle governor: %s\n",
                   strerror(errno));
            return 0;
        }
        fputs("# written by cmp-tune; keeps the governor's release\n"
              "# in step with the applied tuning profile.\n"
              "[Service]\n",
              fh);
        if (plan->clock_mode == 2) {
            fprintf(fh, "Environment=CMP_LOAD_CLOCK=%d,%d\n", plan->clock_min,
                    plan->clock_max);
        }
        if (plan->has_core_offset) {
            fprintf(fh, "Environment=CMP_LOAD_CORE_OFFSET=%d\n",
                    plan->core_offset);
        }
        if (plan->has_mem_offset) {
            fprintf(fh, "Environment=CMP_LOAD_MEM_OFFSET=%d\n",
                    plan->mem_offset);
        }
        if (plan->has_power) {
            fprintf(fh, "Environment=CMP_LOAD_POWER_W=%u\n",
                    plan->power_mw / 1000U);
        }
        fclose(fh);
        printf("idle governor: profile drop-in written\n");
    }
    (void)system("systemctl daemon-reload");
    /* --no-block: this may run from a unit ordered Before= the governor
     * (applying a profile at boot), and a blocking restart would deadlock
     * against that ordering. Queueing the job is enough either way. */
    (void)system("systemctl try-restart --no-block " GOV_UNIT);
    return 1;
}

/* --- commands --------------------------------------------------------------- */

static void cmd_list(void) {
    printf("config: %s\n", config_path);
    for (int i = 0; i < profile_count; ++i) {
        char body[512];
        size_t used = 0;
        validate_profile(&profiles[i]);
        body[0] = '\0';
        for (int k = 0; k < MAX_KEYS; ++k) {
            if (profiles[i].present[k]) {
                used += (size_t)snprintf(
                    body + used, sizeof body - used, "%s%s=%d",
                    used == 0 ? "" : ", ", KEY_NAMES[k], profiles[i].value[k]);
            }
        }
        if (body[0] == '\0') {
            printf("  %-12s (no overrides - resets the card to defaults)\n",
                   profiles[i].name);
        } else {
            printf("  %-12s %s\n", profiles[i].name, body);
        }
    }
}

static void print_limits_line(const Limits *lim) {
    printf("  card says: clocks %d..%d MHz, power %.0f..%.0f W\n",
           lim->clock_min, lim->clock_max, lim->power_min_mw / 1000.0,
           lim->power_max_mw / 1000.0);
    if (lim->has_core_off) {
        printf("             core offset %+d..%+d MHz\n", lim->core_off_lo,
               lim->core_off_hi);
    }
    if (lim->has_mem_off) {
        printf("             memory offset %+d..%+d MHz\n", lim->mem_off_lo,
               lim->mem_off_hi);
    }
}

static void cmd_status(NvmlApi *nvml, Target *targets, int count) {
    for (int i = 0; i < count; ++i) {
        Limits lim;
        unsigned int core = 0, mem = 0, power = 0;
        int co = 0, mo = 0;
        bool have_co = false, have_mo = false;
        read_limits(nvml, targets[i].handle, &lim);
        printf("GPU %u: %s [%s]\n", targets[i].index, targets[i].name,
               targets[i].model);
        if (!nvml->device_get_clock ||
            nvml->device_get_clock(targets[i].handle, NVML_CLOCK_GRAPHICS,
                                   &core) != NVML_SUCCESS ||
            nvml->device_get_clock(targets[i].handle, NVML_CLOCK_MEM, &mem) !=
                NVML_SUCCESS ||
            !nvml->device_get_power_limit ||
            nvml->device_get_power_limit(targets[i].handle, &power) !=
                NVML_SUCCESS) {
            die("cannot read live clocks (missing NVML controls)");
        }
        printf("  now      : core %u MHz, memory %u MHz, power limit %.0f W\n",
               core, mem, power / 1000.0);
        if (nvml->device_get_core_offset &&
            nvml->device_get_core_offset(targets[i].handle, &co) ==
                NVML_SUCCESS) {
            have_co = true;
        }
        if (nvml->device_get_mem_offset &&
            nvml->device_get_mem_offset(targets[i].handle, &mo) ==
                NVML_SUCCESS) {
            have_mo = true;
        }
        {
            char core_text[32], mem_text[32];
            if (have_co) {
                snprintf(core_text, sizeof core_text, "%+d MHz", co);
            } else {
                snprintf(core_text, sizeof core_text, "n/a");
            }
            if (have_mo) {
                snprintf(mem_text, sizeof mem_text, "%+d MHz", mo);
            } else {
                snprintf(mem_text, sizeof mem_text, "n/a");
            }
            printf("  offsets  : core %s, memory %s\n", core_text, mem_text);
        }
        print_limits_line(&lim);
    }
}

static void cmd_show(NvmlApi *nvml, Target *targets, int count,
                     const char *profile_name) {
    Profile *profile = find_profile(profile_name);
    if (profile == NULL) {
        die("no such profile: %s (try: cmp-tune list)", profile_name);
    }
    validate_profile(profile);
    for (int i = 0; i < count; ++i) {
        Limits lim;
        Plan plan;
        char text[512];
        read_limits(nvml, targets[i].handle, &lim);
        resolve(profile, &lim, &plan, targets[i].index);
        describe(&plan, text, sizeof text);
        printf("GPU %u (%s): %s\n", targets[i].index, targets[i].name, text);
    }
}

static void cmd_apply(NvmlApi *nvml, Target *targets, int count,
                      const char *profile_name, bool sync_governor_flag) {
    Profile *profile = find_profile(profile_name);
    Plan plans[64];
    Limits lims[64];
    bool synced = false;
    if (profile == NULL) {
        die("no such profile: %s (try: cmp-tune list)", profile_name);
    }
    need_root();
    validate_profile(profile);
    if (count > 64) {
        die("too many target cards");
    }
    /* resolve against every card first: a bad profile applies to none */
    for (int i = 0; i < count; ++i) {
        read_limits(nvml, targets[i].handle, &lims[i]);
        resolve(profile, &lims[i], &plans[i], targets[i].index);
    }
    for (int i = 0; i < count; ++i) {
        char text[512];
        describe(&plans[i], text, sizeof text);
        printf("GPU %u: %s\n", targets[i].index, text);
        if (plans[i].has_power) {
            if (!nvml_ok(nvml, "nvmlDeviceSetPowerManagementLimit",
                         nvml->device_set_power_limit(targets[i].handle,
                                                      plans[i].power_mw))) {
                die("NVML: nvmlDeviceSetPowerManagementLimit failed");
            }
        }
        if (plans[i].has_core_offset) {
            if (!nvml_ok(nvml, "nvmlDeviceSetGpcClkVfOffset",
                         nvml->device_set_core_offset(targets[i].handle,
                                                      plans[i].core_offset))) {
                die("NVML: nvmlDeviceSetGpcClkVfOffset failed");
            }
        }
        if (plans[i].has_mem_offset) {
            if (!nvml_ok(nvml, "nvmlDeviceSetMemClkVfOffset",
                         nvml->device_set_memory_offset(targets[i].handle,
                                                        plans[i].mem_offset))) {
                die("NVML: nvmlDeviceSetMemClkVfOffset failed");
            }
        }
        if (plans[i].clock_mode == 2) {
            if (!nvml_ok(nvml, "nvmlDeviceSetGpuLockedClocks",
                         nvml->device_set_locked_clocks(
                             targets[i].handle, (unsigned int)plans[i].clock_min,
                             (unsigned int)plans[i].clock_max))) {
                die("NVML: nvmlDeviceSetGpuLockedClocks failed");
            }
        } else if (plans[i].clock_mode == 1) {
            if (!nvml_ok(nvml, "nvmlDeviceResetGpuLockedClocks",
                         nvml->device_reset_locked_clocks(targets[i].handle))) {
                die("NVML: nvmlDeviceResetGpuLockedClocks failed");
            }
        }
    }
    if (sync_governor_flag && count > 0) {
        /* mirror the Python behaviour: the last card's plan drives the
         * governor's load restore */
        synced = sync_governor(&plans[count - 1]) != 0;
    }
    (void)synced;
    printf("applied profile '%s'\n", profile_name);
}

static void cmd_reset(NvmlApi *nvml, Target *targets, int count,
                      bool sync_governor_flag) {
    need_root();
    for (int i = 0; i < count; ++i) {
        Limits lim;
        read_limits(nvml, targets[i].handle, &lim);
        if (!nvml_ok(nvml, "nvmlDeviceSetPowerManagementLimit",
                     nvml->device_set_power_limit(targets[i].handle,
                                                  lim.power_max_mw))) {
            die("NVML: nvmlDeviceSetPowerManagementLimit failed");
        }
        if (lim.has_core_off) {
            if (!nvml_ok(nvml, "nvmlDeviceSetGpcClkVfOffset(0)",
                         nvml->device_set_core_offset(targets[i].handle, 0))) {
                die("NVML: nvmlDeviceSetGpcClkVfOffset failed");
            }
        }
        if (lim.has_mem_off) {
            if (!nvml_ok(nvml, "nvmlDeviceSetMemClkVfOffset(0)",
                         nvml->device_set_memory_offset(targets[i].handle, 0))) {
                die("NVML: nvmlDeviceSetMemClkVfOffset failed");
            }
        }
        if (!nvml_ok(nvml, "nvmlDeviceResetGpuLockedClocks",
                     nvml->device_reset_locked_clocks(targets[i].handle))) {
            die("NVML: nvmlDeviceResetGpuLockedClocks failed");
        }
        printf("GPU %u: power %.0f W, offsets 0, clock lock cleared\n",
               targets[i].index, lim.power_max_mw / 1000.0);
    }
    if (sync_governor_flag) {
        sync_governor(NULL);
    }
}

static void cmd_core_offset(NvmlApi *nvml, Target *targets, int count,
                            int value, bool quiet) {
    need_root();
    for (int i = 0; i < count; ++i) {
        int lo = 0, hi = 0;
        if (!nvml->device_get_core_offset_range ||
            nvml->device_get_core_offset_range(targets[i].handle, &lo, &hi) !=
                NVML_SUCCESS) {
            die("GPU %u does not expose a core VF offset", targets[i].index);
        }
        if (value < lo || value > hi) {
            die("core offset %+d is outside the card's %+d..%+d MHz", value,
                lo, hi);
        }
        if (!nvml_ok(nvml, "nvmlDeviceSetGpcClkVfOffset",
                     nvml->device_set_core_offset(targets[i].handle, value))) {
            die("NVML: nvmlDeviceSetGpcClkVfOffset failed");
        }
        if (!quiet) {
            printf("GPU %u: core offset %+d MHz\n", targets[i].index, value);
        }
    }
}

/* --- entry point ------------------------------------------------------------ */

void tune_usage(void) {
    printf("Usage: cmp-tune [-i N] [--no-sync-governor] COMMAND\n");
    printf("  list                    profiles in the config file\n");
    printf("  status                  live state + the card's supported ranges\n");
    printf("  show [PROFILE]          what a profile would apply\n");
    printf("  apply PROFILE           apply it\n");
    printf("  reset                   back to card defaults\n");
    printf("  core-offset N [-q]      set the core VF offset directly\n");
    printf("  -i, --index N           act on one GPU (default: all)\n");
    printf("  --no-sync-governor      do not touch the idle governor drop-in\n");
}

int tune_main(int argc, char **argv) {
    int index = -1;
    bool sync_governor_flag = true;
    const char *command = NULL;
    const char *profile_name = NULL;
    int offset_value = 0;
    bool quiet = false;
    NvmlApi nvml;
    bool nvml_started = false;
    Target targets[64];
    int count;
    int rc = 1;

    /* global flags may appear before or after the subcommand (argparse
     * tolerated both call shapes we care about) */
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "-i") == 0 || strcmp(argv[i], "--index") == 0) {
            if (i + 1 >= argc) {
                tune_usage();
                return 2;
            }
            index = atoi(argv[++i]);
        } else if (strncmp(argv[i], "--index=", 8) == 0) {
            index = atoi(argv[i] + 8);
        } else if (strcmp(argv[i], "--no-sync-governor") == 0) {
            sync_governor_flag = false;
        } else if (strcmp(argv[i], "-q") == 0 ||
                   strcmp(argv[i], "--quiet") == 0) {
            quiet = true;
        } else if (strcmp(argv[i], "-h") == 0 ||
                   strcmp(argv[i], "--help") == 0) {
            tune_usage();
            return 0;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "cmp-tune: unknown option: %s\n", argv[i]);
            tune_usage();
            return 2;
        } else if (command == NULL) {
            command = argv[i];
        } else if (profile_name == NULL) {
            profile_name = argv[i];
        }
    }
    if (command == NULL) {
        tune_usage();
        return 2;
    }

    load_config();
    if (strcmp(command, "list") == 0) {
        cmd_list();
        return 0;
    }

    if (!nvml_load(&nvml)) {
        return 1;
    }
    if (!nvml_ok(&nvml, "nvmlInit", nvml.init())) {
        nvml_unload(&nvml, false);
        return 1;
    }
    nvml_started = true;
    count = scan_targets(&nvml, index, quiet && strcmp(command, "status") != 0,
                         targets, 64);

    if (strcmp(command, "status") == 0) {
        cmd_status(&nvml, targets, count);
        rc = 0;
    } else if (strcmp(command, "show") == 0) {
        cmd_show(&nvml, targets, count,
                 profile_name != NULL ? profile_name : "stock");
        rc = 0;
    } else if (strcmp(command, "apply") == 0) {
        if (profile_name == NULL) {
            die("apply needs a profile name");
        }
        cmd_apply(&nvml, targets, count, profile_name, sync_governor_flag);
        rc = 0;
    } else if (strcmp(command, "reset") == 0) {
        cmd_reset(&nvml, targets, count, sync_governor_flag);
        rc = 0;
    } else if (strcmp(command, "core-offset") == 0) {
        char *end = NULL;
        if (profile_name == NULL) {
            die("core-offset needs a value in MHz");
        }
        offset_value = (int)strtol(profile_name, &end, 10);
        if (end == profile_name || *end != '\0') {
            die("core-offset: not a whole number: %s", profile_name);
        }
        cmd_core_offset(&nvml, targets, count, offset_value, quiet);
        rc = 0;
    } else {
        fprintf(stderr, "cmp-tune: unknown command: %s\n", command);
        tune_usage();
        rc = 2;
    }
    if (nvml_started) {
        nvml_unload(&nvml, true);
    }
    return rc;
}
