"""Stage public iOS service routes and any already-approved local peer profile.

This never enrolls a certificate, contacts a service or reads account credentials.
The shared public exporter remains strict; local approvals use a separate output.
"""
from pathlib import Path
import os
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
import nextendo_local_peers
import nextendo_services


def stage(repository, source, title_id, destination, collection=None):
    destination = Path(destination)
    public, private = destination/'nextendo', destination/'nextendo-private'
    for path in (public, private):
        if path.exists() or path.is_symlink():
            raise FileExistsError('The iOS service profile destination already exists')
    if collection is None:
        collection = Path.home()/'Library/Application Support/NX Port Studio/Nextendo/PeerCertificates'
    # Validate and capture both profiles before copying anything into Gen/dm.
    # A malformed collection must fail the build rather than silently omit a pin.
    with tempfile.TemporaryDirectory(prefix='nextendo-ios-') as folder:
        root = Path(folder).resolve()
        captured = nextendo_services.stage(source, root/'public', title_id)
        approved = nextendo_local_peers.prepare(repository, title_id, captured, collection, root/'private')
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copytree(captured, public)
        public.chmod(0o700)
        for path in public.iterdir(): path.chmod(0o600)
        if approved: shutil.copytree(approved, private)
    return private if approved else None


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', type=Path)
    parser.add_argument('source', type=Path)
    parser.add_argument('title_id')
    parser.add_argument('destination', type=Path)
    parser.add_argument('--peer-collection', type=Path,
                        default=os.environ.get('DM_NEXTENDO_PEER_COLLECTION') or None)
    args = parser.parse_args()
    try:
        result = stage(args.repository, args.source, args.title_id, args.destination, args.peer_collection)
        print('Nextendo iOS profiles: public and approved local peers' if result else 'Nextendo iOS profiles: public only')
    except (OSError, ValueError) as error:
        raise SystemExit('Nextendo iOS profiles could not be prepared: '+str(error)) from None
