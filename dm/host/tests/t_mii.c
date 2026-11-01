// Original synthetic records only: no console database, firmware or Mii export.
#include "../hle.h"
#undef HLE_FORCE
#undef HLE_FORCE_WAIT
#define HLE_FORCE(name, why, ret, cname, ...) static ret cname(__VA_ARGS__)
#define HLE_FORCE_WAIT HLE_FORCE
#include "../hle_mii.c"
#include <assert.h>
#include <fcntl.h>
#include <sys/wait.h>

static unsigned checks;
static int waits;
#define CHECK(c) do { ++checks; if (!(c)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c); abort(); } } while (0)
uint64_t dm_entropy64(void) { static uint64_t n=100; return ++n; }
void dm_guest_host_wait_begin(void) { ++waits; }
void dm_guest_host_wait_end(void) { --waits; assert(waits>=0); }
void dm_applet_enter(const char *name) { (void)name; }
void dm_applet_leave(void) {}
static dm_mii_charinfo fixture(unsigned index) {
    dm_mii_charinfo c={0}; c.create_id[0]=(uint8_t)(index+1); c.create_id[8]=0x80;
    c.create_id[6]=0x10; // Valid non-v4 CreateId must survive unchanged.
    c.nickname[0]='F'; c.nickname[1]=(uint16_t)('A'+index%26); c.eyebrow_y=3; return c;
}
static void write_file(const char *path,const void *data,size_t n) {
    int fd=open(path,O_WRONLY|O_CREAT|O_TRUNC,0600); CHECK(fd>=0); CHECK(write(fd,data,n)==(ssize_t)n); CHECK(!close(fd));
}
static size_t read_file(const char *path,void *data,size_t n) {
    int fd=open(path,O_RDONLY); CHECK(fd>=0); ssize_t got=read(fd,data,n); CHECK(got>=0); close(fd); return (size_t)got;
}
static void append_crc(uint8_t *p,size_t n) { // Independent fixture encoder, polynomial x^16+x^12+x^5+1.
    unsigned crc=0;
    for (size_t i=0; i<n-2; ++i) { crc^=(unsigned)p[i]<<8; for (int j=0; j<8; ++j) crc=(crc<<1)^((crc&0x8000) ? 0x1021 : 0); }
    p[n-2]=(uint8_t)(crc>>8); p[n-1]=(uint8_t)crc;
}
static void formats(void) {
    dm_mii_charinfo c=fixture(0); dm_mii_collection out={0}, sentinel; memset(&sentinel,0x5a,sizeof sentinel);
    CHECK(dm_mii_charinfo_valid(&c)); CHECK(!dm_mii_decode(&c,sizeof c,&out)); CHECK(out.count==1 && !memcmp(out.entries,&c,sizeof c));
    c.create_id[8]=0xc0; CHECK(!dm_mii_charinfo_valid(&c)); c=fixture(0);
    c.nickname[10]='x'; CHECK(!dm_mii_charinfo_valid(&c)); c=fixture(0);
    c.nickname[1]=0; c.nickname[2]='X'; CHECK(!dm_mii_charinfo_valid(&c)); c=fixture(0);
    c.nickname[0]=0xd800; CHECK(!dm_mii_charinfo_valid(&c)); c.nickname[1]=0xdc00; CHECK(dm_mii_charinfo_valid(&c)); c=fixture(0);
    c.eyebrow_y=2; CHECK(!dm_mii_charinfo_valid(&c)); c=fixture(0);
    c.hair_type=132; CHECK(!dm_mii_charinfo_valid(&c)); c=fixture(0);
    c.mole_y=31; CHECK(!dm_mii_charinfo_valid(&c)); c=fixture(0);
    c.reserved=1; CHECK(!dm_mii_charinfo_valid(&c));
    uint8_t store[68]={0}; store[0]=42; store[1]=127|128; store[2]=100|128; store[3]=3|128; store[4]=2|128;
    store[9]=25|(2<<6); store[10]=20|(3<<6); store[11]=17|(5<<5); store[12]=7|(4<<5);
    store[13]=12|(3<<5); store[14]=15|(6<<5); store[15]=16|(5<<5); store[16]=14|(7<<5);
    store[17]=18|(6<<5); store[18]=16|(7<<5); store[19]=30; store[20]=19;
    store[21]=11|(10<<4); store[22]=8|(9<<4); store[23]=10|(12<<4);
    store[24]=8|(11<<4); store[25]=12|(15<<4); store[26]=8|(7<<4); store[27]=6|(8<<4);
    store[28]='S'; c=fixture(8); memcpy(store+48,c.create_id,16); append_crc(store,66);
    CHECK(!dm_mii_decode(store,sizeof store,&out));
    c=out.entries[0]; CHECK(c.hair_type==42 && c.height==127 && c.build==100 && c.gender==1 && c.type==1);
    CHECK(c.eyebrow_y==18 && c.glass_type==19 && c.mole_type==1 && c.mole_y==30 && c.mouth_aspect==6);
    CHECK(c.eye_rotate==7 && c.eye_aspect==6 && c.nose_scale==8 && c.mouth_scale==7 && c.nickname[0]=='S');
    CHECK(!memcmp(c.create_id,store+48,16));
    store[28]^=1; out=sentinel; CHECK(dm_mii_decode(store,sizeof store,&out)==DM_MII_CHECKSUM); CHECK(!memcmp(&out,&sentinel,sizeof out)); store[28]^=1;
    uint8_t db[6808]={ 'N','F','D','B' }; memcpy(db+4,store,68); db[6804]=1; db[6805]=1; append_crc(db,sizeof db);
    CHECK(!dm_mii_decode(db,sizeof db,&out) && out.count==1); CHECK(!memcmp(out.entries,&c,sizeof c));
    db[6805]=101; append_crc(db,sizeof db); CHECK(dm_mii_decode(db,sizeof db,&out)==DM_MII_INVALID);
    db[6805]=2; memcpy(db+4+68,store,68); append_crc(db,sizeof db); CHECK(dm_mii_decode(db,sizeof db,&out)==DM_MII_INVALID); // Duplicate IDs.
    CHECK(dm_mii_decode("NFIF",4,&out)==DM_MII_UNSUPPORTED); CHECK(dm_mii_decode(store,48,&out)==DM_MII_UNSUPPORTED);
    for (int i=0; i<6; ++i) { mii_default(&c,i>=3,i); CHECK(dm_mii_charinfo_valid(&c)); CHECK(dm_mii_decode(&c,sizeof c,&out)==DM_MII_INVALID); }
    // Every truncation is rejected and output remains untouched on failure.
    c=fixture(0);
    for (size_t n=0; n<sizeof c; ++n) { out=sentinel; int r=dm_mii_decode(&c,n,&out); CHECK(r!=0); CHECK(!memcmp(&out,&sentinel,sizeof out)); }
}
static void persistence(const char *dir) {
    char src[PATH_MAX], db[PATH_MAX]; snprintf(src,sizeof src,"%s/input.charinfo",dir); snprintf(db,sizeof db,"%s/nested/library.dmii",dir);
    dm_mii_collection out={0}; dm_mii_import_result result; dm_mii_charinfo a=fixture(0),b=fixture(1);
    CHECK(!dm_mii_read(db,&out) && !out.count); CHECK(dm_mii_inspect_file(db,&out)==DM_MII_NOT_FOUND);
    write_file(src,&a,sizeof a); CHECK(!dm_mii_import_file(db,src,&result)); CHECK(result.added==1 && result.total==1);
    CHECK(!dm_mii_read(db,&out) && out.count==1 && !memcmp(out.entries,&a,sizeof a));
    uint8_t original[9000],after[9000]; size_t bytes=read_file(db,original,sizeof original);
    CHECK(bytes==104 && !memcmp(original,"DMII\1\0\130\0",8));
    CHECK(!dm_mii_import_file(db,src,&result) && result.unchanged==1 && !result.added && !result.replaced);
    CHECK(read_file(db,after,sizeof after)==bytes && !memcmp(after,original,bytes));
    a.height=72; write_file(src,&a,sizeof a); CHECK(!dm_mii_import_file(db,src,&result) && result.replaced==1 && result.total==1);
    write_file(src,&b,sizeof b); CHECK(!dm_mii_import_file(db,src,&result) && result.added==1 && result.total==2);
    CHECK(!dm_mii_read(db,&out) && !memcmp(out.entries,&a,sizeof a) && !memcmp(out.entries+1,&b,sizeof b));
    bytes=read_file(db,original,sizeof original); b.create_id[8]=0; write_file(src,&b,sizeof b);
    CHECK(dm_mii_import_file(db,src,NULL)==DM_MII_INVALID); CHECK(read_file(db,after,sizeof after)==bytes && !memcmp(after,original,bytes));
    original[bytes-1]^=1; write_file(db,original,bytes); CHECK(dm_mii_read(db,&out)==DM_MII_CHECKSUM);
    b=fixture(1); write_file(src,&b,sizeof b); CHECK(dm_mii_import_file(db,src,NULL)==DM_MII_CHECKSUM);
    CHECK(read_file(db,after,sizeof after)==bytes && !memcmp(after,original,bytes));
    CHECK(!dm_mii_clear(db));
    for (unsigned i=0; i<100; ++i) { a=fixture(i); write_file(src,&a,sizeof a); CHECK(!dm_mii_import_file(db,src,NULL)); }
    a=fixture(100); write_file(src,&a,sizeof a); CHECK(dm_mii_import_file(db,src,NULL)==DM_MII_FULL);
    CHECK(!dm_mii_read(db,&out) && out.count==100); CHECK(!dm_mii_remove(db,out.entries[20].create_id));
    CHECK(!dm_mii_read(db,&out) && out.count==99 && out.entries[20].create_id[0]==22);
    CHECK(!dm_mii_clear(db));
    for (unsigned i=0; i<8; ++i) {
        pid_t child=fork(); CHECK(child>=0);
        if (!child) { char input[PATH_MAX]; snprintf(input,sizeof input,"%s/child%u.charinfo",dir,i); a=fixture(i); write_file(input,&a,sizeof a); _exit(dm_mii_import_file(db,input,NULL)!=0); }
    }
    for (unsigned i=0; i<8; ++i) { int status; CHECK(wait(&status)>0 && WIFEXITED(status) && !WEXITSTATUS(status)); }
    CHECK(!dm_mii_read(db,&out) && out.count==8); // No lost writer between processes.
}
static void seeding(const char *dir) {
    char db[PATH_MAX],seed[PATH_MAX],current[PATH_MAX],lock[PATH_MAX];
    snprintf(db,sizeof db,"%s/seeded.dmii",dir); snprintf(seed,sizeof seed,"%s/seed.charinfo",dir);
    snprintf(current,sizeof current,"%s/new.charinfo",dir); snprintf(lock,sizeof lock,"%s.lock",db);
    dm_mii_charinfo a=fixture(42),b=a; b.height=77; dm_mii_collection out;
    write_file(seed,&a,sizeof a); write_file(current,&b,sizeof b);
    CHECK(!dm_mii_seed_if_missing(db,seed)); CHECK(!dm_mii_read(db,&out) && out.count==1 && !memcmp(out.entries,&a,sizeof a));
    CHECK(!dm_mii_import_file(db,current,NULL)); CHECK(!dm_mii_seed_if_missing(db,seed));
    CHECK(!dm_mii_read(db,&out) && !memcmp(out.entries,&b,sizeof b));
    CHECK(!dm_mii_clear(db)); CHECK(!dm_mii_seed_if_missing(db,seed)); CHECK(!dm_mii_read(db,&out) && !out.count);
    CHECK(!unlink(db));
    for (unsigned i=0; i<9; ++i) {
        pid_t child=fork(); CHECK(child>=0);
        if (!child) _exit((i==4 ? dm_mii_import_file(db,current,NULL) : dm_mii_seed_if_missing(db,seed))!=0);
    }
    for (unsigned i=0; i<9; ++i) { int status; CHECK(wait(&status)>0 && WIFEXITED(status) && !WEXITSTATUS(status)); }
    CHECK(!dm_mii_read(db,&out) && out.count==1 && !memcmp(out.entries,&b,sizeof b));
    CHECK(!unlink(lock)); CHECK(!mkfifo(lock,0600));
    CHECK(dm_mii_import_file(db,current,NULL)==DM_MII_IO); CHECK(dm_mii_seed_if_missing(db,seed)==DM_MII_IO);
    CHECK(!unlink(lock)); CHECK(!symlink(current,lock)); CHECK(dm_mii_import_file(db,current,NULL)==DM_MII_IO);
    CHECK(!dm_mii_read(db,&out) && !memcmp(out.entries,&b,sizeof b));
}
static void services(const char *dir) {
    char src[PATH_MAX],db[PATH_MAX]; snprintf(src,sizeof src,"%s/service.charinfo",dir); snprintf(db,sizeof db,"%s/service.dmii",dir);
    setenv("DM_MII_DATABASE",db,1); unsetenv("DM_MII_SEED");
    uint64_t object=0, other=0; CHECK(h_mii_Init(&object)==0 && !waits); CHECK(h_mii_Init(&other)==0);
    CHECK(h_mii_Count(&object,1)==0 && h_mii_Count(&object,2)==6 && h_mii_Count(&object,3)==6);
    CHECK(!h_mii_Updated(&object,1));
    dm_mii_charinfo c=fixture(10); write_file(src,&c,sizeof c); CHECK(!dm_mii_import_file(db,src,NULL));
    CHECK(h_mii_Count(&object,1)==1 && h_mii_Count(&object,3)==7);
    CHECK(!h_mii_Updated(&object,2)); CHECK(h_mii_Updated(&object,1) && !h_mii_Updated(&object,1)); CHECK(h_mii_Updated(&other,3));
    struct { dm_mii_charinfo info; uint32_t source; } entries[8]; memset(entries,0xa5,sizeof entries); int count=-1;
    CHECK(!h_mii_GetE(&object,&count,entries,8,3) && count==7);
    CHECK(entries[0].source==0 && !memcmp(&entries[0].info,&c,sizeof c));
    for (int i=1; i<7; ++i) CHECK(entries[i].source==1 && dm_mii_charinfo_valid(&entries[i].info));
    CHECK(entries[7].source==0xa5a5a5a5); // No writes past actual count.
    CHECK(!h_mii_Get(&object,&count,NULL,0,3) && count==0);
    CHECK(h_mii_Get(&object,&count,NULL,1,3)!=0 && h_mii_Get(&object,&count,entries,-1,3)!=0);
    CHECK(h_mii_Get(&object,NULL,entries,1,3)!=0 && h_mii_Get(&object,&count,entries,1,4)!=0);
    int index=-1; CHECK(!h_mii_Index(&object,&index,&c) && index==0);
    c.height=2; CHECK(!h_mii_Latest(&object,&c,1) && c.height==0);
    c=fixture(99); CHECK(h_mii_Index(&object,&index,&c)==MII_RES_NOT_FOUND && index==-1);
    c=fixture(11); c.type=1; write_file(src,&c,sizeof c); CHECK(!dm_mii_import_file(db,src,NULL)); CHECK(h_mii_Count(&object,1)==1);
    CHECK(h_mii_Format(&object)==MII_RES_TEST_MODE); // A game cannot silently erase the shared user library.
    h_mii_Fin(&object); CHECK(!h_mii_Avail(&object)); CHECK(h_mii_Avail(&other)); h_mii_Fin(&other); CHECK(!mii_sessions && !waits);
    CHECK(object==0 && other==0); // SDK destructor never receives a fake service pointer.
}
int main(void) {
    char dir[]="/private/tmp/dm-mii-XXXXXX"; CHECK(mkdtemp(dir));
    formats(); persistence(dir); seeding(dir); services(dir);
    // Fixture files are private and small; remove exactly this newly-created tree.
    char command[PATH_MAX]; snprintf(command,sizeof command,"/bin/rm -rf '%s'",dir); CHECK(!system(command));
    printf("Mii: %u checks passed (validated formats/CRC/IDs, atomic persistence, concurrent writers, native service source/count/lifetime).\n",checks); return 0;
}
