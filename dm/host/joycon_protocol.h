// Original Switch Joy-Con HID protocol. Layout/scales cross-checked against SDL's Nintendo and Apple adapters.
// Protocol reference: https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_switch.c
#pragma once
#include "controls_map.h"

typedef struct { int16_t accel_zero[3], gyro_zero[3], accel_sens[3], gyro_sens[3]; float accel_scale[3], gyro_scale[3]; int valid; } dm_joycon_calibration;
typedef struct { double q[4], angle[3]; int started; } dm_joycon_fusion;
static inline int16_t dm_joycon_s16(const uint8_t *v) { return (int16_t)((unsigned)v[0] | (unsigned)v[1]<<8); }
static inline int dm_joycon_calibration_scale(dm_joycon_calibration *c) {
    for (int i=0;i<3;i++) {
        int a=(int)c->accel_sens[i]-c->accel_zero[i], g=(int)c->gyro_sens[i]-c->gyro_zero[i];
        if (a<=0 || g<=0) { c->valid=0; return 0; }
        c->accel_scale[i]=4.f/a; c->gyro_scale[i]=(float)(936.0/g/360.0); // G and revolutions/s
    }
    c->valid=1; return 1;
}
static inline int dm_joycon_factory_calibration(dm_joycon_calibration *c, const uint8_t *data, size_t length) {
    memset(c,0,sizeof *c); if (length<24) return 0;
    for (int i=0;i<3;i++) { c->accel_zero[i]=dm_joycon_s16(data+2*i); c->accel_sens[i]=dm_joycon_s16(data+6+2*i); c->gyro_zero[i]=dm_joycon_s16(data+12+2*i); c->gyro_sens[i]=dm_joycon_s16(data+18+2*i); }
    return dm_joycon_calibration_scale(c);
}
static inline void dm_joycon_user_calibration(dm_joycon_calibration *c,const uint8_t *data,size_t length) {
    if (length<20 || data[0]!=0xb2 || data[1]!=0xa1 || !c->valid) return;
    dm_joycon_calibration updated=*c;
    for (int i=0;i<3;i++) { updated.accel_zero[i]=dm_joycon_s16(data+2+2*i); updated.gyro_zero[i]=dm_joycon_s16(data+14+2*i); }
    if (dm_joycon_calibration_scale(&updated)) *c=updated;
}
static inline void dm_joycon_motion(const dm_joycon_calibration *c,int right,const uint8_t raw[12],double dt,dm_joycon_fusion *fusion,dm_motion_state *state) {
    double a[3],g[3];
    for (int i=0;i<3;i++) { a[i]=dm_joycon_s16(raw+2*i)*c->accel_scale[i]; g[i]=(dm_joycon_s16(raw+6+2*i)-c->gyro_zero[i])*c->gyro_scale[i]; }
    // Native Joy-Con sensor axes -> Apple's controller reference frame; right-hand mounting reverses two axes.
    double acceleration[3]={(right?-1:1)*a[1],(right?1:-1)*a[2],a[0]};
    double rotation[3]={(right?1:-1)*g[1],g[0],(right?-1:1)*g[2]};
    double magnitude=sqrt(acceleration[0]*acceleration[0]+acceleration[1]*acceleration[1]+acceleration[2]*acceleration[2]);
    if (!fusion->started) {
        double *q=fusion->q; q[3]=1;
        if (magnitude>0.5 && magnitude<1.5) {
            q[0]=-acceleration[1]/magnitude; q[1]=acceleration[0]/magnitude; q[2]=0; q[3]=1-acceleration[2]/magnitude;
            double norm=sqrt(q[0]*q[0]+q[1]*q[1]+q[3]*q[3]);
            if (norm<1e-6) { q[0]=1; q[1]=q[2]=q[3]=0; } else for(int i=0;i<4;i++)q[i]/=norm;
        }
        fusion->started=1;
    }
    double x=fusion->q[0],y=fusion->q[1],z=fusion->q[2],w=fusion->q[3],omega[3];
    for(int i=0;i<3;i++){omega[i]=rotation[i]*6.283185307179586; fusion->angle[i]+=rotation[i]*dt;}
    // Accelerometer tilt correction only near 1 G; yaw remains gyro-integrated (Joy-Con has no magnetometer).
    if(magnitude>0.8&&magnitude<1.2){
        double measured[3]={acceleration[0]/magnitude,acceleration[1]/magnitude,acceleration[2]/magnitude};
        double expected[3]={-2*(x*z-w*y),-2*(y*z+w*x),-(1-2*(x*x+y*y))};
        omega[0]+=0.5*(measured[1]*expected[2]-measured[2]*expected[1]);
        omega[1]+=0.5*(measured[2]*expected[0]-measured[0]*expected[2]);
        omega[2]+=0.5*(measured[0]*expected[1]-measured[1]*expected[0]);
    }
    double q[4]={x+0.5*dt*(w*omega[0]+y*omega[2]-z*omega[1]),y+0.5*dt*(w*omega[1]+z*omega[0]-x*omega[2]),z+0.5*dt*(w*omega[2]+x*omega[1]-y*omega[0]),w-0.5*dt*(x*omega[0]+y*omega[1]+z*omega[2])};
    double norm=sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3]);for(int i=0;i<4;i++)fusion->q[i]=q[i]/norm;
    double radians[3]={rotation[0]*6.283185307179586,rotation[1]*6.283185307179586,rotation[2]*6.283185307179586};
    dm_motion_convert(state,acceleration,radians,fusion->q);
    for(int i=0;i<3;i++)state->angle[i]=(float)fusion->angle[i];
}
static inline uint64_t dm_joycon_extra_buttons(const uint8_t *report,size_t length) {
    if(length<6)return 0;
    uint64_t b=0;
    if((report[3]|report[5])&0x20)b|=1ull<<16; // SL
    if((report[3]|report[5])&0x10)b|=1ull<<17; // SR
    if(report[4]&0x10)b|=1ull<<18; // Home
    if(report[4]&0x20)b|=1ull<<19; // Capture
    return b;
}
