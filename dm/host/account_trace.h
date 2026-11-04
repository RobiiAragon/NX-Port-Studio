// Opt-in metadata only: no account values, network addresses or guest pointers.
#pragma once
#include <stdint.h>

typedef enum { DM_ACCOUNT_TRACE_AVAILABLE, DM_ACCOUNT_TRACE_NETWORK_RESULT } dm_account_trace_operation;
typedef struct { int enabled, pending, hold, ip_queried; } dm_account_trace_network;
typedef struct {
    int enabled, provider, cached, query_valid, child_available, expiry_valid, generation_changed;
    int stage, error, bytes, exit_code, signal;
} dm_account_trace_provider_state;
typedef enum {
    DM_ACCOUNT_RETURN_ENSURE, DM_ACCOUNT_RETURN_ID, DM_ACCOUNT_RETURN_TOKEN,
    DM_ACCOUNT_RETURN_ASYNC_ENSURE, DM_ACCOUNT_RETURN_ASYNC_RESULT, DM_ACCOUNT_RETURN_COUNT
} dm_account_trace_return_operation;
typedef enum {
    DM_ACCOUNT_STAGE_ARGUMENT, DM_ACCOUNT_STAGE_USER_HANDLE, DM_ACCOUNT_STAGE_CREDENTIAL,
    DM_ACCOUNT_STAGE_ID_TOKEN, DM_ACCOUNT_STAGE_OUTPUT_BUFFER, DM_ACCOUNT_STAGE_BAAS_ID,
    DM_ACCOUNT_STAGE_ASYNC_SETUP, DM_ACCOUNT_STAGE_ASYNC_CONTEXT,
    DM_ACCOUNT_STAGE_ASYNC_STATE, DM_ACCOUNT_STAGE_ASYNC_COMPLETION
} dm_account_trace_return_stage;
void dm_account_trace_available(uint32_t result, int valid_handle, int available);
void dm_account_trace_provider(int available, dm_account_trace_provider_state state);
void dm_account_trace_nifm(dm_account_trace_operation operation, uint32_t result, int available,
                           dm_account_trace_network state);
// Returns the result unchanged. Failed stages only; no extra account queries.
uint32_t dm_account_trace_return(dm_account_trace_return_operation operation, uint32_t result,
                                dm_account_trace_return_stage stage);
