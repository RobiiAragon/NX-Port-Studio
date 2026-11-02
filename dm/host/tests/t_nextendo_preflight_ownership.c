// An ECHILD result must never authorize signalling a recycled numeric PID.
#include <errno.h>
#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdio.h>
static unsigned spawns, waits, kills, checks;
static int fail_spawn;
static int fixture_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attributes, char *const argv[], char *const env[]) {
    (void)path;(void)actions;(void)attributes;(void)argv;(void)env;spawns++;*pid=2147483646;return fail_spawn ? EAGAIN : 0;
}
static pid_t fixture_wait(pid_t child, int *status, int flags) { (void)child;(void)status;(void)flags;waits++;errno=ECHILD;return -1; }
static int fixture_kill(pid_t child,int sig) { (void)child;(void)sig;kills++;return 0; }
#define posix_spawn fixture_spawn
#define waitpid fixture_wait
#define kill fixture_kill
#include "../hle_nextendo_preflight_mac.c"
#undef posix_spawn
#undef waitpid
#undef kill
#define CHECK(c) do{checks++;if(!(c)){fprintf(stderr,"Ownership failure %d: %s\n",__LINE__,#c);return 1;}}while(0)
int main(void) {
    dm_nextendo_preflight_reply reply;
    CHECK(!dm_nextendo_preflight_query(&reply,100));
    dm_nextendo_preflight_status status=dm_nextendo_preflight_last_status();
    CHECK(status.stage==DM_PREFLIGHT_REAP && status.error==ECHILD && status.bytes==0 && status.exit_code==-1 && !status.signal);
    CHECK(spawns==1 && waits==1 && !kills);
    fail_spawn=1;CHECK(!dm_nextendo_preflight_query(&reply,100));CHECK(spawns==2 && waits==1 && !kills);
    status=dm_nextendo_preflight_last_status();CHECK(status.stage==DM_PREFLIGHT_SPAWN && status.error==EAGAIN && status.bytes==-1);
    CHECK(!dm_nextendo_preflight_query(&reply,0) && !dm_nextendo_preflight_query(&reply,5001));
    status=dm_nextendo_preflight_last_status();CHECK(status.stage==DM_PREFLIGHT_ARGUMENT && status.error==EINVAL && status.bytes==-1);
    CHECK(spawns==2 && !kills);
    printf("Preflight child ownership: %u checks passed; no kill after ECHILD\n",checks);return 0;
}
