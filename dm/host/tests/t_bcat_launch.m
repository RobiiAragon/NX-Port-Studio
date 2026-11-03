// Original synthetic HTTPS responses, signing key and resources. The Python
// runner compiles a temporary runtime copy with ONLY the fixture trust anchor
// and original XML digest substituted; production never accepts a runtime pin.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
static NSString *fixtureRoot,*fixtureMode,*fixtureTitle;
static unsigned requests,catalogRequests,archiveRequests,conditionals;
static BOOL scopeGate;static dispatch_semaphore_t scopeArrived,scopeRelease;
@interface DmBcatFixtureProtocol : NSURLProtocol @end
@implementation DmBcatFixtureProtocol
+(BOOL)canInitWithRequest:(NSURLRequest *)r{(void)r;return YES;}
+(NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r{return r;}
-(void)startLoading{
    @synchronized(DmBcatFixtureProtocol.class){requests++;}
    NSString *path=self.request.URL.path,*file=nil;NSInteger status=200;NSDictionary *headers=@{};
    if([path isEqual:@"/service-catalog/v1/game-catalog"]){
        @synchronized(DmBcatFixtureProtocol.class){catalogRequests++;}
        if([fixtureMode isEqual:@"interrupt"]){[@"ready" writeToFile:[fixtureRoot stringByAppendingPathComponent:@"interrupt-ready"] atomically:YES encoding:NSUTF8StringEncoding error:nil];return;}
        // The catalog uses part of the launch budget, then the archive stalls.
        // A fresh per-request deadline would incorrectly add another 12 seconds.
        if([fixtureMode isEqual:@"timeout"])[NSThread sleepForTimeInterval:4];
        if([fixtureMode isEqual:@"error"]){[self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil]];return;}
        file=[fixtureMode isEqual:@"invalid"]?@"invalid.json":@"catalog.json";
    }else if([path isEqual:[@"/api/bcat/" stringByAppendingString:fixtureTitle]]){
        @synchronized(DmBcatFixtureProtocol.class){archiveRequests++;if([self.request valueForHTTPHeaderField:@"If-None-Match"])conditionals++;}
        if(scopeGate){dispatch_semaphore_signal(scopeArrived);dispatch_semaphore_wait(scopeRelease,DISPATCH_TIME_FOREVER);}
        if([fixtureMode isEqual:@"timeout"])return;
        if([fixtureMode isEqual:@"304"]){status=304;headers=@{@"ETag":@"\"fixture-v1\""};}
        else{file=[fixtureMode isEqual:@"corrupt"]?@"corrupt.zip":[fixtureMode isEqual:@"v2"]?@"v2.zip":@"v1.zip";if(![fixtureMode isEqual:@"noetag"])headers=@{@"ETag":[fixtureMode isEqual:@"v2"]?@"\"fixture-v2\"":@"\"fixture-v1\""};}
    }else if([path hasSuffix:@"/System/GameConfigSetting.xml"])file=@"static.xml";
    else if([path hasSuffix:@"/dummy/dummy.txt"])file=@"dummy.txt";
    else{[self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnsupportedURL userInfo:nil]];return;}
    NSData *data=file?[NSData dataWithContentsOfFile:[fixtureRoot stringByAppendingPathComponent:file]]:NSData.data;
    if(!data)abort();NSHTTPURLResponse *r=[[NSHTTPURLResponse alloc]initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];[self.client URLProtocolDidFinishLoading:self];
}
-(void)stopLoading{}
@end
@interface NSURLSessionConfiguration(DmBcatFixture)
+(instancetype)dm_bcat_fixture_configuration;
@end
@implementation NSURLSessionConfiguration(DmBcatFixture)
+(instancetype)dm_bcat_fixture_configuration{
    NSURLSessionConfiguration *c=[self dm_bcat_fixture_configuration];c.protocolClasses=@[DmBcatFixtureProtocol.class];return c;
}
@end
#ifndef DM_BCAT_RUNTIME_INCLUDE
#define DM_BCAT_RUNTIME_INCLUDE "../hle_bcat_apple.m"
#endif
#import DM_BCAT_RUNTIME_INCLUDE

int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=4&&argc!=5)return 2;fixtureRoot=@(argv[1]);fixtureMode=@(argv[2]);NSString *cache=@(argv[3]);fixtureTitle=argc==5?@(argv[4]):@"0100f8f0000a2000";
    BOOL exerciseScope=[fixtureMode isEqual:@"scoped-refresh"];if(exerciseScope)fixtureMode=@"v1";
    Method a=class_getClassMethod(NSURLSessionConfiguration.class,@selector(ephemeralSessionConfiguration));
    Method b=class_getClassMethod(NSURLSessionConfiguration.class,@selector(dm_bcat_fixture_configuration));method_exchangeImplementations(a,b);
    activeCache=cache;activeVersion=splatoon3(fixtureTitle)?@"11.3.0":@"5.5.2";startTitle=fixtureTitle;startOnline=![fixtureMode isEqual:@"offline"];
    NSString *seed=[fixtureRoot stringByAppendingPathComponent:@"empty-seed"];
    uint64_t before=monotonicTime();selectAtLaunch(seed);double elapsed=(monotonicTime()-before)/(double)NSEC_PER_SEC;
    // This is the first calendar open; it must see the completed launch choice.
    const char *overlay=dm_bcat_overlay();NSString *name=splatoon3(fixtureTitle)?@"us-default/base.pack.zs.enc":@"vsdata/VSSetting_0.byaml";
    NSString *file=overlay?[[@(overlay) stringByAppendingPathComponent:@"DebugUnderPilot/bcat"] stringByAppendingPathComponent:name]:nil;
    NSData *first=file?boundedRead(file,1024):nil;unsigned char marker=first.length?((const unsigned char *)first.bytes)[first.length-1]:0;
    unsigned beforeScope=requests,scopeResult=1;uint64_t scopeBytes=0;
    void *scope=dm_bcat_sync_observe_directory(splatoon3(fixtureTitle)?"us-default":"vsdata");
    int scopeStatus=dm_bcat_sync_observer_status(scope,&scopeResult,&scopeBytes);
    void *missing=dm_bcat_sync_observe_directory("missing"),*invalid=dm_bcat_sync_observe_directory("../escape");
    BOOL asyncPassed=NO;
    if(exerciseScope){
        scopeArrived=dispatch_semaphore_create(0);scopeRelease=dispatch_semaphore_create(0);scopeGate=YES;fixtureMode=@"v2";lastRefresh=0;
        void *pending=dm_bcat_sync_observe_directory(splatoon3(fixtureTitle)?"us-default":"vsdata");
        void *pendingMissing=dm_bcat_sync_observe_directory("missing");
        if(!pending||!pendingMissing||dispatch_semaphore_wait(scopeArrived,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)))return 3;
        unsigned pendingResult=0;uint64_t pendingBytes=123;
        BOOL waited=dm_bcat_sync_observer_status(pending,&pendingResult,&pendingBytes)==2&&pendingBytes==0;
        dispatch_semaphore_signal(scopeRelease);
        uint64_t until=monotonicTime()+3*NSEC_PER_SEC;int status;
        do{status=dm_bcat_sync_observer_status(pending,&pendingResult,&pendingBytes);if(status!=9)usleep(1000);}while(status!=9&&monotonicTime()<until);
        unsigned absentResult=0;uint64_t absentBytes=123;
        int absentStatus=dm_bcat_sync_observer_status(pendingMissing,&absentResult,&absentBytes);
        unsigned oldResult=1;uint64_t oldBytes=0;
        int oldStatus=dm_bcat_sync_observer_status(scope,&oldResult,&oldBytes);
        char delivery[1024];NSData *newData=nil;if(dm_bcat_copy_delivery(delivery,sizeof delivery))newData=boundedRead([[@(delivery) stringByAppendingPathComponent:name] stringByStandardizingPath],1024);
        NSData *oldData=boundedRead(file,1024);
        asyncPassed=waited&&status==9&&!pendingResult&&pendingBytes==scopeBytes&&absentStatus==9&&absentResult&&absentBytes==0&&oldStatus==scopeStatus&&oldResult==scopeResult&&oldBytes==scopeBytes&&newData.length&&((const unsigned char *)newData.bytes)[newData.length-1]==2&&oldData.length&&((const unsigned char *)oldData.bytes)[oldData.length-1]==1;
        dm_bcat_sync_release(pending);dm_bcat_sync_release(pendingMissing);
    }
    NSDictionary *summary=@{@"requests":@(requests),@"catalogRequests":@(catalogRequests),@"archiveRequests":@(archiveRequests),@"conditionalRequests":@(conditionals),@"elapsed":@(elapsed),@"firstCalendarMarker":@(marker),@"hasOverlay":@(overlay!=NULL),@"result":@(activeRefresh?activeRefresh.result:99),@"freshAttempt":@(activeRefresh!=nil),@"hasScopedObserver":@(scope!=NULL),@"scopeStatus":@(scopeStatus),@"scopeResult":@(scopeResult),@"scopeBytes":@(scopeBytes),@"acceptedMissingScope":@(missing!=NULL),@"acceptedInvalidScope":@(invalid!=NULL),@"scopeExtraRequests":@(requests-beforeScope),@"asyncScopePassed":@(asyncPassed)};
    dm_bcat_sync_release(scope);dm_bcat_sync_release(missing);dm_bcat_sync_release(invalid);
    fwrite(jsonData(summary).bytes,1,jsonData(summary).length,stdout);fputc('\n',stdout);return 0;
}}
