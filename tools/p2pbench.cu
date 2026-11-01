// p2pbench — minimal p2pBandwidthLatencyTest equivalent (ticket 06 ops extra).
// CAN-access matrix + peer cudaMemcpyAsync bandwidth, sized for a live-serving
// box: 128 MiB buffers (llama.cpp holds most VRAM), single warmup + timed pass.
#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
    printf("ERR %s @%d: %s\n", #x, __LINE__, cudaGetErrorString(e)); return 1; } } while (0)

int main() {
    const size_t bytes = 128ull << 20;
    int n = 0;
    CK(cudaGetDeviceCount(&n));
    printf("devices=%d buffer=128MiB\n", n);

    void* buf[16];
    for (int i = 0; i < n; i++) {
        CK(cudaSetDevice(i));
        cudaError_t e = cudaMalloc(&buf[i], bytes);
        if (e != cudaSuccess) { printf("dev %d alloc failed: %s\n", i, cudaGetErrorString(e)); return 1; }
        CK(cudaMemset(buf[i], i, bytes));
    }

    printf("can_access_peer:\n");
    for (int i = 0; i < n; i++) {
        printf("  %d:", i);
        for (int j = 0; j < n; j++) {
            int c = 0;
            CK(cudaDeviceCanAccessPeer(&c, i, j));
            printf(" %s", (i == j) ? "X" : (c ? "OK" : "NO"));
        }
        printf("\n");
    }

    printf("peer_copy GB/s (timed, %zu MiB):\n", bytes >> 20);
    for (int i = 0; i < n; i++) {
        CK(cudaSetDevice(i));
        for (int j = 0; j < n; j++) {
            if (i == j) continue;
            cudaError_t e = cudaDeviceEnablePeerAccess(j, 0);
            if (e != cudaSuccess && e != cudaErrorPeerAccessAlreadyEnabled) {
                printf("  %d->%d enable-fail (%s)\n", i, j, cudaGetErrorString(e));
                continue;
            }
            cudaEvent_t a, b;
            CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
            CK(cudaMemcpyAsync(buf[j], buf[i], bytes, cudaMemcpyDeviceToDevice, 0));
            CK(cudaEventRecord(a));
            for (int r = 0; r < 5; r++)
                CK(cudaMemcpyAsync(buf[j], buf[i], bytes, cudaMemcpyDeviceToDevice, 0));
            CK(cudaEventRecord(b));
            CK(cudaEventSynchronize(b));
            float ms = 0;
            CK(cudaEventElapsedTime(&ms, a, b));
            printf("  %d->%d %.2f\n", i, j, (5.0 * bytes) / (ms / 1e3) / 1e9);
            CK(cudaEventDestroy(a)); CK(cudaEventDestroy(b));
        }
    }
    printf("P2PBENCH_DONE\n");
    return 0;
}
