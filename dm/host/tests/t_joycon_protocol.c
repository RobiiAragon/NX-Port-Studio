#include "../joycon_protocol.h"
#include <stdio.h>
static int checks,failures;
#define CHECK(c) do{checks++;if(!(c)){failures++;fprintf(stderr,"joycon protocol failed at %d\n",__LINE__);}}while(0)
static void put16(uint8_t *p,int v){p[0]=v;p[1]=v>>8;}
int main(void){
 uint8_t factory[24]={0};for(int i=0;i<3;i++){put16(factory+6+2*i,16384);put16(factory+12+2*i,i+1);put16(factory+18+2*i,937+i);}
 dm_joycon_calibration c;CHECK(dm_joycon_factory_calibration(&c,factory,sizeof factory));CHECK(fabs(c.accel_scale[0]-1.f/4096)<1e-9);CHECK(fabs(c.gyro_scale[0]-1.f/360)<1e-9);
 uint8_t user[20]={0xb2,0xa1};for(int i=0;i<3;i++)put16(user+14+i*2,2+i);dm_joycon_user_calibration(&c,user,sizeof user);CHECK(c.gyro_zero[0]==2&&c.gyro_sens[0]==937);
 user[0]=0;put16(user+14,100);dm_joycon_user_calibration(&c,user,sizeof user);CHECK(c.gyro_zero[0]==2);
 dm_joycon_factory_calibration(&c,factory,sizeof factory);uint8_t raw[12]={0};put16(raw,-4096);for(int i=0;i<3;i++)put16(raw+6+2*i,c.gyro_zero[i]);put16(raw+8,c.gyro_zero[1]+360);
 dm_joycon_fusion left={0},right={0};dm_motion_state l,r;dm_joycon_motion(&c,0,raw,0.005,&left,&l);dm_joycon_motion(&c,1,raw,0.005,&right,&r);
 CHECK(l.acc[2]==-1&&fabs(l.gyro[0]+1)<1e-6);CHECK(r.acc[2]==-1&&fabs(r.gyro[0]-1)<1e-6);CHECK(fabs(l.angle[0]+0.005)<1e-6);
 CHECK(isfinite(l.dir[0])&&fabs(l.dir[0]-1)<1e-4);
 uint8_t report[49]={0x30};report[3]=0x30;report[4]=0x30;CHECK(dm_joycon_extra_buttons(report,sizeof report)==(15ull<<16));CHECK(!dm_joycon_extra_buttons(report,2));
 memset(factory,0xff,sizeof factory);CHECK(!dm_joycon_factory_calibration(&c,factory,sizeof factory));CHECK(!dm_joycon_factory_calibration(&c,factory,12));
 printf("Joy-Con protocol: %d checks, %d failed\n",checks,failures);return failures!=0;
}
