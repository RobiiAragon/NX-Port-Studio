// Original CMIF bridge for the user friends service. Creator/object contracts:
// libnx friends.c + Switchbrew Friend services; SDK clients use domain objects.
// This is deliberately separate from the legacy zero-output olsc adapter.
#include "nextendo_social.h"
#include <stdatomic.h>
#define SF_FRIEND_OBJECT_MAX 64

typedef struct sf_friend_object {
    _Atomic unsigned refs;
    pthread_mutex_t lock;
    uint64_t completion;
    uint64_t generation;
    int pending, closed;
} sf_friend_object;
typedef struct sf_friend_domain {
    _Atomic unsigned refs;
    pthread_mutex_t lock;
    int creator_live;
    uint32_t next_id;
    struct { uint32_t id; sf_friend_object *object; } objects[SF_FRIEND_OBJECT_MAX];
} sf_friend_domain;
static void sf_friend_object_release(sf_friend_object *object) {
    if (!object || atomic_fetch_sub(&object->refs,1)!=1) return;
    hle_service_event_close(object->completion);
    pthread_mutex_destroy(&object->lock); free(object);
}
static void sf_friend_object_close(sf_friend_object *object) {
    pthread_mutex_lock(&object->lock);
    object->closed=1; object->pending=0; object->generation++;
    hle_signal_system_event_binding(object->completion);
    pthread_mutex_unlock(&object->lock);
}
static sf_friend_domain *sf_friend_domain_new(void) {
    sf_friend_domain *domain=calloc(1,sizeof *domain); if(!domain)return NULL;
    atomic_init(&domain->refs,1); pthread_mutex_init(&domain->lock,NULL);
    domain->creator_live=1;domain->next_id=2;return domain;
}
static void sf_friend_domain_retain(sf_friend_domain *domain) { if(domain)atomic_fetch_add(&domain->refs,1); }
static void sf_friend_domain_release(sf_friend_domain *domain) {
    if(!domain||atomic_fetch_sub(&domain->refs,1)!=1)return;
    for(unsigned i=0;i<SF_FRIEND_OBJECT_MAX;i++)if(domain->objects[i].object) {
        sf_friend_object_close(domain->objects[i].object);sf_friend_object_release(domain->objects[i].object);
    }
    pthread_mutex_destroy(&domain->lock);free(domain);
}
static uint32_t sf_friend_create(sf_friend_domain *domain,uint32_t *id) {
    sf_friend_object *object=calloc(1,sizeof *object);if(!object)return RES_FAIL;
    atomic_init(&object->refs,1);pthread_mutex_init(&object->lock,NULL);
    uint32_t result=hle_service_event_create(&object->completion);
    if(result){sf_friend_object_release(object);return result;}
    pthread_mutex_lock(&domain->lock);
    unsigned i=0;while(i<SF_FRIEND_OBJECT_MAX&&domain->objects[i].object)i++;
    if(!domain->creator_live||i==SF_FRIEND_OBJECT_MAX||!domain->next_id)result=RES_FAIL;
    else { *id=domain->next_id++;domain->objects[i].id=*id;domain->objects[i].object=object; }
    pthread_mutex_unlock(&domain->lock);
    if(result)sf_friend_object_release(object);return result;
}
static sf_friend_object *sf_friend_find(sf_friend_domain *domain,uint32_t id) {
    sf_friend_object *object=NULL;pthread_mutex_lock(&domain->lock);
    for(unsigned i=0;i<SF_FRIEND_OBJECT_MAX;i++)if(domain->objects[i].id==id&&domain->objects[i].object) {
        object=domain->objects[i].object;atomic_fetch_add(&object->refs,1);break;
    }
    pthread_mutex_unlock(&domain->lock);return object;
}
static uint32_t sf_friend_close_object(sf_friend_domain *domain,uint32_t id) {
    sf_friend_object *object=NULL;uint32_t result=RES_FAIL;pthread_mutex_lock(&domain->lock);
    if(id==1&&domain->creator_live){domain->creator_live=0;result=0;}
    else for(unsigned i=0;i<SF_FRIEND_OBJECT_MAX;i++)if(domain->objects[i].id==id&&domain->objects[i].object) {
        object=domain->objects[i].object;domain->objects[i].object=NULL;result=0;break;
    }
    pthread_mutex_unlock(&domain->lock);
    if(object){sf_friend_object_close(object);sf_friend_object_release(object);}return result;
}
static uint32_t sf_u32(const uint8_t *p) { uint32_t value;memcpy(&value,p,4);return value; }
static void sf_put32(uint8_t *p,uint32_t value) { memcpy(p,&value,4); }
typedef struct {
    unsigned type,version,command,object,close;
    const uint8_t *arguments;
    size_t argument_size;
    int descriptors;
} sf_friend_request;
static int sf_friend_parse(const uint8_t *bytes,size_t size,int domain,sf_friend_request *request) {
    if(!bytes||size<0x40||size>0x1000||!domain)return 0;
    uint32_t h0=sf_u32(bytes),h1=sf_u32(bytes+4);
    unsigned type=h0&0xffff;if(type!=4&&type!=6)return 0;
    unsigned nx=h0>>16&15,na=h0>>20&15,nb=h0>>24&15,nw=h0>>28&15;
    size_t cursor=8;
    if(h1>>31) {
        uint32_t special=sf_u32(bytes+cursor);cursor+=4;
        size_t words=(special&1?2:0)+(special>>1&15)+(special>>5&15);
        if(words>(size-cursor)/4)return 0;cursor+=words*4;
    }
    size_t descriptors=nx*8+(na+nb+nw)*12;
    if(descriptors>size-cursor)return 0;cursor+=descriptors;
    size_t words=h1&0x3ff;if(words>(size-cursor)/4)return 0;
    size_t end=cursor+words*4,cm=(cursor+15)&~(size_t)15;
    if(cm>end||end-cm<16)return 0;
    unsigned dtype=bytes[cm],objects=bytes[cm+1],data_size=(unsigned)bytes[cm+2]|(unsigned)bytes[cm+3]<<8;
    uint32_t id=sf_u32(bytes+cm+4);
    if(dtype==2) {
        if(objects||data_size)return 0;
        *request=(sf_friend_request){.type=type,.object=id,.close=1};return 1;
    }
    if(dtype!=1||objects||data_size<16||data_size>end-cm-16)return 0;
    size_t header=cm+16;
    if(sf_u32(bytes+header)!=0x49434653||sf_u32(bytes+header+4)>1)return 0;
    *request=(sf_friend_request){.type=type,.version=sf_u32(bytes+header+4),.command=sf_u32(bytes+header+8),.object=id,
        .arguments=bytes+header+16,.argument_size=data_size-16,.descriptors=nx||na||nb||nw||((h1>>10)&15)||(h1>>31)};
    return 1;
}
static uint32_t sf_friend_reply(uint8_t *bytes,size_t size,const sf_friend_request *request,
    uint32_t result,const void *output,size_t output_size,uint32_t object,uint32_t copy_handle) {
    size_t raw=copy_handle?16:8,cm=(raw+15)&~(size_t)15;
    size_t end=cm+16+16+output_size+(object?4:0);end=(end+3)&~(size_t)3;
    if(end>size)return 0xe401u;
    memset(bytes,0,size);sf_put32(bytes+4,(uint32_t)((end-raw)/4)|(copy_handle?1u<<31:0));
    if(copy_handle){sf_put32(bytes+8,2);sf_put32(bytes+12,copy_handle);}
    sf_put32(bytes+cm,object?1:0);sf_put32(bytes+cm+16,0x4f434653);
    sf_put32(bytes+cm+20,request->version);sf_put32(bytes+cm+24,result);
    if(output_size)memcpy(bytes+cm+32,output,output_size);
    if(object)sf_put32(bytes+cm+32+output_size,object);
    return 0;
}
static uint32_t sf_friend_ensure(sf_friend_object *object,const uint8_t uid[16]) {
    pthread_mutex_lock(&object->lock);
    if(object->closed||object->pending){pthread_mutex_unlock(&object->lock);return RES_FAIL;}
    object->pending=1;uint64_t generation=++object->generation;
    hle_service_event_clear(object->completion);pthread_mutex_unlock(&object->lock);
    uint32_t result=dm_nextendo_friends_ensure(uid);
    pthread_mutex_lock(&object->lock);
    if(object->closed||object->generation!=generation)result=RES_FAIL;
    else {object->pending=0;hle_signal_system_event_binding(object->completion);}
    pthread_mutex_unlock(&object->lock);return result;
}
static uint32_t sf_friend_send(sf_friend_domain *domain,int converted,uint8_t *bytes,size_t size) {
    sf_friend_request request;
    if(!sf_friend_parse(bytes,size,converted,&request))return 0xe401u;
    if(request.close){uint32_t result=sf_friend_close_object(domain,request.object);memset(bytes,0,size);return result;}
    uint32_t result=RES_FAIL,child=0,handle=0;uint8_t available=0;size_t output_size=0;
    if(request.object==1) {
        if(!request.descriptors&&!request.argument_size&&request.command==0)result=sf_friend_create(domain,&child);
    } else {
        sf_friend_object *object=sf_friend_find(domain,request.object);
        if(object) {
            if(!request.descriptors) {
                if(request.command==0&&!request.argument_size) {
                    pthread_mutex_lock(&object->lock);
                    if(!object->closed)result=hle_service_event_copy(object->completion,&handle);
                    pthread_mutex_unlock(&object->lock);
                }
                else if(request.command==1&&!request.argument_size) {
                    pthread_mutex_lock(&object->lock);
                    if(!object->closed) {
                        if(object->pending){object->generation++;object->pending=0;hle_signal_system_event_binding(object->completion);}
                        result=0;
                    }
                    pthread_mutex_unlock(&object->lock);
                } else if(request.argument_size==16&&request.command==10120) {
                    result=dm_nextendo_friends_available(&available,request.arguments);if(!result)output_size=1;
                } else if(request.argument_size==16&&request.command==10121) {
                    uint8_t uid[16];memcpy(uid,request.arguments,16);result=sf_friend_ensure(object,uid);
                }
            }
            sf_friend_object_release(object);
        }
    }
    // Metadata only: no user IDs, handles, addresses or raw IPC bytes.
    LOG("sf: friend:u object %u command %u result %#x",request.object,request.command,result);
    return sf_friend_reply(bytes,size,&request,result,&available,output_size,child,handle);
}
