// Packed Mac app bootstrap, loaded by the real primary host before guest boot.
// LaunchServices starts the declared engine executable directly: no child
// renderer and no exec handover, so this keeps both app ownership and TCC.
// Bundle layout: Resources/romfs.img (the game's RomFS image; legacy romfs/ also supported), Resources/msl/<b-chain | vk | gl> (the Mac shader libraries), Resources/aoc/<index> (DLC), Resources/pso (the pipeline archive made
// offline, handed to the host as DM_PSO_BUNDLE as the iOS app's main.m does), Resources/dm (the rewritten modules, the shader tables and pairs, font/, env.txt). Saves, the pipeline list and temporary files go to ~/Library/Application Support/nxnative/<title ID>/, the host's output to ~/Library/Logs/nxnative/<title ID>.log
// (the previous run's kept as <title ID>.prev.log). Environment switches: one KEY=VALUE per line in <Application Support folder>/env.txt, then Resources/dm/env.txt (the first one wins; neither
// replaces a variable already set), as the iOS app reads Documents/env.txt and dm/env.txt. Then the player's saved choices: launcher.<VAR> strings in the app's preferences domain (its bundle ID), which a
// front end or a settings window writes, each checked against the bundle's settings (Info.plist DMSettings, from launcher.json) and used only for a variable still unset; DM_SAVED_CHOICES=0 ignores them.
// So the order is: the launch environment, the player's env.txt, the bundle's, saved choices, the host's tested defaults (docs/frontends.md, Saved choices).
// Before the guest starts, the settings window (dm/mac/Launcher.swift dm_mac_launcher) runs in this process and puts the player's settings into the environment; it keeps
// what the launch environment and the env files set (DM_ENV_LAUNCH_KEYS, DM_ENV_FILE_KEYS). DM_LAUNCHER=0 or --no-launcher (open <app> --args --no-launcher) starts the game without the window,
// with the saved choices; so does "Show this window at launch" turned off.
#include <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "romfs_image.h"
#include "save_supervisor.h"
#include "front.h"

extern char **environ;
int dm_mac_launcher(void);   // Launcher.swift: 1 = Play (the settings are in the environment), 0 = the player quit, 2 = no window (apply the saved choices here)
static char *g_file_keys, *g_launch_keys;   // the variables the env files set, and the settings the launch environment set (DM_ENV_FILE_KEYS, DM_ENV_LAUNCH_KEYS)

static void add_key(char **list, const char *k) {   // a space-separated list of names
    char *s;
    if (asprintf(&s, "%s%s%s", *list ? *list : "", *list ? " " : "", k) < 0) { fputs("[RED] launcher: out of memory\n", stderr); exit(1); }
    free(*list); *list = s;
}

static int info_string(const char *key, char *out, size_t n) {   // a string key of the bundle's Info.plist
    CFBundleRef b = CFBundleGetMainBundle(); if (!b) return 0;
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFBundleGetValueForInfoDictionaryKey(b, k); CFRelease(k);
    return v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString(v, out, (CFIndex)n, kCFStringEncodingUTF8) && *out;
}

static void alert(const char *title, const char *msg) {   // a dialog (the app has no window of its own), and the same line on stderr
    fprintf(stderr, "[RED] %s\n", msg);
    char *script = "on run argv\ndisplay alert (item 1 of argv) message (item 2 of argv) as critical\nend run";
    char *argv[] = {"osascript", "-e", script, (char *)title, (char *)msg, NULL}; pid_t pid; int st;
    if (!posix_spawnp(&pid, "osascript", NULL, NULL, argv, environ)) while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
}

static int modules_present(const char *dm) {   // the packer's inventory detects even a missing binary/table pair
    CFBundleRef b = CFBundleGetMainBundle(); if (!b) return 0;
    CFTypeRef files = CFBundleGetValueForInfoDictionaryKey(b, CFSTR("DMModuleFiles"));
    if (!files || CFGetTypeID(files) != CFArrayGetTypeID() || !CFArrayGetCount(files)) return 0;
    for (CFIndex i = 0; i < CFArrayGetCount(files); i++) {
        CFTypeRef v = CFArrayGetValueAtIndex(files, i); char name[PATH_MAX], path[PATH_MAX]; struct stat st;
        if (CFGetTypeID(v) != CFStringGetTypeID() || !CFStringGetCString(v, name, sizeof name, kCFStringEncodingUTF8) || !*name || strchr(name, '/')) return 0;
        int n = snprintf(path, sizeof path, "%s/%s", dm, name);
        if (n < 0 || (size_t)n >= sizeof path || stat(path, &st) || !S_ISREG(st.st_mode) || access(path, R_OK)) return 0;
    }
    return 1;
}

static void mkdirs(const char *path) {   // mkdir -p
    char p[PATH_MAX]; snprintf(p, sizeof p, "%s", path);
    for (char *s = p + 1; *s; s++) if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; }
    mkdir(p, 0755);
}

static void env_file(const char *path) {   // KEY=VALUE lines, # starts a comment; a variable already set stays
    FILE *f = fopen(path, "r"); if (!f) return;
    char ln[4096];
    while (fgets(ln, sizeof ln, f)) {
        char *s = ln; while (*s == ' ' || *s == '\t') s++;
        char *e = s + strlen(s); while (e > s && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' ' || e[-1] == '\t')) *--e = 0;
        char *eq = strchr(s, '=');
        if (*s == '#' || !eq || eq == s) continue;
        *eq = 0; char *k = s; for (char *t = eq - 1; t > k && (*t == ' ' || *t == '\t'); t--) *t = 0;
        if (!getenv(k)) {
            setenv(k, eq + 1, 0); add_key(&g_file_keys, k);
            const char *value=!strcmp(k,"DM_MII_DATABASE") || !strcmp(k,"DM_MII_SEED") ? "<private Mii path>" : eq+1;
            fprintf(stderr, "launcher: env %s=%s (%s)\n", k, value, path);
        }
    }
    fclose(f);
}

static int saved_accepted(CFDictionaryRef rule, CFStringRef v, const char *s) {   // a saved choice this build still offers: one of its values, or a number in its range
    CFTypeRef values = CFDictionaryGetValue(rule, CFSTR("values"));
    if (values && CFGetTypeID(values) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(values); i++) {
            CFTypeRef o = CFArrayGetValueAtIndex(values, i);
            if (CFGetTypeID(o) == CFStringGetTypeID() && CFStringCompare(o, v, 0) == kCFCompareEqualTo) return 1;
        }
        return 0;
    }
    CFTypeRef lo = CFDictionaryGetValue(rule, CFSTR("min")), hi = CFDictionaryGetValue(rule, CFSTR("max")); double l, h;
    if (!lo || !hi || CFGetTypeID(lo) != CFNumberGetTypeID() || CFGetTypeID(hi) != CFNumberGetTypeID()) return 0;
    CFNumberGetValue(lo, kCFNumberDoubleType, &l); CFNumberGetValue(hi, kCFNumberDoubleType, &h);
    char *end; double x = strtod(s, &end);
    return *s && !isspace((unsigned char)*s) && !strpbrk(s, "xX") && !*end && x == x && x >= l && x <= h;   // as Setting.accepts (LauncherSettings.swift): no leading space, no hex, no NaN
}

static CFArrayRef setting_rules(void) {   // Info.plist DMSettings (pack_app.py, from launcher.json): each setting's variable and the values it takes
    CFBundleRef b = CFBundleGetMainBundle(); if (!b) return NULL;
    CFTypeRef rules = CFBundleGetValueForInfoDictionaryKey(b, CFSTR("DMSettings"));
    return rules && CFGetTypeID(rules) == CFArrayGetTypeID() ? rules : NULL;
}

static int rule_env(CFTypeRef rule, char *env, size_t n) {   // a rule's variable name
    if (CFGetTypeID(rule) != CFDictionaryGetTypeID()) return 0;
    CFTypeRef e = CFDictionaryGetValue(rule, CFSTR("env"));
    return e && CFGetTypeID(e) == CFStringGetTypeID() && CFStringGetCString(e, env, (CFIndex)n, kCFStringEncodingUTF8);
}

static void saved_choices(void) {   // after the env files, before the bundle's own defaults (DM_LANG): a variable already set keeps its value
    CFArrayRef rules = setting_rules(); CFStringRef domain = CFBundleGetIdentifier(CFBundleGetMainBundle());
    if (!rules || !domain) return;   // packed without launcher settings: nothing to choose
    const char *off = getenv("DM_SAVED_CHOICES");
    if (off && !strcmp(off, "0")) { fprintf(stderr, "launcher: saved choices ignored (DM_SAVED_CHOICES=0)\n"); return; }
    for (CFIndex i = 0; i < CFArrayGetCount(rules); i++) {
        CFTypeRef rule = CFArrayGetValueAtIndex(rules, i); char env[128], s[256];
        if (!rule_env(rule, env, sizeof env)) continue;
        CFStringRef key = CFStringCreateWithFormat(NULL, NULL, CFSTR("launcher.%s"), env);
        CFPropertyListRef v = CFPreferencesCopyAppValue(key, domain); CFRelease(key);
        if (!v) continue;
        if (CFGetTypeID(v) != CFStringGetTypeID() || !CFStringGetCString(v, s, sizeof s, kCFStringEncodingUTF8)) fprintf(stderr, "launcher: saved choice for %s ignored: not a string of at most %zu bytes\n", env, sizeof s - 1);
        else if (!saved_accepted(rule, v, s)) fprintf(stderr, "launcher: saved choice %s=%s ignored: this build does not offer it\n", env, s);
        else if (getenv(env)) fprintf(stderr, "launcher: saved choice %s=%s not used: %s=%s is set (environment or env.txt)\n", env, s, env, getenv(env));
        else { setenv(env, s, 0); fprintf(stderr, "launcher: env %s=%s (saved choice)\n", env, s); }
        CFRelease(v);
    }
}

// Cloud saves: the folder chosen in the settings window (Launcher.swift CloudSavesSection, cloudSaves.folder in the app's preferences) becomes DM_SAVE_SYNC
// (dm/host/save_sync.h), with or without the window; a DM_SAVE_SYNC the launch environment or an env file set wins. A front end may write the key too (docs/frontends.md, The cloud saves folder)
static void cloud_saves_folder(void) {
    CFStringRef domain = CFBundleGetIdentifier(CFBundleGetMainBundle());
    if (getenv("DM_SAVE_SYNC") || !domain) return;
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("cloudSaves.folder"), domain); char s[PATH_MAX];
    if (v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString(v, s, sizeof s, kCFStringEncodingUTF8) && *s) {
        setenv("DM_SAVE_SYNC", s, 1); fprintf(stderr, "launcher: cloud saves through %s\n", s);
    }
    if (v) CFRelease(v);
}

int dm_mac_app_prepare(int *host_argc, char ***host_argv, const char *expected_title) {
    int argc = *host_argc; char **argv = *host_argv;
    char self[PATH_MAX], exe[PATH_MAX]; uint32_t n = sizeof self;
    if (_NSGetExecutablePath(self, &n) || !realpath(self, exe)) return 1;
    char contents[PATH_MAX], res[PATH_MAX], helper[PATH_MAX], dm[PATH_MAX], romfs[PATH_MAX], p[PATH_MAX];
    snprintf(contents, sizeof contents, "%s", exe); *strrchr(contents, '/') = 0; *strrchr(contents, '/') = 0;   // .../Contents/MacOS/<launcher> → .../Contents
    snprintf(res, sizeof res, "%s/Resources", contents); snprintf(helper, sizeof helper, "%s/Helpers/dm-save-supervisor", contents);
    snprintf(dm, sizeof dm, "%s/dm", res); snprintf(romfs, sizeof romfs, "%s/romfs", res);
    char name[256] = "nxnative", id[64] = "", marker[512] = "", lang[32] = "";
    if (!info_string("CFBundleName", name, sizeof name)) snprintf(name, sizeof name, "nxnative");
    info_string("DMRomfsMarker", marker, sizeof marker); info_string("DMLanguage", lang, sizeof lang);
    if (!info_string("DMTitleID", id, sizeof id) || strlen(id) != 16 || strspn(id, "0123456789abcdefABCDEF") != 16 || strcasecmp(id, expected_title)) { alert(name, "This app has no title ID in its Info.plist (DMTitleID): pack it again with build_ipa_from_nsp.py --platform mac-app."); return 1; }
    struct stat st; snprintf(p, sizeof p, "%s/romfs.img", res);
    int valid_romfs;
    if (!stat(p, &st)) {
        romfs_img *image = romfs_image_open(p); valid_romfs = image != NULL;
        romfs_image_close(image); snprintf(romfs, sizeof romfs, "%s", p);
    } else { snprintf(p, sizeof p, "%s/%s", romfs, marker); valid_romfs = !stat(p, &st); }
    if (!valid_romfs || !modules_present(dm)) {
        alert(name, "The game data inside this app is missing or incomplete (Contents/Resources/romfs.img, Contents/Resources/dm): pack it again with build_ipa_from_nsp.py --platform mac-app.");
        return 1;
    }
    const char *home = getenv("HOME"); if (!home || !*home) return 1;
    char sup[PATH_MAX], save[PATH_MAX], temp[PATH_MAX], logs[PATH_MAX], log[PATH_MAX], prev[PATH_MAX];
    // Validate every path before creating state, rotating logs or exporting it.
#define LAUNCHER_STATE_PATH(destination, ...) do { int written = snprintf(destination, sizeof destination, __VA_ARGS__); if (written < 0 || (size_t)written >= sizeof destination) { fputs("[RED] launcher: state path exceeds the platform path limit\n", stderr); return 1; } } while (0)
    LAUNCHER_STATE_PATH(sup, "%s/Library/Application Support/nxnative/%s", home, id);
    LAUNCHER_STATE_PATH(save, "%s/save", sup); LAUNCHER_STATE_PATH(temp, "%s/temp", sup);
    LAUNCHER_STATE_PATH(logs, "%s/Library/Logs/nxnative", home);
    LAUNCHER_STATE_PATH(log, "%s/%s.log", logs, id); LAUNCHER_STATE_PATH(prev, "%s/%s.prev.log", logs, id);
#undef LAUNCHER_STATE_PATH
    mkdirs(save); mkdirs(temp); mkdirs(logs);
    rename(log, prev);
    int fd = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); setvbuf(stdout, NULL, _IOLBF, 0); }
    fprintf(stderr, "launcher: %s (%s), primary host pid %d\n", name, id, getpid());
    CFArrayRef rules = setting_rules();   // the settings the launch environment already set: the window shows them, fixed
    for (CFIndex i = 0; rules && i < CFArrayGetCount(rules); i++) { char env[128]; if (rule_env(CFArrayGetValueAtIndex(rules, i), env, sizeof env) && getenv(env)) add_key(&g_launch_keys, env); }
    snprintf(p, sizeof p, "%s/env.txt", sup); env_file(p);
    snprintf(p, sizeof p, "%s/env.txt", dm); env_file(p);
    setenv("DM_ENV_FILE_KEYS", g_file_keys ? g_file_keys : "", 1); setenv("DM_ENV_LAUNCH_KEYS", g_launch_keys ? g_launch_keys : "", 1);
    free(g_file_keys); free(g_launch_keys);
    // Saved values seed the engine before SwiftUI can create its first Metal
    // device. They are deliberately not added to the fixed-override lists:
    // the settings window must still let the player edit or reset them.
    saved_choices();
    front_hud_env();
    // Personal Miis are shared by native Mac ports, independently of game saves
    // and read-only firmware model resources. An explicit launch override wins.
    snprintf(p, sizeof p, "%s/Library/Application Support/NX Port Studio/Miis/library.dmii", home);
    setenv("DM_MII_DATABASE", p, 0);
    snprintf(p, sizeof p, "%s/mii_database.dmii", dm);
    if (!stat(p, &st) && S_ISREG(st.st_mode)) setenv("DM_MII_SEED", p, 0);
    int window = !(getenv("DM_LAUNCHER") && !strcmp(getenv("DM_LAUNCHER"), "0"));
    for (int i = 1; i < argc && strcmp(argv[i], "--"); i++) if (!strcmp(argv[i], "--no-launcher")) window = 0;
    if (!window) fprintf(stderr, "launcher: no settings window (DM_LAUNCHER=0 or --no-launcher)\n");
    int shown = window ? dm_mac_launcher() : 2;
    if (!shown) return 0;   // Quit: no game
    cloud_saves_folder();
    setenv("DM_ROOT", sup, 0); setenv("DM_ROMFS", romfs, 0); setenv("DM_SAVE", save, 0); setenv("DM_TEMP", temp, 0);
    snprintf(p, sizeof p, "%s/msl", res); setenv("DM_MSL_DIR", p, 0);
    snprintf(p, sizeof p, "%s/font", dm); setenv("DM_FONT_DIR", p, 0);
    snprintf(p, sizeof p, "%s/system_data", dm); if (!stat(p, &st) && S_ISDIR(st.st_mode)) setenv("DM_SYSTEM_DATA_DIR", p, 0);
    snprintf(p, sizeof p, "%s/nextendo-private/routes.tsv", dm); if (!stat(p, &st) && S_ISREG(st.st_mode)) setenv("DM_NEXTENDO_ROUTES", p, 0);
    snprintf(p, sizeof p, "%s/nextendo/routes.tsv", dm); if (!stat(p, &st) && S_ISREG(st.st_mode)) setenv("DM_NEXTENDO_ROUTES", p, 0);
    snprintf(p, sizeof p, "%s/shader_map.tsv", dm); if (!stat(p, &st)) setenv("DM_NVN_SHMAP", p, 0);
    snprintf(p, sizeof p, "%s/aoc", res); if (!stat(p, &st)) setenv("DM_AOC_DIR", p, 0);
    snprintf(p, sizeof p, "%s/pso", res); if (!stat(p, &st)) setenv("DM_PSO_BUNDLE", p, 0);   // the bases of every shader pair: the first start builds none
    if (*lang) setenv("DM_LANG", lang, 0);
    setenv("DM_WINDOW", "1", 0); setenv("DM_AUDIO", "1", 0);
    if (chdir(sup)) { fprintf(stderr, "[RED] launcher: cannot enter %s\n", sup); return 1; }
    // Engine and bootstrap share this PID. Keep the host's own signal/exit
    // semantics; the helper only observes exit and cannot become a renderer.
    if (!dm_mac_save_supervisor_start(helper, getenv("DM_SAVE"), id)) return 1;
    char **prepared = calloc((size_t)argc + 2, sizeof *prepared);
    if (!prepared) { fputs("[RED] launcher: cannot prepare host arguments\n", stderr); return 1; }
    int count = 0, game_args = 0;
    prepared[count++] = argv[0]; prepared[count++] = strdup(dm);
    if (!prepared[1]) { free(prepared); return 1; }
    for (int i = 1; i < argc; i++) {
        if (!game_args && !strcmp(argv[i], "--no-launcher")) continue;
        if (!strcmp(argv[i], "--")) game_args = 1;
        prepared[count++] = argv[i];
    }
    *host_argc = count; *host_argv = prepared;
    return -1;   // continue into the engine, in the declared app executable
}
