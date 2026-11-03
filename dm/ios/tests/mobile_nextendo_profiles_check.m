// Original route-precedence fixture. Keychain and account functions are never called.
#import "../Sources/LauncherNextendoBridge.m"
#include "../Sources/LauncherNextendoProfiles.h"
#include <stdio.h>
void dm_guest_host_wait_begin(void) {}
void dm_guest_host_wait_end(void) {}
void dm_nextendo_set_credential_provider(dm_nextendo_credential_provider provider) { (void)provider; }
static int policy_status = DM_NEXTENDO_ROUTES_UNINITIALIZED, initialized;
static char selected[4096];
int dm_nextendo_routes_status(void) { return policy_status; }
size_t dm_nextendo_routes_count(void) { return policy_status == DM_NEXTENDO_ROUTES_READY; }
int dm_nextendo_routes_initialize(void) {
    initialized++;
    strlcpy(selected, getenv("DM_NEXTENDO_ROUTES") ?: "", sizeof selected);
    return policy_status = DM_NEXTENDO_ROUTES_READY;
}
int dm_nextendo_routes_retry_unconfigured(void) { return policy_status = DM_NEXTENDO_ROUTES_UNINITIALIZED; }
static void profile(NSString *root, BOOL local) {
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *name in local ? @[@"nextendo", @"nextendo-private"] : @[@"nextendo"]) {
        NSString *path = [[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"routes.tsv"];
        if (![files createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil] ||
            ![@"original synthetic profile" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) abort();
    }
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc == 2) {
        dm_launcher_configure_nextendo_routes(argv[1]);
        puts(getenv("DM_NEXTENDO_ROUTES") ?: "<unset>");
        return 0;
    }
    if (argc != 3 || strcmp(argv[1], "--bridge")) return 2;
    NSString *root = [NSString stringWithUTF8String:argv[2]];
    NSString *publicRoot = [root stringByAppendingPathComponent:@"public-only"];
    NSString *privateRoot = [root stringByAppendingPathComponent:@"with-private"];
    profile(publicRoot, NO); profile(privateRoot, YES);
    NSString *privatePath = [privateRoot stringByAppendingPathComponent:@"nextendo-private/routes.tsv"];
    int failed = 0, checks = 0;
    const char *downloaded = "/original-synthetic/downloaded/routes.tsv";
    struct { const char *root, *explicit, *expected; } cases[] = {
        {privateRoot.fileSystemRepresentation, NULL, privatePath.fileSystemRepresentation},
        {publicRoot.fileSystemRepresentation, NULL, downloaded},
        {argv[2], "/original-synthetic/explicit/routes.tsv", "/original-synthetic/explicit/routes.tsv"},
        {argv[2], NULL, downloaded}
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        policy_status = DM_NEXTENDO_ROUTES_UNINITIALIZED;
        unsetenv("DM_NEXTENDO_ROUTES");
        if (cases[i].explicit) setenv("DM_NEXTENDO_ROUTES", cases[i].explicit, 1);
        dm_launcher_configure_nextendo_routes(cases[i].root);
        checks++; failed += dm_mobile_nextendo_apply_service_profile(downloaded) != DM_NEXTENDO_ROUTES_READY;
        checks++; failed += strcmp(selected, cases[i].expected) != 0;
    }
    int before = initialized;
    checks++; failed += dm_mobile_nextendo_apply_service_profile("/different/routes.tsv") != DM_NEXTENDO_ROUTES_READY;
    checks++; failed += initialized != before || strcmp(selected, downloaded);
    unsetenv("DM_NEXTENDO_ROUTES"); policy_status = DM_NEXTENDO_ROUTES_UNINITIALIZED;
    dm_launcher_configure_nextendo_routes(argv[2]);
    checks++; failed += dm_mobile_nextendo_apply_service_profile("relative/routes.tsv") != DM_NEXTENDO_ROUTES_INVALID;
    checks++; failed += getenv("DM_NEXTENDO_ROUTES") != NULL;
    dm_launcher_configure_nextendo_routes(publicRoot.fileSystemRepresentation);
    policy_status = DM_NEXTENDO_ROUTES_INVALID;
    checks++; failed += dm_mobile_nextendo_apply_service_profile("/updated/downloaded/routes.tsv") != DM_NEXTENDO_ROUTES_READY;
    checks++; failed += strcmp(selected, "/updated/downloaded/routes.tsv") != 0;
    printf("mobile profile precedence: %d checks, %d failed\n", checks, failed);
    return failed ? 1 : 0;
}}
