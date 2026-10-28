"""Compile the production mobile coordinator with mock browser/HTTP/store only."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]

@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires Swift on macOS')
class MobileNextendoTests(unittest.TestCase):
    def test_native_legacy_reader_rejects_unsafe_files_without_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            fixture = directory/'files'; fixture.mkdir()
            binary = directory/'legacy-reader'
            result = subprocess.run(['xcrun','clang','-fobjc-arc','-Wall','-Wextra','-Werror','-I',str(REPO/'dm/host'),'-framework','Foundation','-framework','Security',str(Path(__file__).with_name('mobile_nextendo_legacy_check.m')),'-o',str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary),str(fixture)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('0 failed', result.stdout)

    def test_mobile_account_coordinator_and_policy(self):
        core = REPO / 'macOS/NXPortStudio/Sources/PortCore'
        mobile = REPO / 'dm/ios/Sources'
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'mobile-nextendo-check'
            sources = [core / name for name in ('NextendoAccount.swift','NextendoCatalog.swift','NextendoLoopback.swift')]
            sources += [mobile / name for name in ('LauncherNextendoCallback.swift','LauncherNextendoStore.swift','LauncherNextendoModel.swift')]
            sources += [Path(__file__).with_name('mobile_nextendo_check.swift')]
            result = subprocess.run(['xcrun','-sdk','macosx','swiftc','-swift-version','5','-parse-as-library','-o',str(binary),*[str(p) for p in sources]], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('sign-out passed', result.stdout)
