// Standalone owned-GPU arithmetic control. Only own buffers and offline-compiled
// test metallibs enter Metal; no game, renderer state or guest memory is read.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static const uint32_t values[]={0xff800000,0xc0000000,0x80000000,0,0x3e800000,0x3f800000,0x40000000,0x7f800000,0x7fc12345,0xffc54321};
static const char *names[]={"min","max","saturate","isnan","isinf","isfinite","guarded_min","nan_replacement"};
static int nan_bits(uint32_t bits){return (bits&0x7fffffff)>0x7f800000;}
static uint32_t ordinal(uint32_t bits){return bits&0x80000000?~bits:bits^0x80000000;}
// Independent integer-domain IEEE binary32 reference. Numeric zero ordering is
// -0 < +0, as in NVIDIA's min/max instruction contract. NaN payload is unspecified.
static uint32_t minimum(uint32_t a,uint32_t b,int maximum){
    if(nan_bits(a))return b;if(nan_bits(b))return a;
    return maximum?(ordinal(a)>ordinal(b)?a:b):(ordinal(a)<ordinal(b)?a:b);
}
static uint32_t expected(unsigned op,uint32_t a,uint32_t b){
    switch(op){
        case 0:case 6:return minimum(a,b,0);
        case 1:return minimum(a,b,1);
        case 2:return minimum(minimum(a,0,1),0x3f800000,0);
        case 3:return nan_bits(a);
        case 4:return (a&0x7fffffff)==0x7f800000;
        case 5:return (a&0x7f800000)!=0x7f800000;
        default:return nan_bits(a)?0x3f000000:a;
    }
}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=4){fprintf(stderr,"usage: t_metal_math_mode mode own.metallib own_kernel\n");return 2;}
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device){fprintf(stderr,"No Metal device\n");return 2;}
    NSError *error=nil;NSURL *url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
    id<MTLLibrary> library=[device newLibraryWithURL:url error:&error];
    if(!library){fprintf(stderr,"own library failed: %s\n",error.localizedDescription.UTF8String);return 2;}
    id<MTLFunction> function=[library newFunctionWithName:[NSString stringWithUTF8String:argv[3]]];
    id<MTLComputePipelineState> pipeline=function?[device newComputePipelineStateWithFunction:function error:&error]:nil;
    if(!pipeline){fprintf(stderr,"own pipeline failed: %s\n",error.localizedDescription.UTF8String);return 2;}
    enum {N=sizeof values/sizeof *values,PAIRS=N*N,OUTPUT=PAIRS*8};uint32_t pairs[PAIRS*2];
    for(unsigned a=0;a<N;a++)for(unsigned b=0;b<N;b++){unsigned i=a*N+b;pairs[i*2]=values[a];pairs[i*2+1]=values[b];}
    id<MTLBuffer> input=[device newBufferWithBytes:pairs length:sizeof pairs options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[device newBufferWithLength:OUTPUT*4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue=[device newCommandQueue];if(!input||!output||!queue)return 2;
    memset(output.contents,0xcd,OUTPUT*4);id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];[encoder setComputePipelineState:pipeline];
    [encoder setBuffer:input offset:0 atIndex:0];[encoder setBuffer:output offset:0 atIndex:1];
    [encoder dispatchThreadgroups:MTLSizeMake(PAIRS,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[encoder endEncoding];
    [command commit];[command waitUntilCompleted];
    if(command.status!=MTLCommandBufferStatusCompleted||command.error){fprintf(stderr,"own GPU command failed\n");return 2;}
    uint32_t *actual=output.contents;unsigned failures[8]={0},total=0,zero_sign=0,finite_checks=0,finite_numeric_failures=0;NSMutableArray *examples=[NSMutableArray new];
    for(unsigned i=0;i<PAIRS;i++)for(unsigned op=0;op<8;op++){
        uint32_t a=pairs[i*2];
        if(!strcmp(argv[3],"math_derived"))a=nan_bits(a)||(a&0x7fffffff)==0||(a&0x7fffffff)==0x7f800000?0x7fc00000:0x3f800000;
        uint32_t want=expected(op,a,pairs[i*2+1]),got=actual[i*8+op];
        int finite=(pairs[i*2]&0x7fffffff)<0x7f800000&&(pairs[i*2+1]&0x7fffffff)<0x7f800000&&
            (strcmp(argv[3],"math_derived")||(pairs[i*2]&0x7fffffff));
        if(finite)finite_checks++;
        if(got!=want&&!(op!=3&&op!=4&&op!=5&&nan_bits(want)&&nan_bits(got))){
            failures[op]++;total++;if(!((got|want)&0x7fffffff))zero_sign++;
            if(finite&&((got|want)&0x7fffffff))finite_numeric_failures++;
            if(examples.count<12)[examples addObject:@{@"operation":[NSString stringWithUTF8String:names[op]],@"a":[NSString stringWithFormat:@"%08x",pairs[i*2]],@"b":[NSString stringWithFormat:@"%08x",pairs[i*2+1]],@"got":[NSString stringWithFormat:@"%08x",got],@"expected":[NSString stringWithFormat:@"%08x",want]}];
        }
    }
    NSMutableDictionary *byOp=[NSMutableDictionary new];for(unsigned op=0;op<8;op++)byOp[[NSString stringWithUTF8String:names[op]]]=@(failures[op]);
    NSDictionary *result=@{@"mode":[NSString stringWithUTF8String:argv[1]],@"kernel":[NSString stringWithUTF8String:argv[3]],@"device":device.name,@"checks":@(OUTPUT),@"failures":@(total),@"zero_sign_failures":@(zero_sign),@"finite_nondegenerate_checks":@(finite_checks),@"finite_numeric_failures":@(finite_numeric_failures),@"failures_by_operation":byOp,@"examples":examples};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
    return total?1:0;
}}
