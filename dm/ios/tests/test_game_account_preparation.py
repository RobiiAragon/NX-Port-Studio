"""Exercise the boot adapter without device, credentials or authentication."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires Apple Swift SDKs')
class MobileGameAccountPreparationTests(unittest.TestCase):
    def test_worker_wait_and_error_privacy_without_account_io(self):
        mobile = REPO/'dm/ios/Sources'
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder)/'mobile-game-account'
            sources = [mobile/'LauncherGameAccount.swift',Path(__file__).with_name('mobile_game_account_check.swift')]
            result = subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-o',str(binary),*map(str,sources)],capture_output=True,text=True,timeout=90)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            result = subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('no Keychain or network',result.stdout)
            self.assertIn('operation=gameProof http=403',result.stderr)
            self.assertNotIn('DO_NOT_DISPLAY',result.stdout+result.stderr)

    def test_production_core_store_and_adapter_typecheck_for_iphone(self):
        mobile = REPO/'dm/ios/Sources'
        core = REPO/'macOS/NXPortStudio/Sources/PortCore'
        sources = [core/'NextendoAccount.swift',core/'NextendoLoopback.swift',mobile/'LauncherNextendoStore.swift',mobile/'LauncherGameAccount.swift']
        result = subprocess.run(['xcrun','--sdk','iphoneos','swiftc','-target','arm64-apple-ios26.0','-swift-version','5','-parse-as-library','-typecheck',*map(str,sources)],capture_output=True,text=True,timeout=90)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)


if __name__ == '__main__':
    unittest.main()
