#!/usr/bin/env python3
"""Verify a release Studio bundle, without opening it or changing user settings."""
import argparse
from pathlib import Path
import plistlib
import subprocess

DENIED_SUFFIXES = {'.keys', '.keyring', '.nsp', '.nsz', '.xci', '.xcz', '.nca',
                   '.nso', '.nro', '.tik', '.ipa', '.mobileprovision', '.p12', '.pfx', '.pdb'}
DENIED_DIRECTORIES = {'.git', '.build', 'build', '__pycache__', 'system_data', 'exefs', 'romfs', 'saves'}


def verify(bundle):
    root = bundle.resolve(strict=True)
    info = plistlib.loads((root / 'Contents/Info.plist').read_bytes())
    binary = root / 'Contents/MacOS' / info['CFBundleExecutable']
    if info.get('CFBundleIdentifier') != 'org.nxnative.portstudio':
        raise ValueError('Not an NX Port Studio app bundle')
    if any(prefix in binary.read_bytes() for prefix in (b'/Users/', b'/home/')):
        raise ValueError('The release executable contains a local build path')
    engine = root / 'Contents/Resources/nxnative'
    if not (engine / 'ENGINE_REVISION').is_file():
        raise ValueError('The embedded engine has no revision stamp')
    for path in root.rglob('*'):
        if path.is_symlink():
            if not path.resolve(strict=True).is_relative_to(root):
                raise ValueError('A bundle symlink leaves the app')
        elif path.is_dir():
            if path.name.casefold() in DENIED_DIRECTORIES:
                raise ValueError('A private/generated directory entered the app')
        elif path.suffix.casefold() in DENIED_SUFFIXES:
            raise ValueError('A private/game artifact entered the app')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(root)], check=True)
    print(f"Verified Studio {info['CFBundleShortVersionString']} build {info['CFBundleVersion']}; embedded engine and signature valid.")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    verify(parser.parse_args().bundle)
