"""Bounded discovery and private extraction of a user's game inputs.

libarchive is part of macOS. We stream regular game files ourselves instead of
asking an unpacker to restore paths, links, permissions or executable content.
No key material is read by this module.
"""
import ctypes
import ctypes.util
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile

ROM_SUFFIXES = frozenset(('.nsp', '.xci', '.nsz', '.xcz'))
ARCHIVE_SUFFIXES = frozenset(('.zip', '.7z'))
MAX_DEPTH = 4
MAX_ENTRIES = 10000
MAX_FILE_BYTES = 128 * 2**30
MAX_TOTAL_BYTES = 256 * 2**30
CACHE_VERSION = 1
PACKAGE_SUFFIXES = frozenset(('.app', '.bundle', '.framework', '.xcassets', '.xcodeproj', '.xcworkspace', '.appex'))


class InputError(ValueError):
    pass


def discover(folder):
    """Inputs at the root or four folder levels below it; never follow links.

    Generated build, survey and agent work folders must not turn yesterday's
    derived files into duplicate base games on the next scan.
    """
    folder = Path(folder)
    found = []
    for root, dirs, names in os.walk(folder, followlinks=False):
        depth = len(Path(root).relative_to(folder).parts)
        dirs[:] = sorted(d for d in dirs if depth < MAX_DEPTH and not d.startswith('.')
                         and not d.lower().endswith(('_build', '_survey', '-work'))
                         and Path(d).suffix.lower() not in PACKAGE_SUFFIXES
                         and not (Path(root) / d).is_symlink())
        for name in sorted(names):
            path = Path(root) / name
            if not name.startswith('.') and path.suffix.lower() in ROM_SUFFIXES | ARCHIVE_SUFFIXES:
                if path.is_file() and not path.is_symlink(): found.append(path)
    return sorted(found)


def _digest(path):
    h = hashlib.sha256()
    with path.open('rb') as src:
        for chunk in iter(lambda: src.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()


def _identity(info):
    return info.st_dev, info.st_ino, info.st_ctime_ns, info.st_size, info.st_mtime_ns


def _member_path(name):
    # A Windows drive, backslash or control character must not acquire a new
    # meaning if this cache is ever consumed by another tool or platform.
    if (not name or '\\' in name or ':' in name or any(ord(c) < 32 for c in name)
            or name.startswith('/') or '..' in PurePosixPath(name).parts):
        raise InputError('archive contains an unsafe path; extract a clean game dump manually')
    parts = PurePosixPath(name).parts
    if not parts or len(parts) > 32 or len(name.encode('utf-8')) > 4096:
        raise InputError('archive member path exceeds the supported bounds')
    return Path(*parts)


def _library():
    name = ctypes.util.find_library('archive')
    if not name:
        raise InputError('ZIP / 7z game archives require libarchive; extract the archive beside your update NSP and retry')
    lib = ctypes.CDLL(name)
    signatures = {
        'archive_read_new': (ctypes.c_void_p, []),
        'archive_read_support_filter_all': (ctypes.c_int, [ctypes.c_void_p]),
        'archive_read_support_format_zip': (ctypes.c_int, [ctypes.c_void_p]),
        'archive_read_support_format_7zip': (ctypes.c_int, [ctypes.c_void_p]),
        'archive_read_open_filename': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]),
        'archive_read_next_header': (ctypes.c_int, [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]),
        'archive_read_data': (ctypes.c_ssize_t, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]),
        'archive_read_data_skip': (ctypes.c_int, [ctypes.c_void_p]),
        'archive_read_free': (ctypes.c_int, [ctypes.c_void_p]),
        'archive_error_string': (ctypes.c_char_p, [ctypes.c_void_p]),
        'archive_entry_pathname_utf8': (ctypes.c_char_p, [ctypes.c_void_p]),
        'archive_entry_filetype': (ctypes.c_uint, [ctypes.c_void_p]),
        'archive_entry_size': (ctypes.c_int64, [ctypes.c_void_p]),
        'archive_entry_symlink': (ctypes.c_char_p, [ctypes.c_void_p]),
        'archive_entry_hardlink': (ctypes.c_char_p, [ctypes.c_void_p]),
    }
    try:
        for symbol, (result, args) in signatures.items():
            fn = getattr(lib, symbol); fn.restype, fn.argtypes = result, args
    except AttributeError as error:
        raise InputError('the installed libarchive lacks ZIP / 7z support; extract the game archive manually') from error
    return lib


def _extract(source, destination):
    lib = _library(); reader = lib.archive_read_new()
    if not reader: raise InputError('could not allocate the archive reader')

    def check(result):
        if result < 0:
            # Archive errors can include arbitrary member names. Do not emit
            # these as terminal control sequences or gigantic error strings.
            raw = lib.archive_error_string(reader) or b'unknown archive error'
            detail = ''.join(c if c.isprintable() else '?' for c in raw.decode('utf-8', 'replace'))[:300]
            raise InputError(f'cannot read {source.name}: {detail}. Encrypted or damaged archives must be extracted manually')
        return result

    result, total, seen, count = [], 0, set(), 0
    size_limit = min(MAX_TOTAL_BYTES, max(2**30, source.stat().st_size * 1000))
    try:
        check(lib.archive_read_support_filter_all(reader))
        check(lib.archive_read_support_format_zip(reader)); check(lib.archive_read_support_format_7zip(reader))
        check(lib.archive_read_open_filename(reader, os.fsencode(source), 1024 * 1024))
        entry, buffer = ctypes.c_void_p(), ctypes.create_string_buffer(1024 * 1024)
        while True:
            status = check(lib.archive_read_next_header(reader, ctypes.byref(entry)))
            if status == 1: break
            count += 1
            if count > MAX_ENTRIES: raise InputError('archive has too many members (maximum 10,000)')
            raw = lib.archive_entry_pathname_utf8(entry)
            if raw is None: raise InputError('archive contains an undecodable member name')
            try: relative = _member_path(raw.decode('utf-8'))
            except UnicodeError as error: raise InputError('archive member name is not valid UTF-8') from error
            kind = lib.archive_entry_filetype(entry)
            if lib.archive_entry_symlink(entry) or lib.archive_entry_hardlink(entry) or kind not in (stat.S_IFREG, stat.S_IFDIR):
                raise InputError('archive contains a link or special file; only regular game files are supported')
            if kind == stat.S_IFDIR: continue
            size = lib.archive_entry_size(entry)
            if size < 0 or size > MAX_FILE_BYTES: raise InputError('archive member exceeds the supported size (128 GiB)')
            total += size
            if total > size_limit: raise InputError('archive exceeds the expanded-size or compression-ratio limit')
            if relative.suffix.lower() not in ROM_SUFFIXES:
                check(lib.archive_read_data_skip(reader)); continue
            normalized = relative.as_posix().casefold()
            if normalized in seen: raise InputError('archive contains duplicate game paths')
            seen.add(normalized)
            if shutil.disk_usage(destination).free < size + 256 * 2**20:
                raise InputError('not enough free disk space to extract this game archive (256 MiB reserve required)')
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            digest, written = hashlib.sha256(), 0
            with target.open('xb') as out:
                os.chmod(target, 0o600)
                while True:
                    got = check(lib.archive_read_data(reader, buffer, len(buffer)))
                    if not got: break
                    written += got
                    if written > size: raise InputError('archive member expanded beyond its declared size')
                    chunk = buffer.raw[:got]; digest.update(chunk); out.write(chunk)
            if written != size: raise InputError('archive member is truncated')
            result.append({'path': relative.as_posix(), 'size': size, 'sha256': digest.hexdigest()})
        if not result: raise InputError(f'no NSP, XCI, NSZ or XCZ inside {source.name}; extract nested archives manually')
        return result
    finally: lib.archive_read_free(reader)


def extract_archive(source, folder):
    """Reuse only a complete, byte-verified extraction beside the user's game.

    A failed or interrupted extraction leaves no usable cache. The original
    archive is retained and no entry's permissions or timestamps are restored.
    """
    source, folder = Path(source).resolve(), Path(folder).resolve()
    before = source.stat()
    source_hash = _digest(source)
    if _identity(source.stat()) != _identity(before):
        raise InputError('archive changed while checking its bytes; wait for its copy to finish and retry')
    stamp = {'version': CACHE_VERSION, 'source': str(source), 'size': before.st_size,
             'mtime_ns': before.st_mtime_ns, 'sha256': source_hash}
    token = hashlib.sha256(json.dumps(stamp, sort_keys=True).encode()).hexdigest()
    cache = folder / '.nx-archives'
    if cache.is_symlink(): raise InputError('the generated .nx-archives directory must not be a symbolic link')
    cache.mkdir(mode=0o700, exist_ok=True)
    final = cache / token
    if final.exists() or final.is_symlink():
        try:
            if final.is_symlink(): raise ValueError('cache link')
            manifest = final / 'manifest.json'
            if manifest.is_symlink() or manifest.stat().st_size > 4 * 2**20: raise ValueError('invalid manifest')
            saved = json.loads(manifest.read_text())
            if saved['source'] != stamp or not 0 < len(saved['files']) <= MAX_ENTRIES: raise ValueError('different source')
            paths = []
            for item in saved['files']:
                path = final / 'files' / _member_path(item['path'])
                if any(p.is_symlink() for p in (path, *path.parents)) or not path.is_file(): raise ValueError('cache link or missing file')
                if path.stat().st_size != item['size'] or _digest(path) != item['sha256']: raise ValueError('cache bytes changed')
                paths.append(path)
            if _identity(source.stat()) != _identity(before): raise ValueError('source changed during reuse')
            return paths
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise InputError(f'archive cache is incomplete or changed; remove {final} and retry') from error
    with tempfile.TemporaryDirectory(prefix='.partial-', dir=cache) as tmp:
        tmp = Path(tmp); files = tmp / 'files'; files.mkdir(mode=0o700)
        records = _extract(source, files)
        after = source.stat()
        if _identity(after) != _identity(before):
            raise InputError('archive changed during extraction; wait for its copy to finish and retry')
        (tmp / 'manifest.json').write_text(json.dumps({'source': stamp, 'files': records}, sort_keys=True))
        os.chmod(tmp / 'manifest.json', 0o600)
        try: tmp.rename(final)
        except FileExistsError as error: raise InputError('another extraction finished concurrently; retry the build') from error
    return [final / 'files' / record['path'] for record in records]
