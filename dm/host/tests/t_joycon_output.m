// Exercise the actual IOHID output scheduler with a fake transport: no controller is opened.
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDManager.h>
#include "../controls_map.h"
#include "../haptics_apple.h"
#include <time.h>
#define LOG(...) do {} while(0)
static int g_input_on=1;
static dm_controls g_controls;
static NSString *(^g_controls_motion_status)(GCController *);
static GCController *fake_controller;
static int outputs;
static uint64_t times[512];static uint8_t values[512][8];
static uint64_t guest_ns(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+t.tv_nsec;}
static IOReturn fake_report(IOHIDDeviceRef d,IOHIDReportType type,CFIndex id,const uint8_t *bytes,CFIndex length){
 (void)d;(void)type;if(id==0x10&&length==10&&outputs<512){times[outputs]=guest_ns();memcpy(values[outputs++],bytes+2,8);}return kIOReturnSuccess;
}
#define IOHIDDeviceSetReport fake_report
#include "../joycon_mac.inc"
#undef IOHIDDeviceSetReport
static GCController *joycon_controller_for_side(int side){(void)side;return fake_controller;}
static int joycon_player_for_side(int side){(void)side;return 0;}
static void joycon_buttons_changed(void){}
void dm_motion_set_sensor_at(int p,int side,const dm_motion_state *state,uint64_t time){(void)p;(void)side;(void)state;(void)time;}
void dm_haptics_apple_raw_handler(bool (*available)(GCController *),void (*send)(GCController *,const dm_vibration[2])){(void)available;(void)send;}
static void pump(double seconds){NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];while(until.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];}
int main(void){@autoreleasepool{
 fake_controller=(GCController *)[NSObject new];DmJoyCon *d=&g_joycons[0];d->device=(IOHIDDeviceRef)(uintptr_t)1;d->side=0;d->generation=1;
 dm_vibration on[2]={{0.25f,160,0.2f,320},{0}},zero[2]={{0}};
 joycon_rumble_send(fake_controller,on);pump(0.004);
 for(int i=0;i<200;i++)joycon_rumble_send(fake_controller,i==199?zero:on);
 pump(0.09);int failed=0;
 if(outputs!=2){fprintf(stderr,"expected first and coalesced final output, got %d\n",outputs);failed++;}
 for(int i=1;i<outputs;i++)if(times[i]-times[i-1]<30000000){fprintf(stderr,"rumble writes violate 30 ms spacing\n");failed++;}
 uint8_t neutral[8]={0,1,0x40,0x40,0,1,0x40,0x40};if(outputs&&memcmp(values[outputs-1],neutral,8)){fprintf(stderr,"final neutral was lost\n");failed++;}
 d->last_rumble=joycon_host_ns();joycon_rumble_send(fake_controller,on);pump(0.002);int before=outputs;d->device=NULL;d->generation++;pump(0.05);
 if(outputs!=before){fprintf(stderr,"stale reconnect callback emitted output\n");failed++;}
 printf("Joy-Con output: coalescing, >=30 ms spacing, neutral stop and stale-generation checks: %s\n",failed?"FAILED":"passed");return failed!=0;
}}
