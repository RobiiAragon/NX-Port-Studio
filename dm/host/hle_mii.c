// Mii service layer (nn::mii::Database, the Mii editor applet). On hardware Database talks to the mii:u service (an IDatabaseService the SDK keeps at Database +0) and AppendMii /
// ShowMiiEdit start the MiiEdit library applet. The host supplies an imported personal database and the six independent defaults; its native editor remains a separate UI path.
// Mario Kart 8 Deluxe (SDK 4.4.0) initializes a Database at boot (mii:e and mii:u were the first services it opened itself) and builds 12 random Miis for its title screen's demo race; their
// heads are drawn by the SDK's Mii rendering code linked into main, from the MiiModel system data (the host's stand-in below, mounted by hle_fs.c MountSystemData).
// The CharInfo the host builds (0x58 bytes) is the system's default Mii as the mii service's StoreData::BuildDefault makes it: the 3DS-era default parameters, with the colours converted to
// the Switch's common colour indices (hair 1, eyes 8, mouth 19, glasses 8), a create ID of UUID version 4 (fixed for each default Mii, fresh for a random one) and the nickname "no name";
// every field is within CharInfoRaw::Verify's ranges (SDK 4.4.0 sdk+0x1b68c8), so CharInfoAccessor::IsValid accepts it.
#include "hle.h"
#include "mii_database.h"
#include <limits.h>
#include <unistd.h>
#include <sys/stat.h>

uint64_t dm_entropy64(void);

#define MII_RES_NOT_FOUND 0x87Eu        // nn::mii module 126, description 4
#define MII_RES_CANCELED 0xE7Eu         // description 7: the player closed the applet (the SDK's ShowMiiEdit treats it as success)
#define MII_RES_TEST_MODE 0x1987Eu      // description 204: importing a database needs the system's test mode

typedef dm_mii_charinfo mii_charinfo;

// index ≥ 0: default Mii <index> (a fixed create ID, so a game that saved one finds the same Mii again); < 0: a random Mii (a fresh one)
static void mii_default(mii_charinfo *c, int gender, int index) {
    memset(c, 0, sizeof *c);
    uint64_t a = index >= 0 ? 0x4d49494e44454641ull + (uint64_t)index : dm_entropy64(), b = index >= 0 ? 0x554c54444d484f53ull : dm_entropy64();
    memcpy(c->create_id, &a, 8); memcpy(c->create_id + 8, &b, 8);
    c->create_id[6] = (uint8_t)((c->create_id[6] & 0x0f) | 0x40); c->create_id[8] = (uint8_t)((c->create_id[8] & 0x3f) | 0x80);
    if (index >= 0) c->favorite_color = (uint8_t)(index * 2);   // red, yellow, green, sky blue, purple, white
    static const char name[] = "no name";
    for (size_t i = 0; i < sizeof name - 1; i++) c->nickname[i] = (uint16_t)name[i];
    c->gender = gender == 1; c->height = 64; c->build = 64;
    c->hair_type = 33; c->hair_color = 1;
    c->eye_type = 2; c->eye_color = 8; c->eye_scale = 4; c->eye_aspect = 3; c->eye_rotate = 4; c->eye_x = 2; c->eye_y = 12;
    c->eyebrow_type = 6; c->eyebrow_color = 1; c->eyebrow_scale = 4; c->eyebrow_aspect = 3; c->eyebrow_rotate = 6; c->eyebrow_x = 2; c->eyebrow_y = 10;
    c->nose_type = 1; c->nose_scale = 4; c->nose_y = 9;
    c->mouth_type = 23; c->mouth_color = 19; c->mouth_scale = 4; c->mouth_aspect = 3; c->mouth_y = 13;
    c->beard_color = 8; c->mustache_scale = 4; c->mustache_y = 10;
    c->glass_color = 8; c->glass_scale = 4; c->glass_y = 10;
    c->mole_scale = 4; c->mole_x = 2; c->mole_y = 20;
}

// The SDK object owns no Nintendo IPC session: native state stays in a side
// table so its original destructor can still see a null service pointer at +0.
// Every filesystem/lock operation runs on the native wait stack; game stacks
// can be smaller than one validated 100-record library.
typedef struct mii_session { const void *self; uint64_t seen; struct mii_session *next; } mii_session;
static pthread_mutex_t mii_mutex=PTHREAD_MUTEX_INITIALIZER;
static mii_session *mii_sessions;
static dm_mii_collection mii_library;
static uint64_t mii_generation;
static int mii_last_error;
static void mii_unlock(int *locked) { (void)locked; pthread_mutex_unlock(&mii_mutex); dm_guest_host_wait_end(); }
#define MII_LOCK() dm_guest_host_wait_begin(); pthread_mutex_lock(&mii_mutex); int mii_locked_ __attribute__((cleanup(mii_unlock)))=1
static mii_session *mii_session_for(const void *self) {
    for (mii_session *s=mii_sessions; s; s=s->next) if (s->self==self) return s;
    return NULL;
}
static int mii_refresh(void) { // mii_mutex held; invalid disk data never replaces a valid snapshot.
    char path[PATH_MAX]; dm_mii_collection next;
    int error=dm_mii_database_path(path,sizeof path);
    const char *seed=getenv("DM_MII_SEED");
    // The existence probe is only an optimization; the backend rechecks under
    // its writer lock so a bundled seed never overwrites a concurrent import.
    if (!error && seed && *seed && access(path,F_OK) && errno==ENOENT) error=dm_mii_seed_if_missing(path,seed);
    if (!error) error=dm_mii_read(path,&next);
    if (error!=mii_last_error) {
        if (error) LOG("[RED] mii: personal database unavailable: %s",dm_mii_error(error));
        mii_last_error=error;
    }
    if (error) return 0;
    if (!mii_generation || next.count!=mii_library.count || memcmp(next.entries,mii_library.entries,next.count*sizeof(mii_charinfo))) {
        mii_library=next; ++mii_generation;
        LOG("mii: personal library loaded (%u records; normal database view excludes special records)",next.count);
    }
    return 1;
}
static int mii_ready(const void *self) { return mii_session_for(self) && mii_refresh(); }
static int mii_normal_count(void) {
    int count=0; for (uint32_t i=0; i<mii_library.count; ++i) count+=mii_library.entries[i].type==0; return count;
}
HLE_FORCE_WAIT("_ZN2nn3mii8Database10InitializeEv", "native personal database and independent default source", Result, h_mii_Init, void *self) {
    MII_LOCK(); if (!self || !mii_refresh()) return RES_FAIL;
    mii_session *s=mii_session_for(self);
    if (!s) { s=calloc(1,sizeof *s); if (!s) return RES_FAIL; s->self=self; s->next=mii_sessions; mii_sessions=s; }
    s->seen=mii_generation; return RES_OK;
}
HLE_FORCE_WAIT("_ZN2nn3mii8Database8FinalizeEv", "release only this native database session", void, h_mii_Fin, void *self) {
    MII_LOCK(); mii_session **s=&mii_sessions;
    while (*s && (*s)->self!=self) s=&(*s)->next;
    if (*s) { mii_session *old=*s; *s=old->next; free(old); }
}
HLE_FORCE_WAIT("_ZNK2nn3mii8Database11IsAvailableEv", "native database availability", int, h_mii_Avail, const void *self) { MII_LOCK(); return mii_ready(self); }
HLE_FORCE_WAIT("_ZN2nn3mii8Database9IsUpdatedEi", "session-local personal database change observation", int, h_mii_Updated, void *self, int src) {
    MII_LOCK(); if ((src&~3) || !mii_ready(self) || !(src&DM_MII_SOURCE_DATABASE)) return 0;
    mii_session *s=mii_session_for(self); int changed=s->seen!=mii_generation; s->seen=mii_generation; return changed;
}
HLE_FORCE_WAIT("_ZNK2nn3mii8Database14IsFullDatabaseEv", "personal database capacity independent of defaults", int, h_mii_Full, const void *self) { MII_LOCK(); return mii_ready(self) && mii_library.count==DM_MII_CAPACITY; }
enum { MII_DEFAULTS=6 };
static int mii_get(void *buf, int n, int src, size_t stride) {
    int k=0;
    if (src&DM_MII_SOURCE_DATABASE) for (uint32_t i=0; i<mii_library.count && k<n; ++i) {
        if (mii_library.entries[i].type) continue; // Normal mii:u view, not the special-key private database.
        uint8_t *e=(uint8_t *)buf+(size_t)k++*stride; memcpy(e,&mii_library.entries[i],sizeof(mii_charinfo));
        if (stride>sizeof(mii_charinfo)) { uint32_t source=0; memcpy(e+sizeof(mii_charinfo),&source,4); }
    }
    if (src&DM_MII_SOURCE_DEFAULT) for (int i=0; i<MII_DEFAULTS && k<n; ++i) {
        uint8_t *e=(uint8_t *)buf+(size_t)k++*stride; mii_default((mii_charinfo *)e,i>=3,i);
        if (stride>sizeof(mii_charinfo)) { uint32_t source=1; memcpy(e+sizeof(mii_charinfo),&source,4); }
    }
    return k;
}
HLE_FORCE_WAIT("_ZNK2nn3mii8Database8GetCountEi", "count selected personal/default sources", int, h_mii_Count, const void *self, int src) {
    MII_LOCK(); if ((src&~3) || !mii_ready(self)) return 0;
    return (src&DM_MII_SOURCE_DATABASE ? mii_normal_count() : 0)+(src&DM_MII_SOURCE_DEFAULT ? MII_DEFAULTS : 0);
}
static Result mii_get_checked(void *self,int *out,void *buf,int n,int src,size_t stride) {
    if (!out || n<0 || (n && !buf) || (src&~3) || !mii_ready(self)) return RES_FAIL;
    *out=mii_get(buf,n,src,stride); return RES_OK;
}
HLE_FORCE_WAIT("_ZN2nn3mii8Database3GetEPiPNS0_15CharInfoElementEii", "personal/default CharInfo with actual Source enum", Result, h_mii_GetE, void *self, int *out, void *buf, int n, int src) { MII_LOCK(); return mii_get_checked(self,out,buf,n,src,sizeof(mii_charinfo)+4); }
HLE_FORCE_WAIT("_ZN2nn3mii8Database3GetEPiPNS0_8CharInfoEii", "personal/default CharInfo", Result, h_mii_Get, void *self, int *out, void *buf, int n, int src) { MII_LOCK(); return mii_get_checked(self,out,buf,n,src,sizeof(mii_charinfo)); }
HLE_FORCE_WAIT("_ZNK2nn3mii8Database8GetIndexEPiRKNS0_8CharInfoE", "resolve a personal CreateId without fabricating or rewriting it", Result, h_mii_Index, const void *self, int *out, const mii_charinfo *info) {
    MII_LOCK(); if (!out || !info || !mii_ready(self)) return RES_FAIL;
    *out=-1; int index=0;
    for (uint32_t i=0; i<mii_library.count; ++i) {
        const mii_charinfo *c=&mii_library.entries[i]; if (c->type) continue;
        if (!memcmp(c->create_id,info->create_id,16)) { *out=index; return RES_OK; } ++index;
    }
    return MII_RES_NOT_FOUND;
}
HLE_FORCE_WAIT("_ZNK2nn3mii8Database12UpdateLatestEPNS0_8CharInfoEi", "refresh an existing personal/default Mii by its CreateId", Result, h_mii_Latest, const void *self, mii_charinfo *info, int src) {
    MII_LOCK(); if (!info || (src&~3) || !mii_ready(self)) return RES_FAIL;
    if (src&DM_MII_SOURCE_DATABASE) for (uint32_t i=0; i<mii_library.count; ++i) {
        const mii_charinfo *c=&mii_library.entries[i];
        if (!c->type && !memcmp(c->create_id,info->create_id,16)) { *info=*c; return RES_OK; }
    }
    if (src&DM_MII_SOURCE_DEFAULT) for (int i=0; i<MII_DEFAULTS; ++i) {
        mii_charinfo c; mii_default(&c,i>=3,i);
        if (!memcmp(c.create_id,info->create_id,16)) { *info=c; return RES_OK; }
    }
    return MII_RES_NOT_FOUND;
}
// RandomDesc {age, gender, race}: gender 0 male, 1 female, 2 either. The host's "random" Mii is the default one of that gender
HLE_FORCE("_ZN2nn3mii8Database11BuildRandomEPNS0_8CharInfoERKNS0_10RandomDescE", "mii:u service; the default Mii", Result, h_mii_Random, void *self, mii_charinfo *out, const int *desc) {
    (void)self; mii_default(out, desc ? desc[1] : 0, -1); return RES_OK;
}
HLE_FORCE("_ZNK2nn3mii8Database12BuildDefaultEPNS0_8CharInfoEi", "mii:u service; default Mii <index>", Result, h_mii_Default, const void *self, mii_charinfo *out, int index) {
    (void)self; mii_default(out, index >= 3, index < 0 || index >= MII_DEFAULTS ? 0 : index); return RES_OK;
}
HLE_FORCE("_ZN2nn3mii8Database6FormatEv", "normal game access cannot format the shared personal library", Result, h_mii_Format, void *self) { (void)self; return MII_RES_TEST_MODE; }
HLE_FORCE("_ZN2nn3mii8Database6ImportEPKvm", "mii:u service; importing needs the system's test mode", Result, h_mii_Import, void *self, const void *p, size_t n) {
    (void)self; (void)p; LOG("[RED] mii: Database::Import of %zu bytes refused (the host has no test mode)", n); return MII_RES_TEST_MODE;
}
HLE_FORCE("_ZNK2nn3mii8Database6ExportEPvm", "mii:u service; nothing to export", Result, h_mii_Export, const void *self, void *p, size_t n) {
    (void)self; (void)p; (void)n; LOG("[RED] mii: Database::Export refused"); return MII_RES_TEST_MODE;
}
// MiiModel system data (0100000000000802) stand-in. The Mii rendering code an application links (Mario Kart 8 Deluxe 4.0.0: main+0x8f1400..+0x8fc000) reads one texture file
// (NXTexture{Low,Mid}{Linear,SRGB}.dat) and one shape file (Shape{Mid,High}.dat) whole and builds each part of a head from them; the firmware's files are not the host's to ship, so it writes
// files of the same layout in which every part is absent:
//   texture file: +0x0c u32 largest decompressed size of each of the 11 part kinds, +0x38 their alignments, then from +0x64 one 0x1c-byte entry per part (u32 offset, u32 size, u32 stored size,
//     4 zlib parameters, then the texture: u16 width / height at +0x14, format, mip count and kind at +0x18), hats 132, eyes 62, eyebrows 24, beards 2, wrinkles 12, make-up 12, glasses 20,
//     moles 2, mouths 37, mustaches 6, noselines 18 (main+0x8fb0dc);
//   shape file: +0x0c the 12 largest sizes, +0x3c their alignments, from +0x6c one 0x58-byte entry per part (offset, size, stored size, zlib parameters, five vertex attribute offsets
//     and sizes, index offset and size, bounding box), beards 4, facelines 12, masks 12, hats / foreheads / hair in normal and cap form 132 each, glasses 1, noses 18, noselines 18
//     (main+0x8faee8); then the hair transforms (132 × 0x48, +0x12704) and faceline transforms (12 × 0x24, +0x14c24).
// A texture whose size is 0 is skipped when the model is built (main+0x8faaf4); the model's own render targets (face, mask) do not come from the file. Shapes cannot all be absent: the
// faceline is drawn without a check (its position buffer, main+0x8286c4: a null buffer read at main+0xa690d0), so every shape entry points at one shared mesh, one vertex at the origin
// (attribute 0, the position: 4 halves) and the triangle (0, 0, 0) (u16 indices at +0x10), 0x20 bytes of zeros inflated with nn::util::DecompressZlib, stored here as one raw deflate block.
// It builds, and draws nothing. The largest sizes size the model's memory pool (main+0x8f2e6c) and the first alignment is that pool's alignment, so they are one page each instead of 0.
// The first 12 bytes of each header are not read
enum { MII_TEX_SIZE = 0x64 + 0x1c * 327, MII_SHAPE_TABLES = 0x6c + 0x58 * 857 + 0x48 * 132 + 0x24 * 12, MII_MESH_AT = 0x14de0, MII_MESH = 0x20 };
_Static_assert(MII_TEX_SIZE == 0x2428 && MII_SHAPE_TABLES == 0x14dd4, "MiiModel stand-in layout");
static const uint8_t mii_mesh_z[] = {0x78, 0x01, 0x01, MII_MESH, 0, (uint8_t)~MII_MESH, 0xff, [7 ... 7 + MII_MESH - 1] = 0, 0x00, MII_MESH, 0x00, 0x01};   // zlib: stored block, Adler-32 of 32 zeros
enum { MII_SHAPE_SIZE = MII_MESH_AT + sizeof mii_mesh_z };
static void mii_shapes(uint8_t *b) {
    for (int i = 0; i < 857; i++) {
        uint32_t *e = (uint32_t *)(b + 0x6c + 0x58 * i);
        e[0] = MII_MESH_AT; e[1] = MII_MESH; e[2] = sizeof mii_mesh_z;   // data offset, inflated size, stored size
        e[4 + 5] = 8;                                                    // attribute 0 (offset 0) is one 8-byte vertex; attributes 1-4 absent
        e[14] = 0x10; e[15] = 6;                                         // index offset and size: three u16 indices
    }
    memcpy(b + MII_MESH_AT, mii_mesh_z, sizeof mii_mesh_z);
}
static int mii_write(const char *dir, const char *name, int parts, size_t size) {
    char p[1280]; snprintf(p, sizeof p, "%s/%s", dir, name);
    uint8_t *b = calloc(1, size); FILE *f = fopen(p, "wb");
    for (int i = 0; b && i < parts; i++) { uint32_t page = 0x1000; memcpy(b + 0xc + 4 * i, &page, 4); memcpy(b + 0xc + 4 * parts + 4 * i, &page, 4); }
    if (b && parts == 12) mii_shapes(b);
    int ok = b && f && fwrite(b, 1, size, f) == size;
    if (f && fclose(f)) ok = 0;
    free(b);
    if (!ok) LOG("[RED] mii: cannot write the MiiModel stand-in %s", p);
    return ok;
}
int dm_mii_standin(const char *dir) {   // written once per process (the query and the mount both ask), so a host with another layout never leaves old files behind
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; static int done;
    pthread_mutex_lock(&mu);
    if (done) { pthread_mutex_unlock(&mu); return done > 0; }
    char p[1024]; strlcpy(p, dir, sizeof p);
    for (char *s = p + 1; *s; s++) if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; }
    mkdir(p, 0755);
    static const char *tex[] = {"NXTextureLowLinear.dat", "NXTextureLowSRGB.dat", "NXTextureMidLinear.dat", "NXTextureMidSRGB.dat"}, *shape[] = {"ShapeMid.dat", "ShapeHigh.dat"};
    int ok = 1;
    for (int i = 0; i < 4; i++) ok &= mii_write(dir, tex[i], 11, MII_TEX_SIZE);
    for (int i = 0; i < 2; i++) ok &= mii_write(dir, shape[i], 12, MII_SHAPE_SIZE);
    LOG("mii: MiiModel system data is the host's stand-in (no textures, every shape one degenerate triangle: Mii heads draw nothing) in %s", dir);
    done = ok ? 1 : -1;
    pthread_mutex_unlock(&mu);
    return ok;
}

// The Mii editor (MiiEdit library applet): the player closed it without adding a Mii
HLE_FORCE("_ZN2nn3mii9AppendMiiEPi", "MiiEdit applet; cancelled", Result, h_mii_Append, int *index) { DM_APPLET("Mii editor"); (void)index; LOG("mii: AppendMii (the host has no Mii editor: cancelled)"); return MII_RES_CANCELED; }
HLE_FORCE("_ZN2nn3mii11ShowMiiEditEv", "MiiEdit applet; closed at once", Result, h_mii_Edit, void) { DM_APPLET("Mii editor"); LOG("mii: ShowMiiEdit (the host has no Mii editor)"); return RES_OK; }
