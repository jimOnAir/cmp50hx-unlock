/* fma_bench — FP32 FMA throughput probe for CMP 50HX lock detection.
 * The CMP clamp hits FP32-FMA and DP4A only (README A/B: 0.427 vs 13.5 TFLOP/s),
 * so a pure compute-bound FMA chain is the cleanest discriminator.
 * Build: gcc -O2 fma_bench.c -lOpenCL -o fma_bench   Run: ./fma_bench */
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *SRC =
"__kernel void chain(__global float *out, const int iters){\n"
"  int i = get_global_id(0);\n"
"  float a=1.0000001f+i, b=0.9999999f+i, c=1.0f, d=1.0000002f;\n"
"  float e=a*0.5f, f=b*0.5f, g=c*0.5f, h=d*0.5f;\n"
"  for(int n=0;n<iters;n++){\n"
"    a=fma(a,c,0.5f); b=fma(b,d,0.25f); c=fma(c,e,0.125f); d=fma(d,f,0.0625f);\n"
"    e=fma(e,g,0.5f); f=fma(f,h,0.25f); g=fma(g,a,0.125f); h=fma(h,b,0.0625f);\n"
"  }\n"
"  if(a+b+c+d+e+f+g+h==12345.678f) out[i]=a;\n"
"}\n";

#define ITEMS 303104u   /* 148 SM * 2048 */
#define ITERS 100000

int main(int argc, char **argv) {
    cl_platform_id pl[8]; cl_uint npl = 0; int cnt = 0;
    clGetPlatformIDs(8, pl, &npl);
    cl_device_id dev = NULL; int want = argc>1?atoi(argv[1]):0;
    for (cl_uint p = 0; p < npl && !dev; p++) {
        cl_device_id ds[4]; cl_uint nd = 0;
        if (clGetDeviceIDs(pl[p], CL_DEVICE_TYPE_GPU, 4, ds, &nd) != CL_SUCCESS) continue;
        for (cl_uint i = 0; i < nd; i++) {
            char name[128] = {0};
            clGetDeviceInfo(ds[i], CL_DEVICE_NAME, 127, name, NULL);
            printf("device: %s\n", name);
            if (strstr(name, "NVIDIA") && cnt++ == want) { dev = ds[i]; break; }
        }
    }
    if (!dev) { printf("no GPU\n"); return 1; }

    cl_int err;
    cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
    cl_command_queue q = clCreateCommandQueueWithProperties(ctx, dev,
        (cl_queue_properties[]){CL_QUEUE_PROPERTIES, CL_QUEUE_PROFILING_ENABLE, 0}, &err);
    cl_program prg = clCreateProgramWithSource(ctx, 1, &SRC, NULL, &err);
    if ((err = clBuildProgram(prg, 1, &dev, "-cl-fast-relaxed-math", NULL, NULL))) {
        size_t l; char log[4096];
        clGetProgramBuildInfo(prg, dev, CL_PROGRAM_BUILD_LOG, sizeof log, log, &l);
        printf("build: %d\n%s\n", err, log); return 1;
    }
    cl_kernel k = clCreateKernel(prg, "chain", &err);
    cl_mem out = clCreateBuffer(ctx, CL_MEM_READ_WRITE, ITEMS * 4, NULL, &err);
    int iters = ITERS;
    clSetKernelArg(k, 0, sizeof out, &out);
    clSetKernelArg(k, 1, sizeof iters, &iters);

    double flops = (double)ITEMS * ITERS * 8.0 * 2.0; /* 8 FMA * 2 flop */
    for (int run = 0; run < 3; run++) {
        cl_event ev;
        err = clEnqueueNDRangeKernel(q, k, 1, NULL, &(size_t){ITEMS}, &(size_t){256}, 0, NULL, &ev);
        clWaitForEvents(1, &ev);
        cl_ulong t0, t1;
        clGetEventInfo(ev, CL_EVENT_COMMAND_EXECUTION_STATUS, sizeof err, &err, NULL);
        clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_QUEUED, sizeof t0, &t0, NULL);
        clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_END, sizeof t1, &t1, NULL);
        double s = (t1 - t0) / 1e9;
        printf("run %d: %.3f s -> %.2f TFLOP/s FP32\n", run, s, flops / s / 1e12);
        clReleaseEvent(ev);
    }
    return 0;
}
