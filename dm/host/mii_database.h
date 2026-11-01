// Personal Mii data, independent of firmware model/texture resources and of a
// game's save. No original Mii records or console secrets belong in this code.
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct __attribute__((packed)) {
    uint8_t create_id[16]; uint16_t nickname[11];
    uint8_t font_region, favorite_color, gender, height, build, type, region_move;
    uint8_t faceline_type, faceline_color, faceline_wrinkle, faceline_make;
    uint8_t hair_type, hair_color, hair_flip;
    uint8_t eye_type, eye_color, eye_scale, eye_aspect, eye_rotate, eye_x, eye_y;
    uint8_t eyebrow_type, eyebrow_color, eyebrow_scale, eyebrow_aspect, eyebrow_rotate, eyebrow_x, eyebrow_y;
    uint8_t nose_type, nose_scale, nose_y;
    uint8_t mouth_type, mouth_color, mouth_scale, mouth_aspect, mouth_y;
    uint8_t beard_color, beard_type, mustache_type, mustache_scale, mustache_y;
    uint8_t glass_type, glass_color, glass_scale, glass_y;
    uint8_t mole_type, mole_scale, mole_x, mole_y, reserved;
} dm_mii_charinfo;
_Static_assert(sizeof(dm_mii_charinfo) == 0x58, "nn::mii::CharInfo ABI");

enum { DM_MII_CAPACITY = 100, DM_MII_SOURCE_DATABASE = 1, DM_MII_SOURCE_DEFAULT = 2 };
typedef struct { uint32_t count; dm_mii_charinfo entries[DM_MII_CAPACITY]; } dm_mii_collection;
typedef struct { uint32_t added, replaced, unchanged, total; } dm_mii_import_result;
enum {
    DM_MII_OK = 0, DM_MII_INVALID = -1, DM_MII_CHECKSUM = -2,
    DM_MII_UNSUPPORTED = -3, DM_MII_FULL = -4, DM_MII_IO = -5,
    DM_MII_NOT_FOUND = -6
};

// These validate and preserve IDs and appearance. No missing/invalid record is
// replaced with a generated Mii. CharInfo is UTF-16LE, not a host string.
int dm_mii_charinfo_valid(const dm_mii_charinfo *info);
int dm_mii_decode(const void *bytes, size_t size, dm_mii_collection *out);
int dm_mii_inspect_file(const char *path, dm_mii_collection *out);
// Missing database is an empty collection; all other read/validation errors fail.
int dm_mii_read(const char *path, dm_mii_collection *out);
// Merge by CreateId (stable existing positions, append new IDs), under an
// interprocess lock and an atomic, CRC-protected private-file replacement.
int dm_mii_import_file(const char *database, const char *source, dm_mii_import_result *out);
// Existence is checked under the writer lock. Never merge an old bundled seed
// over a database another port or a later explicit import has already created.
int dm_mii_seed_if_missing(const char *database, const char *seed);
int dm_mii_clear(const char *database);
int dm_mii_remove(const char *database, const uint8_t create_id[16]);
// Launchers set a shared Mac path or an app-private iOS path. Direct hosts can
// use DM_MII_DATABASE; otherwise the file lives under DM_ROOT (or the cwd).
int dm_mii_database_path(char *out, size_t capacity);
const char *dm_mii_error(int error);
