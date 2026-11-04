"""NSP script progress (scripts/build_ipa_from_nsp.py --progress): the json mode's events, a count held back and sent by the ticker, a failed step's log tail,
and the human modes' lines; no game files, keys or Xcode needed (temporary files only in a temporary folder)."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[3] / 'scripts/build_ipa_from_nsp.py'
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', SCRIPT)
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)

class OneTick:
    """A ticker stop event that lets one tick through"""
    def __init__(self): self.n = 0
    def wait(self, timeout): self.n += 1; return self.n > 1
    def is_set(self): return False

class Json(unittest.TestCase):
    def setUp(self):
        self.now, self.out = 100.0, io.StringIO()
        self.prog = nsp.Progress('json')
        for cm in (contextlib.redirect_stdout(self.out), mock.patch.object(nsp.time, 'monotonic', side_effect=lambda: self.now),
                   mock.patch.object(nsp.time, 'time', side_effect=lambda: self.now),
                   mock.patch.object(nsp.threading, 'Thread'), mock.patch.object(nsp, 'PROG', self.prog)):   # no real ticker: the tests tick it themselves
            cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)

    def events(self, ev=None):
        return [e for e in map(json.loads, self.out.getvalue().splitlines()) if ev in (None, e['ev'])]

    def test_events(self):
        self.prog.plan(2)
        self.prog.stage('extract Pokémon', step='reading', done=0, total=10, unit='files', est=True)
        self.prog.set(step='writing', done=2, total=4)
        self.prog.say('[RED] two\nlines')
        self.prog.end('4 files')
        self.prog.stage('rewrite')
        self.prog.close(ok=False); self.prog.close(ok=False)
        es = self.events()
        self.assertEqual([e['ev'] for e in es], ['stage', 'progress', 'step', 'progress', 'say', 'stage_end', 'stage', 'progress', 'stage_end'])
        self.assertEqual([es[0][k] for k in ('k', 'n', 'name', 'step')], [1, 2, 'extract Pokémon', 'reading'])
        self.assertEqual([es[1][k] for k in ('frac', 'est', 'eta')], [0, True, None])
        self.assertEqual([es[3][k] for k in ('step', 'frac', 'unit', 'est')], ['writing', 0.5, '', False])   # a new step starts with no count
        self.assertEqual(es[4]['msg'], '[RED] two\nlines')
        self.assertEqual([es[5][k] for k in ('ok', 'summary')], [True, '4 files'])
        self.assertEqual([es[7][k] for k in ('done', 'total', 'frac')], [None, None, None])
        self.assertFalse(es[8]['ok'])
        self.assertIn('Pokémon', self.out.getvalue())   # not escaped

    def test_count_held_back(self):
        self.prog.stage('rewrite', done=0, total=3, unit='modules')
        self.now += 1; self.prog.set(done=1)
        self.now += 0.1; self.prog.set(done=2)   # within JSON_INTERVAL of the last event
        self.prog._tick(OneTick())
        self.assertEqual([e['done'] for e in self.events('progress')], [0, 1])
        self.now += 0.5; self.prog._tick(OneTick())   # the ticker sends it
        self.assertEqual([e['done'] for e in self.events('progress')], [0, 1, 2])
        self.prog.set(done=3); self.prog.end()   # held back again, then sent before stage_end
        es = self.events()
        self.assertEqual([es[-2][k] for k in ('done', 'frac')], [3, 0.99])
        self.assertEqual(es[-1]['ev'], 'stage_end')

    def test_no_prompt(self):
        with mock.patch.object(nsp, 'in_ipython', return_value=True), mock.patch('builtins.input') as inp:
            with self.assertRaisesRegex(nsp.BuildError, 'does not prompt'): nsp.ask('NSP folder: ', 'the NSP folder')
        inp.assert_not_called()

    def test_eta_expires_without_inventing_count_changes(self):
        self.prog.stage('compile', done=0, total=10)
        self.now += 4; self.prog.set(done=1)
        self.assertEqual(self.events('progress')[-1]['eta'], 36)
        self.now += 61; self.prog._tick(OneTick())
        # The JSON client must receive the lost estimate even without another
        # count update. The unchanged count is not another completed artifact.
        last = self.events('progress')[-1]
        self.assertEqual(last['done'], 1)
        self.assertIsNone(last['eta'])
        self.assertEqual(self.prog.cur.changed, 104)

    def test_step_change_discards_rate(self):
        self.prog.stage('compile', done=0, total=10)
        self.now += 4; self.prog.set(done=1)
        self.assertIsNotNone(self.events('progress')[-1]['eta'])
        self.prog.set(step='finishing variants and reflection')
        self.assertIsNone(self.prog.cur.done)
        self.assertIsNone(self.prog.cur.total)
        self.assertIsNone(self.events('progress')[-1]['eta'])

    def test_failed_step(self):
        self.prog.stage('child')
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'child.log'
            with self.assertRaisesRegex(nsp.BuildError, 'exit code 7'):
                nsp.run([sys.executable, '-c', 'import sys; print("out"); print("err", file=sys.stderr); sys.exit(7)'], log)
            self.assertEqual(sorted(log.read_text().split()), ['err', 'out'])
        es = self.events()
        self.assertEqual([e['ev'] for e in es], ['stage', 'progress', 'stage_end', 'say'])
        self.assertFalse(es[2]['ok'])
        self.assertTrue('out' in es[3]['msg'] and 'err' in es[3]['msg'])

class PollClock(unittest.TestCase):
    def test_wall_clock_adjustment_does_not_suspend_polling(self):
        prog = nsp.Progress(); prog.stage('compile')
        class Stop:
            done = False
            def is_set(self): return self.done
            def wait(self, delay): self.delay = delay; self.done = True
        stop = Stop()
        with mock.patch.object(nsp.time, 'time', side_effect=[100, 1000000]), \
             mock.patch.object(nsp.time, 'monotonic', side_effect=[10, 10.2]):
            prog._poll(prog.cur, lambda: None, stop)
        self.assertAlmostEqual(stop.delay, 1)

class ShaderArtifacts(unittest.TestCase):
    """Original synthetic output schedules; no shader tools, game or GPU run."""
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name); self.work = self.root / 'work'; self.out = self.root / 'out'
        self.work.mkdir(); self.out.mkdir()
        self.keys = ['0000000000000001', '0000000000000002', 'ffffffffffffffff']
        self.profile = mock.Mock(); self.profile.table.side_effect = lambda name: self.root / name
        self.map(self.keys)

    def map(self, keys):
        (self.root / 'shader_map.tsv').write_text(''.join(f'p.bin\t{i}\tvs\t{k}\tsource\n' for i, k in enumerate(keys)))

    def watch(self): return nsp.ShaderWatch(self.profile, self.out, self.work)

    def marker(self):
        self.w = self.work / 'dmsh_synthetic'; self.w.mkdir()
        return self.w

    def pair(self, key, mtime=None):
        for suffix in ('_b.metallib', '_b.json'):
            path = self.out / (key + suffix); path.write_text('{}' if suffix.endswith('json') else 'synthetic library')
            if mtime is not None: os.utime(path, (mtime, mtime))

    def compiling(self):
        self.marker()
        for key in self.keys:
            for suffix in ('.bin', '.spv', '.metal'): (self.w / (key + suffix)).write_text('')

    def test_old_outputs_and_old_work_marker_are_not_current_progress(self):
        for key in self.keys: self.pair(key)
        (self.work / 'dmsh_old').mkdir()
        watch = self.watch(); before = watch()
        self.assertEqual((before['step'], before['done']), ('cache check', 0))
        for path in self.out.iterdir(): path.unlink()   # producer cleanup precedes its new marker
        self.marker()
        self.assertEqual(watch()['done'], 0)

    def test_old_mtime_restores_count_after_the_new_marker(self):
        watch = self.watch(); self.compiling()
        self.pair(self.keys[0], mtime=1)
        state = watch()
        self.assertEqual((state['step'], state['done'], state['total'], state['unit']),
                         ('preparing base artifacts', 1, 3, 'shader bases'))
        self.pair(self.keys[1], mtime=1)
        self.assertEqual(watch()['done'], 2)

    def test_out_of_order_last_key_does_not_complete_other_keys(self):
        watch = self.watch(); self.compiling()
        key = self.keys[-1]
        (self.out / (key + '_b.metallib')).write_text('synthetic library')
        self.assertEqual(watch()['done'], 0)   # a library alone has no reflection pair
        self.pair(key)
        self.assertEqual(watch()['done'], 1)
        (self.out / (self.keys[0] + '_b.json')).write_text('{}')
        self.assertEqual(watch()['done'], 1)   # reflection alone is not a pair either

    def test_directory_and_symlink_names_are_not_base_artifacts(self):
        watch = self.watch(); self.compiling()
        key = self.keys[0]
        (self.out / (key + '_b.metallib')).mkdir()
        (self.out / (key + '_b.json')).symlink_to(self.root / 'shader_map.tsv')
        self.assertEqual(watch()['done'], 0)

    def test_geometry_base_before_variants_is_not_stage_completion(self):
        self.map(self.keys[:1]); watch = self.watch(); self.marker()
        self.pair(self.keys[0])
        (self.w / (self.keys[0] + '_g3.metal')).write_text('synthetic pending variant')
        state = watch()
        self.assertEqual(state['step'], 'finishing variants and reflection')
        self.assertNotIn('done', state); self.assertNotIn('total', state)
        prog = nsp.Progress(); prog.stage('shader build', step='preparing base artifacts', done=0, total=1)
        prog.set(**state)
        self.assertIsNotNone(prog.cur)   # the subprocess and stamp still own success
        self.assertIsNone(prog.cur.done); self.assertIsNone(prog.cur.total)

    def test_unknown_and_variant_files_do_not_inflate_translation(self):
        watch = self.watch(); self.marker()
        for key in self.keys: (self.w / (key + '.bin')).write_text('')
        (self.w / (self.keys[0] + '.spv')).write_text('')
        (self.w / (self.keys[0] + '_g0.spv')).write_text('')
        (self.w / 'unknown.spv').write_text('')
        state = watch()
        self.assertEqual((state['step'], state['done'], state['total']), ('translating', 1, 3))

    def test_removed_work_folder_does_not_invent_missing_outputs(self):
        watch = self.watch(); self.compiling(); self.pair(self.keys[0]); watch()
        shutil.rmtree(self.w)
        state = watch()
        self.assertEqual(state['step'], 'finishing variants and reflection')
        self.assertIn('1/3', state['note']); self.assertNotIn('done', state)

class ShadersStale(unittest.TestCase):
    """build_shaders tells a front end (event shaders_stale, json mode) that cached libraries cannot be reused, once, before it rebuilds them"""
    class Stop(Exception): pass

    def run_step(self, mode, chain_dir=None, digest='aaaa', stamp=None, caches=None, keys=('x',), mac=True, reuse=False):
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            sh = Path(tmp) / 'sh'
            if caches is None: caches = [('cache', chain_dir or 'b-OLD', ('x',), stamp)]
            for target, chain, cached, inputs in caches:
                d = sh / target / chain; d.mkdir(parents=True)
                for key in cached: (d / f'{key}_b.metallib').write_text('')
                if inputs: (d / 'inputs.tsv').write_text(f'game\tg\ninputs\t{inputs}\n')
            (Path(tmp) / 'shader_map.tsv').write_text(''.join(f'p.bin\t{i}\tvs\t{k}\tsrc\n' for i, k in enumerate(keys)))
            prog = nsp.Progress(mode)
            g = mock.Mock(); g.dir = Path(tmp); g.table.side_effect = lambda name: Path(tmp) / name
            done = subprocess.CompletedProcess([], 0, stdout=f'{digest}\n', stderr='')
            with contextlib.redirect_stdout(out), mock.patch.object(nsp, 'PROG', prog), mock.patch.object(nsp.threading, 'Thread'), \
                 mock.patch.object(nsp, 'chain_of', return_value='NEW'), mock.patch.object(nsp.subprocess, 'run', return_value=done), \
                 mock.patch.object(nsp, 'run', side_effect=self.Stop) as build, mock.patch.object(nsp, 'rmtree'), \
                 mock.patch.object(nsp, 'fingerprint', return_value='K'), mock.patch.object(nsp, 'reused', return_value='ready' if reuse else None), \
                 mock.patch.object(nsp, 'chain_tables', return_value=True):
                args = ('py', Path(tmp), sh, Path(tmp) / 'xlate', {'WORK': tmp}, Path(tmp), g)
                if reuse:
                    nsp.build_shaders(*args, pkg_key='P', mac=mac)
                    build.assert_not_called()
                else:
                    with self.assertRaises(self.Stop): nsp.build_shaders(*args, mac=mac)
        return out.getvalue()

    def events(self, text): return [e for e in (json.loads(l) for l in text.splitlines()) if e['ev'] == 'shaders_stale']

    def test_chain_changed(self):
        es = self.events(self.run_step('json'))
        self.assertEqual(len(es), 1)
        self.assertEqual([es[0][k] for k in ('reason', 'old', 'new', 'count')], ['chain', 'b-OLD', 'b-NEW', 1])

    def test_inputs_changed(self):
        es = self.events(self.run_step('json', chain_dir='b-NEW', digest='bbbb', stamp='aaaa'))
        self.assertEqual([es[0][k] for k in ('reason', 'old', 'new', 'count')], ['inputs', 'aaaa', 'bbbb', 1])

    def test_current_has_no_event(self):
        self.assertEqual(self.events(self.run_step('json', chain_dir='b-NEW', digest='aaaa', stamp='aaaa')), [])

    def test_partial_current_chain_still_reports_stale(self):
        caches = [('cache', 'b-OLD', ('a', 'b'), 'aaaa'), ('cache', 'b-NEW', ('a',), None)]
        es = self.events(self.run_step('json', caches=caches, keys=('a', 'b')))
        self.assertEqual(len(es), 1)
        self.assertEqual([es[0][k] for k in ('reason', 'old', 'new', 'count')], ['chain', 'b-OLD', 'b-NEW', 2])

    def test_current_mac_does_not_hide_stale_ios(self):
        caches = [('cache', 'b-NEW', ('x',), 'aaaa'), ('ios', 'b-OLD', ('x',), 'aaaa')]
        es = self.events(self.run_step('json', caches=caches, mac=False))
        self.assertEqual(len(es), 1)
        self.assertEqual([es[0][k] for k in ('reason', 'count')], ['chain', 2])

    def test_count_uses_current_keys_not_historical_copies(self):
        caches = [('cache', 'b-OLD', ('a', 'removed'), 'aaaa'), ('cache', 'b-OLDER', ('a',), 'aaaa')]
        es = self.events(self.run_step('json', caches=caches, keys=('a', 'b', 'b')))
        self.assertEqual(es[0]['count'], 2)   # a and b, once each; removed is no longer built

    def test_count_includes_both_selected_targets(self):
        caches = [('cache', 'b-NEW', ('x',), 'aaaa'), ('ios', 'b-NEW', ('x',), 'aaaa')]
        es = self.events(self.run_step('json', caches=caches, digest='bbbb', mac=False))
        self.assertEqual([es[0][k] for k in ('reason', 'count')], ['inputs', 2])

    def test_ios_only_count_excludes_old_mac_libraries(self):
        caches = [('cache', 'b-OLD', ('x',), 'aaaa'), ('ios', 'b-OLD', ('x',), 'aaaa')]
        es = self.events(self.run_step('json', caches=caches, mac=False))
        self.assertEqual(es[0]['count'], 1)

    def test_unselected_mac_stamp_has_no_event(self):
        caches = [('cache', 'b-NEW', (), 'old'), ('ios', 'b-NEW', ('x',), 'aaaa')]
        self.assertEqual(self.events(self.run_step('json', caches=caches, mac=False)), [])

    def test_completed_current_chain_ignores_old_folders(self):
        caches = [('cache', 'b-OLD', ('x',), 'old'), ('cache', 'b-NEW', ('x',), 'aaaa')]
        self.assertEqual(self.events(self.run_step('json', caches=caches)), [])

    def test_no_cached_libraries_has_no_event(self):
        self.assertEqual(self.events(self.run_step('json', caches=[])), [])

    def test_reused_libraries_have_no_event(self):
        self.assertEqual(self.events(self.run_step('json', chain_dir='b-NEW', stamp='aaaa', reuse=True)), [])

    def test_event_precedes_rebuild_with_same_message(self):
        es = [json.loads(line) for line in self.run_step('json').splitlines()]
        stale = next(i for i, e in enumerate(es) if e['ev'] == 'shaders_stale')
        self.assertIsInstance(es[stale]['t'], (int, float))
        self.assertEqual(es[stale + 1]['ev'], 'say')
        self.assertIn('[NOTE] cached shader libraries cannot be reused', es[stale + 1]['msg'])

    def test_no_json_unless_asked(self):
        for mode in ('bar', 'lines', 'off'):
            with self.subTest(mode=mode):
                out = self.run_step(mode)
                self.assertNotIn('shaders_stale', out)
                self.assertIn('[NOTE] cached shader libraries cannot be reused (b-OLD -> b-NEW)', out)


class Cli(unittest.TestCase):
    def test_argument_error_precedes_json_mode(self):
        r = subprocess.run([sys.executable, '-B', str(SCRIPT), '--progress', 'json', '--invalid-option'],
                           capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stdout), (2, ''))
        self.assertIn('usage:', r.stderr)
        self.assertIn('unrecognized arguments: --invalid-option', r.stderr)

    def test_json_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = subprocess.run([sys.executable, '-B', str(SCRIPT), '--progress', 'json', str(Path(tmp) / 'missing'), '-k', str(Path(tmp) / 'keys')],
                               capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stderr), (1, ''))
        es = [json.loads(l) for l in r.stdout.splitlines()]
        self.assertTrue(es and all(e['ev'] == 'say' for e in es))
        self.assertIn('[RED] not a folder:', es[-1]['msg'])

class HumanModes(unittest.TestCase):
    def test_lines(self):
        for mode in ('bar', 'lines', 'off'):
            with self.subTest(mode=mode), contextlib.redirect_stdout(io.StringIO()) as out:
                prog = nsp.Progress(mode); prog.plan(1)
                prog.stage('compile', done=0, total=10); ticker = prog.ticker
                prog.set(step='writing', done=1); prog.say('message'); prog.close()
                if ticker: ticker.join(2); self.assertFalse(ticker.is_alive())
            text = out.getvalue()
            self.assertIn('message', text)
            self.assertIn('✓ [1/1] compile', text)
            self.assertEqual('\r' in text, mode == 'bar')
            self.assertEqual(ticker is None, mode == 'off')

if __name__ == '__main__':
    unittest.main()
