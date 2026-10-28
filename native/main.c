/* main.c — cmp50hx: the merged CMP 50HX userland in one binary.
 *
 * Busybox-style multi-call dispatcher. The hardware phases stay separate
 * INVOCATIONS (the pre-driver osunlock requires the driver absent, the
 * governor/tune require it loaded — the kernel module is the phase barrier
 * that no process merge can cross), but they are one build, one installed
 * artifact, one source of truth for the TU102 register map
 * (common/cmp50hx_regs.h).
 *
 * Symlink names keep every pre-merge entrypoint working unchanged:
 *   cmp-tune       -> tune subcommand
 *   cmp-governor   -> governor subcommand
 *   rm-issue-rate  -> verify subcommand
 *   50hx-osunlock  -> osunlock subcommand
 */
#define _GNU_SOURCE

#include <libgen.h>
#include <stdio.h>
#include <string.h>

int governor_main(int argc, char **argv);
int gen2_main(int argc, char **argv);
int osunlock_main(int argc, char **argv);
int tune_main(int argc, char **argv);
int verify_main(int argc, char **argv);
int explain_main(int argc, char **argv);

static void usage(const char *prog) {
    printf("Usage: %s COMMAND [args]\n", prog);
    printf("  governor [--release]   idle P-state daemon (NVML/NVAPI)\n");
    printf("  gen2                   PCIe Gen2 policy + retrain (BAR0)\n");
    printf("  osunlock [--bdf B] ... pre-driver SEC2 booter unlock (bench,\n");
    printf("                         needs blobs in /usr/local/share/50hx/)\n");
    printf("  tune ...               profile tuning (cmp-tune CLI)\n");
    printf("  verify N               RM issue-rate probe (device index N)\n");
    printf("  explain [efi|cards|dmesg]  translate the unlock logs into English\n");
    printf("Invoked via a legacy name (cmp-tune, cmp-governor, rm-issue-rate,\n");
    printf("50hx-osunlock) it runs that subcommand directly.\n");
}

int main(int argc, char **argv) {
    const char *base;
    int i;

    static const struct {
        const char *name;
        int (*fn)(int, char **);
    } legacy[] = {
        {"cmp-tune", tune_main},
        {"cmp-governor", governor_main},
        {"rm-issue-rate", verify_main},
        {"50hx-osunlock", osunlock_main},
        {"cmp50hx-collect", NULL},   /* not a subcommand; shell script */
        {NULL, NULL},
    };
    static const struct {
        const char *name;
        int (*fn)(int, char **);
    } cmds[] = {
        {"governor", governor_main},
        {"gen2", gen2_main},
        {"osunlock", osunlock_main},
        {"tune", tune_main},
        {"verify", verify_main},
        {"explain", explain_main},
        {NULL, NULL},
    };

    if (argc < 1) {
        usage("cmp50hx");
        return 2;
    }
    base = strrchr(argv[0], '/');
    base = base != NULL ? base + 1 : argv[0];
    for (i = 0; legacy[i].name != NULL; ++i) {
        if (legacy[i].fn != NULL && strcmp(base, legacy[i].name) == 0) {
            return legacy[i].fn(argc, argv);
        }
    }
    if (argc >= 2) {
        for (i = 0; cmds[i].name != NULL; ++i) {
            if (strcmp(argv[1], cmds[i].name) == 0) {
                return cmds[i].fn(argc - 1, argv + 1);
            }
        }
        if (strcmp(argv[1], "help") == 0 || strcmp(argv[1], "--help") == 0 ||
            strcmp(argv[1], "-h") == 0) {
            usage(base);
            return 0;
        }
    }
    fprintf(stderr, "cmp50hx: unknown command: %s\n\n",
            argc >= 2 ? argv[1] : "(none)");
    usage(base);
    return 2;
}
