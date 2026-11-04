"""Run the production startup selector without UIKit, a game or network access."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires Foundation and Apple clang')
class ProfileSelection(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        root = Path(cls.temporary.name)
        cls.binary = root/'select-profile'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                        '-framework', 'Foundation', '-framework', 'Security', '-I'+str(REPO/'dm/host'),
                        str(Path(__file__).with_name('mobile_nextendo_profiles_check.m')), '-o', str(cls.binary)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()

    def run_selector(self, explicit=None):
        env = dict(os.environ); env.pop('DM_NEXTENDO_ROUTES', None)
        if explicit is not None: env['DM_NEXTENDO_ROUTES'] = explicit
        return subprocess.check_output([str(self.binary), str(self.root)], env=env, text=True).strip()

    def route(self, name):
        path = self.root/name/'routes.tsv'; path.parent.mkdir(); path.write_text('original synthetic marker')
        return str(path)

    def test_prefers_approved_private_route_over_public(self):
        self.route('nextendo'); private = self.route('nextendo-private')
        self.assertEqual(self.run_selector(), private)

    def test_falls_back_to_public_when_private_absent(self):
        expected = self.route('nextendo')
        self.assertEqual(self.run_selector(), expected)

    def test_explicit_override_wins_over_both_bundled_profiles(self):
        self.route('nextendo'); self.route('nextendo-private')
        self.assertEqual(self.run_selector('/explicit/routes.tsv'), '/explicit/routes.tsv')

    def test_no_profiles_does_not_set_a_route(self):
        self.assertEqual(self.run_selector(), '<unset>')

    def test_directory_is_not_selected_as_a_route_file(self):
        expected = self.route('nextendo')
        (self.root/'nextendo-private/routes.tsv').mkdir(parents=True)
        self.assertEqual(self.run_selector(), expected)

    def test_mobile_preparation_keeps_private_and_explicit_routes(self):
        result = subprocess.run([str(self.binary), '--bridge', str(self.root)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('14 checks, 0 failed', result.stdout)
