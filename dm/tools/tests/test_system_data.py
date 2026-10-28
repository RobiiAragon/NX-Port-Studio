"""Only validated supported firmware resources enter game bundles."""
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import system_data


class SystemDataTests(unittest.TestCase):
    def test_private_history_keyring_is_staged_without_system_code(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source, output = base / 'system_data', base / 'stage'
            files = source / system_data.FRIENDS_TITLE_ID / 'files'
            files.mkdir(parents=True)
            synthetic = bytes(range(256))
            (files / 'play-history.keyring').write_bytes(synthetic)
            self.assertEqual(system_data.stage(source, output), 1)
            staged = output / system_data.FRIENDS_TITLE_ID / 'files'
            self.assertEqual((staged / 'play-history.keyring').read_bytes(), synthetic)
            self.assertEqual([entry.name for entry in staged.iterdir()], ['play-history.keyring'])

            # A complete sysmodule must never be copied merely because its
            # title ID is allowed for the extracted data resource.
            (files / 'main').write_bytes(b'synthetic-system-code')
            with self.assertRaisesRegex(ValueError, 'invalid private local play-history'):
                system_data.stage(source, output)
            self.assertEqual([entry.name for entry in staged.iterdir()], ['play-history.keyring'])

    def test_history_keyring_wrong_size_preserves_previous_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source, output = base / 'system_data', base / 'stage'
            self.fixture(source)
            system_data.stage(source, output)
            files = source / system_data.FRIENDS_TITLE_ID / 'files'
            files.mkdir(parents=True)
            for size in (0, 255, 257, 1024):
                with self.subTest(size=size):
                    (files / 'play-history.keyring').write_bytes(bytes(size))
                    with self.assertRaisesRegex(ValueError, 'invalid private local play-history'):
                        system_data.stage(source, output)
                    self.assertEqual((output / '0100000000000802/files/resource.dat').read_bytes(), b'real-resource')

    def test_certstore_resources_are_staged(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source, output = base / 'system_data', base / 'stage'
            files = self.fixture(source, '0100000000000800')
            (files / 'ssl_TrustedCerts.bdf').write_bytes(b'extracted-certstore-fixture')
            self.assertEqual(system_data.stage(source, output), 1)
            self.assertEqual((output / '0100000000000800/files/ssl_TrustedCerts.bdf').read_bytes(),
                             b'extracted-certstore-fixture')

    def fixture(self, root, title='0100000000000802'):
        files = root / title / 'files'
        files.mkdir(parents=True)
        (files / 'resource.dat').write_bytes(b'real-resource')
        return files

    def test_copy_filters_root_and_replaces_previous_selection(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source, output = base / 'system_data', base / 'Game.app/system_data'
            files = self.fixture(source)
            (source / 'prod.keys').write_text('must never enter app')
            (source / 'something.nca').touch()
            self.fixture(source, '0100000000009999')
            self.assertEqual(system_data.stage(source, output), 1)
            self.assertEqual((output / '0100000000000802/files/resource.dat').read_bytes(), b'real-resource')
            self.assertEqual([p.name for p in output.iterdir()], ['0100000000000802'])
            (output / 'stale').touch()
            (files / 'resource.dat').write_bytes(b'new')
            system_data.stage(source, output)
            self.assertFalse((output / 'stale').exists())
            self.assertEqual((output / '0100000000000802/files/resource.dat').read_bytes(), b'new')

    def test_rejects_links_before_modifying_previous_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source, output = base / 'system_data', base / 'stage'
            files = self.fixture(source)
            system_data.stage(source, output)
            (files / 'key-link').symlink_to(base / 'prod.keys')
            with self.assertRaisesRegex(ValueError, 'link or special'):
                system_data.stage(source, output)
            self.assertEqual((output / '0100000000000802/files/resource.dat').read_bytes(), b'real-resource')
            (files / 'key-link').unlink()
            with self.assertRaisesRegex(ValueError, 'outside its source'):
                system_data.stage(source, source / 'nested')
            with self.assertRaisesRegex(ValueError, 'outside its source'):
                system_data.stage(source, source.parent)

    def test_missing_and_empty_resources_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, 'no supported'):
                system_data.archives(root)
            (root / '0100000000000802/files').mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, 'empty system data'):
                system_data.archives(root)


if __name__ == '__main__':
    unittest.main()
