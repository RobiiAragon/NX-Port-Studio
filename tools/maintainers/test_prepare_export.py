"""Source-publication guardrails; synthetic bytes only, no game/firmware/key data."""
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('exporter',Path(__file__).with_name('prepare_export.py'))
e=importlib.util.module_from_spec(spec);spec.loader.exec_module(e)

class ExportGuards(unittest.TestCase):
    def test_inherited_art_and_private_data_are_denied(self):
        for path in ['docs/images/game.png','docs/images/diagram.svg','a/prod.keys','a/title.nca','RomFS/file.dat','work/notes.md','macOS/NXPortStudio/.build/file']:
            self.assertIsNotNone(e.filtered(path,set()),path)
        self.assertIsNone(e.filtered('dm/third_party/libvpx/build/make/Makefile',set()))
    def test_only_tracked_compiler_exception_and_no_debug_symbols(self):
        name=e.TRANSLATOR+'System.Runtime.dll'
        self.assertIsNone(e.filtered(name,{name}))
        self.assertIsNotNone(e.filtered(name,set()))
        pdb=e.TRANSLATOR+'compiler.pdb'
        self.assertIsNotNone(e.filtered(pdb,{pdb}))
    def test_binary_signatures(self):
        self.assertEqual(e.binary_kind(bytes.fromhex('cffaedfe')), 'Mach-O')
        self.assertEqual(e.binary_kind(b'MZdata'),'PE')
        self.assertIsNone(e.binary_kind(b'plain text'))
    def test_redacted_report_never_contains_matching_value(self):
        value=b'nxc_' + b'syntheticclient123'
        hits=e.scan('source.swift',value)
        self.assertTrue(hits);self.assertNotIn(value.decode(),str(hits))
        self.assertEqual(e.scan('source.py',b'/Users/test/project/'),[])
        self.assertEqual(e.scan('source.py',b'/Users/'+b'someperson/project/')[0]['category'],'personal_home_path')
    def test_images_removed_and_lost_root_anchor_redirects_to_upstream(self):
        text=b'![test](../docs/images/game.png)\n<img src="../docs/images/game.png">\n[Play](../README.md#play)\n'
        result,changes=e.sanitize_markdown('docs/guide.md',text,{'docs/images/game.png':'art'},{'get-started'},'https://example.test/commit')
        self.assertNotIn(b'![',result);self.assertNotIn(b'<img',result)
        self.assertIn(b'https://example.test/commit/README.md#play',result)
        self.assertTrue(changes)
    def test_reference_images_removed_and_personal_markdown_paths_scrubbed(self):
        text=b'![test][image]\nPath `'+b'/Users/'+b'someperson/Documents/local/file`.\n'
        result,_=e.sanitize_markdown('README.md',text,{},set(),'https://example.test')
        self.assertNotIn(b'![',result);self.assertNotIn(b'/Users/'+b'someperson',result)
        self.assertFalse(e.scan('README.md',result))
    def test_private_signing_and_account_files_denied_without_reading(self):
        for path in ['nextendo-account.json','nextendo-session-backup.json','secrets/client.p12','secrets/client.pfx','signing/profile.mobileprovision','cert/client.key','tls/private.pem','.env.production','android/release.keystore']:
            self.assertIsNotNone(e.filtered(path,set()),path)
    def test_opaque_account_schema_and_oauth_payloads_are_detected(self):
        import json
        cases=[{'schema_version':1,'token_kind':'oauth','token':'opaque-fixture'}, {'access_token':'opaque-fixture'}, {'nested':{'refresh_token':'opaque-fixture'}}]
        for case in cases:
            findings=e.scan('disguised.data',json.dumps(case).encode())
            self.assertTrue(any(x['category']=='serialized_credential_payload' for x in findings))
            self.assertNotIn('opaque-fixture',str(findings))
        self.assertFalse(e.scan('catalog.json',b'{"key_id":"catalog-key-1","payload":"public","signature":"public"}'))
    def test_fixture_exception_is_exact_not_function_wide(self):
        raw=b'func testKeyMaterialRedactedFromLogs() { master_key_00 = '+b'0'*32+b' }'
        self.assertTrue(e.scan('macOS/NXPortStudio/Tests/PortCoreTests/BuildCoreTests.swift',raw))
    def test_source_credentials_are_blocked_not_edited(self):
        hits=e.scan('source.swift',b'let privatePath="'+b'/Users/'+b'someperson/private"')
        self.assertEqual(hits[0]['category'],'personal_home_path')
    def test_original_asset_record_matches_bytes(self):
        import hashlib,json
        draft=Path(__file__).resolve().parents[1]
        if not (draft/'public-assets.json').is_file():draft=Path(__file__).resolve().parents[2]
        for asset in json.loads((draft/'public-assets.json').read_text())['assets']:
            self.assertTrue(asset['provenance'])
            self.assertEqual(hashlib.sha256((draft/asset['path']).read_bytes()).hexdigest(),asset['sha256'])

if __name__=='__main__':unittest.main()
