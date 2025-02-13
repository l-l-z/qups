#if (__CUDA_ARCH__ >= 530)
#define __CUDA_NO_HALF2_OPERATORS__ // block half2 vector math operators
#include <cuda_fp16.h> // define half/half2 types, without half2 operators
#endif

// real/complex conjugation
inline __host__ __device__ float conj(const float a) {
    return a; 
}
inline __host__ __device__ double conj(const double a) {
    return a;
}
#if (__CUDA_ARCH__ >= 530)
inline __host__ __device__ half conj(const half a) {
    return a;
}
#endif

inline __host__ __device__ float2 conj(const float2 a) {
    return make_float2(a.x, -a.y); 
}
inline __host__ __device__ double2 conj(const double2 a) {
    return make_double2(a.x, -a.y); 
}
#if (__CUDA_ARCH__ >= 530)
inline __host__ __device__ half2 conj(const half2 a) {
    return make_half2(a.x, -a.y); 
}
#endif


// complex multiplication
inline __host__ __device__ float2 operator*(const float2 a, const float2 b) {
    return make_float2(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x);
}
inline __host__ __device__ double2 operator*(const double2 a, const double2 b) {
    return make_double2(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x);
}
#if (__CUDA_ARCH__ >= 530)
inline __host__ __device__ half2 operator*(const half2 a, const half2 b) {
    return make_half2(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x);
}
#endif

inline __host__ __device__ float2 operator*(const float2 a, const float b){
    return make_float2(b*a.x, b*a.y);
}
inline __host__ __device__ double2 operator*(const double2 a, const double b){
    return make_double2(b*a.x, b*a.y);
}
#if (__CUDA_ARCH__ >= 530)
inline __host__ __device__ half2 operator*(const half2 a, const half b){
    return make_half2(b*a.x, b*a.y);
}
#endif

// real/complex addition/assignment
inline __host__ __device__ void operator+=(float2 &a, const float2 b){
    a.x += b.x;
    a.y += b.y;
}
inline __host__ __device__ void operator+=(double2 &a, const double2 b){
    a.x += b.x;
    a.y += b.y;
}
#if (__CUDA_ARCH__ >= 530)
inline __host__ __device__ void operator+=(half2 &a, const half2 b){
    a.x += b.x;
    a.y += b.y;
}
#endif


/*
* Compute the cross correlation of two sets of data. The data will be
* correlated in the first dimension. M >= N must be satisfied.
*
* Inputs:
*  x:         first signal  (M x S)
*  y:         second signal (N x S)
*
* Outputs:
*  z:         resulting cross correlation
*
*
*/
# ifndef M
__constant__ size_t M; 
# endif
# ifndef N
__constant__ size_t N;
# endif
# ifndef L
__constant__ size_t L; // total number of lags
# endif
# ifndef L0
__constant__ int L0; // starting lag
# endif

// xcorr template
template <typename T>
inline __device__ void conv_temp(const T* x, const T* y, T* z, T za){
    /*    xcorr_temp(const T* x, const T* y, T* z, T za)
     x, y: input array pointer(s)
     za: 0 value for the data type
     z:    output array pointer
     cross correlation 
    */

    // get lag and stride indices
    const int    l = threadIdx.x + blockDim.x*blockIdx.x; // lag index 
    const size_t s = threadIdx.y + blockDim.y*blockIdx.y; // slice
    
    // if valid lag indices, multiply and accumulate in-place
    if(l < L)
        # pragma unroll
        for(int i = 0, j = L0 - l; i < M || j < N; ++i, ++j)
            if(0 <= i && i < M && 0 <= j && j < N) // signal in bounds
                za += x[i+s*M] * conj(y[j+s*N]); // accum the cross product

    // output result:
    if(l < L)
        z[l+s*L] = za;
}

// xcorr kernels
__global__ void convf(const float* x, const float* y, float* z){
    conv_temp<float>(x, y, z, 0.0f);
}

__global__ void conv(const double* x, const double* y, double* z){
    conv_temp<double>(x, y, z, 0.0);
}
#if (__CUDA_ARCH__ >= 530)
__global__ void convh(const ushort* x, const ushort* y, ushort* z){
    conv_temp<half>((half*)x, (half*)y, (half*)z, 0.0f);
}
#endif
__global__ void convcf(const float2* x, const float2* y, float2* z){
    conv_temp<float2>(x, y, z, make_float2(0.0f,0.0f));
}

__global__ void convc(const double2* x, const double2* y, double2* z){
    conv_temp<double2>(x, y, z, make_double2(0.0,0.0));
}
#if (__CUDA_ARCH__ >= 530)
__global__ void convch(const ushort2* x, const ushort2* y, ushort2* z){
    conv_temp<half2>((half2*)x, (half2*)y, (half2*)z, make_half2(0.0f, 0.0f));
}
#endif


