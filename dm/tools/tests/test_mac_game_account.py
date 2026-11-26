"""Actual packed-host C/Swift account bridge, with an entirely fake async service.

No GUI, Keychain item, account data, network request or guest module is opened.
The main CFRunLoop must remain responsive while the existing worker waits.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SERVICE = r'''
import Foundation
private let lock = NSLock()
private var calls: Int32 = 0, heartbeats: Int32 = 0, failures: Int32 = 0
private var pending: CheckedContinuation<Void, Never>?
enum NextendoAccountStep: String { case gameProof }
enum NextendoError: Error { case accountHTTPStatus(NextendoAccountStep, Int) }
struct FixtureFailure: LocalizedError {
    var errorDescription: String? { "DO_NOT_PRINT_ACCOUNT_FIXTURE" }
}
actor NextendoAccountService {
    func prepareGameAccount(forceGameRefresh: Bool = false) async throws -> Int? {
        await withCheckedContinuation { continuation in
            lock.lock(); calls += forceGameRefresh ? 1 : 1000; pending = continuation; lock.unlock()
            DispatchQueue.main.async { lock.lock(); heartbeats += 1; lock.unlock() }
        }
        lock.lock(); let fail = failures; lock.unlock()
        if fail == 1 { throw FixtureFailure() }
        if fail == 2 { throw NextendoError.accountHTTPStatus(.gameProof,403) }
        return nil
    }
}
@_cdecl("fixture_calls") public func fixtureCalls() -> Int32 { lock.lock(); defer { lock.unlock() }; return calls }
@_cdecl("fixture_heartbeats") public func fixtureHeartbeats() -> Int32 { lock.lock(); defer { lock.unlock() }; return heartbeats }
@_cdecl("fixture_release") public func fixtureRelease(_ fail: Int32) {
    lock.lock(); failures = fail; let continuation = pending; pending = nil; lock.unlock()
    continuation?.resume()
}
'''
AGENT = r'''
import Foundation
private var answer: Int32 = 0, prepares: Int32 = 0
@_cdecl("fixture_agent_answer") public func fixtureAgentAnswer(_ value: Int32) { answer = value }
@_cdecl("fixture_agent_prepares") public func fixtureAgentPrepares() -> Int32 { prepares }
@_cdecl("dm_mac_agent_prepare") public func dmMacAgentPrepare(_ invalidate: @escaping @convention(c) () -> Void) -> Bool {
    prepares += 1; if answer != 0 { invalidate() }; return answer != 0
}
@_cdecl("dm_mac_agent_credential") public func dmMacAgentCredential(_ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int, _ size: UnsafeMutablePointer<Int>?) -> Bool {
    let record = Array("AGENT".utf8); guard let buffer, let size, capacity >= record.count else { return false }
    buffer.update(from: record, count: record.count); size.pointee = record.count; return true
}
'''
DRIVER = r'''
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdatomic.h>
#include "bundle_mac.c"
static dm_net_mode_t mode;
dm_net_mode_t dm_net_mode(void) { return mode; }
static dm_nextendo_credential_provider installed;
static unsigned invalidations;
void dm_nextendo_set_credential_provider(dm_nextendo_credential_provider provider) { installed = provider; }
void dm_nextendo_account_invalidate_social(void) { invalidations++; }
static _Atomic unsigned started, finished;
static void *worker(void *unused) {
    (void)unused; started=1; dm_mac_bundle_prepare_account(); finished=1; return NULL;
}
static unsigned checks, failures;
#define CHECK(c) do { checks++; if(!(c)){failures++;fprintf(stderr,"FAIL line %d\n",__LINE__);} } while(0)
static int until(int (*predicate)(void)) {
    CFAbsoluteTime end=CFAbsoluteTimeGetCurrent()+5;
    while(!predicate() && CFAbsoluteTimeGetCurrent()<end) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,true);
    return predicate();
}
static int done(void) { return finished; }
static int (*calls)(void), (*heartbeats)(void);
static int expected;
static int called(void) { return calls()==expected && heartbeats()==expected; }
static void run_skipped(void) {
    unsigned before=calls ? (unsigned)calls() : 0; started=finished=0; pthread_t thread;
    CHECK(!pthread_create(&thread,NULL,worker,NULL)); CHECK(until(done)); CHECK(!pthread_join(thread,NULL));
    CHECK(!calls || (unsigned)calls()==before);
}
int main(int argc,char **argv) {
    if(argc!=2 && argc!=3)return 2;
    mode=DM_NET_NEXTENDO; run_skipped(); // An ordinary CLI host has no bootstrap.
    bootstrap_image=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); CHECK(bootstrap_image!=NULL); if(!bootstrap_image)return 2;
    calls=dlsym(bootstrap_image,"fixture_calls"); heartbeats=dlsym(bootstrap_image,"fixture_heartbeats");
    void (*release)(int)=dlsym(bootstrap_image,"fixture_release");
    CHECK(calls && heartbeats && release); if(!calls || !heartbeats || !release)return 2;
    unsetenv("DM_NEXTENDO_ROUTES");
    const dm_net_mode_t local[]={DM_NET_OFFLINE,DM_NET_LAN,DM_NET_LDN,DM_NET_AUTO};
    for(unsigned i=0;i<sizeof local/sizeof *local;i++){mode=local[i];run_skipped();}
    setenv("DM_NEXTENDO_ROUTES","/synthetic-profile",1);
    for(unsigned i=0;i<4;i++) {
        mode=i ? DM_NET_AUTO : DM_NET_NEXTENDO; started=finished=0; expected=calls()+1; pthread_t thread;
        CHECK(!pthread_create(&thread,NULL,worker,NULL)); CHECK(until(called));
        CHECK(started && !finished); // First SDK/game work cannot run while the request is held.
        release(i==2 ? 1 : i==3 ? 2 : 0); CHECK(until(done)); CHECK(!pthread_join(thread,NULL));
        CHECK(calls()==expected && heartbeats()==expected); // One async request and responsive main queue.
    }
    // Accidental calls on main must not block its run loop or access storage.
    void (*prepare)(void)=dlsym(bootstrap_image,"dm_mac_prepare_game_account"); CHECK(prepare!=NULL);
    if(prepare){expected=calls();prepare();CHECK(calls()==expected);}
    CHECK(installed==NULL); // A bootstrap without the agent client keeps the port's own path.
    if(argc==3) { // docs/nextendo-agent.md: an answering agent owns the account for this port.
        bootstrap_image=dlopen(argv[2],RTLD_NOW|RTLD_LOCAL); CHECK(bootstrap_image!=NULL); if(!bootstrap_image)return 2;
        calls=dlsym(bootstrap_image,"fixture_calls"); heartbeats=dlsym(bootstrap_image,"fixture_heartbeats"); release=dlsym(bootstrap_image,"fixture_release");
        void (*answer)(int)=dlsym(bootstrap_image,"fixture_agent_answer"); int (*prepares)(void)=dlsym(bootstrap_image,"fixture_agent_prepares");
        CHECK(calls && heartbeats && release && answer && prepares); if(!calls || !heartbeats || !release || !answer || !prepares)return 2;
        mode=DM_NET_NEXTENDO; answer(1); unsigned before=(unsigned)calls();
        started=finished=0; pthread_t thread; CHECK(!pthread_create(&thread,NULL,worker,NULL)); CHECK(until(done)); CHECK(!pthread_join(thread,NULL));
        CHECK((unsigned)calls()==before && prepares()==1 && invalidations==1 && installed!=NULL); // No renewal here, no storage read.
        uint8_t record[16]; size_t size=0; CHECK(installed && installed(record,sizeof record,&size) && size==5 && !memcmp(record,"AGENT",5));
        CHECK(installed && !installed(record,4,&size)); // A short buffer fails, never truncates.
        mode=DM_NET_OFFLINE; installed=NULL; run_skipped(); CHECK(prepares()==1 && installed==NULL); // Local modes never ask the agent.
        for(unsigned i=0;i<2;i++) { // 0: the agent does not answer; 1: DM_NEXTENDO_AGENT=0 skips it.
            mode=DM_NET_NEXTENDO; answer(i==0 ? 0 : 1); if(i==1) setenv("DM_NEXTENDO_AGENT","0",1);
            int asked=prepares(); installed=NULL; started=finished=0; expected=calls()+1;
            CHECK(!pthread_create(&thread,NULL,worker,NULL)); CHECK(until(called)); release(0); CHECK(until(done)); CHECK(!pthread_join(thread,NULL));
            CHECK(installed==NULL && prepares()==asked+(i==0)); unsetenv("DM_NEXTENDO_AGENT");
        }
    }
    printf("Mac account bridge: %u checks, %u failures; synthetic async service only\n",checks,failures);
    return failures!=0;
}
'''


@unittest.skipUnless(sys.platform == 'darwin', 'Mac C/Swift bootstrap')
class MacGameAccount(unittest.TestCase):
    def test_actual_bridge_keeps_main_responsive_and_orders_guest(self):
        with tempfile.TemporaryDirectory(prefix='mac-account-', dir=os.environ.get('NXNATIVE_TEST_ROOT')) as tmp:
            root = Path(tmp)
            (root / 'service.swift').write_text(SERVICE)
            (root / 'driver.c').write_text(DRIVER)
            (root / 'agent.swift').write_text(AGENT)
            (root / 'game_profile.h').write_text('#define DM_GAME_ID "0100000000000001"\n')
            for name, san in [('normal', []), ('asan', ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'])]:
                with self.subTest(build=name):
                    library, agent, driver = root / (name + '.dylib'), root / (name + '-agent.dylib'), root / name
                    for out, extra in ((library, []), (agent, [root / 'agent.swift'])):
                        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-emit-library',
                                        '-O', '-g', *(['-sanitize=address'] if san else []), '-o', out, REPO / 'dm/mac/GameAccount.swift', root / 'service.swift', *extra], check=True, capture_output=True)
                    subprocess.run(['xcrun', 'clang', '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', *san,
                                    '-I', root, '-I', REPO / 'dm/host', '-o', driver, root / 'driver.c', '-framework', 'CoreFoundation'], check=True, capture_output=True)
                    result = subprocess.run([driver, library, agent], capture_output=True, text=True, timeout=20)
                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    self.assertIn('0 failures', result.stdout)
                    self.assertIn('account preparation failed', result.stderr)
                    self.assertIn('operation=gameProof http=403', result.stderr)
                    self.assertNotIn('DO_NOT_PRINT_ACCOUNT_FIXTURE', result.stdout + result.stderr)

    def test_preparation_precedes_bcat_and_sdk_entry(self):
        main = (REPO / 'dm/host/main.c').read_text()
        guest = main[main.index('static void guest_main(void) {'):main.index('\nstruct dm_flags')]
        self.assertLess(guest.index('dm_mac_bundle_prepare_account();'), guest.index('dm_bcat_start('))
        self.assertLess(guest.index('dm_mac_bundle_prepare_account();'), guest.index('guest_thread_init();'))


if __name__ == '__main__':
    unittest.main()
