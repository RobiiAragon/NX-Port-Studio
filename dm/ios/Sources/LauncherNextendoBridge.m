// App-private Keychain reader for the native account bridge. No token travels
// through SwiftUI, environment variables, application resources or log output.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "nextendo_account.h"
#include "nextendo_routes.h"

void dm_guest_host_wait_begin(void);
void dm_guest_host_wait_end(void);

static bool mobile_credential(uint8_t *buffer, size_t capacity, size_t *size) {
    if (!size) return false;
    *size = 0;
    if (!buffer || !capacity) return false;
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"org.nxnative.nextendo.account",
        (__bridge id)kSecAttrAccount: @"active", (__bridge id)kSecAttrSynchronizable: @NO,
        (__bridge id)kSecReturnData: @YES, (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
    CFTypeRef item = NULL;
    dm_guest_host_wait_begin();
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &item);
    dm_guest_host_wait_end();
    if (status != errSecSuccess || !item) { if (item) CFRelease(item); return false; }
    NSData *data = CFBridgingRelease(item);
    if (![data isKindOfClass:NSData.class] || !data.length || data.length > 65536 || data.length > capacity) return false;
    memcpy(buffer, data.bytes, data.length);
    *size = data.length;
    return true; // The HLE validates schema, identity, nx2 proof shape and expiry.
}
void dm_mobile_nextendo_use_keychain(void) { dm_nextendo_set_credential_provider(mobile_credential); }
int dm_mobile_nextendo_routes_state(void) {
    // Do not freeze the immutable route policy before the user applies a mode.
    int state = dm_nextendo_routes_status();
    return state == DM_NEXTENDO_ROUTES_READY && !dm_nextendo_routes_count() ? DM_NEXTENDO_ROUTES_MISSING : state;
}

// One-time migration input only. Native game reads never fall back to this file.
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
static int legacy_directory(void) {
    NSString *path = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return path ? open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1;
}
static int legacy_read_at(int directory, const char *name, uint8_t *buffer, size_t capacity, size_t *size) {
    *size = 0;
    int fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
        (st.st_mode & 0777) != 0600 || st.st_size <= 0 || st.st_size > 65536 || (uint64_t)st.st_size > capacity) {
        close(fd); return 0;
    }
    size_t done = 0;
    while (done < (size_t)st.st_size) {
        ssize_t n = read(fd, buffer + done, (size_t)st.st_size - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return 0; }
        done += (size_t)n;
    }
    close(fd); *size = done; return 1;
}
static int legacy_read(int directory, uint8_t *buffer, size_t capacity, size_t *size) {
    return legacy_read_at(directory, "nextendo-account.json", buffer, capacity, size);
}
int dm_mobile_nextendo_copy_legacy(uint8_t *buffer, size_t capacity, size_t *size) {
    if (!buffer || !size || !capacity) return 0;
    *size = 0; int directory = legacy_directory(); if (directory < 0) return 0;
    int result = legacy_read(directory, buffer, capacity, size); close(directory); return result;
}
#ifdef DM_MOBILE_NEXTENDO_LEGACY_TEST
static void (*legacy_retired_hook)(int directory);
#endif
static int retire_legacy(int directory, const uint8_t *expected, size_t size) {
    // Capture the directory entry atomically. A replacement published after this
    // point keeps its original name and must never be deleted by migration.
    NSString *temporary = [@".nextendo-migration-" stringByAppendingString:NSUUID.UUID.UUIDString];
    const char *name = temporary.fileSystemRepresentation;
    if (renameatx_np(directory, "nextendo-account.json", directory, name, RENAME_EXCL)) return errno == ENOENT;
#ifdef DM_MOBILE_NEXTENDO_LEGACY_TEST
    if (legacy_retired_hook) legacy_retired_hook(directory);
#endif
    if (expected) {
        uint8_t bytes[65536]; size_t got = 0;
        if (!size || size > sizeof bytes || !legacy_read_at(directory, name, bytes, sizeof bytes, &got) || got != size || memcmp(bytes, expected, size)) {
            // Restore only if no newer record occupies the original name. If a
            // concurrent record exists, retain the captured private file too.
            (void)renameatx_np(directory, name, directory, "nextendo-account.json", RENAME_EXCL);
            return 0;
        }
    }
    return unlinkat(directory, name, 0) == 0;
}
int dm_mobile_nextendo_remove_legacy(const uint8_t *expected, size_t size) {
    int directory = legacy_directory(); if (directory < 0) return 0;
    int result = retire_legacy(directory, expected, size);
    close(directory); return result;
}
