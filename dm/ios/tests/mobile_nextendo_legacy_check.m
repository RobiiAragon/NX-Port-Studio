// Exercise the actual bounded reader using a temporary directory, never the
// app's Documents or Keychain. Account/route hooks are inert link-time fixtures.
#define DM_MOBILE_NEXTENDO_LEGACY_TEST 1
#import "../Sources/LauncherNextendoBridge.m"
#include <stdio.h>
void dm_guest_host_wait_begin(void) {}
void dm_guest_host_wait_end(void) {}
void dm_nextendo_set_credential_provider(dm_nextendo_credential_provider provider) { (void)provider; }
int dm_nextendo_routes_status(void) { return -1; }
size_t dm_nextendo_routes_count(void) { return 0; }
static const char replacement[] = "a newer synthetic record";
static void publish_replacement(int directory) {
    int fd = openat(directory, "nextendo-account.json", O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (fd >= 0) { write(fd, replacement, sizeof replacement); close(fd); }
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int directory = open(argv[1], O_DIRECTORY | O_RDONLY | O_CLOEXEC), failures = 0;
    if (directory < 0) return 2;
    const char *name = "nextendo-account.json", bytes[] = "synthetic migration fixture";
    int fd = openat(directory, name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) return 2;
    write(fd, bytes, sizeof bytes); close(fd);
    uint8_t output[65536]; size_t size = 0;
    failures += !legacy_read(directory, output, sizeof output, &size) || size != sizeof bytes || memcmp(output, bytes, sizeof bytes);
    failures += legacy_read(directory, output, 1, &size) != 0;
    fchmodat(directory, name, 0644, 0);
    failures += legacy_read(directory, output, sizeof output, &size) != 0;
    fchmodat(directory, name, 0600, 0);
    fd = openat(directory, name, O_WRONLY); ftruncate(fd, 65537); close(fd);
    failures += legacy_read(directory, output, sizeof output, &size) != 0;
    unlinkat(directory, name, 0);
    fd = openat(directory, "elsewhere", O_CREAT | O_EXCL | O_WRONLY, 0600);
    write(fd, bytes, sizeof bytes); close(fd);
    symlinkat("elsewhere", directory, name);
    failures += legacy_read(directory, output, sizeof output, &size) != 0;
    unlinkat(directory, name, 0);
    mkfifoat(directory, name, 0600);
    failures += legacy_read(directory, output, sizeof output, &size) != 0;
    unlinkat(directory, name, 0);
    fd = openat(directory, name, O_CREAT | O_EXCL | O_WRONLY, 0600);
    write(fd, bytes, sizeof bytes); close(fd);
    legacy_retired_hook = publish_replacement;
    failures += !retire_legacy(directory, (const uint8_t *)bytes, sizeof bytes);
    legacy_retired_hook = NULL;
    failures += !legacy_read(directory, output, sizeof output, &size) || size != sizeof replacement || memcmp(output, replacement, sizeof replacement);
    failures += retire_legacy(directory, (const uint8_t *)bytes, sizeof bytes) != 0;
    failures += !legacy_read(directory, output, sizeof output, &size) || size != sizeof replacement || memcmp(output, replacement, sizeof replacement);
    failures += !retire_legacy(directory, NULL, 0);
    unlinkat(directory, "elsewhere", 0);
    close(directory);
    printf("mobile legacy reader: %d failed\n", failures);
    return failures ? 1 : 0;
}
