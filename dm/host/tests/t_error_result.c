// Exercise the registered applet hook with read-only objects ending at a guard
// page: default/unknown tags must never touch their nonexistent payload.
#include "../hle_error.c"
#include <mach-o/getsect.h>
#include <sys/mman.h>
#include <unistd.h>

static unsigned entered, left, checks, failed;
#define CHECK(c, text) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s\n",text); } } while (0)
void dm_applet_enter(const char *name) { entered++; CHECK(!strcmp(name,"error"),"same error-applet focus scope"); }
void dm_applet_leave(void) { left++; }
extern const struct mach_header_64 _mh_execute_header;
static void (*show)(const void *);
static void capture(const void *variant, char *out, size_t capacity) {
    FILE *stream = tmpfile(); if (!stream) abort();
    fflush(stderr); int saved = dup(STDERR_FILENO); if (saved < 0 || dup2(fileno(stream),STDERR_FILENO) < 0) abort();
    show(variant); fflush(stderr);
    if (fseek(stream,0,SEEK_SET)) abort();
    size_t count = fread(out,1,capacity-1,stream); out[count] = 0;
    if (dup2(saved,STDERR_FILENO) < 0) abort();
    close(saved); fclose(stream);
    CHECK(entered == left,"applet scope balances on every logging path");
}
int main(void) {
    unsigned long size = 0; unsigned matches = 0;
    const hle_force_ent *hooks = (const hle_force_ent *)getsectiondata(&_mh_execute_header,"__DATA","swforce",&size);
    for (size_t i = 0; hooks && i < size / sizeof *hooks; i++)
        if (!strcmp(hooks[i].name,"_ZN2nn3err9ShowErrorERKNS0_18ErrorResultVariantE")) { show = hooks[i].fn; matches++; }
    CHECK(matches == 1 && show,"exactly one registered variant applet hook"); if (!show) return 1;
    long page = sysconf(_SC_PAGESIZE); if (page < 16) abort();
    uint8_t *region = mmap(NULL,(size_t)page*2,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);
    if (region == MAP_FAILED || mprotect(region+page,(size_t)page,PROT_NONE)) abort();
    char output[512]; uint32_t tag = 0;
    uint8_t *object = region+page-4;
    memcpy(object,&tag,4); if (mprotect(region,(size_t)page,PROT_READ)) abort();
    capture(object,output,sizeof output);
    CHECK(strstr(output,"tag=0 (no decoded payload)") && !strstr(output,"result=") && !strstr(output,"code="),"default four-byte object reads no payload");
    if (mprotect(region,(size_t)page,PROT_READ|PROT_WRITE)) abort();
    tag = UINT32_MAX; memcpy(object,&tag,4); if (mprotect(region,(size_t)page,PROT_READ)) abort();
    capture(object,output,sizeof output);
    CHECK(strstr(output,"tag=4294967295 (no decoded payload)") && !strstr(output,"result=") && !strstr(output,"code="),"unknown tag reads only the four-byte discriminator");
    if (mprotect(region,(size_t)page,PROT_READ|PROT_WRITE)) abort();
    object = region+page-8; tag = 1; uint32_t result = 0x234abcd;
    memcpy(object,&tag,4); memcpy(object+4,&result,4); if (mprotect(region,(size_t)page,PROT_READ)) abort();
    capture(object,output,sizeof output);
    CHECK(strstr(output,"tag=1 result=0x0234abcd"),"Result logs its full numeric value at the page boundary");
    if (mprotect(region,(size_t)page,PROT_READ|PROT_WRITE)) abort();
    object = region+page-12; tag = 2; uint64_t code = (uint64_t)123 << 32 | 2618;
    memcpy(object,&tag,4); memcpy(object+4,&code,8); if (mprotect(region,(size_t)page,PROT_READ)) abort();
    capture(object,output,sizeof output);
    CHECK(strstr(output,"tag=2 code=2618-0123"),"unaligned packed ErrorCode is decoded without reading past its boundary");
    capture(NULL,output,sizeof output);
    CHECK(strstr(output,"ErrorResultVariant): null") && !strstr(output,"0x"),"null logs no pointer or payload");
    uint8_t unaligned[16] = {0}, saved[16]; tag = 1; result = UINT32_MAX;
    memcpy(unaligned+1,&tag,4); memcpy(unaligned+5,&result,4); memcpy(saved,unaligned,sizeof saved);
    capture(unaligned+1,output,sizeof output);
    CHECK(strstr(output,"result=0xffffffff") && !memcmp(unaligned,saved,sizeof saved),"unaligned Result is read without mutating the object");
    tag = 2; code = UINT64_MAX; memcpy(unaligned+1,&tag,4); memcpy(unaligned+5,&code,8);
    capture(unaligned+1,output,sizeof output);
    CHECK(strstr(output,"code=4294967295-4294967295"),"ErrorCode components are not truncated");
    tag = 1; result = 0; memcpy(unaligned+1,&tag,4); memcpy(unaligned+5,&result,4);
    capture(unaligned+1,output,sizeof output);
    CHECK(strstr(output,"result=0x00000000"),"zero Result is logged honestly without changing the applet outcome");
    CHECK(entered == 8 && left == 8,"all calls retain the original applet enter/leave behavior");
    munmap(region,(size_t)page*2);
    printf("error result: %u checks, %u failed\n",checks,failed); return failed != 0;
}
