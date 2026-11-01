// No launcher child or exec handover: the declared app executable is the host.
// Unbundled tools keep their original CLI and do not load AppKit/SwiftUI here.
#include "bundle_mac.h"
#include "game_profile.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    return prepare(argc, argv, DM_GAME_ID);
}
