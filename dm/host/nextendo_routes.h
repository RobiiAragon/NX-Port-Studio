// Public endpoint policy, separate from account credentials and game eligibility.
#pragma once
#include <stddef.h>
enum { DM_NEXTENDO_ROUTES_UNINITIALIZED = -1, DM_NEXTENDO_ROUTES_READY = 0,
       DM_NEXTENDO_ROUTES_MISSING = 1, DM_NEXTENDO_ROUTES_INVALID = 2,
       DM_NEXTENDO_ROUTES_IO = 3, DM_NEXTENDO_ROUTES_LIMIT = 4,
       DM_NEXTENDO_ROUTES_CERTIFICATE = 5 };
// Call after network preferences and before the guest. Reads DM_NEXTENDO_ROUTES
// once; no token is accepted through the file or environment. Repeated calls are
// idempotent. DNS/TLS callbacks also initialize lazily if registered at startup.
int dm_nextendo_routes_initialize(void);
int dm_nextendo_routes_status(void);
size_t dm_nextendo_routes_count(void);
