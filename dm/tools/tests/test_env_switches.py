"""docs/env_switches.tsv lists every DM_* switch the code reads, each with a class and a meaning (dm/tools/env_switches.py writes it; class and meaning are kept by hand).
A switch the code reads that the table does not list, a row for a switch nothing reads any more, or a row without a meaning fails here."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from dm.tools import env_switches

REPO = Path(__file__).resolve().parents[3]


class EnvSwitches(unittest.TestCase):
    def test_enum_members_are_constants_without_hiding_type_or_value_names(self):
        text = '''typedef enum DM_KIND { DM_FIRST = -7, DM_SECOND,
                  OTHER = DM_REFERENCE, DM_LAST = 3 } kind;
                  enum { DM_ANONYMOUS = 1 };'''
        self.assertEqual(env_switches.enum_constants(text), {'DM_FIRST', 'DM_SECOND', 'DM_LAST', 'DM_ANONYMOUS'})
        self.assertEqual(env_switches.enum_constants('/* enum { DM_COMMENT }; */ // enum { DM_LINE };'), set())

    def test_real_environment_read_wins_over_enum_constant(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'constants.h').write_text('enum { DM_CONSTANT = -7, DM_SHARED = 1 };')
            (root / 'source.c').write_text('get' + 'env("DM_SHARED");')
            (root / 'guide.md').write_text('`DM_CONSTANT` is a result code; `DM_SHARED` is also an environment setting.')
            with patch.object(env_switches, 'REPO', root), patch.object(env_switches, 'tracked', return_value=['constants.h', 'source.c', 'guide.md']):
                reads, docs = env_switches.scan()
            self.assertNotIn('DM_CONSTANT', reads)
            self.assertNotIn('DM_CONSTANT', docs)
            self.assertEqual(reads['DM_SHARED'], {'source.c'})
            self.assertEqual(docs['DM_SHARED'], {'guide.md'})

    def test_table_is_current_and_complete(self):
        r = subprocess.run([sys.executable, str(REPO / 'dm/tools/env_switches.py'), '--check'], cwd=REPO, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == '__main__':
    unittest.main()
