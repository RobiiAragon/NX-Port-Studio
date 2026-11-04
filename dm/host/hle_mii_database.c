// Original importer and persistence. Public format references (not SDK code):
// switchbrew/libnx nx/include/switch/services/mii.h (CharInfo/source flags),
// Genwald/MiiPort include/mii_ext.h (CoreData/StoreData/NFDB), ISC licensed.
// No conversion of QR/encrypted NFIF files or console-specific HMAC secrets.
#include "mii_database.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

enum { MII_HEADER = 16, MII_NFDB = 4 + 100 * 68 + 4, MII_MAX_FILE = MII_HEADER + DM_MII_CAPACITY * 88 };
static uint16_t mii_u16(const uint8_t *p) { return (uint16_t)(p[0] | (unsigned)p[1] << 8); }
static uint32_t mii_u32(const uint8_t *p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void mii_put32(uint8_t *p, uint32_t n) { for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(n >> (i * 8)); }
static uint32_t mii_crc32(uint32_t crc, const void *bytes, size_t size) {
    const uint8_t *p = bytes;
    while (size--) { crc ^= *p++; for (int i = 0; i < 8; ++i) crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1))); }
    return crc;
}
static int mii_crc16_valid(const uint8_t *p, size_t size) {
    uint16_t crc = 0;
    for (size_t i = 0; i < size; ++i) {
        crc ^= (uint16_t)p[i] << 8;
        for (int bit = 0; bit < 8; ++bit) crc = (uint16_t)((crc << 1) ^ (crc & 0x8000 ? 0x1021 : 0));
    }
    return crc == 0; // CRC-16/XMODEM, stored in network byte order, included.
}
int dm_mii_charinfo_valid(const dm_mii_charinfo *info) {
    if (!info) return 0;
    const uint8_t *p = (const uint8_t *)info;
    unsigned nonzero = 0; for (int i = 0; i < 16; ++i) nonzero |= p[i];
    if (!nonzero || (p[8] & 0xc0) != 0x80 || info->reserved) return 0;
    // Nintendo CreateIds require the RFC 4122 variant, not a fabricated version
    // nibble. Preserve the full ID from the export, including non-v4 IDs.
    int ended = 0;
    for (unsigned i = 0; i < 11; ++i) {
        uint16_t c = mii_u16(p + 16 + i * 2);
        if (!c) { if (!i) return 0; ended = 1; continue; }
        if (ended || i == 10 || c == 0xfffe || c == 0xffff) return 0;
        if (c >= 0xd800 && c <= 0xdbff) {
            if (i >= 9) return 0;
            uint16_t low = mii_u16(p + 16 + (++i) * 2);
            if (low < 0xdc00 || low > 0xdfff) return 0;
        } else if (c >= 0xdc00 && c <= 0xdfff) return 0;
    }
    if (!ended) return 0;
    // Common Switch CharInfo ranges; SDK 4.4.0 CharInfoRaw::Verify confirms
    // them in MK8's own SDK. Eyebrow Y is stored with the +3 origin applied.
    static const uint8_t maximum[] = {
        3,11,1,127,127,1,3,11,9,11,11,131,99,1,59,99,7,6,7,12,18,
        23,99,8,6,11,12,18,17,8,18,35,99,8,6,18,99,5,5,8,16,19,
        99,7,20,1,8,16,30
    };
    _Static_assert(sizeof maximum == 0x57 - 0x26, "CharInfo field range coverage");
    for (size_t i = 0; i < sizeof maximum; ++i) if (p[0x26 + i] > maximum[i]) return 0;
    return info->eyebrow_y >= 3;
}
static int mii_collection_valid(const dm_mii_collection *c) {
    if (!c || c->count > DM_MII_CAPACITY) return 0;
    for (uint32_t i = 0; i < c->count; ++i) {
        if (!dm_mii_charinfo_valid(&c->entries[i])) return 0;
        // The host's six independent defaults own fixed original IDs. Letting
        // a personal record reuse one would make combined-source lists and
        // saved ID lookups ambiguous. Never silently re-key an import.
        for (unsigned index=0; index<6; ++index) {
            uint8_t id[16]; uint64_t a=0x4d49494e44454641ull+index,b=0x554c54444d484f53ull;
            memcpy(id,&a,8); memcpy(id+8,&b,8); id[6]=(id[6]&15)|0x40; id[8]=(id[8]&63)|0x80;
            if (!memcmp(id,c->entries[i].create_id,16)) return 0;
        }
        for (uint32_t j = 0; j < i; ++j) if (!memcmp(c->entries[i].create_id, c->entries[j].create_id, 16)) return 0;
    }
    return 1;
}
static int mii_store_decode(const uint8_t p[68], dm_mii_charinfo *c) {
    if (!mii_crc16_valid(p, 66)) return DM_MII_CHECKSUM;
    // The final device CRC is seeded with the original console's Mii author ID.
    // It is not portable authentication and is neither verified nor forged here.
    // We import appearance/identity into CharInfo, which carries no device CRC.
    if (((p[5] | p[6] | p[7] | p[8]) & 0x80) || (p[19] & 0xe0) || (p[20] & 0xe0)) return DM_MII_INVALID;
    memset(c, 0, sizeof *c); memcpy(c->create_id, p + 48, 16); memcpy(c->nickname, p + 28, 20);
    c->hair_type=p[0]; c->height=p[1]&127; c->mole_type=p[1]>>7;
    c->build=p[2]&127; c->hair_flip=p[2]>>7; c->hair_color=p[3]&127; c->type=p[3]>>7;
    c->eye_color=p[4]&127; c->gender=p[4]>>7; c->eyebrow_color=p[5]&127;
    c->mouth_color=p[6]&127; c->beard_color=p[7]&127; c->glass_color=p[8]&127;
    c->eye_type=p[9]&63; c->region_move=p[9]>>6; c->mouth_type=p[10]&63; c->font_region=p[10]>>6;
    c->eye_y=p[11]&31; c->glass_scale=p[11]>>5; c->eyebrow_type=p[12]&31; c->mustache_type=p[12]>>5;
    c->nose_type=p[13]&31; c->beard_type=p[13]>>5; c->nose_y=p[14]&31; c->mouth_aspect=p[14]>>5;
    c->mouth_y=p[15]&31; c->eyebrow_aspect=p[15]>>5; c->mustache_y=p[16]&31; c->eye_rotate=p[16]>>5;
    c->glass_y=p[17]&31; c->eye_aspect=p[17]>>5; c->mole_x=p[18]&31; c->eye_scale=p[18]>>5;
    c->mole_y=p[19]&31; c->glass_type=p[20]&31; c->favorite_color=p[21]&15; c->faceline_type=p[21]>>4;
    c->faceline_color=p[22]&15; c->faceline_wrinkle=p[22]>>4; c->faceline_make=p[23]&15; c->eye_x=p[23]>>4;
    c->eyebrow_scale=p[24]&15; c->eyebrow_rotate=p[24]>>4; c->eyebrow_x=p[25]&15; c->eyebrow_y=(p[25]>>4)+3;
    c->nose_scale=p[26]&15; c->mouth_scale=p[26]>>4; c->mustache_scale=p[27]&15; c->mole_scale=p[27]>>4;
    return dm_mii_charinfo_valid(c) ? DM_MII_OK : DM_MII_INVALID;
}
int dm_mii_decode(const void *bytes, size_t size, dm_mii_collection *out) {
    if (!bytes || !out || size > MII_MAX_FILE) return DM_MII_INVALID;
    const uint8_t *p = bytes; dm_mii_collection next = {0}; int error = DM_MII_OK;
    if (size >= MII_HEADER && !memcmp(p, "DMII", 4)) {
        if (mii_u16(p+4) != 1 || mii_u16(p+6) != sizeof(dm_mii_charinfo)) return DM_MII_UNSUPPORTED;
        next.count = mii_u32(p+8);
        if (next.count > DM_MII_CAPACITY || size != MII_HEADER + next.count * sizeof(dm_mii_charinfo)) return DM_MII_INVALID;
        uint32_t crc = mii_crc32(mii_crc32(~0u,p,12),p+MII_HEADER,size-MII_HEADER)^~0u;
        if (crc != mii_u32(p+12)) return DM_MII_CHECKSUM;
        memcpy(next.entries,p+MII_HEADER,size-MII_HEADER);
    } else if (size == sizeof(dm_mii_charinfo)) {
        next.count=1; memcpy(next.entries,p,size);
    } else if (size == 68) {
        next.count=1; error=mii_store_decode(p,next.entries);
    } else if (size == MII_NFDB && !memcmp(p,"NFDB",4)) {
        if (p[size-4] != 1) return DM_MII_UNSUPPORTED;
        next.count=p[size-3]; if (next.count > DM_MII_CAPACITY) return DM_MII_INVALID;
        if (!mii_crc16_valid(p,size)) return DM_MII_CHECKSUM;
        for (uint32_t i=0; i<next.count && !error; ++i) error=mii_store_decode(p+4+i*68,&next.entries[i]);
    } else return DM_MII_UNSUPPORTED;
    if (error) return error;
    if (!mii_collection_valid(&next)) return DM_MII_INVALID;
    *out=next; return DM_MII_OK;
}
static int mii_file_read(const char *path, dm_mii_collection *out, int missing_empty) {
    if (!path || !*path || !out) return DM_MII_INVALID;
    int fd=open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    if (fd<0) {
        if (errno==ENOENT && missing_empty) { memset(out,0,sizeof *out); return DM_MII_OK; }
        return errno==ENOENT ? DM_MII_NOT_FOUND : DM_MII_IO;
    }
    struct stat st; int error=DM_MII_INVALID; uint8_t bytes[MII_MAX_FILE];
    if (!fstat(fd,&st) && S_ISREG(st.st_mode) && st.st_size>0 && st.st_size <= MII_MAX_FILE) {
        size_t n=0, size=(size_t)st.st_size; ssize_t r=0;
        while (n<size) { r=read(fd,bytes+n,size-n); if (r<0 && errno==EINTR) continue; if (r<=0) break; n+=(size_t)r; }
        uint8_t extra; do { r=read(fd,&extra,1); } while (r<0 && errno==EINTR);
        error=n==size && r==0 ? dm_mii_decode(bytes,size,out) : DM_MII_IO;
    }
    close(fd); return error;
}
int dm_mii_read(const char *path, dm_mii_collection *out) { return mii_file_read(path,out,1); }
int dm_mii_inspect_file(const char *path, dm_mii_collection *out) { return mii_file_read(path,out,0); }
static int mii_parents(const char *path) {
    char directory[PATH_MAX]; size_t n=strlen(path); if (n>=sizeof directory) return 0;
    memcpy(directory,path,n+1);
    for (char *p=directory+1; *p; ++p) if (*p=='/') {
        *p=0; int ok=!mkdir(directory,0700) || errno==EEXIST; struct stat st;
        if (!ok || stat(directory,&st) || !S_ISDIR(st.st_mode)) return 0;
        *p='/';
    }
    return 1;
}
static int mii_lock(const char *path) {
    char lock[PATH_MAX]; if (!path || !*path || snprintf(lock,sizeof lock,"%s.lock",path)>=(int)sizeof lock || !mii_parents(path)) return -1;
    int fd=open(lock,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK,0600);
    if (fd<0) return -1;
    struct stat st; if (fstat(fd,&st) || !S_ISREG(st.st_mode)) { close(fd); return -1; }
    while (flock(fd,LOCK_EX)) { if (errno==EINTR) continue; close(fd); return -1; }
    return fd;
}
static int mii_sync(int fd) {
    int r; do { r=fsync(fd); } while (r && errno==EINTR);
    return r;
}
static int mii_write(const char *path, const dm_mii_collection *c) {
    if (!mii_collection_valid(c)) return DM_MII_INVALID;
    uint8_t bytes[MII_MAX_FILE]={ 'D','M','I','I',1,0,88,0 };
    size_t size=MII_HEADER+c->count*sizeof(dm_mii_charinfo);
    mii_put32(bytes+8,c->count); memcpy(bytes+MII_HEADER,c->entries,size-MII_HEADER);
    mii_put32(bytes+12,mii_crc32(mii_crc32(~0u,bytes,12),bytes+MII_HEADER,size-MII_HEADER)^~0u);
    char temp[PATH_MAX], parent[PATH_MAX];
    if (snprintf(temp,sizeof temp,"%s.XXXXXX",path)>=(int)sizeof temp) return DM_MII_IO;
    const char *base=strrchr(path,'/'); size_t prefix=base ? (size_t)(base-path) : 0;
    if (!base) strcpy(parent,".");
    else if (!prefix) strcpy(parent,"/");
    else { memcpy(parent,path,prefix); parent[prefix]=0; }
    base=base ? base+1 : path;
    // Hold the same directory for the rename and its metadata barrier. Follow
    // the existing parent-path policy; the temporary inode must belong to this
    // opened directory before its name is used by renameat/unlinkat.
    int directory=open(parent,O_RDONLY|O_DIRECTORY|O_CLOEXEC); if (directory<0) return DM_MII_IO;
    int fd=mkstemp(temp); if (fd<0) { close(directory); return DM_MII_IO; }
    const char *temporary=strrchr(temp,'/'); temporary=temporary ? temporary+1 : temp;
    struct stat created, named;
    if (fstat(fd,&created) || fstatat(directory,temporary,&named,AT_SYMLINK_NOFOLLOW) ||
        !S_ISREG(named.st_mode) || created.st_dev!=named.st_dev || created.st_ino!=named.st_ino) {
        // A concurrently moved/replaced parent is not the locked path anymore.
        // Do not rename or delete a different directory's entry by pathname.
        close(fd); close(directory); return DM_MII_IO;
    }
    size_t n=0;
    while (n<size) { ssize_t r=write(fd,bytes+n,size-n); if (r<0 && errno==EINTR) continue; if (r<=0) break; n+=(size_t)r; }
    int ok=n==size && !mii_sync(fd); if (close(fd)) ok=0;
    int error=DM_MII_IO;
    if (ok && !renameat(directory,temporary,directory,base)) {
        // Once renamed, the new file can already be observed by other readers.
        // A failed directory sync cannot be described as a rolled-back write.
        error=mii_sync(directory) ? DM_MII_COMMIT_UNCERTAIN : DM_MII_OK;
    } else unlinkat(directory,temporary,0);
    close(directory); return error;
}
int dm_mii_import_file(const char *database, const char *source, dm_mii_import_result *out) {
    dm_mii_collection incoming, current;
    int error=mii_file_read(source,&incoming,0); if (error) return error;
    if (!incoming.count) return DM_MII_INVALID; // Import never silently clears a library.
    int lock=mii_lock(database); if (lock<0) return DM_MII_IO;
    error=dm_mii_read(database,&current); dm_mii_import_result result={0};
    for (uint32_t i=0; i<incoming.count && !error; ++i) {
        uint32_t at=0; for (; at<current.count; ++at) if (!memcmp(incoming.entries[i].create_id,current.entries[at].create_id,16)) break;
        if (at==current.count) {
            if (at==DM_MII_CAPACITY) { error=DM_MII_FULL; break; }
            current.entries[current.count++]=incoming.entries[i]; ++result.added;
        } else if (memcmp(&incoming.entries[i],&current.entries[at],sizeof(dm_mii_charinfo))) {
            current.entries[at]=incoming.entries[i]; ++result.replaced;
        } else ++result.unchanged;
    }
    if (!error && (result.added || result.replaced)) error=mii_write(database,&current);
    close(lock);
    if (!error && out) { result.total=current.count; *out=result; }
    return error;
}
int dm_mii_seed_if_missing(const char *database, const char *seed) {
    int lock=mii_lock(database); if (lock<0) return DM_MII_IO;
    struct stat st; int error=DM_MII_OK;
    if (lstat(database,&st)) {
        if (errno!=ENOENT) error=DM_MII_IO;
        else {
            dm_mii_collection initial;
            error=mii_file_read(seed,&initial,0);
            if (!error) error=initial.count ? mii_write(database,&initial) : DM_MII_INVALID;
        }
    } // An existing path, including empty/corrupt files and symlinks, is not replaced.
    close(lock); return error;
}
int dm_mii_clear(const char *database) {
    int lock=mii_lock(database); if (lock<0) return DM_MII_IO;
    dm_mii_collection empty={0}; int error=mii_write(database,&empty); close(lock); return error;
}
int dm_mii_remove(const char *database, const uint8_t id[16]) {
    if (!id) return DM_MII_INVALID;
    int lock=mii_lock(database); if (lock<0) return DM_MII_IO;
    dm_mii_collection current; int error=dm_mii_read(database,&current);
    if (!error) {
        uint32_t i=0; for (; i<current.count; ++i) if (!memcmp(id,current.entries[i].create_id,16)) break;
        if (i==current.count) error=DM_MII_NOT_FOUND;
        else { --current.count; memmove(current.entries+i,current.entries+i+1,(current.count-i)*sizeof(dm_mii_charinfo)); error=mii_write(database,&current); }
    }
    close(lock); return error;
}
int dm_mii_database_path(char *out, size_t capacity) {
    if (!out || !capacity) return DM_MII_INVALID;
    const char *path=getenv("DM_MII_DATABASE"), *root=getenv("DM_ROOT");
    int n=path && *path ? snprintf(out,capacity,"%s",path) : snprintf(out,capacity,"%s/miis.dmii",root && *root ? root : ".");
    return n>=0 && (size_t)n<capacity ? DM_MII_OK : DM_MII_INVALID;
}
const char *dm_mii_error(int error) {
    switch (error) {
        case DM_MII_OK: return "success";
        case DM_MII_INVALID: return "invalid Mii fields, identity, duplicate IDs, count or file size";
        case DM_MII_CHECKSUM: return "Mii checksum mismatch";
        case DM_MII_UNSUPPORTED: return "unsupported Mii format/version; use CharInfo, StoreData or decrypted NFDB";
        case DM_MII_FULL: return "the personal Mii library already contains 100 records";
        case DM_MII_NOT_FOUND: return "Mii or source file not found";
        case DM_MII_COMMIT_UNCERTAIN: return "Mii replacement is visible but directory synchronization failed; durability is unconfirmed";
        default: return "Mii file could not be read or replaced";
    }
}
