"""Registered EUR startup inputs: real selection/build gates and metadata only, no game assets."""
import importlib.util
from pathlib import Path
import re
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(REPO / 'dm/games'), str(REPO / 'dm/gfx/tools')]
import game
import dmsh_chain

spec = importlib.util.spec_from_file_location('nsp_splatoon2', REPO / 'scripts/build_ipa_from_nsp.py')
assert spec is not None and spec.loader is not None
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)
TID = 0x0100F8F0000A2000
BUILD = 'v3342336'
MAIN = '592c7051a4e620563d0296096d8f0ac5'
SDK = 'ead5aad43c3efa01682460ece70a8189'


class Splatoon2Profile(unittest.TestCase):
    def test_registered_selection_and_exact_executable_gate(self):
        g = game.by_title(TID)
        self.assertIsNotNone(g)
        assert g is not None
        self.assertEqual(g.dir, REPO / 'dm/games/0100F8F0000A2000')
        self.assertEqual(g.words('modules'), ['main', 'sdk'])
        self.assertEqual(g.words('shader_versions'), [BUILD])
        alias = game.by_build(MAIN)
        self.assertIsNotNone(alias)
        assert alias is not None
        self.assertEqual(alias.id, g.id)
        # Header bytes are synthetic. A different SDK must not inherit this
        # registered build's qualification merely because its NACP says 5.5.2.
        with tempfile.TemporaryDirectory() as root:
            extracted = Path(root); exefs = extracted / 'ExeFS'; exefs.mkdir()
            for module, bid in [('main', MAIN), ('sdk', SDK)]:
                (exefs / module).write_bytes(b'NSO0' + bytes(0x3c) + bytes.fromhex(bid) + bytes(0x50))
            self.assertEqual(nsp.build_mismatch(extracted, BUILD, g), [])
            (exefs / 'sdk').write_bytes(b'NSO0' + bytes(0x3c) + bytes.fromhex('aa' * 16) + bytes(0x50))
            self.assertEqual(len(nsp.build_mismatch(extracted, BUILD, g)), 1)
        header = game.header(g)
        self.assertIn(MAIN, header)
        self.assertIn('5.5.2', header)
        self.assertIn('DM_GAME_SYS_RESOURCE 0x0', header)

    def test_pair_coverage_and_qualified_shader_input_identity(self):
        g = game.by_title(TID)
        assert g is not None
        stages = {}
        for line in g.table('shader_map.tsv').read_text().splitlines():
            if not line or line.startswith(('#', 'package\t')): continue
            _, _, stage, key, _ = line.split('\t')
            self.assertRegex(key, r'^[0-9a-f]{16}$')
            self.assertNotIn(key, stages)
            stages[key] = stage
        self.assertEqual(len(stages), 74541)
        for name, count in [('shader_pairs.tsv', 51462), ('pso_pairs.tsv', 7944)]:
            pairs = [line.split('\t') for line in g.table(name).read_text().splitlines() if line and not line.startswith('#')]
            self.assertEqual(len(pairs), count)
            for vertex, pixel in pairs:
                self.assertEqual((stages[vertex], stages[pixel]), ('vertex', 'pixel'))
        # This stamp is the qualified real split's identity, not a shader binary.
        self.assertEqual(dmsh_chain.inputs(g), '6b44c021109c')
        self.assertIsNone(re.search(r'/Users/|prod\.keys|dev\.keys', g.table('game.tsv').read_text()))


if __name__ == '__main__':
    unittest.main()
