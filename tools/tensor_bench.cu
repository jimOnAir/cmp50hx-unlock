// SPDX-License-Identifier: GPL-2.0-only
// tensor_bench — tensor-core MMA throughput probe for the CMP 50HX lock profile
// (gtuu-mining ticket 01: is the FP16→FP32 accumulate path, FMLA32, clamped
// locked like FFMA/DP4A? A/B baseline: efi-unlock/runs/20260910-ab-stock-vs-efi.md
// finding #3; run doc: efi-unlock/runs/2026-11-12-tensor-ab.md).
//
// Method ported (NOT code) from GPU-Tensor-Unlock-Universal @ 1d6a508
// (GPL-2.0, tensor_benchmark.py, evaluated read-only in the source sweep):
//   1. runtime-randomized input fragments — a host seed per run hashed per
//      thread feeds every A/B fragment, so nothing is compile-time constant.
//      This is the fix for the naive-mmapeak trap: all-zero fragments fold to
//      trivial products and silently overcount throughput.
//   2. finite non-zero IEEE-754 accumulator verification after EVERY measured
//      run (raw accumulator bits + iteration signature written back by block 0);
//      a folded/collapsed result is a FAILURE with a loud line and non-zero
//      exit, never a printed number.
//   3. per-kernel warmup + timed-run loop, median/best summary.
//
// sm_75 shape constraint (verified against ptxas, CUDA 13.4): the Ampere
// m16n8k16 (f16) / m16n8k32 (s8) shapes are rejected on sm_75 ("requires
// .target sm_80 or higher"). The fleet is TU102/sm_75, so the f16 MMAs use
// m16n8k8 and the s8 IMMA uses m8n8k16 — the shapes the reference itself
// selects for is_turing_sm. BF16/TF32/FP8 are sm_80+ silicon: not implemented.
//
// Build gate (exact fleet-target command; zero warnings expected):
//   nvcc -O3 -std=c++17 -arch=sm_75 -Xcompiler -Wall -o tensor_bench tools/tensor_bench.cu
// Run (plain host run; CUDA_VISIBLE_DEVICES=<idx> pins the guinea-pig card):
//   ./tensor_bench [--iters N] [--runs N] [--device N] [--allow-non-tu102] [--help]
// Output idiom (greppable like fma_bench / autotune perf lines):
//   run N: <sec> s -> <X> TF/s <KERNELNAME>
//
// Only cudart is linked. The optional cuDeviceGetUuid/cuDeviceGetPCIBusId
// stamping resolves those two QUERY entry points through dlopen("libcuda.so.1")
// at runtime (the CUDA 13.x runtime API no longer exposes a device-UUID call)
// with a /proc/driver/nvidia fallback — no JIT, no module loading: every
// kernel here is pre-compiled into the binary (sm_75 cubin + compute_75 PTX).

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <dlfcn.h>
#include <cuda_runtime.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
    fprintf(stderr, "ERR %s @%d: %s\n", #x, __LINE__, cudaGetErrorString(e_)); return 1; } } while (0)

#define KERNELS_PER_BLOCK 256          /* 8 warps */
#define BLOCKS_PER_SM     8
#define UNROLL_MMA        4            /* mma instrs per accumulator chain per loop iteration */
#define CHAINS            2            /* independent accumulator chains (ILP) */
#define ITER_SIGNATURE_MAGIC 0x67B05A5Au
#define OUT_WORDS         64           /* [0..31]=accumulator bits + iters, [32..47]=loop signature */

// ---------------------------------------------------------------------------
// fragment randomization (anti-constant-folding). Values are kept small and
// positive so the full-sweep accumulators stay in IEEE-754 range:
//   f16 fragments in [2^-5, 2^-4) -> per-mma growth ~8*2^-10, well inside
//   the fp16 accumulator max (65504) for the whole measured loop;
//   s8 bytes in [1, 8] -> per-mma growth <= 16*64, no int32 overflow.
// ---------------------------------------------------------------------------
__device__ __forceinline__ unsigned mix32(unsigned x) {
    x ^= x >> 16; x *= 0x7FEB352Du;
    x ^= x >> 15; x *= 0x846CA68Bu;
    x ^= x >> 16;
    return x;
}
__device__ __forceinline__ unsigned frag_f16(unsigned r) {   // two fp16 halves, exponent 2^-5
    return (0x2800u | (r & 0x3FFu)) | ((0x2800u | ((r >> 10) & 0x3FFu)) << 16);
}
__device__ __forceinline__ unsigned frag_s8(unsigned r) {    // four s8 bytes, each 1..8
    return (1u + (r & 7u)) | ((1u + ((r >> 3) & 7u)) << 8) |
           ((1u + ((r >> 6) & 7u)) << 16) | ((1u + ((r >> 9) & 7u)) << 24);
}
__device__ __forceinline__ unsigned init_f16(unsigned r) {   // fp16 accumulator seed in [1, 2)
    return (0x3C00u | (r & 0x3FFu)) | ((0x3C00u | ((r >> 10) & 0x3FFu)) << 16);
}

// every thread mixes the run seed with its grid position; the seed is a kernel
// argument (host rand per launch) so no fragment is a compile-time constant
__device__ __forceinline__ unsigned thread_seed(unsigned seed) {
    return mix32(seed ^ (blockIdx.x * 0x9E3779B9u) ^ (threadIdx.x * 0x85EBCA6Bu));
}

__device__ __forceinline__ void stamp(unsigned* out, unsigned acc0, unsigned iters) {
    if (blockIdx.x == 0 && threadIdx.x < 32) {
        out[threadIdx.x] = acc0 + iters;                 // verifier subtracts iters back off
        out[threadIdx.x + 32] = iters ^ ITER_SIGNATURE_MAGIC;  // proves the loop ran full length
    }
}

// ---------------------------------------------------------------------------
// K1: FP16 -> FP16 accumulate, m16n8k8 (FMLA16 baseline)
// ---------------------------------------------------------------------------
__global__ void kern_fmla16(unsigned* out, unsigned seed, unsigned iters) {
    unsigned s = thread_seed(seed);
    unsigned a0 = frag_f16(mix32(s + 1u)), a1 = frag_f16(mix32(s + 2u)), b0 = frag_f16(mix32(s + 3u));
    unsigned h0 = init_f16(mix32(s + 4u)), h1 = init_f16(mix32(s + 5u));
    unsigned h2 = init_f16(mix32(s + 6u)), h3 = init_f16(mix32(s + 7u));
    for (unsigned i = 0; i < iters; i++) {
#pragma unroll
        for (int u = 0; u < UNROLL_MMA; u++) {
            asm volatile("mma.sync.aligned.m16n8k8.row.col.f16.f16.f16.f16 {%0,%1}, {%2,%3}, {%4}, {%0,%1};"
                : "+r"(h0), "+r"(h1) : "r"(a0), "r"(a1), "r"(b0));
            asm volatile("mma.sync.aligned.m16n8k8.row.col.f16.f16.f16.f16 {%0,%1}, {%2,%3}, {%4}, {%0,%1};"
                : "+r"(h2), "+r"(h3) : "r"(a0), "r"(a1), "r"(b0));
        }
    }
    stamp(out, h0, iters);
}

// ---------------------------------------------------------------------------
// K2: FP16 -> FP32 accumulate, m16n8k8 (FMLA32 — the subject of the A/B)
// ---------------------------------------------------------------------------
__global__ void kern_fmla32(unsigned* out, unsigned seed, unsigned iters) {
    unsigned s = thread_seed(seed);
    unsigned a0 = frag_f16(mix32(s + 1u)), a1 = frag_f16(mix32(s + 2u)), b0 = frag_f16(mix32(s + 3u));
    float f0 = 1.0f + (float)(s & 0xFFu) / 256.0f, f1 = 1.5f, f2 = 1.25f, f3 = 1.75f;
    float g0 = 1.0f + (float)(s & 0xF0u) / 4096.0f, g1 = 1.5f, g2 = 1.25f, g3 = 1.75f;
    for (unsigned i = 0; i < iters; i++) {
#pragma unroll
        for (int u = 0; u < UNROLL_MMA; u++) {
            asm volatile("mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32 {%0,%1,%2,%3}, {%4,%5}, {%6}, {%0,%1,%2,%3};"
                : "+f"(f0), "+f"(f1), "+f"(f2), "+f"(f3) : "r"(a0), "r"(a1), "r"(b0));
            asm volatile("mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32 {%0,%1,%2,%3}, {%4,%5}, {%6}, {%0,%1,%2,%3};"
                : "+f"(g0), "+f"(g1), "+f"(g2), "+f"(g3) : "r"(a0), "r"(a1), "r"(b0));
        }
    }
    stamp(out, __float_as_uint(f0), iters);
}

// ---------------------------------------------------------------------------
// K3: INT8 -> INT32 accumulate, m8n8k16 IMMA (IMLA)
// ---------------------------------------------------------------------------
__global__ void kern_imla(unsigned* out, unsigned seed, unsigned iters) {
    unsigned s = thread_seed(seed);
    unsigned a0 = frag_s8(mix32(s + 1u)), b0 = frag_s8(mix32(s + 2u));
    int c0 = 1 + (int)(s % 997u), c1 = 3;
    int d0 = 2 + (int)((s >> 10) % 991u), d1 = 5;
    for (unsigned i = 0; i < iters; i++) {
#pragma unroll
        for (int u = 0; u < UNROLL_MMA; u++) {
            asm volatile("mma.sync.aligned.m8n8k16.row.col.s32.s8.s8.s32 {%0,%1}, {%2}, {%3}, {%0,%1};"
                : "+r"(c0), "+r"(c1) : "r"(a0), "r"(b0));
            asm volatile("mma.sync.aligned.m8n8k16.row.col.s32.s8.s8.s32 {%0,%1}, {%2}, {%3}, {%0,%1};"
                : "+r"(d0), "+r"(d1) : "r"(a0), "r"(b0));
        }
    }
    stamp(out, (unsigned)c0, iters);
}

// ---------------------------------------------------------------------------
// K4: scalar FP32 FFMA control (CUDA cores; known ~1/32 clamped when locked)
// ---------------------------------------------------------------------------
__global__ void kern_ffma(unsigned* out, unsigned seed, unsigned iters) {
    unsigned s = thread_seed(seed);
    float f0 = 1.0f + (float)(s & 0x3Fu) / 1024.0f, f1 = 1.25f, f2 = 1.5f, f3 = 1.75f;
    float fb = __uint_as_float(0x3F800000u - (mix32(s + 8u) & 0x3FFFu)); // in (0.998, 1.0]
    float fc = (float)(mix32(s + 9u) & 0xFFFFu) * 1.2e-7f;               // small, non-zero
    for (unsigned i = 0; i < iters; i++) {
#pragma unroll
        for (int u = 0; u < UNROLL_MMA; u++) {
            asm volatile("fma.rn.f32 %0, %0, %1, %2;" : "+f"(f0) : "f"(fb), "f"(fc));
            asm volatile("fma.rn.f32 %0, %0, %1, %2;" : "+f"(f1) : "f"(fb), "f"(fc));
            asm volatile("fma.rn.f32 %0, %0, %1, %2;" : "+f"(f2) : "f"(fb), "f"(fc));
            asm volatile("fma.rn.f32 %0, %0, %1, %2;" : "+f"(f3) : "f"(fb), "f"(fc));
        }
    }
    stamp(out, __float_as_uint(f0), iters);
}

// ---------------------------------------------------------------------------
// verification — a folded/collapsed accumulator is a FAILURE, not a number
// ---------------------------------------------------------------------------
enum AccKind { ACC_F16X2, ACC_F32, ACC_S32 };

static void die_verify(const char* name, const char* why) {
    fprintf(stderr,
        "VERIFY-FAIL %s: %s\n"
        "VERIFY-FAIL %s: accumulator is folded/collapsed — this run is a FAILURE, not a throughput number\n",
        name, why, name);
    exit(1);
}

static double decode_half(unsigned h) {   // one fp16 half in low 16 bits
    unsigned e = (h >> 10) & 0x1Fu, m = h & 0x3FFu;
    double v;
    if (e == 0x1Fu) return m ? NAN : HUGE_VAL;
    v = (e == 0u) ? (double)m / 1024.0 * 0.0009765625 : ldexp(1.0 + (double)m / 1024.0, (int)e - 15);
    return (h & 0x8000u) ? -v : v;
}

static void verify(const unsigned* h, unsigned iters, AccKind kind, const char* name) {
    for (int i = 32; i < 48; i++) {       // iteration signature (block 0 lanes 0..15 copy)
        if (h[i] != (iters ^ ITER_SIGNATURE_MAGIC))
            die_verify(name, "loop-count signature mismatch (kernel skipped or truncated its loop)");
    }
    unsigned first = h[0];
    bool all_same = true, all_zero = true;
    for (int i = 0; i < 32; i++) {
        unsigned v = h[i] - iters;        // raw accumulator bits (kernel added iters)
        if (v != 0u) all_zero = false;
        if (v != first) all_same = false;
    }
    if (all_zero) die_verify(name, "all-zero accumulators (the mmapeak constant-fragment overcounting trap)");
    if (all_same) die_verify(name, "all-lane-identical accumulators (constant-folded fragments)");
    for (int i = 0; i < 32; i++) {
        unsigned v = h[i] - iters;
        if (kind == ACC_F32) {
            float f; memcpy(&f, &v, 4);
            if (!std::isfinite(f) || f <= 0.0f) die_verify(name, "non-finite or non-positive fp32 accumulator");
        } else if (kind == ACC_F16X2) {
            double lo = decode_half(v & 0xFFFFu), hi = decode_half(v >> 16);
            if (!std::isfinite(lo) || !std::isfinite(hi) || lo <= 0.0 || hi <= 0.0)
                die_verify(name, "non-finite or non-positive fp16 accumulator half");
        } else {  // ACC_S32
            if ((int)v <= 0) die_verify(name, "non-positive s32 accumulator");
        }
    }
}

// ---------------------------------------------------------------------------
// identity stamping: UUID / PCI BDF / driver version / LnkSta
// ---------------------------------------------------------------------------
typedef int (*fn_cuInit)(void);
typedef int (*fn_cuDeviceGet)(int*, int);
typedef int (*fn_cuDeviceGetUuid)(unsigned char*, int);
typedef int (*fn_cuDeviceGetPCIBusId)(char*, int, int);

static bool stamp_uuid_bdf(int dev, char* uuid, size_t usz, char* bdf, size_t bsz) {
    uuid[0] = 0; bdf[0] = 0;
    void* h = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
    if (h) {
        auto pInit = (fn_cuInit)dlsym(h, "cuInit");
        auto pGet = (fn_cuDeviceGet)dlsym(h, "cuDeviceGet");
        auto pUuid = (fn_cuDeviceGetUuid)dlsym(h, "cuDeviceGetUuid_v2");
        if (!pUuid) pUuid = (fn_cuDeviceGetUuid)dlsym(h, "cuDeviceGetUuid");
        auto pBdf = (fn_cuDeviceGetPCIBusId)dlsym(h, "cuDeviceGetPCIBusId");
        int cd = dev;
        if (pInit && pGet && pUuid && pBdf && pInit() == 0 && pGet(&cd, dev) == 0) {
            unsigned char raw[16];
            if (pUuid(raw, cd) == 0)
                snprintf(uuid, usz, "GPU-%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                         raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                         raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]);
            char b[64] = {0};
            if (pBdf(b, (int)sizeof b, cd) == 0 && b[0]) {
                for (char* p = b; *p; p++) if (*p >= 'A' && *p <= 'Z') *p = (char)(*p + 32);
                snprintf(bdf, bsz, "%s", b);   // already domain-normalized "0000:04:00.0"
            }
        }
        dlclose(h);
    }
    return uuid[0] && bdf[0];
}

static bool stamp_uuid_from_procfs(const char* bdf, char* uuid, size_t usz) {
    DIR* d = opendir("/proc/driver/nvidia/gpus");
    if (!d || !bdf || !bdf[0]) { if (d) closedir(d); return false; }
    struct dirent* e;
    bool found = false;
    while ((e = readdir(d)) != nullptr) {
        char path[400];
        snprintf(path, sizeof path, "/proc/driver/nvidia/gpus/%s/information", e->d_name);
        FILE* f = fopen(path, "r");
        if (!f) continue;
        char line[256], cand[80] = {0};
        bool loc = false;
        while (fgets(line, sizeof line, f)) {
            if (strstr(line, "Bus Location") && strstr(line, bdf)) loc = true;
            if (strstr(line, "GPU UUID")) { sscanf(strstr(line, "GPU UUID"), "GPU UUID : %79s", cand); }
        }
        fclose(f);
        if (loc && cand[0]) { snprintf(uuid, usz, "%s", cand); found = true; break; }
    }
    closedir(d);
    return found;
}

static void read_first_line(const char* path, char* buf, size_t bsz) {
    buf[0] = 0;
    FILE* f = fopen(path, "r");
    if (!f) return;
    if (fgets(buf, (int)bsz, f)) { size_t n = strlen(buf); while (n && (buf[n-1] == '\n' || buf[n-1] == '\r')) buf[--n] = 0; }
    fclose(f);
}

static void usage(void) {
    printf(
"tensor_bench — CMP 50HX (TU102/sm_75) tensor-MMA throughput probe (ticket 01)\n"
"Kernels measured (inline-PTX mma.sync.aligned, sm_75 shapes):\n"
"  FMLA16  FP16 -> FP16 accumulate mma m16n8k8   (baseline; expected NOT clamped)\n"
"  FMLA32  FP16 -> FP32 accumulate mma m16n8k8   (the A/B subject)\n"
"  IMLA    INT8 -> INT32 accumulate mma m8n8k16  (IMMA path)\n"
"  FFMA    scalar FP32 fma.rn.f32 CUDA-core control (known ~1/32 clamped locked)\n"
"Options:\n"
"  --device N          CUDA device index (default 0; CUDA_VISIBLE_DEVICES is honored)\n"
"  --iters N           loop iterations per kernel (default 50000)\n"
"  --runs N            timed runs per kernel (default 5)\n"
"  --allow-non-tu102   run on non-sm_75 GPUs for correctness self-check only\n"
"  --help              this text\n"
"Output: 'run N: <sec> s -> <X> TF/s <KERNELNAME>' per timed run + per-kernel\n"
"median/best, then the FMLA16/FMLA32 ratio. Verification failure exits non-zero.\n");
}

int main(int argc, char** argv) {
    int dev = 0;
    unsigned iters = 50000, runs = 5;
    bool allow_non_tu102 = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) { usage(); return 0; }
        else if (!strcmp(argv[i], "--device") && i + 1 < argc) dev = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--iters") && i + 1 < argc) iters = (unsigned)atol(argv[++i]);
        else if (!strcmp(argv[i], "--runs") && i + 1 < argc) runs = (unsigned)atol(argv[++i]);
        else if (!strcmp(argv[i], "--allow-non-tu102")) allow_non_tu102 = true;
        else { fprintf(stderr, "unknown arg: %s (--help)\n", argv[i]); return 2; }
    }
    if (iters == 0u || runs == 0u) { fprintf(stderr, "--iters/--runs must be > 0\n"); return 2; }

    int ndev = 0;
    CK(cudaGetDeviceCount(&ndev));
    if (dev < 0 || dev >= ndev) { fprintf(stderr, "no such device index %d (of %d)\n", dev, ndev); return 2; }
    CK(cudaSetDevice(dev));
    cudaDeviceProp prop{};
    CK(cudaGetDeviceProperties(&prop, dev));

    char uuid[80] = {0}, bdf[64] = {0};
    if (!stamp_uuid_bdf(dev, uuid, sizeof uuid, bdf, sizeof bdf)) {
        // fallback: build the BDF from runtime attributes, UUID from the driver procfs
        int dom = 0, bus = 0, pdi = 0;
        cudaDeviceGetAttribute(&dom, cudaDevAttrPciDomainId, dev);
        cudaDeviceGetAttribute(&bus, cudaDevAttrPciBusId, dev);
        cudaDeviceGetAttribute(&pdi, cudaDevAttrPciDeviceId, dev);
        snprintf(bdf, sizeof bdf, "%04x:%02x:%02x.0", dom & 0xFFFF, bus & 0xFF, pdi & 0x1F);
        stamp_uuid_from_procfs(bdf, uuid, sizeof uuid);
    }
    char drv[80] = {0};
    read_first_line("/sys/module/nvidia/version", drv, sizeof drv);
    int drvapi = 0;
    cudaDriverGetVersion(&drvapi);
    char lps[64] = {0}, lpw[64] = {0};
    if (bdf[0]) {
        char p[160];
        snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/current_link_speed", bdf); read_first_line(p, lps, sizeof lps);
        snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/current_link_width", bdf); read_first_line(p, lpw, sizeof lpw);
    }

    printf("tensor_bench: cmp50hx tensor-MMA lock-profile probe\n");
    printf("gpu:    %s (sm_%d%d, %d SMs)\n", prop.name, prop.major, prop.minor, prop.multiProcessorCount);
    printf("uuid:   %s\n", uuid[0] ? uuid : "unavailable");
    printf("bdf:    %s\n", bdf[0] ? bdf : "unavailable");
    if (lps[0] || lpw[0]) printf("LnkSta: %s x%s\n", lps[0] ? lps : "?", lpw[0] ? lpw : "?");
    printf("driver: %s (CUDA driver API %d)\n", drv[0] ? drv : "n/a", drvapi);

    if (prop.major != 7 || prop.minor != 5) {
        if (!allow_non_tu102) {
            fprintf(stderr, "refusing to run: sm_%d%d is not the TU102/sm_75 fleet target"
                            " (use --allow-non-tu102 for a correctness-only self-check)\n",
                    prop.major, prop.minor);
            return 3;
        }
        printf("WARNING: not sm_75 — throughput numbers below are meaningless for the fleet; self-check only\n");
    }

    int blocks = prop.multiProcessorCount * BLOCKS_PER_SM;
    unsigned warps = (unsigned)blocks * (KERNELS_PER_BLOCK / 32);
    unsigned threads = (unsigned)blocks * KERNELS_PER_BLOCK;
    double mma_flops = (double)warps * (double)iters * (UNROLL_MMA * CHAINS) * 2048.0; // 1024 MACs/mma
    double ffma_flops = (double)threads * (double)iters * (UNROLL_MMA * 4) * 2.0;
    printf("config: iters=%u runs=%u grid=%dx%d\n", iters, runs, blocks, KERNELS_PER_BLOCK);

    struct Spec { const char* name; AccKind kind; double flops; };
    const Spec specs[] = {
        { "FMLA16", ACC_F16X2, mma_flops },
        { "FMLA32", ACC_F32,   mma_flops },
        { "IMLA",   ACC_S32,   mma_flops },
        { "FFMA",   ACC_F32,   ffma_flops },
    };
    double med[4] = {0}, best[4] = {0};
    srand((unsigned)time(nullptr) ^ (unsigned)clock());

    unsigned* dout = nullptr;
    CK(cudaMalloc(&dout, OUT_WORDS * sizeof(unsigned)));
    unsigned hout[OUT_WORDS];

    for (int k = 0; k < 4; k++) {
        const Spec& sp = specs[k];
        double tf[64];
        unsigned cap = runs > 63u ? 63u : runs;

        // warmup launch + verification (also catches a kernel that cannot load)
        CK(cudaMemset(dout, 0, OUT_WORDS * sizeof(unsigned)));
        unsigned seed = (unsigned)rand() * 2654435761u + 1u;
        switch (k) {
            case 0: kern_fmla16<<<blocks, KERNELS_PER_BLOCK>>>(dout, seed, iters); break;
            case 1: kern_fmla32<<<blocks, KERNELS_PER_BLOCK>>>(dout, seed, iters); break;
            case 2: kern_imla<<<blocks, KERNELS_PER_BLOCK>>>(dout, seed, iters); break;
            default: kern_ffma<<<blocks, KERNELS_PER_BLOCK>>>(dout, seed, iters); break;
        }
        CK(cudaGetLastError());
        CK(cudaDeviceSynchronize());
        CK(cudaMemcpy(hout, dout, sizeof hout, cudaMemcpyDeviceToHost));
        verify(hout, iters, sp.kind, sp.name);

        for (unsigned r = 0; r < cap; r++) {
            CK(cudaMemset(dout, 0, OUT_WORDS * sizeof(unsigned)));
            seed = (unsigned)rand() * 2654435761u + 1u;
            cudaEvent_t ev0, ev1;
            CK(cudaEventCreate(&ev0)); CK(cudaEventCreate(&ev1));
            CK(cudaEventRecord(ev0));
            switch (k) {
                case 0: kern_fmla16<<<blocks, KERNELS_PER_BLOCK>>>(dout, seed, iters); break;
                case 1: kern_fmla32<<<blocks, KERNELS_PER_BLOCK>>>(dout, seed, iters); break;
                case 2: kern_imla<<<blocks, KERNELS_PER_BLOCK>>>(dout, seed, iters); break;
                default: kern_ffma<<<blocks, KERNELS_PER_BLOCK>>>(dout, seed, iters); break;
            }
            CK(cudaGetLastError());
            CK(cudaEventRecord(ev1));
            CK(cudaEventSynchronize(ev1));
            float ms = 0.0f;
            CK(cudaEventElapsedTime(&ms, ev0, ev1));
            CK(cudaEventDestroy(ev0)); CK(cudaEventDestroy(ev1));
            double s = ms / 1000.0;
            if (s < 1e-9) s = 1e-9;
            // verify AFTER every measured run — a folded result is a FAILURE
            CK(cudaMemcpy(hout, dout, sizeof hout, cudaMemcpyDeviceToHost));
            verify(hout, iters, sp.kind, sp.name);
            tf[r] = sp.flops / s / 1e12;
            printf("run %u: %.3f s -> %.2f TF/s %s\n", r, s, tf[r], sp.name);
        }
        // median by sort of small array
        for (unsigned a = 0; a < cap; a++) for (unsigned b_ = a + 1; b_ < cap; b_++)
            if (tf[b_] < tf[a]) { double t = tf[a]; tf[a] = tf[b_]; tf[b_] = t; }
        med[k] = tf[cap / 2];
        best[k] = tf[cap - 1];
        printf("summary: median %.2f TF/s best %.2f TF/s (%u runs) %s\n", med[k], best[k], cap, sp.name);
    }

    if (med[0] > 0.0 && med[1] > 0.0)
        printf("ratio FMLA16/FMLA32: %.2f (1.00 = full-rate accumulate, ~2.00 = half-rate/clamped branch)\n",
               med[0] / med[1]);
    printf("TENSORBENCH_DONE\n");
    return 0;
}
