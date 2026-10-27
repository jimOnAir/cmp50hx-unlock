// fp32 FMA throughput probe for CMP card-state comparison.
// Pure compute — should be identical across Gen1/Gen2 link speeds.
#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

__global__ void fma_bench(float *out, int iters)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    float a = 1.0f + i * 1e-7f, b = 1.000001f, c = 0.999999f;
    for (int r = 0; r < iters; r++) {
        a = fmaf(a, b, c);
        b = fmaf(b, c, a);
        c = fmaf(c, a, b);
    }
    if (a + b + c == 12345.678f) out[i] = a;   // keep alive, never true
}

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
    std::printf("CUDA error %s @%d\n", cudaGetErrorString(e_), __LINE__); exit(2);} } while (0)

int main(void)
{
    const int n = 1 << 20;
    const int iters = 20000;
    float *d = nullptr;
    CK(cudaMalloc(&d, n * sizeof(float)));
    CK(cudaMemset(d, 0, n * sizeof(float)));
    cudaEvent_t e0, e1;
    CK(cudaEventCreate(&e0)); CK(cudaEventCreate(&e1));
    char name[128] = {0};
    cudaDeviceProp prop = {};
    CK(cudaGetDeviceProperties(&prop, 0));
    std::snprintf(name, sizeof name, "%s", prop.name);
    std::printf("device  : %s (SMs=%d)\n", name, prop.multiProcessorCount);
    fma_bench<<<n / 256, 256>>>(d, iters);      // warmup
    CK(cudaGetLastError());
    for (int rep = 0; rep < 3; rep++) {
        CK(cudaEventRecord(e0));
        fma_bench<<<n / 256, 256>>>(d, iters);
        CK(cudaGetLastError());
        CK(cudaEventRecord(e1));
        CK(cudaEventSynchronize(e1));
        float ms = 0;
        CK(cudaEventElapsedTime(&ms, e0, e1));
        double tflops = (double)n * iters * 6.0 / (ms / 1000.0) / 1e12;
        std::printf("fma rep%d: %.2f TFLOP/s fp32\n", rep, tflops);
    }
    return 0;
}
