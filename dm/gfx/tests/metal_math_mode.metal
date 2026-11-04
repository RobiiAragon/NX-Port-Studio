// Original runtime-input controls. The packaging test applies dmsh_build.precise
// to this source before compiling it with each real CLI flag selection.
#include <metal_stdlib>
using namespace metal;
static inline void write_math(float a,float b,device uint *output,uint i) {
    output[i*8+0]=as_type<uint>(fast::min(a,b));
    output[i*8+1]=as_type<uint>(fast::max(a,b));
    output[i*8+2]=as_type<uint>(fast::clamp(a,0.0f,1.0f));
    output[i*8+3]=uint(isnan(a));
    output[i*8+4]=uint(isinf(a));
    output[i*8+5]=uint(isfinite(a));
    output[i*8+6]=as_type<uint>(isnan(a)?b:(isnan(b)?a:fast::min(a,b)));
    output[i*8+7]=as_type<uint>(isnan(a)?0.5f:a);
}
kernel void math_control(device const uint2 *input [[buffer(0)]],device uint *output [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    write_math(as_type<float>(input[i].x),as_type<float>(input[i].y),output,i);
}
kernel void math_float(constant float2 *input [[buffer(0)]],device uint *output [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    write_math(input[i].x,input[i].y,output,i);
}
kernel void math_derived(device const uint2 *input [[buffer(0)]],device uint *output [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    float a=as_type<float>(input[i].x);
    write_math(a/a,as_type<float>(input[i].y),output,i);
}
