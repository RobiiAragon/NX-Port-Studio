// Canonical API behavior with a synthetic proof and mock transport only.
#import "../nextendo_api_apple.h"
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include "../account_trace.h"
#include "t_trace_capture.h"
static int checks, failures, requests;
static BOOL linked = YES;
static unsigned response_status = 200;
static bool oversized, transport_failed;
// Exercise the production streaming delegate directly; no URL connection starts.
@interface DmNextendoApiTransfer : NSObject <NSURLSessionDataDelegate,NSURLSessionTaskDelegate>
@property(nonatomic) NSMutableData *data;
@property(nonatomic) BOOL failed;
@property(nonatomic) NSInteger status;
@property(nonatomic) dispatch_semaphore_t completed;
@end
#define CHECK(x) do { checks++; if (!(x)) { failures++; fprintf(stderr,"API check failed at %d\n",__LINE__); } } while (0)
NSString *dm_nextendo_api_bearer(const char *resource) { (void)resource;return linked ? @"synthetic-proof" : nil; }
NSData *dm_nextendo_api_identity(const char *resource) { (void)resource;return nil; }
bool dm_nextendo_api_passive_valid(NSString *proof,uint64_t generation) { return linked && generation==7 && [proof isEqual:@"synthetic-proof"]; }
void dm_guest_host_wait_begin(void) {}
void dm_guest_host_wait_end(void) {}
static bool transport(const char *url,const char *method,const char *authorization,const uint8_t *body,size_t body_size,
                      uint8_t *output,size_t capacity,size_t *size,unsigned *status) {
    requests++; CHECK(!strcmp(authorization,"Bearer synthetic-proof"));
    CHECK(!strcmp(url,"https://nextendo.network/api/friends") || !strcmp(url,"https://nextendo.network/api/me") || !strcmp(url,"https://nextendo.network/api/presence"));
    if (strstr(url,"presence")) { CHECK(!strcmp(method,"POST") && body && body_size); }
    else { CHECK(!strcmp(method,"GET") && !body_size); }
    const char json[]="{\"friends\":[]}"; CHECK(capacity >= sizeof json);
    memcpy(output,json,sizeof json-1); *size=oversized?capacity+1:sizeof json-1; *status=response_status;
    return !transport_failed;
}
static void httpMetadata(void) {
    linked=YES;
    const char *disabled[]={"0","true","01",""};uint8_t output[256];size_t size=0;
    TraceCapture capture=trace_capture_begin();unsetenv("DM_ACCOUNT_TRACE");
    CHECK(!dm_nextendo_api_request("friends",NULL,0,output,sizeof output,&size));
    for(unsigned i=0;i<sizeof disabled/sizeof *disabled;i++) {
        setenv("DM_ACCOUNT_TRACE",disabled[i],1);CHECK(!dm_nextendo_api_request("friends",NULL,0,output,sizeof output,&size));
    }
    char *text=trace_capture_end(capture);CHECK(!*text);free(text);
    setenv("DM_ACCOUNT_TRACE","1",1);capture=trace_capture_begin();response_status=403;
    CHECK(dm_nextendo_api_request("friends",NULL,0,output,sizeof output,&size)!=0);
    for(unsigned i=0;i<64;i++) {response_status=400+i%2;CHECK(dm_nextendo_api_request("friends",NULL,0,output,sizeof output,&size)!=0);}
    errno=EAGAIN;dm_account_trace_api(DM_ACCOUNT_API_ME,700);CHECK(errno==EAGAIN);
    dm_account_trace_api((dm_account_trace_api_operation)99,200);
    text=trace_capture_end(capture);
    CHECK(strstr(text,"op=api.friends http_status=403")!=NULL&&strstr(text,"op=api.me http_status=0")!=NULL);
    CHECK(!strstr(text,"synthetic-proof")&&!strstr(text,"Bearer")&&!strstr(text,"https://")&&!strstr(text,"friends\"")&&!strstr(text,"700"));
    unsigned lines=0;for(char *p=text;*p;p++)if(*p=='\n')lines++;CHECK(lines==33);free(text);
    unsetenv("DM_ACCOUNT_TRACE");response_status=200;
}
int main(void) { @autoreleasepool {
    unsetenv("DM_ACCOUNT_TRACE");
    dm_nextendo_api_test_transport(transport); uint8_t output[256]; size_t size=99;
    CHECK(!dm_nextendo_api_request("friends",NULL,0,output,sizeof output,&size) && size==14);
    CHECK(!dm_nextendo_api_request("me",NULL,0,output,sizeof output,&size));
    CHECK(!dm_nextendo_api_request("presence",(const uint8_t*)"{}",2,output,sizeof output,&size));
    CHECK(!dm_nextendo_api_request_passive("presence",(const uint8_t*)"{}",2,output,sizeof output,&size,@"synthetic-proof",7));
    int passive_requests=requests;
    CHECK(dm_nextendo_api_request_passive("presence",(const uint8_t*)"{}",2,output,sizeof output,&size,@"synthetic-proof",8)!=0 && !size && requests==passive_requests);
    for (unsigned status=300;status<=500;status+=100) { response_status=status; CHECK(dm_nextendo_api_request("friends",NULL,0,output,sizeof output,&size)!=0 && !size); }
    response_status=200; oversized=true; CHECK(dm_nextendo_api_request("friends",NULL,0,output,sizeof output,&size)!=0 && !size); oversized=false;
    transport_failed=true; CHECK(dm_nextendo_api_request("friends",NULL,0,output,sizeof output,&size)!=0 && !size); transport_failed=false;
    int before=requests;
    CHECK(dm_nextendo_api_request("https://untrusted.invalid",NULL,0,output,sizeof output,&size)!=0);
    CHECK(dm_nextendo_api_request("../friends",NULL,0,output,sizeof output,&size)!=0);
    CHECK(dm_nextendo_api_request("friends",(const uint8_t*)"{}",2,output,sizeof output,&size)!=0);
    CHECK(dm_nextendo_api_request("presence",NULL,0,output,sizeof output,&size)!=0);
    linked=NO; CHECK(dm_nextendo_api_request("friends",NULL,0,output,sizeof output,&size)!=0);
    CHECK(before==requests && !size);
    NSURLSession *dummy=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    NSURL *dummy_url=[NSURL URLWithString:@"https://nextendo.network/api/friends"];CHECK(dummy_url!=nil);if(!dummy_url)return 1;
    NSURLSessionDataTask *dummy_task=[dummy dataTaskWithURL:dummy_url]; // never resumed
    DmNextendoApiTransfer *transfer=[DmNextendoApiTransfer new];
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:dummy_url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Length":@"1048577"}];
    CHECK(response!=nil);if(!response)return 1;
    __block BOOL cancelled=NO;
    [transfer URLSession:dummy dataTask:dummy_task didReceiveResponse:response completionHandler:^(NSURLSessionResponseDisposition disposition){cancelled=disposition==NSURLSessionResponseCancel;}];
    CHECK(cancelled&&transfer.failed&&!transfer.data.length);
    transfer=[DmNextendoApiTransfer new];
    NSMutableData *large_data=[NSMutableData dataWithLength:1024*1024];CHECK(large_data!=nil);if(!large_data)return 1;
    [transfer URLSession:dummy dataTask:dummy_task didReceiveData:large_data];
    CHECK(!transfer.failed&&transfer.data.length==1024*1024);
    NSData *extra_data=[NSData dataWithBytes:"X" length:1];CHECK(extra_data!=nil);if(!extra_data)return 1;
    [transfer URLSession:dummy dataTask:dummy_task didReceiveData:extra_data];
    CHECK(transfer.failed&&transfer.data.length==1024*1024);
    transfer=[DmNextendoApiTransfer new];__block BOOL redirect_refused=NO;
    NSURL *redirect_url=[NSURL URLWithString:@"https://untrusted.invalid/"];CHECK(redirect_url!=nil);if(!redirect_url)return 1;
    [transfer URLSession:dummy task:dummy_task willPerformHTTPRedirection:response newRequest:[NSURLRequest requestWithURL:redirect_url] completionHandler:^(NSURLRequest *request){redirect_refused=request==nil;}];
    CHECK(redirect_refused&&transfer.failed);
    [transfer URLSession:dummy task:dummy_task didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
    CHECK(transfer.failed&&dispatch_semaphore_wait(transfer.completed,DISPATCH_TIME_NOW)==0);
    [dummy invalidateAndCancel];
    httpMetadata();printf("Nextendo API: %d checks, %d failed; synthetic transport only\n",checks,failures); return failures?1:0;
} }
