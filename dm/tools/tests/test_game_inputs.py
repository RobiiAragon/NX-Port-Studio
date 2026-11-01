"""Safe game/archive discovery; every input is synthetic and contains no keys."""
import ctypes
import importlib.util
import os
from pathlib import Path
import shutil
import stat
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
import game_inputs as inputs
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp_inputs', REPO / 'scripts/build_ipa_from_nsp.py')
assert spec is not None and spec.loader is not None
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)
APP = 0x0100000000010000


def pfs0(tid):
    name = f'{tid:016x}0000000000000011.tik'.encode() + b'\0'
    return b'PFS0' + struct.pack('<III', 1, len(name), 0) + struct.pack('<QQII', 0, 0, 0, 0) + name


def identity(tid=APP, app=APP, kind='Application', version=0):
    return {'formatVersion': 1, 'records': [{'titleId': f'{tid:016x}', 'applicationTitleId': f'{app:016x}', 'type': kind, 'version': version}]}


def sevenzip(path, entries):
    """Exercise the system 7z decoder using libarchive's independent writer."""
    lib = inputs._library()
    signatures = {
        'archive_write_new': (ctypes.c_void_p, []),
        'archive_write_set_format_7zip': (ctypes.c_int, [ctypes.c_void_p]),
        'archive_write_open_filename': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p]),
        'archive_entry_new': (ctypes.c_void_p, []),
        'archive_entry_set_pathname': (None, [ctypes.c_void_p, ctypes.c_char_p]),
        'archive_entry_set_filetype': (None, [ctypes.c_void_p, ctypes.c_uint]),
        'archive_entry_set_perm': (None, [ctypes.c_void_p, ctypes.c_int]),
        'archive_entry_set_size': (None, [ctypes.c_void_p, ctypes.c_int64]),
        'archive_write_header': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p]),
        'archive_write_data': (ctypes.c_ssize_t, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]),
        'archive_entry_free': (None, [ctypes.c_void_p]),
        'archive_write_close': (ctypes.c_int, [ctypes.c_void_p]),
        'archive_write_free': (ctypes.c_int, [ctypes.c_void_p]),
    }
    for symbol, (result, args) in signatures.items():
        fn = getattr(lib, symbol); fn.restype, fn.argtypes = result, args
    writer = lib.archive_write_new()
    try:
        assert lib.archive_write_set_format_7zip(writer) == 0
        assert lib.archive_write_open_filename(writer, os.fsencode(path)) == 0
        for name, data in entries:
            entry = lib.archive_entry_new()
            try:
                lib.archive_entry_set_pathname(entry, name.encode())
                lib.archive_entry_set_filetype(entry, stat.S_IFREG)
                lib.archive_entry_set_perm(entry, 0o600); lib.archive_entry_set_size(entry, len(data))
                assert lib.archive_write_header(writer, entry) == 0
                assert lib.archive_write_data(writer, data, len(data)) == len(data)
            finally: lib.archive_entry_free(entry)
        assert lib.archive_write_close(writer) == 0
    finally: lib.archive_write_free(writer)


class GameInputs(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp)
        cm = mock.patch.object(nsp, 'say', lambda text: None); cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)

    def archive(self, entries, name='Base.zip'):
        path = self.tmp / name
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as out:
            for key, value in entries: out.writestr(key, value)
        return path

    def assert_no_complete_cache(self):
        cache = self.tmp / '.nx-archives'
        self.assertTrue(not cache.exists() or not list(cache.iterdir()))

    def test_case_insensitive_nested_scan_and_generated_exclusions(self):
        for sub in ('one/two/three/four', 'one/two/three/four/five', 'old_build', 'old-work', 'old_survey', '.hidden', 'Old.app'):
            path = self.tmp / sub; path.mkdir(parents=True, exist_ok=True); (path / 'dump.NSP').write_bytes(pfs0(APP))
        (self.tmp / 'folder.nsp').mkdir()
        (self.tmp / 'link.NSP').symlink_to(self.tmp / 'one/two/three/four/dump.NSP')
        (self.tmp / 'linked').symlink_to(self.tmp / 'one', target_is_directory=True)
        self.assertEqual(inputs.discover(self.tmp), [self.tmp / 'one/two/three/four/dump.NSP'])

    def test_temporary_work_root_keeps_archive_files_out_of_game_folder(self):
        source = self.archive([('Base.nsp', pfs0(APP))])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app, family = nsp.scan_nsps(self.tmp, work_root=root)
            self.assertEqual(app, APP)
            self.assertTrue(family['base'].is_relative_to(root))
            self.assertTrue((root / '.nx-archives').is_dir())
        self.assertEqual(list(self.tmp.iterdir()), [source])

    def test_zip_base_and_direct_update_build_family(self):
        source = self.archive([('Folder/Base.NSP', pfs0(APP)), ('readme.txt', b'do not extract')])
        update = self.tmp / 'Update [v393216].nsp'; update.write_bytes(pfs0(APP | 0x800))
        app, family = nsp.scan_nsps(self.tmp)
        self.assertEqual(app, APP); self.assertEqual(family['updates'], [(393216, update)])
        self.assertEqual(family['base'].read_bytes(), pfs0(APP))
        self.assertEqual(family['base'].stat().st_mode & 0o777, 0o600)
        self.assertTrue(source.is_file()); self.assertFalse((family['base'].parent.parent / 'readme.txt').exists())

    def test_real_system_sevenzip_roundtrip(self):
        source = self.tmp / 'Base.7Z'; sevenzip(source, [('Nested/Base.nsp', pfs0(APP))])
        paths = inputs.extract_archive(source, self.tmp)
        self.assertEqual([p.read_bytes() for p in paths], [pfs0(APP)])

    def test_reuse_verifies_bytes_and_corrupt_cache_is_rejected(self):
        source = self.archive([('Base.nsp', pfs0(APP))]); paths = inputs.extract_archive(source, self.tmp)
        with mock.patch.object(inputs, '_extract', side_effect=AssertionError('must reuse')):
            self.assertEqual(inputs.extract_archive(source, self.tmp), paths)
        old = paths[0].read_bytes(); paths[0].write_bytes(b'x' + old[1:])
        with self.assertRaisesRegex(inputs.InputError, 'incomplete or changed'): inputs.extract_archive(source, self.tmp)

    def test_changed_source_gets_new_immutable_cache(self):
        source = self.archive([('Base.nsp', pfs0(APP))]); first = inputs.extract_archive(source, self.tmp)[0]
        self.archive([('Other.nsp', pfs0(APP))]); os.utime(source, ns=(1, 1))
        second = inputs.extract_archive(source, self.tmp)[0]
        self.assertNotEqual(first.parent.parent, second.parent.parent); self.assertTrue(first.is_file())

    def test_same_size_and_mtime_source_change_is_not_reused(self):
        source = self.archive([('Base.nsp', b'one')]); before = source.stat()
        first = inputs.extract_archive(source, self.tmp)[0]
        self.archive([('Base.nsp', b'two')]); self.assertEqual(source.stat().st_size, before.st_size)
        os.utime(source, ns=(before.st_atime_ns, before.st_mtime_ns))
        second = inputs.extract_archive(source, self.tmp)[0]
        self.assertNotEqual(first, second); self.assertEqual(first.read_bytes(), b'one'); self.assertEqual(second.read_bytes(), b'two')

    def test_unsafe_paths_rejected_without_any_complete_extraction(self):
        for name in ('../escape.nsp', '/absolute.nsp', 'C:/drive.nsp', 'nested\\..\\..\\escape.nsp', 'a/../../escape.nsp'):
            with self.subTest(name=name):
                source = self.archive([(name, pfs0(APP))])
                with self.assertRaisesRegex(inputs.InputError, 'unsafe path'): inputs.extract_archive(source, self.tmp)
                self.assert_no_complete_cache()
        self.assertFalse((self.tmp.parent / 'escape.nsp').exists())

    def test_symlink_entry_rejected(self):
        entry = zipfile.ZipInfo('link.nsp'); entry.create_system = 3; entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        source = self.archive([(entry, b'/outside')])
        with self.assertRaisesRegex(inputs.InputError, 'link or special'): inputs.extract_archive(source, self.tmp)
        self.assert_no_complete_cache()

    def test_duplicate_casefold_paths_rejected(self):
        source = self.archive([('Base.nsp', pfs0(APP)), ('base.NSP', pfs0(APP))])
        with self.assertRaisesRegex(inputs.InputError, 'duplicate game paths'): inputs.extract_archive(source, self.tmp)
        self.assert_no_complete_cache()

    def test_corrupt_archive_and_no_roms_have_actionable_errors(self):
        source = self.tmp / 'bad.7z'; source.write_bytes(b'not an archive')
        with self.assertRaisesRegex(inputs.InputError, 'cannot read'): inputs.extract_archive(source, self.tmp)
        self.assert_no_complete_cache()
        source = self.archive([('readme.txt', b'not a game')])
        with self.assertRaisesRegex(inputs.InputError, 'no NSP, XCI'): inputs.extract_archive(source, self.tmp)
        self.assert_no_complete_cache()

    def test_bounds_and_space_failure_cleanup(self):
        source = self.archive([('Base.nsp', pfs0(APP))])
        with mock.patch.object(inputs, 'MAX_FILE_BYTES', 1), self.assertRaisesRegex(inputs.InputError, 'size'):
            inputs.extract_archive(source, self.tmp)
        self.assert_no_complete_cache()
        with mock.patch.object(inputs.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 1})()), self.assertRaisesRegex(inputs.InputError, 'free disk'):
            inputs.extract_archive(source, self.tmp)
        self.assert_no_complete_cache()

    def test_member_count_and_total_size_limits(self):
        source = self.archive([('Base.nsp', pfs0(APP)), ('Other.txt', b'other')])
        with mock.patch.object(inputs, 'MAX_ENTRIES', 1), self.assertRaisesRegex(inputs.InputError, 'too many members'):
            inputs.extract_archive(source, self.tmp)
        self.assert_no_complete_cache()
        with mock.patch.object(inputs, 'MAX_TOTAL_BYTES', 1), self.assertRaisesRegex(inputs.InputError, 'expanded-size'):
            inputs.extract_archive(source, self.tmp)
        self.assert_no_complete_cache()

    def test_cache_symlinks_rejected_and_interruption_cleans_partial(self):
        outside = self.tmp / 'outside'; outside.mkdir()
        cache = self.tmp / '.nx-archives'; cache.symlink_to(outside, target_is_directory=True)
        source = self.archive([('Base.nsp', pfs0(APP))])
        with self.assertRaisesRegex(inputs.InputError, 'symbolic link'): inputs.extract_archive(source, self.tmp)
        cache.unlink()
        def interrupt(_source, destination):
            (destination / 'partial.nsp').write_bytes(b'partial')
            raise KeyboardInterrupt
        with mock.patch.object(inputs, '_extract', side_effect=interrupt), self.assertRaises(KeyboardInterrupt):
            inputs.extract_archive(source, self.tmp)
        self.assert_no_complete_cache()

    def test_duplicates_and_update_only_report_clear_recovery(self):
        (self.tmp / 'Update.nsp').write_bytes(pfs0(APP | 0x800))
        with self.assertRaisesRegex(nsp.BuildError, 'update or DLC alone'): nsp.scan_nsps(self.tmp)
        (self.tmp / 'Base.NSP').write_bytes(pfs0(APP)); (self.tmp / 'Copy.nsp').write_bytes(pfs0(APP))
        with self.assertRaisesRegex(nsp.BuildError, 'more than one base'): nsp.scan_nsps(self.tmp)

    def test_uppercase_compression_prefers_plain_mirror(self):
        (self.tmp / 'Game.NSZ').write_bytes(pfs0(APP)); (self.tmp / 'game.NSP').write_bytes(pfs0(APP))
        self.assertEqual(nsp.scan_nsps(self.tmp)[1]['base'].name, 'game.NSP')

    def test_empty_plain_copy_does_not_hide_compressed_game(self):
        (self.tmp / 'Game.NSZ').write_bytes(pfs0(APP)); (self.tmp / 'game.NSP').write_bytes(b'')
        self.assertEqual(nsp.scan_nsps(self.tmp)[1]['base'].name, 'Game.NSZ')

    def test_uppercase_compressed_input_is_converted(self):
        source = self.tmp / 'Game [V0].XCZ'; source.write_bytes(pfs0(APP))
        app, family = nsp.scan_nsps(self.tmp)
        self.assertEqual(nsp.version_of(source), 0)
        def convert(command, log, **kwargs):
            out = Path(command[command.index('-o') + 1]); (out / (source.stem + '.xci')).write_bytes(b'converted')
        keys = self.tmp / 'synthetic.keys'; keys.write_text('synthetic fixture')
        with mock.patch.object(nsp, 'run', side_effect=convert), mock.patch.object(nsp, 'PROG', mock.Mock()), mock.patch.object(nsp.importlib.util, 'find_spec', return_value=object()):
            result = nsp.decompress_nsz(self.tmp, app, family, keys, {})
        self.assertEqual(result['base'].suffix, '.xci'); self.assertEqual(result['base'].read_bytes(), b'converted')

    def test_nested_same_named_nsz_base_and_update_keep_distinct_outputs(self):
        base, update = self.tmp / 'Base/dump.nsz', self.tmp / 'Update/dump.nsz'
        for path, tid in ((base, APP), (update, APP | 0x800)):
            path.parent.mkdir(); path.write_bytes(pfs0(tid)); os.utime(path, ns=(1, 1))
        self.assertEqual(base.stat().st_size, update.stat().st_size)
        app, family = nsp.scan_nsps(self.tmp)
        runs = []
        def convert(command, log, **kwargs):
            source, out = Path(command[-1]), Path(command[command.index('-o') + 1]); runs.append(source)
            (out / (source.stem + '.nsp')).write_bytes(source.read_bytes())
        keys = self.tmp / 'synthetic.keys'; keys.write_text('synthetic fixture')
        with mock.patch.object(nsp, 'run', side_effect=convert), mock.patch.object(nsp, 'PROG', mock.Mock()), mock.patch.object(nsp.importlib.util, 'find_spec', return_value=object()):
            result = nsp.decompress_nsz(self.tmp, app, family, keys, {})
            repeated = nsp.decompress_nsz(self.tmp, app, family, keys, {})
        self.assertEqual(len(runs), 2); self.assertEqual(result, repeated)
        self.assertNotEqual(result['base'], result['updates'][0][1])
        self.assertEqual(nsp.title_of(result['base']), APP)
        self.assertEqual(nsp.title_of(result['updates'][0][1]), APP | 0x800)

    def test_malformed_pfs0_metadata_is_bounded(self):
        source = self.tmp / 'Bad.nsp'
        for data in (b'PFS0', b'PFS0' + struct.pack('<III', 0xffffffff, 0xffffffff, 0),
                     b'PFS0' + struct.pack('<III', 1, 1, 0),
                     b'PFS0' + struct.pack('<III', 1, 1, 0) + struct.pack('<QQII', 0, 0, 2, 0) + b'\0',
                     b'PFS0' + struct.pack('<III', 1, 1, 0) + struct.pack('<QQII', 0, 0, 0, 0) + b'x'):
            source.write_bytes(data)
            with self.subTest(size=len(data)), self.assertRaisesRegex(nsp.BuildError, 'PFS0'): nsp.title_of(source)

    def test_ticketless_unlabelled_cartridge_uses_metadata(self):
        source = self.tmp / 'My cartridge.XCI'; source.write_bytes(bytes(0x100) + b'HEAD' + bytes(0x100))
        identify = mock.Mock(return_value=identity())
        app, family = nsp.scan_nsps(self.tmp, identify=identify)
        self.assertEqual((app, family['base']), (APP, source)); identify.assert_called_once_with(source)

    def test_untagged_update_uses_its_exact_cnmt_version(self):
        base, update = self.tmp / 'Base.nsp', self.tmp / 'Update.nsp'
        base.write_bytes(pfs0(APP)); update.write_bytes(pfs0(APP | 0x800))
        identify = mock.Mock(return_value=identity(APP | 0x800, kind='Patch', version=393216))
        app, family = nsp.scan_nsps(self.tmp, identify=identify)
        self.assertEqual((app, family['updates']), (APP, [(393216, update)])); identify.assert_called_once_with(update)

    def test_known_tagged_inputs_do_not_build_or_call_probe(self):
        base, update = self.tmp / 'Base.nsp', self.tmp / 'Update [v393216].nsp'
        base.write_bytes(pfs0(APP)); update.write_bytes(pfs0(APP | 0x800))
        with mock.patch.object(nsp, 'build_nx_extract', side_effect=AssertionError('must be lazy')):
            identify = nsp.make_container_identifier(REPO, self.tmp, self.tmp / 'synthetic.keys', {})
            self.assertEqual(nsp.scan_nsps(self.tmp, identify=identify)[0], APP)
        self.assertFalse((self.tmp / '.nx-identify').exists())

    def test_identity_schema_rejects_malformed_and_inconsistent_records(self):
        path = self.tmp / 'Unknown.xci'
        invalid = [None, {'formatVersion': True, 'records': []}, {'formatVersion': 2, 'records': []}, {'formatVersion': 1, 'records': []},
                   identity(APP + 1), identity(APP | 0x800, kind='Application'), identity(APP, kind='Patch'),
                   identity(APP | 0x800, kind='AddOnContent'), identity(kind='SystemProgram'), identity(version=True), identity(version=-1), identity(version=2**32),
                   identity(app=APP + 1)]
        malformed = identity(); malformed['records'][0]['titleId'] = 'not hex'; invalid.append(malformed)
        malformed = identity(); malformed['records'] *= 2; invalid.append(malformed)
        for document in invalid:
            with self.subTest(document=document), self.assertRaisesRegex(nsp.BuildError, 'invalid game metadata'):
                nsp.container_identity(document, path)
        self.assertEqual(nsp.container_identity(identity(APP + 0x1001, kind='AddOnContent', version=65536), path),
                         (APP + 0x1001, APP, 'AddOnContent', 65536))

    def test_metadata_disagreement_and_multiple_games_are_not_guessed(self):
        source = self.tmp / 'Update.nsp'; source.write_bytes(pfs0(APP | 0x800))
        with self.assertRaisesRegex(nsp.BuildError, 'disagrees with the ticket'):
            nsp.scan_nsps(self.tmp, identify=lambda path: identity())
        source.unlink(); (self.tmp / 'Base.nsp').write_bytes(pfs0(APP))
        unknown = self.tmp / 'Other.xci'; unknown.write_bytes(bytes(0x100) + b'HEAD' + bytes(0x100))
        with self.assertRaisesRegex(nsp.BuildError, 'more than one game'):
            nsp.scan_nsps(self.tmp, identify=lambda path: identity(APP + 0x10000, APP + 0x10000))

    def test_metadata_probe_builds_once_and_writes_private_bounded_json(self):
        first, second = self.tmp / 'One.xci', self.tmp / 'Two.xci'
        for path in (first, second): path.write_bytes(b'synthetic cartridge')
        keys = self.tmp / 'synthetic.keys'; keys.write_text('not real keys')
        commands = []
        def run(command, log, **kwargs):
            commands.append(command); Path(command[-1]).write_text(__import__('json').dumps(identity()))
        with mock.patch.object(nsp, 'build_nx_extract', return_value=self.tmp / 'nx_extract') as build, \
             mock.patch.object(nsp, 'run', side_effect=run), mock.patch.object(nsp.shutil, 'which', return_value='/fake/dotnet'), mock.patch.object(nsp, 'PROG', mock.Mock()):
            identify = nsp.make_container_identifier(REPO, self.tmp, keys, {'PATH': '/fake'})
            self.assertEqual(identify(first), identity()); self.assertEqual(identify(second), identity())
        self.assertEqual(build.call_count, 1); self.assertEqual(len(commands), 2)
        self.assertEqual(commands[0][:2], ['/fake/dotnet', self.tmp / 'nx_extract.dll'])
        self.assertEqual(commands[0][2:5], [keys, '--identify', first])
        self.assertEqual((self.tmp / '.nx-identify').stat().st_mode & 0o777, 0o700)
        for output in (self.tmp / '.nx-identify').glob('identity-*.json'): self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_metadata_probe_dependency_failure_and_invalid_output_are_actionable(self):
        source = self.tmp / 'Unknown.xci'; source.write_bytes(b'synthetic cartridge')
        with mock.patch.object(nsp.shutil, 'which', return_value=None), self.assertRaisesRegex(nsp.BuildError, '.NET SDK 10'):
            nsp.make_container_identifier(REPO, self.tmp, self.tmp / 'synthetic.keys', {})(source)
        def run(command, log, **kwargs): Path(command[-1]).write_bytes(b'?' * (2**20 + 1))
        with mock.patch.object(nsp, 'build_nx_extract', return_value=self.tmp / 'nx_extract'), \
             mock.patch.object(nsp, 'run', side_effect=run), mock.patch.object(nsp.shutil, 'which', return_value='/fake/dotnet'), mock.patch.object(nsp, 'PROG', mock.Mock()), \
             self.assertRaisesRegex(nsp.BuildError, 'invalid game metadata output'):
            nsp.make_container_identifier(REPO, self.tmp, self.tmp / 'synthetic.keys', {})(source)


if __name__ == '__main__': unittest.main()
