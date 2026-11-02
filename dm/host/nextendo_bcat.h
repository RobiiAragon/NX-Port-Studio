#ifndef DM_NEXTENDO_BCAT_H
#define DM_NEXTENDO_BCAT_H
#include <stddef.h>
#include <stdint.h>
/* Public calendar data only. No account credential is required or accepted. */
int dm_bcat_supported(const char *title);
/* Build helper: a verified catalog and complete immutable snapshot are required. */
int dm_bcat_prepare(const char *title, const char *version, const char *catalog,
                    const char *destination, char *error, size_t error_size);
int dm_bcat_validate(const char *title, const char *version, const char *directory);
/* Called from the pre-guest boot thread with the front end's event loop live.
 * Online launches check before selecting the immutable RomFS overlay, sharing
 * a 12-second network budget. Offline/errors retain the last validated copy.
 * Later guest synchronization refreshes delivery opens only, never live RomFS. */
void dm_bcat_start(const char *module_directory, const char *title, int online);
const char *dm_bcat_overlay(void);
const char *dm_bcat_delivery(void);
int dm_bcat_copy_delivery(char *out, size_t size);
int dm_bcat_request_sync(void);
int dm_bcat_sync_status(unsigned *result, uint64_t *downloaded);
void *dm_bcat_sync_observe(void);
int dm_bcat_sync_observer_status(const void *observer, unsigned *result, uint64_t *downloaded);
void dm_bcat_sync_release(void *observer);
void dm_bcat_digest(const void *bytes, size_t length, unsigned char out[16]);
#endif
