"""Stage the shared, portable Nextendo codecs into a per-game iOS project.

No credentials or account state are copied. The optional public OAuth client ID
is build metadata, supplied by the application's registered owner at build time.
"""
from pathlib import Path
import re
import shutil


SHARED_NAMES = ('NextendoAccount.swift', 'NextendoCatalog.swift')
SHARED_DIRECTORY = Path('macOS/NXPortStudio/Sources/PortCore')


def stage_engine(repository, engine):
    """Keep the same two source codecs available in a packaged Studio engine."""
    source = Path(repository) / SHARED_DIRECTORY
    target = Path(engine) / SHARED_DIRECTORY
    target.mkdir(parents=True, exist_ok=True)
    for name in SHARED_NAMES:
        shutil.copyfile(source / name, target / name)


def prepare(repository, generated, client_id=''):
    client_id = client_id.strip()
    if client_id and not re.fullmatch(r'nxc_[A-Za-z0-9_-]{3,128}', client_id):
        raise ValueError('The registered Nextendo application client ID is invalid.')
    source = Path(repository) / SHARED_DIRECTORY
    target = Path(generated) / 'NextendoShared'
    target.mkdir(parents=True, exist_ok=True)
    for name in SHARED_NAMES:
        shutil.copyfile(source / name, target / name)
    return client_id


if __name__ == '__main__':
    import os
    import sys
    try:
        if sys.argv[1] == '--stage-engine':
            stage_engine(sys.argv[2], sys.argv[3])
        else:
            prepare(sys.argv[1], sys.argv[2], os.environ.get('DM_NEXTENDO_CLIENT_ID', ''))
    except (OSError, ValueError) as error:
        # Never print supplied values or any account material.
        print('Nextendo mobile build metadata could not be prepared.', file=sys.stderr)
        raise SystemExit(1) from None
