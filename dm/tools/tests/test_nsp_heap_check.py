"""Heap-check reuse depends on the latest successful observation, not a cached launch failure.
Synthetic provisional profiles only; no game files, host launch, keys or Xcode needed.
"""
import importlib.util
from pathlib import Path
import tempfile
import types
import unittest


REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
assert spec is not None and spec.loader is not None
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)


class HeapChecked(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.g = types.SimpleNamespace(dir=Path(tmp.name))
        self.profile = self.g.dir / 'game.tsv'

    def checked(self, *lines):
        self.profile.write_text('name\tSynthetic Game\n' + '\n'.join(lines) + '\n', encoding='utf-8')
        before = self.profile.read_bytes()
        result = nsp.heap_checked(self.g)
        self.assertEqual(self.profile.read_bytes(), before)
        return result

    def test_no_observation(self):
        self.assertFalse(self.checked('# provisional profile', 'mem_alias\t0x100000000'))

    def test_successful_heap_observations_are_reused(self):
        for result in ('heap 0.00 GB', 'heap 1.44 GB', 'heap 12.50 GB; set mem_alias, mem_reserve'):
            with self.subTest(result=result):
                self.assertTrue(self.checked(f'# heap check: 2026-10-31, {result}'))

    def test_no_heap_observations_are_reused(self):
        for result in ('no heap set', 'no heap set; set app_pool'):
            with self.subTest(result=result):
                self.assertTrue(self.checked(f'# heap check: 2026-10-31, {result}'))

    def test_failures_and_unknown_results_retry(self):
        for result in ('the host stopped before nnMain (exit 134)',
                       'the host stopped before nnMain (exit 0)',
                       'no nnMain within the time limit',
                       'the heap request did not fit',
                       'the heap request did not fit; set mem_alias, mem_reserve',
                       'heap check timed out', 'unknown', '',
                       'heap 1..44 GB', 'heap NaN GB', 'heap 1.44 GB failed',
                       'no heap set before the host crashed'):
            with self.subTest(result=result):
                self.assertFalse(self.checked(f'# heap check: 2026-10-31, {result}'))

    def test_latest_failure_overrides_previous_success(self):
        self.assertFalse(self.checked('# heap check: 2026-10-30, heap 1.44 GB',
                                      '# heap check: 2026-10-31, the host stopped before nnMain (exit 134)'))

    def test_latest_success_overrides_previous_failure(self):
        self.assertTrue(self.checked('# heap check: 2026-10-30, the host stopped before nnMain (exit 134)',
                                     '# heap check: 2026-10-31, heap 1.44 GB'))

    def test_oom_key_changes_require_a_successful_validation(self):
        calibrated = ('# heap check: 2026-10-30, no heap set',
                      'mem_alias\t0x100000000',
                      '# heap check: 2026-10-31, the heap request did not fit; set mem_alias')
        self.assertFalse(self.checked(*calibrated))
        self.assertTrue(self.checked(*calibrated, '# heap check: 2026-10-31, heap 2.09 GB'))

    def test_latest_malformed_stamp_does_not_reuse_older_success(self):
        for stamp in ('# heap check:', '# heap check: unrecognized',
                      '# heap check:2026-10-31, no heap set',
                      '# heap check: 2026-10-31, no heap set; unknown'):
            with self.subTest(stamp=stamp):
                self.assertFalse(self.checked('# heap check: 2026-10-30, heap 1.44 GB', stamp))

    def test_last_appended_stamp_wins_even_if_the_clock_moves_back(self):
        self.assertFalse(self.checked('# heap check: 2026-10-31, heap 1.44 GB',
                                      '# heap check: 2026-10-30, no nnMain within the time limit'))

    def test_other_comments_after_the_latest_stamp_do_not_hide_it(self):
        self.assertTrue(self.checked('# heap check: 2026-10-31, no heap set',
                                     '# memory keys kept', 'app_pool\t0x40000000'))


if __name__ == '__main__':
    unittest.main()
