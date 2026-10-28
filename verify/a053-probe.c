#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdint.h>

typedef uint32_t NvHandle, NvU32;
typedef int32_t  NvV32;
typedef uint64_t NvP64;

#define NV_ESC_RM_CONTROL 0x2AU
#define NV_ESC_RM_ALLOC   0x2BU
#define NV_IOCTL_MAGIC    'F'

typedef struct {
    NvHandle hRoot, hParent, hNew;
    NvV32    hClass;
    NvP64    pParms;
    NvP64    pRights;
    NvU32    paramsSize;
    NvU32    flags;
    NvV32    status;
} NVOS64;

typedef struct {
    NvHandle hClient, hObject;
    NvV32    cmd;
    NvU32    flags;
    NvP64    params;
    NvU32    paramsSize;
    NvV32    status;
} NVOS54;

typedef struct {
    NvU32 deviceId;
    NvHandle hClientShare, hTargetClient, hTargetDevice;
    NvV32 flags;
    uint64_t vaSpaceSize, vaStartInternal, vaLimitInternal;
    NvV32 vaMode;
} N0080P;
typedef struct { NvU32 subDeviceId; } N2080P;

#define NV01_ROOT          0x0000U
#define NV01_DEVICE_0      0x0080U
#define NV20_SUBDEVICE_0   0x2080U
#define CMD_A053           0x2080A053U
#define CMD_GET_PSTATE     0x20802068U

static int fd;

static NvHandle mk(NvHandle client, NvHandle parent, NvU32 cls, void *ap, NvU32 asz, const char *what)
{
    NVOS64 a;
    memset(&a, 0, sizeof a);
    a.hRoot = client; a.hParent = parent; a.hNew = 0;
    a.hClass = cls; a.pParms = (NvP64)(uintptr_t)ap; a.paramsSize = asz;
    a.pRights = 0;
    if (ioctl(fd, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_ALLOC, NVOS64), &a) < 0) {
        perror("ioctl-alloc"); exit(2);
    }
    if (a.status) { fprintf(stderr, "%s alloc status 0x%x\n", what, a.status); exit(3); }
    return a.hNew;
}

static NvV32 ctrl(NvHandle h, NvU32 cmd, void *p, NvU32 sz)
{
    NVOS54 c;
    memset(&c, 0, sizeof c);
    c.hClient = h; c.hObject = h; c.cmd = cmd;
    c.params = (NvP64)(uintptr_t)p; c.paramsSize = sz;
    if (ioctl(fd, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL, NVOS54), &c) < 0) {
        perror("ioctl-ctrl"); exit(2);
    }
    return c.status;
}

int main(int argc, char **argv)
{
    int gpu = 0;
    NvU32 cmd = CMD_A053;
    NvU32 p0 = 0, p1 = 0, psz = 8;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-i") && i + 1 < argc) gpu = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-c") && i + 1 < argc) cmd = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "-p") && i + 1 < argc) p1 = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) psz = strtoul(argv[++i], 0, 0);
    }
    fd = open("/dev/nvidiactl", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    char p[64];
    snprintf(p, sizeof p, "/dev/nvidia%d", gpu);
    int gfd = open(p, O_RDWR);
    if (gfd < 0) fprintf(stderr, "warn: %s not open\n", p);
    NvHandle cl = mk(0, 0, NV01_ROOT, NULL, 0, "client");
    N0080P dp;
    memset(&dp, 0, sizeof dp);
    dp.deviceId = (NvU32)gpu;
    NvHandle dv = mk(cl, cl, NV01_DEVICE_0, &dp, sizeof dp, "device");
    N2080P sp = { .subDeviceId = 0 };
    NvHandle sd = mk(cl, dv, NV20_SUBDEVICE_0, &sp, sizeof sp, "subdevice");

    NvU32 pst = 0xFF;
    (void)ctrl(sd, CMD_GET_PSTATE, &pst, sizeof pst);
    fprintf(stderr, "GET_CURRENT_PSTATE -> 0x%x\n", pst);

    NvU32 par[2] = { p0, p1 };
    fprintf(stderr, "gpu %d cmd 0x%x params {%u,%u} size %u\n", gpu, cmd, par[0], par[1], psz);
    NVOS54 c;
    memset(&c, 0, sizeof c);
    c.hClient = cl; c.hObject = sd; c.cmd = cmd;
    c.params = (NvP64)(uintptr_t)par; c.paramsSize = psz;
    if (ioctl(fd, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL, NVOS54), &c) < 0) { perror("ctrl"); return 2; }
    printf("STATUS 0x%x (%s)\n", c.status,
           c.status == 0 ? "NV_OK" :
           c.status == 0x56 ? "NV_ERR_NOT_SUPPORTED" :
           c.status == 0x1F ? "NV_ERR_INVALID_ARGUMENT" :
           c.status == 0x29 ? "NV_ERR_INVALID_SIZE" :
           c.status == 0x57 ? "NV_ERR_OBJECT_NOT_FOUND" : "other");
    pst = 0xFF;
    (void)ctrl(sd, CMD_GET_PSTATE, &pst, sizeof pst);
    fprintf(stderr, "after: GET_CURRENT_PSTATE -> 0x%x\n", pst);
    return 0;
}
