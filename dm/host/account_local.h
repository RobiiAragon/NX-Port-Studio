// Local account identity shared by services. This does not grant an online ID.
#pragma once
#include <stddef.h>
#include <string.h>
int dm_account_uid_exists(const void *uid);
int dm_account_copy_uid(void *output);
// NN's 33-byte nickname holds at most 32 complete UTF-8 bytes and a terminator.
// A malformed prefix is rejected; an explicit empty local override stays empty.
static inline int dm_account_copy_nickname(char output[33],const char *text) {
    if(!output)return 0;
    memset(output,0,33);if(!text)return 0;
    const unsigned char *p=(const unsigned char *)text;size_t n=0;
    while(n<32 && p[n]) {
        unsigned c=p[n],width=c<0x80 ? 1 : c>=0xc2 && c<=0xdf ? 2 : c>=0xe0 && c<=0xef ? 3 : c>=0xf0 && c<=0xf4 ? 4 : 0;
        if(!width)goto invalid;
        if(width>32-n)break;
        for(unsigned i=1;i<width;i++)if((p[n+i]&0xc0)!=0x80)goto invalid;
        if((c==0xe0 && p[n+1]<0xa0) || (c==0xed && p[n+1]>=0xa0) ||
           (c==0xf0 && p[n+1]<0x90) || (c==0xf4 && p[n+1]>=0x90))goto invalid;
        memcpy(output+n,text+n,width);n+=width;
    }
    return 1;
invalid:
    memset(output,0,33);return 0;
}
