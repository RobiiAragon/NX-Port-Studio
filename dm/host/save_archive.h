// Original ZIP interchange for decrypted save files. No console save/container
// encryption or account identity is synthesized. JKSV metadata is optional.
#ifndef DM_SAVE_ARCHIVE_H
#define DM_SAVE_ARCHIVE_H
#include <stddef.h>
#include <stdint.h>

enum { DM_SAVE_META_BYTES = 86, DM_SAVE_ZIP_MAX_ENTRIES = 32768 };
typedef struct {
    uint64_t files, directories, bytes;
    int has_metadata;
    uint64_t title_id;
    int save_type;
    unsigned char metadata[DM_SAVE_META_BYTES];
} dm_save_archive_info;

// Destination must be an existing empty private staging directory. Failures
// never replace a live save; the caller owns and removes its staging tree.
// expected_type: 1 account, 3 device, -1 either (a primary save can be either).
int dm_save_zip_extract(const char *zip, const char *staging, uint64_t title,
                        int expected_type, dm_save_archive_info *info);
// Creates an exclusive new ZIP; the caller publishes it only after success.
// metadata may be NULL. If supplied, it must be an original validated record.
int dm_save_zip_create(const char *directory, const char *zip,
                       const unsigned char *metadata, size_t metadata_size,
                       dm_save_archive_info *info);
const char *dm_save_archive_error(int error);
// Shared for a running game; exclusive for save management. Returns an owned
// descriptor, or -errno. Closing it releases the lease. No blocking waits.
int dm_save_archive_lock(const char *directory,int exclusive);
// Both directories must have the same parent. Existing data is swapped into
// staging and retained as the previous save; no directory is deleted here.
// installed is set after publication, even if the subsequent directory fsync
// fails. Callers must report that durability warning without retrying a swap.
int dm_save_archive_replace(const char *staging,const char *destination,
                            int *installed,int *has_previous);
typedef struct {
    dm_save_archive_info info;
    int installed;
    char backup_path[4096];
} dm_save_archive_operation;
// Complete UI operations, holding an exclusive lease. Only the runtime's two
// save slots are accepted; imports retain the old tree under save-backups.
int dm_save_archive_import(const char *zip,const char *root,const char *slot,
                           uint64_t title,int expected_type,dm_save_archive_operation *out);
int dm_save_archive_export(const char *root,const char *slot,const char *zip,
                           dm_save_archive_operation *out);
// iOS can preload guest initializers before its launcher is shown. In that
// case validate/copy now, then apply before preload on the next cold launch.
int dm_save_archive_queue(const char *zip,const char *root,const char *slot,
                          uint64_t title,int expected_type,dm_save_archive_operation *out);
int dm_save_archive_apply_pending(const char *root,uint64_t title,dm_save_archive_operation *out);
int dm_save_archive_has_pending(const char *root);
int dm_save_archive_cancel_pending(const char *root);
#endif
