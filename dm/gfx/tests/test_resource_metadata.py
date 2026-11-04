"""Own GPU resources: passive metadata, unchanged normal resolution and pixels."""
import os
from pathlib import Path
import re
import subprocess
import unittest

KEYS = '0123456789abcdef,fedcba9876543210'
FIELDS = {'key', 'frame', 'pass', 'stage', 'role', 'slot', 'serial', 'descriptor',
          'type', 'format', 'width', 'height', 'depth', 'levels', 'layers',
          'samples', 'level', 'slice', 'plane', 'render_layers', 'dummy'}


def fixture_run(mode='', keys=KEYS, types=''):
    env = dict(os.environ, DM_NVN_RESOURCE_TRACE_KEYS=keys, DM_NVN_RESOURCE_TRACE_TYPES=types)
    for name in ('DM_NVN_PASSDUMP', 'DM_NVN_PASSDUMP_ALL', 'DM_NVN_KEYDUMP', 'DM_NVN_CBDUMP', 'DM_NVN_TEXINFO'):
        env.pop(name, None)
    args = [env['DM_TEST_RESOURCE_METADATA']] + ([mode] if mode else [])
    return subprocess.run(args, env=env, text=True, capture_output=True, timeout=60)


class ResourceMetadataTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('DM_TEST_RESOURCE_METADATA'), 'set DM_TEST_RESOURCE_METADATA to the own GPU fixture')
    def test_scalar_texu_remains_untraced(self):
        p = fixture_run('texu')
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertRegex(p.stdout, r'RESOURCE_METADATA \d+ checks, 0 failed')
        lines = [line for line in p.stderr.splitlines() if line.startswith('[dm] [nvn-resource] ')]
        self.assertEqual(len(lines), 9, 'eight producer attachments and one consumer attachment; no scalar TEXU binding')
        self.assertTrue(all('role=color ' in line for line in lines))
        self.assertNotIn('[RED]', p.stderr)

    @unittest.skipUnless(os.environ.get('DM_TEST_RESOURCE_METADATA'), 'set DM_TEST_RESOURCE_METADATA to the own GPU fixture')
    def test_identical_own_pixels_and_resolution_counts_off_on(self):
        results = []
        for keys in ('', KEYS):
            p = fixture_run(keys=keys)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertRegex(p.stdout, r'RESOURCE_METADATA \d+ checks, 0 failed')
            counts = re.search(r'^PATH_COUNTS .*$', p.stdout, re.M)
            self.assertIsNotNone(counts, p.stdout)
            assert counts is not None
            lines = [line for line in p.stderr.splitlines() if line.startswith('[dm] [nvn-resource] ')]
            self.assertNotIn('[RED]', p.stderr)
            results.append((counts.group(0), lines))
        self.assertEqual(results[0][0], results[1][0], 'same ordinary texture queries, ID resolves, fits, view creation, passes, draws and GPU copy/dispatch counts')
        self.assertEqual(results[0][1], [])
        self.assertEqual(len(results[1][1]), 10, 'eight MRT planes, one 3D input and one consumer output; the next frame reuses the same metadata')
        facts = []
        for line in results[1][1]:
            fields = dict(part.split('=', 1) for part in line.split()[2:])
            self.assertEqual(set(fields), FIELDS)
            self.assertIn(fields['key'], KEYS.split(','))
            self.assertIn(fields['role'], ('color', 'texture'))
            for k, v in fields.items():
                if k not in ('key', 'role'):
                    self.assertRegex(v, r'^-?\d+$', k)
            self.assertNotRegex(line, r'0x|addr|pointer|uniform|pixel|hash|payload|float')
            facts.append(fields)
        producer = [f for f in facts if f['key'] == KEYS.split(',')[0]]
        self.assertEqual({(int(f['slot']), int(f['plane'])) for f in producer}, {(i, i) for i in range(8)})
        self.assertTrue(all(f['role'] == 'color' and f['descriptor'] == '-1' for f in producer))
        sampled = [f for f in facts if f['role'] == 'texture']
        self.assertEqual(len(sampled), 1)
        self.assertEqual(sampled[0]['descriptor'], '701')
        self.assertEqual({f['frame'] for f in facts}, {'1'})
        self.assertEqual(sampled[0]['serial'], producer[0]['serial'])
        for f in producer + sampled:
            self.assertEqual((f['type'], f['format'], f['width'], f['height'], f['depth'], f['dummy']), ('7', '92', '8', '8', '8', '0'))

    @unittest.skipUnless(os.environ.get('DM_TEST_RESOURCE_METADATA'), 'set DM_TEST_RESOURCE_METADATA to the own GPU fixture')
    def test_type_filter_preserves_budget_for_late_3d_replacement(self):
        counts, facts = [], []
        for keys, types in (('', ''), (KEYS, ''), (KEYS, '7'), (KEYS, '7,invalid')):
            p = fixture_run('pingpong', keys, types)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertRegex(p.stdout, r'RESOURCE_METADATA \d+ checks, 0 failed')
            match = re.search(r'^PATH_COUNTS .*$', p.stdout, re.M)
            self.assertIsNotNone(match, p.stdout)
            assert match is not None
            counts.append(match.group(0))
            lines = [line for line in p.stderr.splitlines() if line.startswith('[dm] [nvn-resource] ')]
            row = [dict(part.split('=', 1) for part in line.split()[2:]) for line in lines]
            for line, fields in zip(lines, row):
                self.assertEqual(set(fields), FIELDS)
                self.assertNotRegex(line, r'0x|addr|pointer|uniform|pixel|hash|payload|float')
            facts.append(row)
            self.assertNotIn('[RED]', p.stderr)
            self.assertEqual('invalid type list' in p.stderr, bool(types and types != '7'))
        self.assertEqual(len(set(counts)), 1, 'same GPU outputs and normal resource/command counts with filter off/on/invalid')
        self.assertEqual(facts[0], [])
        self.assertEqual(len(facts[1]), 32, 'unfiltered alternating 2D attachments spend the fixed cap')
        self.assertLess(max(int(f['frame']) for f in facts[1]), 40)
        self.assertEqual(facts[3], [], 'malformed type filter disables the trace without changing replay')
        filtered = facts[2]
        self.assertEqual(len(filtered), 18, 'two sets of eight 3D planes and a declared 3D binding')
        self.assertEqual({f['type'] for f in filtered}, {'7'})
        self.assertEqual({int(f['frame']) for f in filtered}, {1, 40})
        for frame in (1, 40):
            rows = [f for f in filtered if int(f['frame']) == frame]
            attachments = [f for f in rows if f['role'] == 'color']
            bindings = [f for f in rows if f['role'] == 'texture']
            self.assertEqual({(int(f['slot']), int(f['plane'])) for f in attachments}, {(i, i) for i in range(8)})
            self.assertEqual(len(bindings), 1)
            self.assertEqual({f['serial'] for f in rows}, {bindings[0]['serial']})
            self.assertEqual({(f['width'], f['height'], f['depth']) for f in rows}, {('8', '8', '8')})
        self.assertNotEqual(filtered[0]['serial'], filtered[-1]['serial'])

    def test_hooks_only_observe_already_resolved_metadata(self):
        source = (Path(__file__).parents[1] / 'nvn/nvn_mtl.m').read_text()
        self.assertIn('if (b->kind == NVN_RB_TEX && resource_trace_on()', source)
        self.assertIn('nvn_resource_trace_type_watches(g_resource_trace_type_mask, b->dtt)', source)
        self.assertIn('nvn_resource_trace_type_watches(g_resource_trace_type_mask, f.type)', source)
        for name in ('resource_texture_fact', 'resource_attachment_snapshot', 'resource_fact_emit'):
            match = re.search(r'\b' + name + r'\([^;{}]+\) \{', source)
            self.assertIsNotNone(match, name)
            assert match is not None
            start = match.end()
            depth, end = 1, start
            while depth:
                depth += (source[end] == '{') - (source[end] == '}')
                end += 1
            body = source[start:end-1]
            self.assertNotRegex(body, r'\b(tex_mtl|tex_by_id|tex_fast|tex_fit|ubo_handle|c2_handle|memcpy|CFRelease|CFRetain|CFBridgingRetain|newTexture|newBuffer)\b|\.contents|gpuResourceID|\bretain\b')


if __name__ == '__main__':
    unittest.main()
