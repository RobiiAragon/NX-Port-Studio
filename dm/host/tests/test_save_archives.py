"""Real ZIP interoperability with independent Python writers/readers, no games.

Run normally or with DM_SAVE_ARCHIVE_SANITIZE=1 for actual ASan/UBSan processes.
The tested C implementation is shared by Studio and the Apple game launchers.
"""
from pathlib import Path
import os
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest
import warnings
import zipfile

HOST = Path(__file__).resolve().parents[1]
TITLE = 0x0100152000022000


def metadata(title=TITLE, kind=1, revision=1):
    # Independent packed JKSV v1 metadata. Synthetic account bytes only.
    result = bytearray(86)
    struct.pack_into('<IBQ', result, 0, 0x56534B4A, revision, title)
    result[13:29] = bytes(range(16))
    result[37] = kind
    struct.pack_into('<qq', result, 61, 32 * 1024 * 1024, 4 * 1024 * 1024)
    return result


class Archives(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='nx-save-zip-build-')
        cls.driver = Path(cls.build.name) / 'save-zip'
        flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if os.getenv('DM_SAVE_ARCHIVE_SANITIZE') else []
        subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', *flags,
                        str(HOST / 'save_archive.c'), str(HOST / 'tests/save_archive_driver.c'),
                        '-larchive', '-o', str(cls.driver)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nx-save-zip-case-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.zip'
        self.stage = self.root / 'stage'
        self.stage.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def zip(self, entries, compression=zipfile.ZIP_DEFLATED):
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(self.source, 'w', compression=compression) as archive:
                for name, data in entries:
                    archive.writestr(name, data)

    def run_driver(self, *args, success=True):
        process = subprocess.run([str(self.driver), *map(str, args)], capture_output=True, text=True)
        self.assertNotIn('AddressSanitizer', process.stderr)
        self.assertNotIn('runtime error:', process.stderr)
        self.assertEqual(process.returncode, 0 if success else 1, process.stderr + process.stdout)
        values = process.stdout.split()
        self.assertEqual(len(values), 7)
        return [int(v, 16 if i == 5 else 10) for i, v in enumerate(values)]

    def extract(self, success=True, title=TITLE, kind=-1):
        return self.run_driver('extract', self.source, self.stage, format(title, 'x'), kind, success=success)

    def managed(self, command, kind=-1, slot='save', success=True):
        return self.run_driver(command, self.source, self.root, slot, format(TITLE, 'x'), kind, success=success)

    def test_managed_import_retains_old_tree_and_exports_flat_zip(self):
        live = self.root / 'save'; live.mkdir(); (live / 'old').write_bytes(b'old')
        self.zip([('new', b'new'), ('.nx_save_meta.bin', metadata())])
        self.managed('import', kind=1)
        self.assertEqual((live / 'new').read_bytes(), b'new')
        backups = list((self.root / 'save-backups').iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'old').read_bytes(), b'old')
        exported = self.root / 'out.zip'
        self.run_driver('export', self.root, 'save', exported)
        with zipfile.ZipFile(exported) as z:
            self.assertEqual(set(z.namelist()), {'new', '.nx_save_meta.bin'})
            self.assertEqual(z.read('.nx_save_meta.bin'), metadata())
        self.run_driver('export', self.root, 'save', exported, success=False)

    def test_queue_delays_import_and_applies_once_without_rollback(self):
        live = self.root / 'save'; live.mkdir(); (live / 'progress').write_bytes(b'old')
        self.zip([('progress', b'new'), ('.nx_save_meta.bin', metadata())])
        self.managed('queue')
        self.assertEqual((live / 'progress').read_bytes(), b'old')
        pending = self.root / '.jksv-pending-save.zip'
        content = pending.read_bytes()
        token = bytes.fromhex(subprocess.check_output(['xattr', '-px', 'org.nxportstudio.jksv-applied-job', str(pending)], text=True))
        self.managed('import', success=False)
        self.managed('queue', success=False)
        self.run_driver('apply', self.root, format(TITLE, 'x'))
        self.assertFalse(pending.exists())
        self.assertEqual((live / 'progress').read_bytes(), b'new')
        self.assertEqual(bytes.fromhex(subprocess.check_output(['xattr', '-px', 'org.nxportstudio.jksv-applied-job', str(live)], text=True)), token)
        (live / 'progress').write_bytes(b'newer gameplay')
        pending.write_bytes(content); subprocess.run(['xattr', '-wx', 'org.nxportstudio.jksv-applied-job', token.hex(), str(pending)], check=True)
        self.run_driver('apply', self.root, format(TITLE, 'x'))
        self.assertEqual((live / 'progress').read_bytes(), b'newer gameplay')
        self.assertFalse(pending.exists())
        self.assertEqual(len(list((self.root / 'save-backups').iterdir())), 1)

    def test_invalid_queue_cleans_only_owned_files(self):
        # Literal template names are unrelated user data, never owned scratch.
        sentinel = self.root / '.jksv-check-XXXXXX'; sentinel.mkdir(); (sentinel / 'keep').write_bytes(b'keep')
        copy = self.root / '.jksv-queued-XXXXXX'; copy.write_bytes(b'keep')
        self.zip([('../escape', b'invalid')])
        self.managed('queue', success=False)
        self.assertEqual((sentinel / 'keep').read_bytes(), b'keep')
        self.assertEqual(copy.read_bytes(), b'keep')
        self.assertFalse(list(self.root.glob('.jksv-pending-*')))
        self.assertEqual(list(self.root.glob('.jksv-check-*')), [sentinel])
        self.source.unlink()
        self.managed('queue', success=False)
        self.assertEqual((sentinel / 'keep').read_bytes(), b'keep')
        self.assertEqual(copy.read_bytes(), b'keep')

    def test_queue_coexists_with_game_shared_lease_but_import_apply_are_busy(self):
        import fcntl
        self.zip([('file', b'new')])
        with (self.root / '.jksv-access.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            self.managed('queue')
            self.run_driver('apply', self.root, format(TITLE, 'x'), success=False)
            self.managed('import', success=False)
        self.run_driver('apply', self.root, format(TITLE, 'x'))
        self.assertEqual((self.root / 'save/file').read_bytes(), b'new')

    def test_apfs_commit_clone_preserves_original_metadata_and_applied_job(self):
        import ctypes
        self.zip([('progress', b'restored'), ('.nx_save_meta.bin', metadata())]); self.managed('queue')
        self.run_driver('apply', self.root, format(TITLE, 'x'))
        live = self.root / 'save'; work = self.root / 'save.work'
        libc = ctypes.CDLL(None, use_errno=True)
        libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        self.assertEqual(libc.clonefile(os.fsencode(live), os.fsencode(work), 0), 0, ctypes.get_errno())
        for key in ['org.nxportstudio.jksv-metadata', 'org.nxportstudio.jksv-applied-job']:
            self.assertEqual(subprocess.check_output(['xattr', '-px', key, str(live)]), subprocess.check_output(['xattr', '-px', key, str(work)]))
        (work / 'progress').write_bytes(b'later commit')
        next_tree = self.root / 'save.new'
        self.assertEqual(libc.clonefile(os.fsencode(work), os.fsencode(next_tree), 0), 0, ctypes.get_errno())
        self.run_driver('replace', next_tree, live)
        self.run_driver('export', self.root, 'save', self.root / 'committed.zip')
        with zipfile.ZipFile(self.root / 'committed.zip') as archive:
            self.assertEqual(archive.read('progress'), b'later commit')
            self.assertEqual(archive.read('.nx_save_meta.bin'), metadata())

    def test_cancel_pending_leaves_committed_data_untouched(self):
        live = self.root / 'save'; live.mkdir(); (live / 'progress').write_bytes(b'old')
        self.zip([('progress', b'new')]); self.managed('queue')
        self.run_driver('cancel', self.root)
        self.run_driver('apply', self.root, format(TITLE, 'x'))
        self.assertEqual((live / 'progress').read_bytes(), b'old')

    def test_runtime_case_aliases_export_guest_names_and_restore_losslessly(self):
        source = self.root / 'save'; source.mkdir()
        (source / 'SAVE.dat').write_bytes(b'upper')
        (source / '.dm-case-1').write_bytes(b'lower')
        subprocess.run(['xattr', '-w', 'org.d2rmobile.guest-name', 'save.dat', str(source / '.dm-case-1')], check=True)
        (source / 'levels').mkdir(); (source / 'levels/lower').write_bytes(b'lower dir')
        (source / '.dm-case-2').mkdir(); (source / '.dm-case-2/upper').write_bytes(b'upper dir')
        subprocess.run(['xattr', '-w', 'org.d2rmobile.guest-name', 'Levels', str(source / '.dm-case-2')], check=True)
        self.run_driver('create', source, self.source)
        with zipfile.ZipFile(self.source) as archive:
            self.assertEqual(archive.read('SAVE.dat'), b'upper')
            self.assertEqual(archive.read('save.dat'), b'lower')
            self.assertEqual(archive.read('Levels/upper'), b'upper dir')
            self.assertFalse(any(n.startswith('.dm-case-') for n in archive.namelist()))
        self.extract()
        result = self.root / 'round-trip.zip'
        self.run_driver('create', self.stage, result)
        with zipfile.ZipFile(self.source) as before, zipfile.ZipFile(result) as after:
            self.assertEqual({n: before.read(n) for n in before.namelist()}, {n: after.read(n) for n in after.namelist()})

    def test_case_colliding_zip_and_literal_alias_name_remain_distinct(self):
        expected = {'SAVE': b'upper', 'save': b'lower', '.dm-case-1': b'literal', 'Dir/one': b'one', 'dir/two': b'two'}
        self.zip(list(expected.items())); self.extract()
        output = self.root / 'round-trip.zip'; self.run_driver('create', self.stage, output)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual({n: archive.read(n) for n in archive.namelist() if not n.endswith('/')}, expected)

    def test_invalid_or_duplicate_runtime_guest_alias_is_not_exported(self):
        source = self.root / 'save'; source.mkdir(); alias = source / '.dm-case-1'; alias.write_bytes(b'alias')
        (source / 'good').write_bytes(b'ordinary')
        for name in ['../escape', 'good', '.nx_save_meta.bin', 'a/b', '.']:
            with self.subTest(name=name):
                subprocess.run(['xattr', '-w', 'org.d2rmobile.guest-name', name, str(alias)], check=True)
                self.run_driver('create', source, self.source, success=False)
                self.assertFalse(self.source.exists())

    def test_deflated_raw_jksv_tree_and_unicode(self):
        self.zip([('userdata.dat', b'fixture\x00' * 60000), ('nested/', b''), ('nested/part.bin', bytes(range(256))), ('vacío.bin', b'')])
        result = self.extract()
        self.assertEqual(result[1:4], [3, 1, 480256])
        self.assertEqual((self.stage / 'userdata.dat').read_bytes(), b'fixture\x00' * 60000)
        self.assertEqual((self.stage / 'nested/part.bin').read_bytes(), bytes(range(256)))
        self.assertEqual((self.stage / 'vacío.bin').stat().st_size, 0)

    def test_metadata_is_validated_and_excluded_from_game_files(self):
        self.zip([('save.bin', b'save'), ('.nx_save_meta.bin', metadata())])
        result = self.extract(kind=1)
        self.assertEqual(result[4:], [1, TITLE, 1])
        self.assertEqual(sorted(p.name for p in self.stage.iterdir()), ['save.bin'])

    def test_wrong_title_metadata_preserves_existing_save(self):
        live = self.root / 'live'; live.mkdir(); (live / 'save').write_bytes(b'original')
        self.zip([('save', b'new'), ('.nx_save_meta.bin', metadata(title=TITLE + 1))])
        self.assertNotEqual(self.extract(success=False)[0], 0)
        self.assertEqual((live / 'save').read_bytes(), b'original')

    def test_wrong_save_type(self):
        self.zip([('.nx_save_meta.bin', metadata(kind=3)), ('save', b'device')])
        self.extract(success=False, kind=1)

    def test_future_or_truncated_metadata_refused(self):
        for raw in [metadata(revision=2), metadata()[:-1], metadata(kind=6), b'not metadata']:
            with self.subTest(size=len(raw)):
                self.zip([('.nx_save_meta.bin', raw), ('save', b'a')])
                self.extract(success=False)

    def test_unsafe_paths_are_never_written(self):
        for name in ['../escape', '/absolute', 'a/../b', 'a//b', './save', 'C:/save', '..\\escape', 'a/\x01b']:
            with self.subTest(name=name):
                self.zip([(name, b'unsafe')]); self.extract(success=False)
                self.assertEqual(list(self.stage.iterdir()), [])
        self.assertFalse((self.root / 'escape').exists())

    def test_windows_separator_normalization_cannot_overwrite_an_alias(self):
        self.zip([('a\\b', b'original'), ('a/b', b'replacement')])
        self.extract(success=False)
        self.assertEqual((self.stage / 'a/b').read_bytes(), b'original')

    def test_duplicate_file_and_file_directory_collision(self):
        for entries in [[('save', b'a'), ('save', b'b')], [('save', b'a'), ('save/child', b'b')]]:
            with self.subTest(entries=entries):
                self.zip(entries); self.extract(success=False)
                shutil.rmtree(self.stage); self.stage.mkdir()

    def test_archive_symlink_is_refused(self):
        link = zipfile.ZipInfo('link'); link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.zip([(link, b'../outside')]); self.extract(success=False)
        self.assertEqual(list(self.stage.iterdir()), [])

    def test_crc_error_and_truncation_are_refused(self):
        self.zip([('save', b'known-fixture')], zipfile.ZIP_STORED)
        data = self.source.read_bytes(); at = data.index(b'known-fixture')
        self.source.write_bytes(data[:at] + b'X' + data[at + 1:]); self.extract(success=False)
        shutil.rmtree(self.stage); self.stage.mkdir()
        self.source.write_bytes(data[:-24]); self.extract(success=False)

    def test_non_zip_and_empty_backup_refused(self):
        for data in [b'not a zip', b'']:
            self.source.write_bytes(data); self.extract(success=False)
        self.zip([('.nx_save_meta.bin', metadata())]); self.extract(success=False)

    def test_nonempty_destination_and_symlink_source_refused(self):
        (self.stage / 'keep').write_bytes(b'original')
        self.zip([('new', b'a')]); self.extract(success=False)
        self.assertEqual((self.stage / 'keep').read_bytes(), b'original')
        (self.stage / 'keep').unlink()
        actual = self.root / 'actual.zip'; self.source.rename(actual); self.source.symlink_to(actual)
        self.extract(success=False)

    def test_export_has_no_wrapper_and_preserves_original_metadata(self):
        source = self.root / 'files'; source.mkdir(); (source / 'nested').mkdir()
        (source / 'nested/file').write_bytes(bytes(range(256)))
        (source / 'zero').write_bytes(b'')
        meta = self.root / 'meta'; meta.write_bytes(metadata())
        out = self.root / 'export.zip'
        result = self.run_driver('create', source, out, meta)
        self.assertEqual(result[1], 2)
        with zipfile.ZipFile(out) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(archive.read('nested/file'), bytes(range(256)))
            self.assertEqual(archive.read('.nx_save_meta.bin'), metadata())
            self.assertNotIn('files/', archive.namelist())

    def test_export_refuses_external_symlink_without_leaving_zip(self):
        source = self.root / 'files'; source.mkdir()
        outside = self.root / 'private'; outside.write_bytes(b'outside')
        (source / 'link').symlink_to(outside)
        out = self.root / 'export.zip'
        self.run_driver('create', source, out, success=False)
        self.assertFalse(out.exists())

    def test_imported_metadata_survives_round_trip_without_becoming_game_file(self):
        self.zip([('save', b'original'), ('.nx_save_meta.bin', metadata(kind=3))])
        self.extract(kind=3)
        out = self.root / 'roundtrip.zip'
        self.run_driver('create', self.stage, out)
        with zipfile.ZipFile(out) as archive:
            self.assertEqual(archive.read('save'), b'original')
            self.assertEqual(archive.read('.nx_save_meta.bin'), metadata(kind=3))
        self.assertFalse((self.stage / '.nx_save_meta.bin').exists())

    def test_atomic_replace_keeps_the_entire_previous_save(self):
        live = self.root / 'live'; live.mkdir(); (live / 'old').write_bytes(b'previous')
        (self.stage / 'new').write_bytes(b'imported')
        result = self.run_driver('replace', self.stage, live)
        self.assertEqual(result[1:3], [1, 1])
        self.assertEqual((live / 'new').read_bytes(), b'imported')
        self.assertFalse((live / 'old').exists())
        self.assertEqual((self.stage / 'old').read_bytes(), b'previous')

    def test_first_import_and_unsafe_destination(self):
        live = self.root / 'live'; (self.stage / 'new').write_bytes(b'imported')
        result = self.run_driver('replace', self.stage, live)
        self.assertEqual(result[1:3], [1, 0])
        self.stage.mkdir(); (self.stage / 'replacement').write_bytes(b'other')
        other = self.root / 'outside'; other.mkdir(); (other / 'keep').write_bytes(b'keep')
        link = self.root / 'link'; link.symlink_to(other, target_is_directory=True)
        result = self.run_driver('replace', self.stage, link, success=False)
        self.assertEqual(result[1:3], [0, 0])
        self.assertEqual((other / 'keep').read_bytes(), b'keep')

    def test_shared_runtime_lease_blocks_exclusive_save_management(self):
        self.run_driver('lease', self.root)

    def test_export_never_overwrites_a_file(self):
        source = self.root / 'files'; source.mkdir(); (source / 'save').write_bytes(b'a')
        out = self.root / 'export.zip'; out.write_bytes(b'keep')
        self.run_driver('create', source, out, success=False)
        self.assertEqual(out.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
