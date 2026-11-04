"""Real cross-process refresh exclusion with synthetic records and transport."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[3]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires Swift on macOS')
class NextendoRenewalProcesses(unittest.TestCase):
    def test_two_processes_reload_under_the_lease_and_rotate_only_once(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            root.chmod(0o700)
            binary = root/'fixture'
            core = REPO/'macOS/NXPortStudio/Sources/PortCore'
            sources = [core/'NextendoAccount.swift', core/'NextendoLoopback.swift', Path(__file__).with_name('nextendo_renewal_fixture.swift')]
            result = subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-o',str(binary),*map(str,sources)],capture_output=True,text=True,timeout=90)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            subprocess.run([str(binary),'seed',str(root)],check=True,capture_output=True,text=True)

            def wait_for(name):
                deadline = time.monotonic()+10
                while not (root/name).exists():
                    self.assertLess(time.monotonic(),deadline,'Synthetic worker did not reach '+name)
                    time.sleep(0.01)

            workers = []
            try:
                workers.append(subprocess.Popen([str(binary),'worker',str(root),'one'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True))
                wait_for('refresh-started')
                workers.append(subprocess.Popen([str(binary),'worker',str(root),'two'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True))
                wait_for('waiting-two')
                (root/'release').touch()
                for worker in workers:
                    stdout,stderr = worker.communicate(timeout=15)
                    self.assertEqual(worker.returncode,0,stdout+stderr)
                    self.assertIn('no Keychain or network',stdout)
            finally:
                for worker in workers:
                    if worker.poll() is None:
                        worker.kill()
                    worker.communicate()
            self.assertEqual(json.loads((root/'counts.json').read_text()),{'requests':3,'refresh':1})
            record = json.loads((root/'account.json').read_text())
            self.assertEqual(record['token_kind'],'nex')
            self.assertEqual(record['renewal']['refresh_token'],'sentinel-new-refresh')
            self.assertEqual((root/'locks/account.lock').stat().st_mode & 0o777,0o600)


if __name__ == '__main__':
    unittest.main()
