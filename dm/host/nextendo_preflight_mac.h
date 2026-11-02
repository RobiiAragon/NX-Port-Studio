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
typedef enum {
    DM_PREFLIGHT_DONE, DM_PREFLIGHT_ARGUMENT, DM_PREFLIGHT_EXECUTABLE,
    DM_PREFLIGHT_PIPE, DM_PREFLIGHT_QUEUE, DM_PREFLIGHT_SPAWN,
    DM_PREFLIGHT_REGISTER, DM_PREFLIGHT_READ, DM_PREFLIGHT_REAP,
    DM_PREFLIGHT_TIMEOUT, DM_PREFLIGHT_WAIT, DM_PREFLIGHT_EXIT,
    DM_PREFLIGHT_PACKET, DM_PREFLIGHT_PROTOCOL
} dm_nextendo_preflight_stage;
typedef struct { int stage, error, bytes, exit_code, signal; } dm_nextendo_preflight_status;
dm_nextendo_preflight_status dm_nextendo_preflight_last_status(void);
// A complete versioned packet and a clean exit from the owned child are required.
int dm_nextendo_preflight_query(dm_nextendo_preflight_reply *out, unsigned timeout_ms);
int dm_nextendo_account_preflight_child(int fd);
