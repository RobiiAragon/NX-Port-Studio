// Shared IOHID fallback for original Joy-Con IMUs omitted by macOS GameController.
// All access is on the main run loop; devices are never seized. SPI commands only READ calibration.
#import <IOKit/hid/IOHIDManager.h>
#include "joycon_protocol.h"
#include "joycon_rumble.h"
#include <stdatomic.h>
#include <time.h>
static GCController *joycon_controller_for_side(int side);
static int joycon_player_for_side(int side); // front_mac: associates the physical halves with the actual GameController player
static void joycon_buttons_changed(void);
static void joycon_rumble_routes_changed(void);
typedef struct {
    IOHIDDeviceRef device;
    uint8_t report[128],sequence,rumble[8],original_mode;
    int side,calibration_stage,attempts,active,original_imu,changed_mode,generation,battery,charging,player_lights,rumble_active,rumble_errors,rumble_pending,rumble_scheduled;
    uint64_t reports,last_report,last_packet,last_reset,last_rumble,extra;
    dm_joycon_calibration calibration;
    dm_joycon_fusion fusion;
} DmJoyCon;
static DmJoyCon g_joycons[8];
static IOHIDManagerRef g_joycon_manager;
static NSTimer *g_joycon_timer,*g_joycon_rumble_timer;
static _Atomic uintptr_t g_joycon_rumble_controller[8];
static int joycon_active(void) { return g_input_on && g_controls.motion; }
static uint64_t joycon_host_ns(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+t.tv_nsec; }
static IOReturn joycon_command(DmJoyCon *d,uint8_t command,const uint8_t *payload,size_t length) {
    if(!d->device || length>38)return kIOReturnBadArgument;
    uint8_t output[49]={1,d->sequence++&15}; memcpy(output+2,d->rumble,8); output[10]=command;
    if(length)memcpy(output+11,payload,length);
    return IOHIDDeviceSetReport(d->device,kIOHIDReportTypeOutput,1,output,sizeof output);
}
static void joycon_spi(DmJoyCon *d,uint32_t address,uint8_t length) {
    uint8_t data[5]={address,address>>8,address>>16,address>>24,length};
    IOReturn result=joycon_command(d,0x10,data,sizeof data);
    if(result!=kIOReturnSuccess)LOG("Joy-Con %s: calibration read failed (%#x)",d->side?"R":"L",result);
}
static void joycon_update(void) {
    int routes_changed=0;
    for(int i=0;i<8;i++) {
        DmJoyCon *d=&g_joycons[i]; if(!d->device || d->calibration_stage<2)continue;
        GCController *controller=joycon_controller_for_side(d->side);
        int player=joycon_player_for_side(d->side);
        uintptr_t key=player>=0 ? (uintptr_t)(__bridge void *)controller : 0;
        if(atomic_exchange(&g_joycon_rumble_controller[i],key)!=key)routes_changed=1;
        static const uint8_t patterns[8]={1,3,7,15,9,5,13,6};
        if(player>=0 && d->player_lights!=player) { uint8_t lights=patterns[player%8]; if(joycon_command(d,0x30,&lights,1)==kIOReturnSuccess)d->player_lights=player; }
        int enabled=joycon_active() && player>=0 && d->calibration.valid;
        if(enabled && d->active && d->last_packet>d->last_report && d->last_packet-d->last_report>3000000000ull && d->last_packet-d->last_reset>3000000000ull) {
            // Other controller clients can disable IMU reporting. Re-enable only after observing packets without sensor data for three seconds.
            uint8_t enable=1;joycon_command(d,0x40,&enable,1);d->last_reset=d->last_packet;
            LOG("Joy-Con %s: another client stopped IMU reports; reactivating requested motion",d->side?"R":"L");
        }
        if(enabled != d->active) {
            uint8_t enable=enabled; IOReturn result=joycon_command(d,0x40,&enable,1);
            if(result==kIOReturnSuccess) {
                d->active=enabled; memset(&d->fusion,0,sizeof d->fusion);
                if(enabled) { uint8_t mode=0x30; result=joycon_command(d,0x03,&mode,1); d->changed_mode=result==kIOReturnSuccess; }
                else if(player>=0)dm_motion_set_sensor_at(player,d->side,NULL,guest_ns());
            }
            if(result!=kIOReturnSuccess)LOG("Joy-Con %s: IMU activation failed (%#x)",d->side?"R":"L",result);
        }
    }
    if(routes_changed)joycon_rumble_routes_changed();
}
static void joycon_report(void *context,IOReturn result,void *sender,IOHIDReportType type,uint32_t reportID,uint8_t *data,CFIndex length) {
    (void)sender;(void)type; DmJoyCon *d=context;
    if(result!=kIOReturnSuccess || !d->device || length<1 || data[0]!=reportID)return;
    if(!d->original_mode && (reportID==0x30 || reportID==0x3f) && !d->changed_mode)d->original_mode=reportID;
    if(reportID==0x21 && length>=20 && (data[13]&0x80) && data[14]==0x10) {
        uint32_t address=(uint32_t)data[15]|(uint32_t)data[16]<<8|(uint32_t)data[17]<<16|(uint32_t)data[18]<<24;
        size_t n=data[19];if(n>(size_t)length-20)return;
        if(address==0x6020 && d->calibration_stage==0) {
            if(!dm_joycon_factory_calibration(&d->calibration,data+20,n)) { LOG("Joy-Con %s: invalid factory IMU calibration; sensor remains unavailable",d->side?"R":"L");return; }
            d->calibration_stage=1; joycon_spi(d,0x8026,20);
        } else if(address==0x8026 && d->calibration_stage==1) {
            dm_joycon_user_calibration(&d->calibration,data+20,n);d->calibration_stage=2;
            LOG("Joy-Con %s: IMU factory/user calibration ready (gyro bias %d,%d,%d)",d->side?"R":"L",d->calibration.gyro_zero[0],d->calibration.gyro_zero[1],d->calibration.gyro_zero[2]);
            joycon_update();
        }
        return;
    }
    if(reportID!=0x30 || length<49)return;
    d->last_packet=guest_ns();
    if(!d->active && d->calibration_stage<2) {
        for(int k=13;k<49;k++)if(data[k]){d->original_imu=1;break;}
    }
    d->battery=((data[2]&0xe0)>>5)*25; d->charging=(data[2]&0x10)!=0;
    uint64_t extra=dm_joycon_extra_buttons(data,(size_t)length);
    if(data[d->side?3:5]&0x20)extra |= d->side?DM_BTN_RIGHT_SL:DM_BTN_LEFT_SL;
    if(data[d->side?3:5]&0x10)extra |= d->side?DM_BTN_RIGHT_SR:DM_BTN_LEFT_SR;
    if(extra!=d->extra){d->extra=extra;joycon_buttons_changed();}
    if(!d->active || !joycon_active() || !d->calibration.valid)return;
    int acceleration_present=0;
    for(int k=0;k<3;k++)for(int b=0;b<6;b++)acceleration_present |= data[13+k*12+b];
    if(!acceleration_present)return; // An IMU disabled by another client is unavailable, never a successful zero measurement.
    int player=joycon_player_for_side(d->side); if(player<0)return;
    uint64_t now=guest_ns();
    // The report contains newest, previous, oldest; publish all three in chronological order, at the sensor's 5 ms spacing.
    for(int k=2;k>=0;k--) {
        uint64_t timestamp=now>(uint64_t)k*5000000 ? now-(uint64_t)k*5000000 : 0;
        dm_motion_state state;dm_joycon_motion(&d->calibration,d->side,data+13+k*12,0.005,&d->fusion,&state);
        dm_motion_set_sensor_at(player,d->side,&state,timestamp);
    }
    d->last_report=now;d->reports++;
    if(d->reports==1)LOG("Joy-Con %s: real calibrated IMU reports received for player %d",d->side?"R":"L",player+1);
}
static void joycon_added(void *context,IOReturn result,void *sender,IOHIDDeviceRef device) {
    (void)context;(void)sender;if(result!=kIOReturnSuccess)return;
    int product=[(__bridge NSNumber *)IOHIDDeviceGetProperty(device,CFSTR(kIOHIDProductIDKey)) intValue];
    if(product!=0x2006 && product!=0x2007)return;
    for(int i=0;i<8;i++)if(g_joycons[i].device==device)return;
    DmJoyCon *d=NULL;for(int i=0;i<8;i++)if(!g_joycons[i].device){d=&g_joycons[i];break;}if(!d)return;
    IOReturn opened=IOHIDDeviceOpen(device,kIOHIDOptionsTypeNone);
    if(opened!=kIOReturnSuccess){LOG("Joy-Con: shared IMU open failed (%#x); GameController buttons remain available",opened);return;}
    int generation=d->generation+1;memset(d,0,sizeof *d);d->generation=generation;d->device=(IOHIDDeviceRef)CFRetain(device);d->side=product==0x2007;d->battery=-1;d->player_lights=-1;
    memcpy(d->rumble,(uint8_t[]){0,1,0x40,0x40,0,1,0x40,0x40},8);
    IOHIDDeviceRegisterInputReportCallback(device,d->report,sizeof d->report,joycon_report,d);
    IOHIDDeviceScheduleWithRunLoop(device,CFRunLoopGetMain(),kCFRunLoopCommonModes);
    uint8_t vibration=1;joycon_command(d,0x48,&vibration,1);
    joycon_spi(d,0x6020,24);
    // A missing reply is an error, not a successful zero sensor. Retry the read with bounded attempts.
    __block void (^retry)(void); retry=^{
        if(!d->device || d->generation!=generation || d->calibration_stage>=2){retry=nil;return;}
        if(++d->attempts>=3){LOG("Joy-Con %s: calibration reply timed out; raw motion unavailable",d->side?"R":"L");retry=nil;return;}
        joycon_spi(d,d->calibration_stage ? 0x8026 : 0x6020,d->calibration_stage?20:24);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),retry);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),retry);
}
static void joycon_close(DmJoyCon *d) {
    if(!d->device)return;
    d->rumble_active=d->rumble_pending=0;
    uint64_t close_now=joycon_host_ns();
    if(d->last_rumble && close_now-d->last_rumble<30000000) {
        uint64_t remaining=30000000-(close_now-d->last_rumble);struct timespec pause={0,(long)remaining};
        while(nanosleep(&pause,&pause)!=0 && errno==EINTR){}
    }
    uint8_t stop[10]={0x10,d->sequence++&15,0,1,0x40,0x40,0,1,0x40,0x40};
    IOHIDDeviceSetReport(d->device,kIOHIDReportTypeOutput,0x10,stop,sizeof stop);
    int player=joycon_player_for_side(d->side);if(player>=0)dm_motion_set_sensor_at(player,d->side,NULL,guest_ns());
    if(d->active && !d->original_imu){uint8_t zero=0;joycon_command(d,0x40,&zero,1);}
    if(d->changed_mode && d->original_mode && d->original_mode!=0x30)joycon_command(d,0x03,&d->original_mode,1);
    IOHIDDeviceRegisterInputReportCallback(d->device,d->report,sizeof d->report,NULL,NULL);
    IOHIDDeviceUnscheduleFromRunLoop(d->device,CFRunLoopGetMain(),kCFRunLoopCommonModes);
    IOHIDDeviceClose(d->device,kIOHIDOptionsTypeNone);CFRelease(d->device);d->device=NULL;d->extra=0;
    atomic_store(&g_joycon_rumble_controller[d-g_joycons],0);joycon_rumble_routes_changed();
    joycon_buttons_changed();
}
static void joycon_removed(void *context,IOReturn result,void *sender,IOHIDDeviceRef device) {
    (void)context;(void)result;(void)sender;for(int i=0;i<8;i++)if(g_joycons[i].device==device)joycon_close(&g_joycons[i]);
}
static NSString *joycon_status(GCController *controller) {
    if(![controller.productCategory localizedCaseInsensitiveContainsString:@"Joy-Con"])return nil;
    NSMutableArray *parts=[NSMutableArray new];
    for(int i=0;i<8;i++) {
        DmJoyCon *d=&g_joycons[i];if(!d->device)continue;
        NSString *sensor=d->reports ? @"gyro + acceleration" : d->calibration_stage>=2 ? @"IMU ready" : @"calibrating IMU";
        [parts addObject:[NSString stringWithFormat:@"%@: %@%@",d->side?@"R":@"L",sensor,d->battery>=0?[NSString stringWithFormat:@", %d%%%@",d->battery,d->charging?@" charging":@""]:@""]];
    }
    return parts.count?[parts componentsJoinedByString:@" · "]:nil;
}
static uint64_t joycon_extra_for_player(int player) {
    uint64_t value=0;for(int i=0;i<8;i++)if(g_joycons[i].device && joycon_player_for_side(g_joycons[i].side)==player)value|=g_joycons[i].extra;
    return value;
}
static void joycon_stop(void) {
    if(!NSThread.isMainThread){dispatch_sync(dispatch_get_main_queue(),^{joycon_stop();});return;}
    for(int i=0;i<8;i++)atomic_store(&g_joycon_rumble_controller[i],0);
    for(int i=0;i<8;i++)joycon_close(&g_joycons[i]);
    [g_joycon_timer invalidate];g_joycon_timer=nil;[g_joycon_rumble_timer invalidate];g_joycon_rumble_timer=nil;
    if(g_joycon_manager){IOHIDManagerUnscheduleFromRunLoop(g_joycon_manager,CFRunLoopGetMain(),kCFRunLoopCommonModes);IOHIDManagerClose(g_joycon_manager,kIOHIDOptionsTypeNone);CFRelease(g_joycon_manager);g_joycon_manager=NULL;}
}
static bool joycon_rumble_available(GCController *controller) {
    uintptr_t key=(uintptr_t)(__bridge void *)controller;
    for(int i=0;i<8;i++)if(atomic_load(&g_joycon_rumble_controller[i])==key && key)return true;
    return false;
}
static void joycon_rumble_write(DmJoyCon *d) {
    uint8_t output[10]={0x10,d->sequence++&15};memcpy(output+2,d->rumble,8);
    IOReturn result=IOHIDDeviceSetReport(d->device,kIOHIDReportTypeOutput,0x10,output,sizeof output);
    d->last_rumble=joycon_host_ns();
    if(result!=kIOReturnSuccess && (++d->rumble_errors<=3 || d->rumble_errors%64==0))LOG("Joy-Con %s: vibration output failed (%#x)",d->side?"R":"L",result);
}
static void joycon_rumble_flush(DmJoyCon *d) {
    if(!d->device || !d->rumble_pending)return;
    uint64_t now=joycon_host_ns(),remaining=d->last_rumble && now-d->last_rumble<30000000 ? 30000000-(now-d->last_rumble) : 0;
    if(remaining) {
        if(d->rumble_scheduled)return;
        d->rumble_scheduled=1;int generation=d->generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)remaining),dispatch_get_main_queue(),^{
            if(!d->device || d->generation!=generation)return;
            d->rumble_scheduled=0;joycon_rumble_flush(d);
        });
        return;
    }
    // Coalesce to the latest requested value, including zero. Scheduled callbacks cannot replay an old value after stop/reconnect.
    d->rumble_pending=0;joycon_rumble_write(d);
}
static void joycon_rumble_send(GCController *controller,const dm_vibration motor[2]) {
    dm_vibration left=motor[0],right=motor[1];
    dispatch_async(dispatch_get_main_queue(),^{
        for(int i=0;i<8;i++) {
            DmJoyCon *d=&g_joycons[i];if(!d->device || joycon_controller_for_side(d->side)!=controller)continue;
            uint8_t neutral[4]={0,1,0x40,0x40};memcpy(d->rumble,neutral,4);memcpy(d->rumble+4,neutral,4);
            dm_joycon_encode_rumble(d->side?right:left,d->rumble+(d->side?4:0));
            dm_vibration value=d->side?right:left;
            d->rumble_active=value.amplitude_low>0 || value.amplitude_high>0;
            d->rumble_pending=1;joycon_rumble_flush(d);
        }
    });
}
static void joycon_rumble_routes_changed(void) { dm_haptics_apple_raw_handler(joycon_rumble_available,joycon_rumble_send); }
static void joycon_start(void) {
    if(g_joycon_manager)return;
    g_joycon_manager=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(g_joycon_manager,(__bridge CFDictionaryRef)@{@(kIOHIDVendorIDKey):@0x057e});
    IOHIDManagerRegisterDeviceMatchingCallback(g_joycon_manager,joycon_added,NULL);IOHIDManagerRegisterDeviceRemovalCallback(g_joycon_manager,joycon_removed,NULL);
    IOHIDManagerScheduleWithRunLoop(g_joycon_manager,CFRunLoopGetMain(),kCFRunLoopCommonModes);
    IOReturn result=IOHIDManagerOpen(g_joycon_manager,kIOHIDOptionsTypeNone);
    if(result!=kIOReturnSuccess)LOG("Joy-Con: IOHID manager unavailable (%#x)",result);
    dm_haptics_apple_raw_handler(joycon_rumble_available,joycon_rumble_send);
    g_controls_motion_status=^NSString *(GCController *c){return joycon_status(c);};
    g_joycon_timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){(void)timer;joycon_update();}];
    // Nintendo's rumble watchdog needs unchanged continuous effects refreshed every 50 ms; zeros stop refresh immediately.
    g_joycon_rumble_timer=[NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer){
        (void)timer;uint64_t now=joycon_host_ns();
        for(int i=0;i<8;i++){DmJoyCon *d=&g_joycons[i];if(d->device && d->rumble_active && g_input_on && now-d->last_rumble>=50000000){d->rumble_pending=1;joycon_rumble_flush(d);}}
    }];
    atexit(joycon_stop);
}
