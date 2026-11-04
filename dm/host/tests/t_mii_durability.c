// Original synthetic data and real temporary files. Fault injection is local to
// this test translation unit, never a runtime environment switch or SDK patch.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../mii_database.h"

static unsigned checks;
#define CHECK(c) do { ++checks; if (!(c)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c); abort(); } } while (0)
enum { FAIL_NONE, FAIL_FILE_SYNC, FAIL_RENAME, FAIL_DIRECTORY_SYNC, FAIL_DIRECTORY_OPEN };
static int failure, interrupt_file, interrupt_directory;
static char order[128]; static size_t order_n;
static void note(char c) { CHECK(order_n+1<sizeof order); order[order_n++]=c; order[order_n]=0; }
static int test_fsync(int fd) {
    struct stat st; CHECK(!fstat(fd,&st)); int directory=S_ISDIR(st.st_mode);
    CHECK(directory || S_ISREG(st.st_mode)); note(directory ? 'd' : 'f');
    if ((directory && interrupt_directory) || (!directory && interrupt_file)) {
        if (directory) --interrupt_directory; else --interrupt_file;
        errno=EINTR; return -1;
    }
    if (failure==(directory ? FAIL_DIRECTORY_SYNC : FAIL_FILE_SYNC)) { errno=EIO; return -1; }
    return fsync(fd);
}
static int test_renameat(int from, const char *source, int to, const char *destination) {
    struct stat a,b; CHECK(!fstat(from,&a) && !fstat(to,&b));
    CHECK(S_ISDIR(a.st_mode) && a.st_dev==b.st_dev && a.st_ino==b.st_ino);
    note('r'); if (failure==FAIL_RENAME) { errno=EIO; return -1; }
    return renameat(from,source,to,destination);
}
static int test_open(const char *path, int flags, ...) {
    mode_t mode=0;
    if (flags&O_CREAT) { va_list ap; va_start(ap,flags); mode=(mode_t)va_arg(ap,int); va_end(ap); }
    if ((flags&O_DIRECTORY) && failure==FAIL_DIRECTORY_OPEN) { errno=EACCES; return -1; }
    return open(path,flags,mode);
}
#define fsync test_fsync
#define renameat test_renameat
#define open test_open
#include "../hle_mii_database.c"
#undef fsync
#undef renameat
#undef open
#define main mii_import_main
#include "../../tools/mii_import.c"
#undef main

static void reset(int error) { failure=error; interrupt_file=interrupt_directory=0; order_n=0; order[0]=0; }
static dm_mii_charinfo fixture(unsigned id) {
    dm_mii_charinfo value={0}; value.create_id[0]=(uint8_t)id; value.create_id[6]=0x10; value.create_id[8]=0x80;
    value.nickname[0]='D'; value.nickname[1]='M'; value.eyebrow_y=3; return value;
}
static void source_write(const char *path, const dm_mii_charinfo *value) {
    int fd=open(path,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC,0600); CHECK(fd>=0);
    CHECK(write(fd,value,sizeof *value)==sizeof *value); CHECK(!close(fd));
}
static size_t bytes_read(const char *path, uint8_t bytes[9000]) {
    int fd=open(path,O_RDONLY|O_CLOEXEC); CHECK(fd>=0); ssize_t size=read(fd,bytes,9000);
    CHECK(size>=0 && size<9000); CHECK(!close(fd)); return (size_t)size;
}
static void no_temporaries(const char *directory) {
    DIR *dir=opendir(directory); CHECK(dir); struct dirent *entry;
    while ((entry=readdir(dir))) {
        if (!strncmp(entry->d_name,"library.dmii.",13)) CHECK(!strcmp(entry->d_name,"library.dmii.lock"));
    }
    CHECK(!closedir(dir));
}
static void unchanged(const char *database, const uint8_t *original, size_t count) {
    uint8_t current[9000]; CHECK(bytes_read(database,current)==count && !memcmp(current,original,count));
}
static void failure_boundaries(const char *directory) {
    char database[4096], source[4096]; snprintf(database,sizeof database,"%s/library.dmii",directory);
    snprintf(source,sizeof source,"%s/source.charinfo",directory);
    dm_mii_charinfo a=fixture(1), b=fixture(2); source_write(source,&a);
    dm_mii_import_result result={0}; reset(FAIL_NONE);
    CHECK(dm_mii_import_file(database,source,&result)==DM_MII_OK);
    CHECK(!strcmp(order,"frd") && result.added==1 && result.total==1);
    uint8_t before[9000]; size_t count=bytes_read(database,before);
    CHECK(count==16+sizeof a && !memcmp(before,"DMII\1\0\130\0",8));
    source_write(source,&b);
    for (int error=FAIL_FILE_SYNC; error<=FAIL_DIRECTORY_OPEN; ++error) {
        if (error==FAIL_DIRECTORY_SYNC) continue;
        reset(error); memset(&result,0x5a,sizeof result); dm_mii_import_result sentinel=result;
        CHECK(dm_mii_import_file(database,source,&result)==DM_MII_IO);
        CHECK(!memcmp(&result,&sentinel,sizeof result)); unchanged(database,before,count); no_temporaries(directory);
        CHECK(!strcmp(order,error==FAIL_FILE_SYNC ? "f" : error==FAIL_RENAME ? "fr" : ""));
    }
    reset(FAIL_DIRECTORY_SYNC); memset(&result,0xa5,sizeof result); dm_mii_import_result sentinel=result;
    CHECK(dm_mii_import_file(database,source,&result)==DM_MII_COMMIT_UNCERTAIN);
    CHECK(!strcmp(order,"frd") && !memcmp(&result,&sentinel,sizeof result));
    dm_mii_collection loaded; CHECK(!dm_mii_read(database,&loaded) && loaded.count==2);
    CHECK(!memcmp(loaded.entries,&a,sizeof a) && !memcmp(loaded.entries+1,&b,sizeof b));
    no_temporaries(directory);
    // Seeing identical bytes is not a new durability receipt. No-change imports
    // retain their existing API behavior; a future Append must not use this as
    // confirmation of the failed write's barrier.
    reset(FAIL_NONE); CHECK(!dm_mii_import_file(database,source,&result));
    CHECK(!order_n && result.unchanged==1 && !result.added && !result.replaced);
    a.height=22; source_write(source,&a); reset(FAIL_NONE); interrupt_file=interrupt_directory=1;
    CHECK(!dm_mii_import_file(database,source,&result)); CHECK(!strcmp(order,"ffrdd"));
    CHECK(result.replaced==1 && result.total==2); no_temporaries(directory);
    // A different process can acquire the released lock and commit without
    // losing the visible replacement after the earlier uncertain write.
    pid_t child=fork(); CHECK(child>=0);
    if (!child) { dm_mii_charinfo c=fixture(3); source_write(source,&c); reset(FAIL_NONE); _exit(dm_mii_import_file(database,source,NULL)!=DM_MII_OK); }
    int status; CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && !WEXITSTATUS(status));
    CHECK(!dm_mii_read(database,&loaded) && loaded.count==3);
    CHECK(!memcmp(loaded.entries,&a,sizeof a) && !memcmp(loaded.entries+1,&b,sizeof b) && loaded.entries[2].create_id[0]==3);
    reset(FAIL_DIRECTORY_SYNC); CHECK(dm_mii_remove(database,b.create_id)==DM_MII_COMMIT_UNCERTAIN);
    CHECK(!dm_mii_read(database,&loaded) && loaded.count==2 && loaded.entries[1].create_id[0]==3);
    reset(FAIL_DIRECTORY_SYNC); CHECK(dm_mii_clear(database)==DM_MII_COMMIT_UNCERTAIN);
    CHECK(!dm_mii_read(database,&loaded) && !loaded.count); no_temporaries(directory);
    CHECK(!unlink(database)); source_write(source,&a); reset(FAIL_DIRECTORY_SYNC);
    CHECK(dm_mii_seed_if_missing(database,source)==DM_MII_COMMIT_UNCERTAIN);
    CHECK(!dm_mii_read(database,&loaded) && loaded.count==1 && !memcmp(loaded.entries,&a,sizeof a));
    CHECK(strstr(dm_mii_error(DM_MII_COMMIT_UNCERTAIN),"unconfirmed")); no_temporaries(directory);
    // The actual CLI must propagate the distinct error, with no import counts
    // or private records presented as a successful operation.
    b=fixture(4); source_write(source,&b); int output[2]; CHECK(!pipe(output));
    child=fork(); CHECK(child>=0);
    if (!child) {
        close(output[0]); if (dup2(output[1],STDOUT_FILENO)<0) _exit(99); close(output[1]);
        reset(FAIL_DIRECTORY_SYNC); char *argv[]={"mii-import","import",database,source,NULL};
        int error=mii_import_main(4,argv); fflush(stdout); _exit(error);
    }
    CHECK(!close(output[1])); char json[256]={0}; size_t size=0; ssize_t got;
    while ((got=read(output[0],json+size,sizeof json-size-1))>0) size+=(size_t)got;
    CHECK(got==0 && !close(output[0]));
    CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==1);
    CHECK(!strcmp(json,"{\"code\":-7,\"added\":0,\"replaced\":0,\"unchanged\":0,\"records\":[]}\n"));
    CHECK(!dm_mii_read(database,&loaded) && loaded.count==2 && loaded.entries[1].create_id[0]==4);
    no_temporaries(directory);
    CHECK(!unlink(database)); CHECK(!unlink(source));
    CHECK(strlen(database)+5<sizeof database); strcat(database,".lock"); CHECK(!unlink(database));
}
int main(void) {
    char directory[]="/private/tmp/dm-mii-durability-XXXXXX"; CHECK(mkdtemp(directory));
    failure_boundaries(directory);
    // An unqualified relative filename uses '.', not an empty directory name.
    int saved=open(".",O_RDONLY|O_DIRECTORY|O_CLOEXEC); CHECK(saved>=0); CHECK(!chdir(directory));
    reset(FAIL_NONE); CHECK(!dm_mii_clear("library.dmii") && !strcmp(order,"frd"));
    CHECK(!unlink("library.dmii") && !unlink("library.dmii.lock")); CHECK(!fchdir(saved)); CHECK(!close(saved));
    CHECK(!rmdir(directory)); printf("Mii durability: %u checks passed\n",checks); return 0;
}
