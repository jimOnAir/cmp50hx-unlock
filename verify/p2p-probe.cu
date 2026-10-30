#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do { cudaError_t e = (x); if (e != cudaSuccess) printf("  err %s @ %d: %s\n", #x, __LINE__, cudaGetErrorString(e)); } while (0)

int main() {
    int n = 0;
    CK(cudaGetDeviceCount(&n));
    printf("devices: %d\n", n);
    for (int a = 0; a < n; a++)
        for (int b = 0; b < n; b++)
            if (a != b) {
                int c = 0;
                CK(cudaDeviceCanAccessPeer(&c, a, b));
                printf("canAccessPeer %d->%d: %s\n", a, b, c ? "YES" : "no");
            }
    if (n < 2) { printf("need 2 GPUs\n"); return 1; }

    const size_t sz = 64ull << 20;
    void *da = nullptr, *db = nullptr;
    CK(cudaSetDevice(0));
    CK(cudaMalloc(&da, sz));
    CK(cudaDeviceEnablePeerAccess(1, 0));
    CK(cudaSetDevice(1));
    CK(cudaMalloc(&db, sz));
    CK(cudaDeviceEnablePeerAccess(0, 0));
    CK(cudaMemset(da, 1, sz));
    CK(cudaMemset(db, 2, sz));

    cudaEvent_t e0, e1;
    cudaEventCreate(&e0);
    cudaEventCreate(&e1);
    for (int dir = 0; dir < 2; dir++) {
        if (dir == 0) {
            CK(cudaSetDevice(0));
            cudaEventRecord(e0);
            CK(cudaMemcpyPeerAsync(db, 1, da, 0, sz));
            cudaEventRecord(e1);
        } else {
            CK(cudaSetDevice(1));
            cudaEventRecord(e0);
            CK(cudaMemcpyPeerAsync(da, 0, db, 1, sz));
            cudaEventRecord(e1);
        }
        cudaEventSynchronize(e1);
        float ms = 0;
        cudaEventElapsedTime(&ms, e0, e1);
        printf("peer copy %s: %.2f GB/s (%.1f ms)\n", dir ? "1->0" : "0->1", sz / 1e9 / (ms / 1e3), ms);
    }

    CK(cudaSetDevice(0));
    cudaEventRecord(e0);
    for (int i = 0; i < 1000; i++) CK(cudaMemcpyPeerAsync(db, 1, da, 0, 4096));
    cudaEventRecord(e1);
    cudaEventSynchronize(e1);
    float ms = 0;
    cudaEventElapsedTime(&ms, e0, e1);
    printf("peer 4KB pipelined: %.2f us/transfer\n", ms * 1000.0 / 1000.0);
    return 0;
}
