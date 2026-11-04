// Internal native HTTPS boundary. Never exposed to the guest HLE symbol table.
#pragma once
#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

// Returns only a currently valid NEX proof, in explicit Nextendo mode.
NSString *dm_nextendo_api_bearer(void);
NSData *dm_nextendo_api_identity(void);
// Memory-only social authorization. Never reads storage or calls a provider.
// A nonzero generation identifies this validated proof's current local lifetime.
NSString *dm_nextendo_api_passive_bearer(uint64_t *generation);
bool dm_nextendo_api_passive_valid(NSString *proof, uint64_t generation);
bool dm_nextendo_api_baas_namespace(const char *kind);
uint32_t dm_nextendo_api_baas_id(uint64_t *output);
// Only the canonical provider's friends, me and presence resources are admitted.
uint32_t dm_nextendo_api_request(const char *resource, const uint8_t *body, size_t body_size,
                               uint8_t *output, size_t capacity, size_t *output_size);
// Same canonical transport, authorized only by a current memory snapshot. The
// caller retains the exact proof/generation across publication and completion.
uint32_t dm_nextendo_api_request_passive(const char *resource, const uint8_t *body, size_t body_size,
    uint8_t *output, size_t capacity, size_t *output_size, NSString *proof, uint64_t generation);
#ifdef DM_NEXTENDO_API_TEST
typedef bool (*dm_nextendo_api_transport)(const char *url, const char *method, const char *authorization,
    const uint8_t *body, size_t body_size, uint8_t *output, size_t capacity, size_t *size, unsigned *status);
void dm_nextendo_api_test_transport(dm_nextendo_api_transport transport);
#endif
