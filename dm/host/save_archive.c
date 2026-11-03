// ZIP is a file interchange format, not a Horizon encrypted save filesystem.
// JKSV's optional .nx_save_meta.bin contract is independently represented from
// its public SaveMetaData declaration; no JKSV implementation is included.
#include "save_archive.h"
#include "../third_party/libarchive-headers/archive.h"
#include "../third_party/libarchive-headers/archive_entry.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/xattr.h>
#include <unistd.h>

#define SAVE_META ".nx_save_meta.bin"
#define META_XATTR "org.nxportstudio.jksv-metadata"
#define JOB_XATTR "org.nxportstudio.jksv-applied-job"
#define MAX_BYTES (UINT64_C(8) * 1024 * 1024 * 1024)
#define MAX_FILE_BYTES (UINT64_C(2) * 1024 * 1024 * 1024)
enum { BAD_ZIP = 20001, BAD_PATH, BAD_META, WRONG_TITLE, WRONG_TYPE,
       TOO_LARGE, UNSAFE_FILE, CHANGED_SOURCE, EMPTY_SAVE, PENDING_IMPORT };

static uint64_t le64(const unsigned char *p) {
    uint64_t n=0; for (unsigned i=0;i<8;i++) n|=(uint64_t)p[i]<<(8*i); return n;
}
static int meta_valid(const unsigned char *p, size_t n) {
    return n==DM_SAVE_META_BYTES && !memcmp(p,"JKSV",4) && p[4]==1 &&
        le64(p+5) && (p[37]==1 || p[37]==3);
}
static int same_stat(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino &&
        a->st_size==b->st_size && a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec &&
        a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec &&
        a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
static int path_valid(const char *p) {
    if (!p || !*p || *p=='/' || strlen(p)>=PATH_MAX) return 0;
    size_t component=0; unsigned depth=1;
    for (const unsigned char *s=(const unsigned char *)p;;++s) {
        if (*s && (*s<32 || *s==127 || *s=='\\' || *s==':')) return 0;
        if (*s=='/' || !*s) {
            const unsigned char *start=s-component;
            if (!component || component>255 || (component==1 && start[0]=='.') ||
                (component==2 && start[0]=='.' && start[1]=='.')) return 0;
            if (!*s) return 1;
            if (++depth>64) return 0;
            component=0;
        } else ++component;
    }
}
// dup() shares a directory stream offset. Each independent enumeration needs
// a fresh open description, including after the staging-empty check.
static DIR *open_directory(int parent) {
    int fd=openat(parent,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC);if(fd<0)return NULL;
    DIR *dir=fdopendir(fd);if(!dir)close(fd);return dir;
}
// The guest filesystem stores case-colliding names using this established
// attribute. ZIP entries always use guest names, never private physical aliases.
#define GUEST_NAME_XATTR "org.d2rmobile.guest-name"
static int guest_component(int fd,const char *physical,char out[256]) {
    strlcpy(out,physical,256);
    if(!strncmp(physical,".dm-case-",9)){
        ssize_t n=fgetxattr(fd,GUEST_NAME_XATTR,out,255,0,0);
        if(n<0){if(errno!=ENOATTR)return errno;strlcpy(out,physical,256);}
        else {if(!n||memchr(out,0,(size_t)n))return BAD_PATH;out[n]=0;}
    }
    return path_valid(out)&&!strchr(out,'/')?0:BAD_PATH;
}
static int resolve_child(int parent,const char *wanted,char physical[256],int *exists) {
    *exists=0;DIR *dir=open_directory(parent);if(!dir)return errno;
    struct dirent *entry;int error=0;
    while((entry=readdir(dir))){
        if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        int fd=openat(parent,entry->d_name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
        if(fd<0){error=errno;break;}
        char guest[256];error=guest_component(fd,entry->d_name,guest);close(fd);if(error)break;
        if(!strcmp(guest,wanted)){strlcpy(physical,entry->d_name,256);*exists=1;break;}
    }
    closedir(dir);if(error||*exists)return error;
    strlcpy(physical,wanted,256);struct stat st;
    for(unsigned i=0;;i++){
        if(fstatat(parent,physical,&st,AT_SYMLINK_NOFOLLOW)){return errno==ENOENT?0:errno;}
        if(i>=DM_SAVE_ZIP_MAX_ENTRIES)return TOO_LARGE;
        snprintf(physical,256,".dm-case-%u",i+1);
    }
}
static int directory_child(int parent,const char *wanted,int *error) {
    char physical[256];int exists;
    *error=resolve_child(parent,wanted,physical,&exists);if(*error)return -1;
    if(!exists&&mkdirat(parent,physical,0700)){*error=errno;return -1;}
    int fd=openat(parent,physical,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0){*error=errno;return -1;}
    if(!exists&&strcmp(physical,wanted)&&fsetxattr(fd,GUEST_NAME_XATTR,wanted,strlen(wanted),0,0)){*error=errno;close(fd);return -1;}
    return fd;
}
// Each ancestor is an owned descriptor; preserve Horizon's case-sensitive
// names even on the default case-insensitive APFS volume.
static int parent_fd(int root,char *path,char **leaf,int *error) {
    int fd=dup(root);if(fd<0){*error=errno;return -1;}
    char *part=path,*slash;
    while((slash=strchr(part,'/'))){
        *slash=0;int next=directory_child(fd,part,error);close(fd);if(next<0)return -1;
        fd=next;part=slash+1;
    }
    *leaf=part;return fd;
}
static int write_all(int fd,const void *data,size_t n) {
    const unsigned char *p=data;
    while(n){ssize_t k=write(fd,p,n);if(k<0&&errno==EINTR)continue;if(k<=0)return errno?errno:EIO;p+=k;n-=(size_t)k;}
    return 0;
}
static int read_entry(struct archive *a,int fd,uint64_t size,unsigned char *meta) {
    unsigned char buffer[65536];uint64_t total=0;
    for (;;) {
        la_ssize_t n=archive_read_data(a,buffer,sizeof buffer);
        if(n<0)return BAD_ZIP;if(!n)break;
        if((uint64_t)n>size-total)return BAD_ZIP;
        if(meta)memcpy(meta+total,buffer,(size_t)n);
        else {int error=write_all(fd,buffer,(size_t)n);if(error)return error;}
        total+=(uint64_t)n;
    }
    return total==size?0:BAD_ZIP;
}
static int directory_empty(int fd) {
    DIR *d=open_directory(fd);if(!d)return 0;int empty=1;struct dirent *e;
    while((e=readdir(d)))if(strcmp(e->d_name,".")&&strcmp(e->d_name,"..")){empty=0;break;}
    closedir(d);return empty;
}
int dm_save_zip_extract(const char *zip,const char *staging,uint64_t title,int expected_type,dm_save_archive_info *out) {
    if(!zip||!staging||!out||!title||(expected_type!=-1&&expected_type!=1&&expected_type!=3))return EINVAL;
    dm_save_archive_info info={.save_type=-1};int error=0,fd=-1,root=-1;struct archive *a=NULL;struct stat before,after;
    fd=open(zip,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return errno;
    if(fstat(fd,&before)||!S_ISREG(before.st_mode)){error=UNSAFE_FILE;goto done;}
    if(before.st_size<0||(uint64_t)before.st_size>MAX_BYTES){error=TOO_LARGE;goto done;}
    root=open(staging,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(root<0){error=errno;goto done;}
    if(!directory_empty(root)){error=EEXIST;goto done;}
    a=archive_read_new();if(!a){error=ENOMEM;goto done;}
    if(archive_read_support_format_zip_seekable(a)!=ARCHIVE_OK || archive_read_open_fd(a,fd,65536)!=ARCHIVE_OK){error=BAD_ZIP;goto done;}
    struct archive_entry *entry;unsigned entries=0;int next;
    while((next=archive_read_next_header(a,&entry))==ARCHIVE_OK) {
        if(++entries>DM_SAVE_ZIP_MAX_ENTRIES){error=TOO_LARGE;break;}
        // libarchive canonicalizes ZIP's Windows separators. Validate the
        // resulting relative path; traversal and aliases remain rejected.
        const char *name=archive_entry_pathname_utf8(entry);char path[PATH_MAX];
        if(!name||strlen(name)>=sizeof path){error=BAD_PATH;break;}
        strcpy(path,name);size_t length=strlen(path);mode_t type=archive_entry_filetype(entry);
        if(type==AE_IFDIR && length && path[length-1]=='/')path[--length]=0;
        if(!path_valid(path)){error=BAD_PATH;break;}
        if(archive_entry_symlink(entry)||archive_entry_hardlink(entry)||archive_entry_is_encrypted(entry)||
            (type!=AE_IFREG&&type!=AE_IFDIR)){error=UNSAFE_FILE;break;}
        la_int64_t size=archive_entry_size(entry);
        if(!archive_entry_size_is_set(entry)||size<0||(uint64_t)size>MAX_FILE_BYTES||
            (uint64_t)size>MAX_BYTES-info.bytes){error=TOO_LARGE;break;}
        if(!strcmp(path,SAVE_META)) {
            if(type!=AE_IFREG||info.has_metadata||size!=DM_SAVE_META_BYTES){error=BAD_META;break;}
            error=read_entry(a,-1,(uint64_t)size,info.metadata);if(error)break;
            if(!meta_valid(info.metadata,sizeof info.metadata)){error=BAD_META;break;}
            info.has_metadata=1;info.title_id=le64(info.metadata+5);info.save_type=info.metadata[37];
            if(info.title_id!=title){error=WRONG_TITLE;break;}
            if(expected_type>=0&&expected_type!=info.save_type){error=WRONG_TYPE;break;}
            continue;
        }
        char *leaf;int parent=parent_fd(root,path,&leaf,&error);
        if(parent<0)break;
        if(type==AE_IFDIR) {
            if(size)error=BAD_ZIP;
            else {int d=directory_child(parent,leaf,&error);if(d>=0)close(d);}
            info.directories++;
        } else {
            char physical[256];int exists=0;
            error=resolve_child(parent,leaf,physical,&exists);
            if(!error&&exists)error=EEXIST;
            int file=error?-1:openat(parent,physical,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
            if(file<0&&!error)error=errno;
            if(file>=0){
                if(strcmp(physical,leaf)&&fsetxattr(file,GUEST_NAME_XATTR,leaf,strlen(leaf),0,0))error=errno;
                if(!error)error=read_entry(a,file,(uint64_t)size,NULL);
                if(!error&&fsync(file))error=errno;close(file);
            }
            info.files++;info.bytes+=(uint64_t)size;
        }
        if(!error&&fsync(parent))error=errno;
        close(parent);if(error)break;
    }
    if(!error&&next!=ARCHIVE_EOF)error=BAD_ZIP;
    if(!error&&!info.files)error=EMPTY_SAVE;
    if(!error&&(fstat(fd,&after)||!same_stat(&before,&after)))error=CHANGED_SOURCE;
    // Metadata travels with the directory's atomic replacement, but is never
    // exposed as a save file to the guest application.
    if(!error&&info.has_metadata&&fsetxattr(root,META_XATTR,info.metadata,sizeof info.metadata,0,0))error=errno;
    if(!error&&fsync(root))error=errno;
done:
    if(a){int r=archive_read_free(a);if(!error&&r!=ARCHIVE_OK)error=BAD_ZIP;}
    if(root>=0)close(root);close(fd);if(!error)*out=info;return error;
}
static int writer_data(struct archive *a,const void *data,size_t size) {
    const unsigned char *p=data;
    while(size){la_ssize_t n=archive_write_data(a,p,size);if(n<=0)return EIO;p+=n;size-=(size_t)n;}
    return 0;
}
static int pack_directory(struct archive *a,int root,const char *prefix,unsigned depth,dm_save_archive_info *info) {
    if(depth>64)return TOO_LARGE;
    DIR *dir=open_directory(root);if(!dir)return errno;int error=0;struct dirent *d;
    char **seen=NULL;size_t seen_n=0;
    while((d=readdir(dir))) {
        if(!strcmp(d->d_name,".")||!strcmp(d->d_name,".."))continue;
        if(info->directories+info->files>=DM_SAVE_ZIP_MAX_ENTRIES){error=TOO_LARGE;break;}
        struct stat before,after;if(fstatat(root,d->d_name,&before,AT_SYMLINK_NOFOLLOW)){error=errno;break;}
        int isdir=S_ISDIR(before.st_mode);
        if(!isdir&&!S_ISREG(before.st_mode)){error=UNSAFE_FILE;break;}
        if(before.st_size<0||(!isdir&&((uint64_t)before.st_size>MAX_FILE_BYTES||(uint64_t)before.st_size>MAX_BYTES-info->bytes))){error=TOO_LARGE;break;}
        int file=openat(root,d->d_name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|(isdir?O_DIRECTORY:0));if(file<0){error=errno;break;}
        if(fstat(file,&after)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino){close(file);error=CHANGED_SOURCE;break;}
        char guest[256],path[PATH_MAX];error=guest_component(file,d->d_name,guest);
        if(!error){
            for(size_t i=0;i<seen_n;i++)if(!strcmp(seen[i],guest)){error=BAD_PATH;break;}
        }
        if(!error){
            char **next=realloc(seen,(seen_n+1)*sizeof *seen);
            if(!next)error=ENOMEM;else{seen=next;seen[seen_n]=strdup(guest);if(!seen[seen_n])error=ENOMEM;else seen_n++;}
        }
        int length=error?-1:snprintf(path,sizeof path,"%s%s%s",prefix,*prefix?"/":"",guest);
        if(!error&&(length<0||(size_t)length>=sizeof path||!path_valid(path)||!strcmp(path,SAVE_META)))error=BAD_PATH;
        if(error){close(file);break;}
        struct archive_entry *entry=archive_entry_new();if(!entry){close(file);error=ENOMEM;break;}
        archive_entry_set_pathname_utf8(entry,path);archive_entry_set_filetype(entry,isdir?AE_IFDIR:AE_IFREG);
        archive_entry_set_perm(entry,isdir?0700:0600);archive_entry_set_size(entry,isdir?0:before.st_size);
        archive_entry_set_mtime(entry,before.st_mtime,0);
        if(archive_write_header(a,entry)!=ARCHIVE_OK)error=EIO;
        archive_entry_free(entry);
        if(!error&&isdir){++info->directories;error=pack_directory(a,file,path,depth+1,info);}
        else if(!error){
            unsigned char buffer[65536];uint64_t left=(uint64_t)before.st_size;
            while(left){ssize_t n=read(file,buffer,left<sizeof buffer?(size_t)left:sizeof buffer);if(n<0&&errno==EINTR)continue;if(n<=0){error=CHANGED_SOURCE;break;}error=writer_data(a,buffer,(size_t)n);if(error)break;left-=(uint64_t)n;}
            if(!error&&(fstat(file,&after)||!same_stat(&before,&after)))error=CHANGED_SOURCE;
            ++info->files;info->bytes+=(uint64_t)before.st_size;
        }
        close(file);if(error)break;
    }
    for(size_t i=0;i<seen_n;i++)free(seen[i]);free(seen);closedir(dir);return error;
}
int dm_save_zip_create(const char *directory,const char *zip,const unsigned char *metadata,size_t metadata_size,dm_save_archive_info *out) {
    if(!directory||!zip||!out||(metadata_size&&!metadata))return EINVAL;
    if(metadata_size&&!meta_valid(metadata,metadata_size))return BAD_META;
    int root=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(root<0)return errno;
    unsigned char original_meta[DM_SAVE_META_BYTES];
    if(!metadata_size){
        ssize_t n=fgetxattr(root,META_XATTR,original_meta,sizeof original_meta,0,0);
        if(n>=0){if(!meta_valid(original_meta,(size_t)n)){close(root);return BAD_META;}metadata=original_meta;metadata_size=(size_t)n;}
        else if(errno!=ENOATTR){int error=errno;close(root);return error;}
    }
    int fd=open(zip,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0){int e=errno;close(root);return e;}
    struct archive *a=archive_write_new();int error=0;dm_save_archive_info info={.save_type=-1};
    if(!a){error=ENOMEM;goto done;}
    if(archive_write_set_format_zip(a)!=ARCHIVE_OK||archive_write_zip_set_compression_deflate(a)!=ARCHIVE_OK||archive_write_open_fd(a,fd)!=ARCHIVE_OK){error=EIO;goto done;}
    error=pack_directory(a,root,"",0,&info);
    if(!error&&!info.files)error=EMPTY_SAVE;
    if(!error&&metadata_size){
        struct archive_entry *entry=archive_entry_new();if(!entry){error=ENOMEM;goto done;}
        archive_entry_set_pathname(entry,SAVE_META);archive_entry_set_filetype(entry,AE_IFREG);archive_entry_set_perm(entry,0600);archive_entry_set_size(entry,(la_int64_t)metadata_size);
        if(archive_write_header(a,entry)!=ARCHIVE_OK)error=EIO;else error=writer_data(a,metadata,metadata_size);
        archive_entry_free(entry);
        if(!error){info.has_metadata=1;memcpy(info.metadata,metadata,metadata_size);info.title_id=le64(metadata+5);info.save_type=metadata[37];}
    }
done:
    if(a){int r=archive_write_close(a);if(!error&&r!=ARCHIVE_OK)error=EIO;r=archive_write_free(a);if(!error&&r!=ARCHIVE_OK)error=EIO;}
    if(!error&&fsync(fd))error=errno;
    close(fd);close(root);if(error)unlink(zip);else *out=info;return error;
}
static int lock_file(const char *directory,const char *name,int exclusive) {
    if(!directory)return -EINVAL;
    int root=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(root<0)return -errno;
    int fd=openat(root,name,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);int error=errno;close(root);
    if(fd<0)return -error;
    struct stat st;
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_nlink!=1){close(fd);return -EINVAL;}
    if(flock(fd,(exclusive?LOCK_EX:LOCK_SH)|LOCK_NB)){error=errno;close(fd);return -error;}
    return fd;
}
int dm_save_archive_lock(const char *directory,int exclusive) { return lock_file(directory,".jksv-access.lock",exclusive); }
int dm_save_archive_replace(const char *staging,const char *destination,int *installed,int *has_previous) {
    if(!staging||!destination||!installed||!has_previous||strlen(staging)>=PATH_MAX||strlen(destination)>=PATH_MAX)return EINVAL;
    *installed=0;*has_previous=0;
    char left[PATH_MAX],right[PATH_MAX];strcpy(left,staging);strcpy(right,destination);
    char *a=strrchr(left,'/'),*b=strrchr(right,'/');
    if(!a||!b||a==left||b==right)return EINVAL;
    *a++=0;*b++=0;
    if(strcmp(left,right)||!path_valid(a)||!path_valid(b)||strchr(a,'/')||strchr(b,'/')||!strcmp(a,b))return EINVAL;
    int root=open(left,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(root<0)return errno;
    struct stat source,target;int error=0,had=0;
    if(fstatat(root,a,&source,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(source.st_mode)){error=EINVAL;goto done;}
    if(!fstatat(root,b,&target,AT_SYMLINK_NOFOLLOW)){if(!S_ISDIR(target.st_mode)){error=EINVAL;goto done;}had=1;}
    else if(errno!=ENOENT){error=errno;goto done;}
    if(renameatx_np(root,a,root,b,had?RENAME_SWAP:RENAME_EXCL)){error=errno;goto done;}
    *installed=1;*has_previous=had;
    if(fsync(root))error=errno;
done:
    close(root);return error;
}
static int slot_valid(const char *slot) { return slot&&(!strcmp(slot,"save")||!strcmp(slot,"save_device")); }
static int joined(char *out,size_t cap,const char *parent,const char *name) {
    int n=snprintf(out,cap,"%s/%s",parent,name);return n<0||(size_t)n>=cap?ENAMETOOLONG:0;
}
static int pending_path(char *out,size_t cap,const char *root,const char *slot) {
    char name[80];snprintf(name,sizeof name,".jksv-pending-%s.zip",slot);return joined(out,cap,root,name);
}
int dm_save_archive_has_pending(const char *root) {
    if(!root)return 0;
    char path[PATH_MAX];struct stat st;
    for(unsigned i=0;i<2;i++)if(!pending_path(path,sizeof path,root,i?"save_device":"save")&&!lstat(path,&st))return 1;
    return 0;
}
// Used only for this operation's unpublished staging directory. After a swap,
// that path contains the previous save and is deliberately never removed.
static void discard_stage(int parent,const char *name) {
    int fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return;DIR *d=open_directory(fd);
    if(d){struct dirent *e;while((e=readdir(d))){
        if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
        struct stat st;
        if(!fstatat(fd,e->d_name,&st,AT_SYMLINK_NOFOLLOW)&&S_ISDIR(st.st_mode))discard_stage(fd,e->d_name);
        else unlinkat(fd,e->d_name,0);
    }closedir(d);}
    close(fd);unlinkat(parent,name,AT_REMOVEDIR);
}
static int import_archive(const char *zip,const char *root,const char *slot,uint64_t title,int expected_type,const unsigned char *job,int held_lease,dm_save_archive_operation *out) {
    if(!zip||!root||!slot_valid(slot)||!out)return EINVAL;
    memset(out,0,sizeof *out);
    int lease=held_lease>=0?held_lease:dm_save_archive_lock(root,1);if(lease<0)return -lease;
    if(!job&&dm_save_archive_has_pending(root)){if(held_lease<0)close(lease);return PENDING_IMPORT;}
    int parent=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC),error=0;
    char stage[PATH_MAX],target[PATH_MAX];int installed=0,previous=0;
    if(parent<0){error=errno;goto done;}
    if((error=joined(stage,sizeof stage,root,".jksv-import-XXXXXX"))||
       (error=joined(target,sizeof target,root,slot)))goto done;
    if(!mkdtemp(stage)){error=errno;goto done;}
    error=dm_save_zip_extract(zip,stage,title,expected_type,&out->info);
    if(!error&&job&&setxattr(stage,JOB_XATTR,job,16,0,0))error=errno;
    if(!error)error=dm_save_archive_replace(stage,target,&installed,&previous);
    out->installed=installed;
    if(!installed){discard_stage(parent,strrchr(stage,'/')+1);goto done;}
    if(previous){
        // A failed backup move leaves the old tree at stage, still retained.
        strlcpy(out->backup_path,stage,sizeof out->backup_path);
        if(!mkdirat(parent,"save-backups",0700)||errno==EEXIST){
            int backups=openat(parent,"save-backups",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if(backups>=0){
                char name[128];snprintf(name,sizeof name,"JKSV-%s-%s",strrchr(stage,'/')+1+13,slot);
                if(!renameatx_np(parent,strrchr(stage,'/')+1,backups,name,RENAME_EXCL)){
                    char directory[PATH_MAX];
                    if(!joined(directory,sizeof directory,root,"save-backups"))joined(out->backup_path,sizeof out->backup_path,directory,name);
                    if(fsync(backups)&&!error)error=errno;
                }
                close(backups);
            }
        }
    }
    if(fsync(parent)&&!error)error=errno;
done:
    if(parent>=0)close(parent);if(held_lease<0)close(lease);return error;
}
int dm_save_archive_import(const char *zip,const char *root,const char *slot,uint64_t title,int expected_type,dm_save_archive_operation *out) {
    return import_archive(zip,root,slot,title,expected_type,NULL,-1,out);
}
int dm_save_archive_queue(const char *zip,const char *root,const char *slot,uint64_t title,int expected_type,dm_save_archive_operation *out) {
    if(!zip||!root||!slot_valid(slot)||!out)return EINVAL;
    memset(out,0,sizeof *out);
    // Queuing changes no committed save and may coexist with a running guest.
    int lease=dm_save_archive_lock(root,0);if(lease<0)return -lease;
    int queue_lease=lock_file(root,".jksv-queue.lock",1);if(queue_lease<0){close(lease);return -queue_lease;}
    int own_copy=0,own_stage=0,error=0,input=-1,output=-1,parent=-1;char copy[PATH_MAX]={0},stage[PATH_MAX]={0},pending[PATH_MAX];
    unsigned char job[16];arc4random_buf(job,sizeof job);
    if(dm_save_archive_has_pending(root)){error=PENDING_IMPORT;goto done;}
    parent=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(parent<0){error=errno;goto done;}
    if((error=joined(copy,sizeof copy,root,".jksv-queued-XXXXXX"))||
       (error=joined(stage,sizeof stage,root,".jksv-check-XXXXXX"))||
       (error=pending_path(pending,sizeof pending,root,slot)))goto done;
    input=open(zip,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(input<0){error=errno;goto done;}
    struct stat before,after;if(fstat(input,&before)||!S_ISREG(before.st_mode)){error=UNSAFE_FILE;goto done;}
    if(before.st_size<0||(uint64_t)before.st_size>MAX_BYTES){error=TOO_LARGE;goto done;}
    output=mkstemp(copy);if(output<0){error=errno;copy[0]=0;goto done;}
    own_copy=1;fcntl(output,F_SETFD,FD_CLOEXEC);
    unsigned char buffer[65536];uint64_t total=0;
    for(;;){ssize_t n=read(input,buffer,sizeof buffer);if(n<0&&errno==EINTR)continue;if(n<0){error=errno;break;}if(!n)break;
        if((uint64_t)n>MAX_BYTES-total){error=TOO_LARGE;break;}error=write_all(output,buffer,(size_t)n);if(error)break;total+=(uint64_t)n;}
    if(!error&&(fstat(input,&after)||!same_stat(&before,&after)||(uint64_t)before.st_size!=total))error=CHANGED_SOURCE;
    if(!error&&fsetxattr(output,JOB_XATTR,job,sizeof job,0,0))error=errno;
    if(!error&&fsync(output))error=errno;
    close(output);output=-1;if(error)goto done;
    if(!mkdtemp(stage)){error=errno;stage[0]=0;goto done;}
    own_stage=1;error=dm_save_zip_extract(copy,stage,title,expected_type,&out->info);if(error)goto done;
    if(renamex_np(copy,pending,RENAME_EXCL)){error=errno;goto done;}
    own_copy=0;out->installed=1;
    if(fsync(parent))error=errno;
done:
    if(output>=0)close(output);if(input>=0)close(input);
    if(parent>=0&&own_stage)discard_stage(parent,strrchr(stage,'/')+1);
    if(own_copy)unlink(copy);
    if(parent>=0)close(parent);close(queue_lease);close(lease);return error;
}
int dm_save_archive_apply_pending(const char *root,uint64_t title,dm_save_archive_operation *out) {
    if(!root||!out||!title)return EINVAL;
    memset(out,0,sizeof *out);int first_error=0;
    int lease=dm_save_archive_lock(root,1);if(lease<0)return -lease;
    for(unsigned i=0;i<2;i++){
        const char *slot=i?"save_device":"save";char pending[PATH_MAX],current[PATH_MAX];
        int error=pending_path(pending,sizeof pending,root,slot);if(error){first_error=error;break;}
        error=joined(current,sizeof current,root,slot);if(error){first_error=error;break;}
        int input=open(pending,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
        if(input<0){if(errno!=ENOENT&&!first_error)first_error=errno;continue;}
        struct stat st;unsigned char job[16],applied[16];
        if(fstat(input,&st)||!S_ISREG(st.st_mode)||fgetxattr(input,JOB_XATTR,job,sizeof job,0,0)!=sizeof job){close(input);if(!first_error)first_error=BAD_META;continue;}
        close(input);
        // The token travels with the committed directory and its later game
        // transactions. A leftover queue file can never roll back new progress.
        int already=getxattr(current,JOB_XATTR,applied,sizeof applied,0,0)==sizeof applied&&!memcmp(job,applied,sizeof job);
        dm_save_archive_operation result={0};
        if(!already){
            char additional[PATH_MAX];int kind=i?3:-1;
            if(!i&&!joined(additional,sizeof additional,root,"save_device")&&!lstat(additional,&st))kind=1;
            error=import_archive(pending,root,slot,title,kind,job,lease,&result);
            if(error&&!first_error)first_error=error;
            if(!result.installed)continue;
            *out=result;
        }
        if(unlink(pending)&&errno!=ENOENT&&!first_error)first_error=errno;
        int parent=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(parent>=0){if(fsync(parent)&&!first_error)first_error=errno;close(parent);}
    }
    close(lease);return first_error;
}
int dm_save_archive_cancel_pending(const char *root) {
    int lease=dm_save_archive_lock(root,0);if(lease<0)return -lease;
    int queue_lease=lock_file(root,".jksv-queue.lock",1);if(queue_lease<0){close(lease);return -queue_lease;}
    int error=0;char path[PATH_MAX];
    for(unsigned i=0;i<2;i++){
        int e=pending_path(path,sizeof path,root,i?"save_device":"save");
        if(!e&&unlink(path)&&errno!=ENOENT)e=errno;
        if(e&&!error)error=e;
    }
    int parent=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(parent>=0){if(fsync(parent)&&!error)error=errno;close(parent);}
    close(queue_lease);close(lease);return error;
}
int dm_save_archive_export(const char *root,const char *slot,const char *zip,dm_save_archive_operation *out) {
    if(!root||!slot_valid(slot)||!zip||!out||strlen(zip)>=PATH_MAX)return EINVAL;
    memset(out,0,sizeof *out);
    int lease=dm_save_archive_lock(root,1);if(lease<0)return -lease;
    int error=0;char directory[PATH_MAX],temporary[PATH_MAX],parent_path[PATH_MAX];
    strlcpy(parent_path,zip,sizeof parent_path);char *leaf=strrchr(parent_path,'/');
    if(!leaf||leaf==parent_path){error=EINVAL;goto done;}*leaf++=0;
    if(!path_valid(leaf)||strchr(leaf,'/')){error=EINVAL;goto done;}
    int parent=open(parent_path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(parent<0){error=errno;goto done;}
    char name[80];snprintf(name,sizeof name,".jksv-export-%08x-%08x.zip",arc4random(),arc4random());
    if((error=joined(directory,sizeof directory,root,slot))||
       (error=joined(temporary,sizeof temporary,parent_path,name))){close(parent);goto done;}
    error=dm_save_zip_create(directory,temporary,NULL,0,&out->info);int own_temporary=!error;
    if(!error){
        if(renameatx_np(parent,name,parent,leaf,RENAME_EXCL))error=errno;
        else{out->installed=1;if(fsync(parent))error=errno;}
    }
    if(own_temporary&&!out->installed)unlinkat(parent,name,0);
    close(parent);
done:
    close(lease);return error;
}
const char *dm_save_archive_error(int error) {
    switch(error){
        case 0:return "OK";case BAD_ZIP:return "The ZIP is corrupt or uses an unsupported ZIP feature.";
        case BAD_PATH:return "The ZIP contains an unsafe or reserved path.";
        case BAD_META:return "The JKSV metadata is invalid or unsupported.";
        case WRONG_TITLE:return "The JKSV backup belongs to a different game.";
        case WRONG_TYPE:return "The JKSV backup has a different save type.";
        case TOO_LARGE:return "The backup exceeds the supported save limits.";
        case UNSAFE_FILE:return "Only regular save files and directories are supported.";
        case CHANGED_SOURCE:return "The source changed during the operation. Close the game and retry.";
        case EMPTY_SAVE:return "The backup contains no save files.";
        case PENDING_IMPORT:return "An import is pending. Restart the port to apply it first.";
        default:return strerror(error);
    }
}
