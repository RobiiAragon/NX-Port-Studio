// No launcher child or exec handover: the declared app executable is the host.
// Unbundled tools keep their original CLI and do not load AppKit/SwiftUI here.
#include "bundle_mac.h"
#include "game_profile.h"
#include "net_socket.h"
#include "nextendo_account.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *bootstrap_image;

// NX Port Studio's Nextendo agent, when it answers, owns the account for this
// port (docs/nextendo-agent.md): the host reads its record through the provider
// and this process neither reads the Keychain nor renews.
static bool (*agent_credential)(uint8_t *, size_t, size_t *);
static bool agent_provider(uint8_t *buffer, size_t capacity, size_t *size) {
    return agent_credential && agent_credential(buffer, capacity, size);
}

// Called on the existing guest worker while the primary AppKit loop is active.
// CLI hosts and local-only modes do not load account code or read storage.
void dm_mac_bundle_prepare_account(void) {
    if (!bootstrap_image || !dm_net_nextendo_enabled()) return;
    bool (*agent)(void (*)(void)) = dlsym(bootstrap_image, "dm_mac_agent_prepare");
    agent_credential = dlsym(bootstrap_image, "dm_mac_agent_credential");
    const char *use_agent = getenv("DM_NEXTENDO_AGENT");   // 0: skip the agent, sign in from this port
    if ((!use_agent || strcmp(use_agent, "0")) && agent && agent_credential && agent(dm_nextendo_account_invalidate_social)) {
        dm_nextendo_set_credential_provider(agent_provider);
        return;
    }
    void (*prepare)(void) = dlsym(bootstrap_image, "dm_mac_prepare_game_account");
    if (prepare) prepare();
    else fputs("[RED] launcher: account preparation is unavailable in the bundled bootstrap\n", stderr);
}

int dm_mac_bundle_prepare(int *argc, char ***argv) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle || CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("DMPrimaryHost")) != kCFBooleanTrue) return -1;
    CFTypeRef value = CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("DMTitleID"));
    char title[64];
    if (!value || CFGetTypeID(value) != CFStringGetTypeID() ||
        !CFStringGetCString(value, title, sizeof title, kCFStringEncodingUTF8) || strcasecmp(title, DM_GAME_ID)) {
        fputs("[RED] launcher: bundle title does not match this native host; pack the matching host again\n", stderr);
        return 1;
    }
    char self[PATH_MAX], executable[PATH_MAX], library[PATH_MAX]; uint32_t n = sizeof self;
    if (_NSGetExecutablePath(self, &n) || !realpath(self, executable)) return 1;
    char *slash = strrchr(executable, '/'); if (!slash) return 1; *slash = 0;
    int length = snprintf(library, sizeof library, "%s/../Frameworks/DMMacBootstrap.dylib", executable);
    if (length < 0 || (size_t)length >= sizeof library) return 1;
    void *image = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!image) { fprintf(stderr, "[RED] launcher: cannot load the bundled bootstrap: %s\n", dlerror()); return 1; }
    int (*prepare)(int *, char ***, const char *) = dlsym(image, "dm_mac_app_prepare");
    if (!prepare) { fputs("[RED] launcher: bundled bootstrap has no compatible entry point\n", stderr); return 1; }
    // Keep the image loaded: AppKit/SwiftUI callbacks and prepared argv live on.
    int result = prepare(argc, argv, DM_GAME_ID);
    if (result < 0) bootstrap_image = image;
    return result;
}
