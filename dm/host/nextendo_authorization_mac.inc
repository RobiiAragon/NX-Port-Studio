// Main-thread observation of one explicit local authorization. The credential
// read runs off-main; closing its sheet drops feedback, never starts another read.
#import <Foundation/Foundation.h>
#include "nextendo_account.h"
@interface DmNextendoAuthorization : NSObject
@property(nonatomic,readonly) BOOL busy;
- (BOOL)authorizeWithCompletion:(void (^)(uint32_t result))completion;
- (BOOL)observePendingWithCompletion:(void (^)(uint32_t result))completion;
- (void)cancelObservation;
@end
@implementation DmNextendoAuthorization {
    BOOL _busy;
    uint64_t _generation;
    void (^_completion)(uint32_t);
}
- (BOOL)busy { return _busy; }
- (void)cancelObservation {
    NSAssert(NSThread.isMainThread,@"Authorization UI belongs to the main thread");
    _completion=nil;
}
- (BOOL)observePendingWithCompletion:(void (^)(uint32_t))completion {
    NSAssert(NSThread.isMainThread,@"Authorization UI belongs to the main thread");
    if (!_busy || !completion) return NO; _completion=[completion copy]; return YES;
}
- (BOOL)authorizeWithCompletion:(void (^)(uint32_t))completion {
    NSAssert(NSThread.isMainThread,@"Authorization UI belongs to the main thread");
    if (_busy || !completion) return NO;
    _busy=YES; uint64_t generation=++_generation; _completion=[completion copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        uint32_t result=dm_nextendo_account_authorize_local();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy=NO;
            if (self->_generation!=generation) return;
            void (^finished)(uint32_t)=self->_completion; self->_completion=nil;
            if (finished) finished(result);
        });
    }); return YES;
}
@end
