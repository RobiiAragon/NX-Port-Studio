"""Verify portable-code staging and public client metadata without game assets."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('nextendo_resources', REPO / 'dm/ios/tools/nextendo_resources.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class NextendoResourcesTests(unittest.TestCase):
    def test_exact_shared_codecs_only_and_no_default_client(self):
        with tempfile.TemporaryDirectory() as directory:
            generated = Path(directory)
            self.assertEqual(module.prepare(REPO, generated), '')
            names = {'NextendoAccount.swift','NextendoCatalog.swift'}
            self.assertEqual({p.name for p in (generated/'NextendoShared').iterdir()}, names)
            for name in names:
                self.assertEqual((generated/'NextendoShared'/name).read_bytes(), (REPO/'macOS/NXPortStudio/Sources/PortCore'/name).read_bytes())
    def test_packaged_engine_can_prepare_mobile_without_the_studio_module(self):
        with tempfile.TemporaryDirectory() as directory:
            engine, generated = Path(directory)/'Engine', Path(directory)/'Gen'
            module.stage_engine(REPO, engine)
            module.prepare(engine, generated)
            self.assertEqual(len(list(engine.rglob('*.swift'))), 2)
            self.assertEqual((generated/'NextendoShared/NextendoAccount.swift').read_bytes(),
                             (REPO/'macOS/NXPortStudio/Sources/PortCore/NextendoAccount.swift').read_bytes())

    def test_invalid_public_client_metadata_is_rejected_before_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            generated = Path(directory)/'Gen'
            for invalid in ('https://example.test', 'two words', 'client\nID', '$()'):
                with self.assertRaises(ValueError): module.prepare(REPO, generated, invalid)
            self.assertFalse(generated.exists())
    def test_template_registers_own_callback_and_dynamic_metadata(self):
        template = (REPO/'dm/ios/project.yml').read_text()
        for expected in ('Gen/NextendoShared', 'nxnative-nextendo', 'DMNextendoClientID: "${DM_NEXTENDO_CLIENT_ID}"', 'DMGameTitleID: "${GAME}"', 'AuthenticationServices'):
            self.assertIn(expected, template)
        self.assertNotIn('NSAllowsArbitraryLoads', template)
