// Opt-in metadata only: no account values, network addresses or guest pointers.
#pragma once
#include <stdint.h>

typedef enum { DM_ACCOUNT_TRACE_AVAILABLE, DM_ACCOUNT_TRACE_NETWORK_RESULT } dm_account_trace_operation;
typedef struct { int enabled, pending, hold, ip_queried; } dm_account_trace_network;
typedef struct {
    int enabled, provider, cached, query_valid, child_available, expiry_valid, generation_changed;
    int stage, error, bytes, exit_code, signal;
} dm_account_trace_provider_state;
void dm_account_trace_available(uint32_t result, int valid_handle, int available);
void dm_account_trace_provider(int available, dm_account_trace_provider_state state);
void dm_account_trace_nifm(dm_account_trace_operation operation, uint32_t result, int available,
                           dm_account_trace_network state);
