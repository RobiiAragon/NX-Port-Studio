"""Real event-driven exit supervision, with synthetic saves and no GUI/game."""
from pathlib import Path
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[3]
TITLE = '0100000000000001'

DRIVER = r'''
#include "save_supervisor.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (!dm_mac_save_supervisor_start(argv[1], getenv("DM_SAVE"), "0100000000000001")) return 10;
    printf("READY %d\n", getpid()); fflush(stdout);
    char byte; (void)read(0, &byte, 1);
    return 7;
}
'''


@unittest.skipUnless(sys.platform == 'darwin', 'macOS kqueue NOTE_EXIT')
class SaveSupervisor(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix='save-supervisor-', dir=os.environ.get('NXNATIVE_TEST_ROOT'))).resolve()
        cls.helper, cls.driver = cls.root / 'helper', cls.root / 'driver'
        (cls.root / 'driver.c').write_text(DRIVER)
        common = ['xcrun', 'clang', '-O1', '-Wall', '-Wextra', '-Werror', '-I', str(REPO / 'dm/mac'), '-I', str(REPO / 'dm/host')]
        subprocess.run(common + ['-o', str(cls.helper), str(REPO / 'dm/mac/save_supervisor.c'), str(REPO / 'dm/host/save_sync.c')], check=True)
        subprocess.run(common + ['-o', str(cls.driver), str(cls.root / 'driver.c'), str(REPO / 'dm/mac/save_supervisor_start.c')], check=True)
        (cls.root / 'nonack.c').write_text('#include <signal.h>\n#include <stdio.h>\n#include <unistd.h>\nint main(void){signal(SIGTERM,SIG_IGN);printf("NONACK %d\\n",getpid());fflush(stdout);for(;;)pause();}\n')
        cls.nonack = cls.root / 'nonack'
        subprocess.run(common + ['-o', str(cls.nonack), str(cls.root / 'nonack.c')], check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root)

    def test_cloud_disabled_never_starts_a_helper(self):
        for value in (None, '', '0'):
            env = dict(os.environ)
            env.pop('DM_SAVE_SYNC', None)
            if value is not None:
                env['DM_SAVE_SYNC'] = value
            # A missing helper must be irrelevant when cloud syncing is off.
            result = subprocess.run([self.driver, self.root / 'not-present'], input=b'x', env=env, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 7)
            self.assertIn(b'READY', result.stdout)
            self.assertNotIn(b'supervisor', result.stderr)

    def test_enabled_cloud_fails_closed_when_observation_cannot_start(self):
        for helper in (self.root / 'missing', Path('/usr/bin/false')):
            result = subprocess.run([self.driver, helper], input=b'x',
                                    env=dict(os.environ, DM_SAVE=str(self.root / 'save'), DM_SAVE_SYNC=str(self.root / 'cloud')),
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 10)
            self.assertNotIn(b'READY', result.stdout)

    def test_nonacknowledging_helper_that_ignores_term_is_reaped_within_bound(self):
        start = time.monotonic()
        result = subprocess.run([self.driver, self.nonack], input=b'x',
                                env=dict(os.environ, DM_SAVE=str(self.root / 'save'), DM_SAVE_SYNC=str(self.root / 'cloud')),
                                capture_output=True, timeout=8)
        self.assertLess(time.monotonic() - start, 7)
        self.assertEqual(result.returncode, 10)
        self.assertNotIn(b'READY', result.stdout)
        match = re.search(rb'NONACK (\d+)', result.stdout)
        assert match is not None, 'the nonacknowledging helper did not report its PID'
        child = int(match.group(1))
        with self.assertRaises(ProcessLookupError): os.kill(child, 0)

    def test_committed_save_survives_normal_exit_and_unhandled_signals(self):
        for sig in (None, signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGKILL):
            with self.subTest(signal=sig), tempfile.TemporaryDirectory(dir=self.root) as tmp:
                base = Path(tmp); save = base / 'save'; save.mkdir()
                payload = b'original synthetic committed progress\x00\xff'
                (save / 'progress').write_bytes(payload)
                cloud = base / 'cloud'
                p = subprocess.Popen([self.driver, self.helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=dict(os.environ, DM_SAVE=str(save), DM_SAVE_SYNC=str(cloud)))
                self.addCleanup(lambda process=p: process.poll() is None and process.kill())
                assert p.stdout is not None
                self.assertEqual(p.stdout.readline().strip(), f'READY {p.pid}'.encode())
                if sig is not None:
                    p.send_signal(sig)
                stdout, stderr = p.communicate(b'x' if sig is None else None, timeout=10)
                self.assertEqual(p.returncode, 7 if sig is None else -sig)
                deadline = time.monotonic() + 10
                bundle = cloud / TITLE / 'save.dmsync'
                while not bundle.is_file() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(bundle.is_file(), stderr.decode(errors='replace'))
                self.assertIn(payload, bundle.read_bytes())
                self.assertEqual((save / 'progress').read_bytes(), payload)
                self.assertIn(b'primary host', stderr)

    def test_helper_has_no_gui_framework(self):
        linked = subprocess.run(['otool', '-L', self.helper], capture_output=True, text=True, check=True).stdout
        self.assertNotIn('AppKit', linked)
        self.assertNotIn('SwiftUI', linked)


if __name__ == '__main__':
    unittest.main()
