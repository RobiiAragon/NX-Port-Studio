#include "account_trace.h"
#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Four independent budgets keep a polling NIFM caller from hiding account state.
static _Atomic unsigned events[4 + DM_ACCOUNT_RETURN_COUNT + DM_ACCOUNT_API_COUNT];
static _Atomic uint64_t previous[4 + DM_ACCOUNT_RETURN_COUNT + DM_ACCOUNT_API_COUNT] = {UINT64_MAX,UINT64_MAX,UINT64_MAX,UINT64_MAX};
static int reserve_event(unsigned section, uint64_t signature) {
    const char *flag = getenv("DM_ACCOUNT_TRACE");
    if (!flag || strcmp(flag, "1")) return 0;
    if (atomic_exchange(&previous[section],signature) == signature) return 0;
    unsigned count = atomic_load(&events[section]);
    while (count < 32) {
        if (atomic_compare_exchange_weak(&events[section], &count, count + 1)) return 1;
    }
    return 0;
}
void dm_account_trace_available(uint32_t result, int valid_handle, int available) {
    int saved = errno;
    uint64_t signature = result | (uint64_t)(valid_handle+1)<<32 | (uint64_t)(available+1)<<34;
    if (reserve_event(0,signature)) fprintf(stderr, "[account-trace] op=acc.available result=0x%x valid_handle=%d available=%d\n",
                                result, valid_handle, available);
    errno = saved;
}
void dm_account_trace_provider(int available, dm_account_trace_provider_state state) {
    int saved = errno;
    uint64_t signature = (uint64_t)(available+1) | (uint64_t)(state.enabled+1)<<2 |
        (uint64_t)(state.provider+1)<<4 | (uint64_t)(state.cached+1)<<6 |
        (uint64_t)(state.query_valid+1)<<8 | (uint64_t)(state.child_available+1)<<10 |
        (uint64_t)(state.expiry_valid+1)<<12 | (uint64_t)(state.generation_changed+1)<<14;
    const int details[]={state.stage,state.error,state.bytes,state.exit_code,state.signal,state.credential_reason,state.security_status};
    for(unsigned i=0;i<sizeof details/sizeof *details;i++) signature=(signature^(uint32_t)details[i])*UINT64_C(1099511628211);
    if (reserve_event(1,signature)) fprintf(stderr,"[account-trace] op=acc.provider available=%d enabled=%d provider=%d cached=%d query_valid=%d child_available=%d expiry_valid=%d generation_changed=%d stage=%d error=%d bytes=%d exit=%d signal=%d credential_reason=%d security_status=%d\n",
        available,state.enabled,state.provider,state.cached,state.query_valid,state.child_available,state.expiry_valid,state.generation_changed,
        state.stage,state.error,state.bytes,state.exit_code,state.signal,state.credential_reason,state.security_status);
    errno = saved;
}
void dm_account_trace_nifm(dm_account_trace_operation operation, uint32_t result, int available,
                           dm_account_trace_network state) {
    int saved = errno;
    uint64_t signature = result | (uint64_t)(available+1)<<32 | (uint64_t)(state.enabled+1)<<34 |
        (uint64_t)(state.pending+1)<<36 | (uint64_t)(state.hold+1)<<38 | (uint64_t)(state.ip_queried+1)<<40;
    unsigned section = operation == DM_ACCOUNT_TRACE_AVAILABLE ? 2 : 3;
    if (reserve_event(section,signature)) fprintf(stderr, "[account-trace] op=nifm.%s return=0x%x available=%d enabled=%d pending=%d hold=%d ip_queried=%d\n",
                                operation == DM_ACCOUNT_TRACE_AVAILABLE ? "available" : "result",
                                result, available, state.enabled, state.pending, state.hold, state.ip_queried);
    errno = saved;
}
uint32_t dm_account_trace_return(dm_account_trace_return_operation operation, uint32_t result,
                                dm_account_trace_return_stage stage) {
    int saved = errno;
    static const char *names[] = {"acc.ensure", "acc.id", "acc.load_token", "acc.async_ensure", "acc.async_result"};
    if (result && (unsigned)operation < DM_ACCOUNT_RETURN_COUNT && (unsigned)stage <= DM_ACCOUNT_STAGE_ASYNC_COMPLETION &&
        reserve_event(4 + (unsigned)operation, result | (uint64_t)stage << 32))
        fprintf(stderr, "[account-trace] op=%s result=0x%x stage=%u\n", names[operation], result, (unsigned)stage);
    errno = saved; return result;
}
uint32_t dm_account_trace_credential_return(dm_account_trace_return_operation operation, uint32_t result,
                                          dm_nextendo_credential_diagnostic diagnostic) {
    int saved=errno;
    static const char *names[]={"acc.ensure","acc.id","acc.load_token","acc.async_ensure","acc.async_result"};
    uint64_t signature=result | (uint64_t)DM_ACCOUNT_STAGE_CREDENTIAL<<32;
    signature=(signature^diagnostic.reason)*UINT64_C(1099511628211);
    signature=(signature^(uint32_t)diagnostic.security_status)*UINT64_C(1099511628211);
    if (result && (unsigned)operation<DM_ACCOUNT_RETURN_COUNT && diagnostic.reason>DM_CRED_UNOBSERVED && diagnostic.reason<DM_CRED_REASON_COUNT &&
        reserve_event(4+(unsigned)operation,signature))
        fprintf(stderr,"[account-trace] op=%s result=0x%x stage=2 credential_reason=%u security_status=%d\n",names[operation],result,diagnostic.reason,diagnostic.security_status);
    errno=saved;return result;
}
void dm_account_trace_api(dm_account_trace_api_operation operation,unsigned http_status) {
    int saved=errno;
    static const char *names[]={"api.me","api.friends","api.presence"};
    if((unsigned)operation<DM_ACCOUNT_API_COUNT) {
        unsigned status=http_status>=100&&http_status<=599?http_status:0;
        if(reserve_event(4+DM_ACCOUNT_RETURN_COUNT+(unsigned)operation,(uint64_t)status+1))
            fprintf(stderr,"[account-trace] op=%s http_status=%u\n",names[operation],status);
    }
    errno=saved;
}
