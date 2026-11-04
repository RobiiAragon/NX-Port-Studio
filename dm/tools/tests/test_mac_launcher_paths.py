"""Compile the production Mac launcher's state setup, without a game or app UI.

The actual formatter, mkdir helper, log rotation and environment exports run in
a child against owned temporary homes. Only snprintf results are injected.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
LAUNCHER = REPO / 'dm/mac/launcher.c'
TITLE = '0100000000000001'
PREFIX = r'''
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static unsigned mutations, exports, formats, fail_at;
static int full_result;
static int fixture_snprintf(char *out,size_t size,const char *format,...) {
 va_list args;va_start(args,format);int result=vsnprintf(out,size,format,args);va_end(args);
 return ++formats==fail_at ? full_result ? (int)size : -1 : result;
}
static int fixture_mkdir(const char *path,mode_t mode) { mutations++;return mkdir(path,mode); }
static int fixture_rename(const char *from,const char *to) { mutations++;return rename(from,to); }
static int fixture_open(const char *path,int flags,mode_t mode) { mutations++;return open(path,flags,mode); }
static int fixture_setenv(const char *key,const char *value,int replace) { exports++;return setenv(key,value,replace); }
static void report(void) { printf("fixture-effects %u %u %u\n",mutations,exports,formats); }
#define mkdir fixture_mkdir
'''


def driver(source):
    helper = source[source.index('static void mkdirs('):source.index('\nstatic void env_file(')]
    start = source.index('    char sup[PATH_MAX]')
    setup = source[start:source.index('    fprintf(stderr, "launcher:', start)]
    export = next(line for line in source.splitlines() if 'setenv("DM_ROOT", sup' in line)
    return PREFIX + helper + r'''
#undef mkdir
int main(int argc,char **argv) {
 if(argc!=4)return 2;
 const char *home=argv[1],*id="0100000000000001",*romfs="/synthetic-romfs";
 fail_at=(unsigned)strtoul(argv[2],NULL,10);full_result=!strcmp(argv[3],"full");
 if(atexit(report))return 2;
#undef snprintf
#define snprintf fixture_snprintf
#define rename fixture_rename
#define open fixture_open
''' + setup + r'''
#undef snprintf
#undef rename
#undef open
#define setenv fixture_setenv
''' + export + r'''
#undef setenv
 return 0;
}
'''


@unittest.skipUnless(sys.platform == 'darwin', 'Mac launcher state paths')
class MacLauncherPaths(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix='launcher-paths-')).resolve()
        source = cls.root / 'driver.c'
        source.write_text(driver(LAUNCHER.read_text()))
        cls.binaries = []
        for name, flags in [('normal', []), ('asan', ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'])]:
            binary = cls.root / name
            subprocess.run(['xcrun', 'clang', '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                            *flags, '-o', binary, source], check=True)
            cls.binaries.append(binary)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root)

    def home(self, base, length=None):
        home = base / 'home'; home.mkdir()
        while length is not None and len(os.fsencode(home)) < length:
            remaining = length - len(os.fsencode(home))
            size = min(200, remaining - 1)
            if remaining - size - 1 == 1: size -= 1
            self.assertGreater(size, 0)
            home /= 'a' * size; home.mkdir()
        return home

    def invoke(self, binary, home, fail_at=0, kind='negative'):
        env = dict(os.environ, ASAN_OPTIONS='halt_on_error=1:detect_stack_use_after_return=1',
                   UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
        for key in ('DM_ROOT', 'DM_ROMFS', 'DM_SAVE', 'DM_TEMP'): env.pop(key, None)
        return subprocess.run([binary, home, str(fail_at), kind], capture_output=True, text=True,
                              timeout=10, env=env)

    def paths(self, home):
        root = home / 'Library/Application Support/nxnative' / TITLE
        logs = home / 'Library/Logs/nxnative'
        return root / 'save', root / 'temp', logs / (TITLE + '.log'), logs / (TITLE + '.prev.log')

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue(result.stdout.startswith('fixture-effects 0 0 '), result.stdout)
        self.assertIn('[RED] launcher: state path exceeds the platform path limit', result.stderr)

    def test_short_home_preserves_legacy_paths_data_and_log_rotation(self):
        for binary in self.binaries:
            with self.subTest(mode=binary.name), tempfile.TemporaryDirectory(dir=self.root) as tmp:
                home = self.home(Path(tmp)); save, temp, log, previous = self.paths(home)
                save.mkdir(parents=True); temp.mkdir(); log.parent.mkdir(parents=True)
                (save / 'slot').write_bytes(b'original save'); (temp / 'cache').write_bytes(b'original cache')
                log.write_bytes(b'original log'); previous.write_bytes(b'older log')
                result = self.invoke(binary, home)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotEqual(save.stat().st_ino, temp.stat().st_ino)
                self.assertEqual((save / 'slot').read_bytes(), b'original save')
                self.assertEqual((temp / 'cache').read_bytes(), b'original cache')
                self.assertEqual(previous.read_bytes(), b'original log')
                effects = log.read_text().strip().split()
                self.assertEqual(effects[0], 'fixture-effects'); self.assertGreater(int(effects[1]), 0)
                self.assertEqual(effects[2:], ['4', '6'])

    def test_exact_path_capacity_accepts_distinct_save_and_temp(self):
        limit = os.pathconf(self.root, 'PC_PATH_MAX') - 1
        length = limit - len('/Library/Application Support/nxnative/' + TITLE + '/save')
        for binary in self.binaries:
            with self.subTest(mode=binary.name), tempfile.TemporaryDirectory(dir=self.root) as tmp:
                home = self.home(Path(tmp), length); result = self.invoke(binary, home)
                self.assertEqual(result.returncode, 0, result.stderr)
                save, temp, _, _ = self.paths(home)
                self.assertEqual(len(os.fsencode(save)), limit)
                self.assertTrue(save.is_dir() and temp.is_dir())
                self.assertNotEqual(save.stat().st_ino, temp.stat().st_ino)

    def test_overflow_rejected_before_state_io_and_exports(self):
        limit = os.pathconf(self.root, 'PC_PATH_MAX') - 1
        boundary = limit - len('/Library/Application Support/nxnative/' + TITLE + '/save')
        for binary in self.binaries:
            for length in (boundary + 1, boundary + 4):
                with self.subTest(mode=binary.name, length=length), tempfile.TemporaryDirectory(dir=self.root) as tmp:
                    home = self.home(Path(tmp), length); sentinel = home / 'original'
                    sentinel.write_bytes(b'preserve existing data')
                    self.assert_rejected(self.invoke(binary, home))
                    self.assertFalse((home / 'Library').exists())
                    self.assertEqual(sentinel.read_bytes(), b'preserve existing data')

    def test_each_negative_or_full_format_result_preserves_existing_state(self):
        for binary in self.binaries:
            for kind in ('negative', 'full'):
                for index in range(1, 7):
                    with self.subTest(mode=binary.name, kind=kind, format=index), tempfile.TemporaryDirectory(dir=self.root) as tmp:
                        home = self.home(Path(tmp)); save, temp, log, previous = self.paths(home)
                        save.mkdir(parents=True); temp.mkdir(); log.parent.mkdir(parents=True)
                        files = [save / 'slot', temp / 'cache', log, previous]
                        for file in files: file.write_bytes(b'original fixture data')
                        self.assert_rejected(self.invoke(binary, home, index, kind))
                        self.assertTrue(all(file.read_bytes() == b'original fixture data' for file in files))


if __name__ == '__main__': unittest.main()
