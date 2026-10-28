#!/usr/bin/env python3
"""Validate and stage extracted firmware resources, never NCAs or keys.

Input: system_data/<title-id>/files from nx_extract --firmware. Only the
supported system archives and their regular RomFS files enter a game bundle.
"""
import argparse
import os
from pathlib import Path
import shutil
import tempfile

TITLE_IDS = tuple(f'010000000000{x:04x}' for x in (0x800, 0x802, 0x805, 0x809, *range(0x810, 0x815)))


def archives(root):
    root = Path(root).expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f'system data directory unavailable: {root}')
    found = []
    for title_id in TITLE_IDS:
        archive = root / title_id
        files = archive / 'files'
        if not archive.exists() and not archive.is_symlink():
            continue
        if archive.is_symlink() or files.is_symlink() or not files.is_dir():
            raise ValueError(f'invalid system data archive: {title_id}/files')
        count = 0
        for directory, dirs, names in os.walk(files, followlinks=False):
            for name in dirs + names:
                path = Path(directory) / name
                if path.is_symlink() or not (path.is_dir() or path.is_file()):
                    raise ValueError(f'system data contains a link or special file: {path.relative_to(root)}')
            count += len(names)
        if not count:
            raise ValueError(f'empty system data archive: {title_id}/files')
        found.append((title_id, files))
    if not found:
        raise ValueError(f'no supported extracted system archives in {root}')
    return found


def stage(root, destination):
    selected = archives(root)  # validate before replacing a previous staged tree
    destination = Path(destination).absolute()
    source = Path(root).expanduser().resolve()
    target = destination.resolve()
    if target == source or source in target.parents or target in source.parents:
        raise ValueError('system data destination must be outside its source')
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f'.{destination.name}-', dir=destination.parent))
    try:
        for title_id, files in selected:
            shutil.copytree(files, temporary / title_id / 'files')
        # Staging is part of the build before signing. A failed copy above leaves
        # the previous resources intact; omitted archives are removed on success.
        if destination.is_symlink() or destination.is_file():
            destination.unlink()
        elif destination.exists():
            shutil.rmtree(destination)
        temporary.rename(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return len(selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root')
    parser.add_argument('--stage', metavar='DESTINATION')
    args = parser.parse_args()
    try:
        count = stage(args.root, args.stage) if args.stage else len(archives(args.root))
    except (OSError, ValueError) as error:
        parser.exit(1, f'[RED] {error}\n')
    print(f'system data: {count} extracted archives')


if __name__ == '__main__':
    main()
