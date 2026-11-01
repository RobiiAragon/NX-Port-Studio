"""Options acquired after dyld constructors start each real diagnostic once."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
DRIVER = r'''
#include "dm.h"
#include <time.h>
#include <unistd.h>
module_t *g_mod; int g_nmod;
uint64_t now_ns(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+t.tv_nsec;}
void svc_guest_range(uint8_t **base,size_t *size){*base=NULL;*size=0;}
int thr_name_of(pthread_t thread,char *name,size_t n){(void)thread;(void)name;(void)n;return 0;}
void dm_fdstat_start(void);void dm_memstat_start(void);void dm_thrcpu_start(void);
int main(int argc,char **argv){
 if(argc!=3)return 2;
 // Constructors have already observed all three options unset, as when a
 // packed app learns them later from env.txt or its settings window.
 setenv("DM_FD_LOG","1",1);setenv("DM_MEMSTAT",argv[1],1);setenv("DM_THRCPU",argv[2],1);
 for(int i=0;i<2;i++){dm_fdstat_start();dm_memstat_start();dm_thrcpu_start();}
 sleep(3);return 0;
}
'''


@unittest.skipUnless(sys.platform == 'darwin', 'macOS diagnostic APIs')
class LateDiagnostics(unittest.TestCase):
    def test_late_environment_starts_existing_diagnostics_without_duplicate_threads(self):
        with tempfile.TemporaryDirectory(prefix='late-diagnostics-', dir=os.environ.get('NXNATIVE_TEST_ROOT')) as tmp:
            root = Path(tmp); (root / 'driver.c').write_text(DRIVER)
            (root / 'game_profile.h').write_text('#define DM_GAME_ID "0100000000000001"\n')
            out = root / 'driver'
            subprocess.run(['xcrun', 'clang', '-O1', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-fobjc-arc',
                            '-I', REPO / 'dm/host', '-I', root, '-framework', 'Foundation', '-framework', 'Metal',
                            '-o', out, root / 'driver.c', REPO / 'dm/host/memstat.m', REPO / 'dm/host/hle_fdstat.c'], check=True)
            env = dict(os.environ)
            for key in ('DM_FD_LOG', 'DM_MEMSTAT', 'DM_THRCPU', 'DM_MEMSTAT_DUMP'): env.pop(key, None)
            memory, cpu = root / 'memory.tsv', root / 'cpu.tsv'
            # A short interval exercises the actual CPU thread without waiting
            # the default ten seconds; memstat and fdstat sample every second.
            result = subprocess.run([out, memory, str(cpu) + ',1'], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            rounds = re.findall(r'descriptors round (\d+)', result.stderr)
            self.assertGreaterEqual(len(rounds), 1)
            self.assertEqual(rounds.count('1'), 1)
            self.assertEqual(len(rounds), len(set(rounds)))
            mem = memory.read_text(); thread = cpu.read_text()
            self.assertEqual(mem.count('seconds\tphys_footprint'), 1)
            self.assertGreaterEqual(len([line for line in mem.splitlines() if line[:1].isdigit()]), 2)
            self.assertEqual(thread.count('seconds\tthread ID'), 1)
            self.assertGreaterEqual(thread.count('\ttotal\t'), 1)


if __name__ == '__main__': unittest.main()
