// Private, same-executable Mac account probe. Never transports credentials.
#pragma once
#include <stdint.h>
#define DM_NEXTENDO_PREFLIGHT_ARG "--nextendo-account-preflight"
#define DM_NEXTENDO_PREFLIGHT_FD 3
#define DM_NEXTENDO_PREFLIGHT_MAGIC UINT32_C(0x4e585046)
typedef struct {
    uint32_t magic, version, pid, available;
    uint64_t expires_ms, reserved;
} dm_nextendo_preflight_reply;
// A complete versioned packet and a clean exit from the owned child are required.
int dm_nextendo_preflight_query(dm_nextendo_preflight_reply *out, unsigned timeout_ms);
int dm_nextendo_account_preflight_child(int fd);
