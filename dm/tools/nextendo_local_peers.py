"""Prepare a private profile from explicitly approved local service certificates.

This never enrolls peers, contacts a server, changes system trust or stages an
iOS export. The public profile remains the sole source of service addresses.
"""
from pathlib import Path
import ctypes
import hashlib
import ipaddress
import json
import os
import re
import secrets
import ssl
import stat
import subprocess
import sys
import tempfile
import time

import nextendo_services

INDEX_MAX = 256 * 1024
CERT_MAX = 65536
CERT_TOTAL_MAX = 1024 * 1024
ROUTE_MAX = 128


def _owned(info, directory=False, ancestor=False):
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    # A root-owned sticky ancestor (e.g. /tmp on Linux) cannot replace an
    # already-owned protected child. The collection/output directory itself
    # must still reject every group/other-write bit.
    sticky_ancestor = directory and ancestor and info.st_uid == 0 and info.st_mode & stat.S_ISVTX
    if not kind(info.st_mode) or info.st_uid not in (0, os.geteuid()) or (info.st_mode & 0o022 and not sticky_ancestor):
        raise ValueError('A local peer collection path has unsafe ownership or permissions')


def _directory(path):
    """Open every component without following symlinks; keep subsequent reads relative."""
    path = Path(os.path.abspath(path))
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        _owned(os.fstat(fd), True, len(path.parts) > 1)
        for index, part in enumerate(path.parts[1:], 1):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = child
            _owned(os.fstat(fd), True, index < len(path.parts) - 1)
        return fd
    except BaseException:
        os.close(fd); raise


def _read(directory, name, limit):
    fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=directory)
    try:
        before = os.fstat(fd); _owned(before)
        if not 0 < before.st_size <= limit:
            raise ValueError('A local peer collection file exceeds its bounds')
        data = bytearray()
        while len(data) <= limit:
            part = os.read(fd, min(65536, limit + 1 - len(data)))
            if not part: break
            data.extend(part)
        after = os.fstat(fd)
        if len(data) != before.st_size or len(data) > limit or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError('A local peer collection file changed while reading')
        return bytes(data)
    finally:
        os.close(fd)


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value: raise ValueError('Duplicate local peer collection field')
        value[key] = item
    return value


def _title(value):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-fA-F]{16}', value) or not int(value, 16):
        raise ValueError('Invalid local peer title identity')
    return value.lower()


def _host(value):
    if not isinstance(value, str): raise ValueError('Invalid exact local service hostname')
    host = value.lower().removesuffix('.')
    if not 0 < len(host) <= 253 or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in host.split('.')):
        raise ValueError('Invalid exact local service hostname')
    try: ipaddress.ip_address(host)
    except ValueError: return host
    raise ValueError('A local service identity must be a DNS hostname')


def _score(kind, pattern, host):
    """hle_nextendo_routes.c match_score: exact > label > DNS-boundary suffix."""
    if kind == 'exact': return 100000 + len(pattern) if pattern == host else 0
    if kind == 'suffix': return len(pattern) if host == pattern or host.endswith('.' + pattern) else 0
    if kind == 'label':
        prefix, suffix = pattern.split('*')
        if len(host) < len(prefix) + len(suffix) or not host.startswith(prefix) or not host.endswith(suffix): return 0
        middle = host[len(prefix):len(host) - len(suffix) if suffix else len(host)]
        return 10000 + len(pattern) if '.' not in middle else 0
    raise ValueError('Unsupported public route kind')


def _effective(rows, host):
    best, score = None, 0
    for row in rows:
        value = _score(row[0], row[1], host)
        if value > score: best, score = row, value
    if best is None or best[3] == '-': raise ValueError('Approved peer has no public TLS service route')
    if best[3] not in ('@host', host): raise ValueError('Approved peer conflicts with the public TLS identity')
    return best[2]


def _certificate(data):
    # Require a single DER SEQUENCE, not a valid certificate followed by junk.
    if len(data) < 4 or data[0] != 0x30: raise ValueError('Invalid approved DER certificate')
    n = data[1]; offset = 2
    if n & 128:
        count = n & 127
        if not 1 <= count <= 3 or len(data) < 2 + count or data[2] == 0:
            raise ValueError('Invalid approved DER certificate length')
        n = int.from_bytes(data[2:2 + count], 'big'); offset += count
        if n < 128: raise ValueError('Noncanonical approved DER certificate length')
    if offset + n != len(data): raise ValueError('Invalid approved DER certificate bounds')
    # Parse structure and current validity. Runtime still checks the exact leaf, validity,
    # purpose, key/signature strength and possession on the encrypted connection.
    try:
        result = subprocess.run(['openssl', 'x509', '-inform', 'DER', '-noout', '-dates'], input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError('Approved DER certificate could not be parsed') from error
    try:
        dates = dict(line.split('=', 1) for line in result.stdout.decode('ascii').splitlines())
        if set(dates) != {'notBefore', 'notAfter'}: raise ValueError('Unexpected certificate validity fields')
        before, after = (ssl.cert_time_to_seconds(dates[key]) for key in ('notBefore', 'notAfter'))
    except (ValueError, UnicodeError) as error:
        raise ValueError('Approved DER certificate validity could not be parsed') from error
    if not before <= time.time() <= after: raise ValueError('Approved DER certificate is not currently valid')


def _selected(directory, title):
    index = _read(directory, 'index.json', INDEX_MAX)
    try: value = json.loads(index, object_pairs_hook=_unique_object)
    except (UnicodeError, RecursionError) as error: raise ValueError('Invalid local peer collection JSON') from error
    if not isinstance(value, dict) or type(value.get('formatVersion')) is not int or value['formatVersion'] != 1:
        raise ValueError('Unsupported local peer collection format')
    entries = value.get('certificates')
    if not isinstance(entries, dict) or len(entries) > 256: raise ValueError('Invalid local peer certificate inventory')
    selected = {}
    bindings_count = 0
    for digest, entry in entries.items():
        if not re.fullmatch('[0-9a-f]{64}', digest) or not isinstance(entry, dict): raise ValueError('Invalid local peer certificate entry')
        if entry.get('role') != 'approved-service-leaf': continue
        approval, bindings = entry.get('approval'), entry.get('bindings')
        if not isinstance(approval, str) or not approval.strip() or len(approval) > 1024 or any(ord(c) < 32 or ord(c) == 127 for c in approval):
            raise ValueError('A local service certificate needs explicit approval')
        if entry.get('file') != digest + '.der' or not isinstance(bindings, list): raise ValueError('Invalid approved certificate binding inventory')
        bindings_count += len(bindings)
        if bindings_count > 1024: raise ValueError('Too many approved service bindings')
        for binding in bindings:
            if not isinstance(binding, dict): raise ValueError('Invalid approved service binding')
            bound_title, host = _title(binding.get('titleID')), _host(binding.get('host'))
            try:
                if not isinstance(binding.get('ip'), str): raise ValueError('Expected an IPv4 string')
                ipaddress.IPv4Address(binding['ip'])
            except (KeyError, ValueError, TypeError) as error: raise ValueError('Invalid historical service address') from error
            if bound_title != title: continue
            if host in selected and selected[host]['sha256'] != digest: raise ValueError('Ambiguous approved certificates for one service')
            selected[host] = {'sha256':digest, 'approvalSHA256':hashlib.sha256(approval.encode()).hexdigest()}
    certificates = {}
    for entry in selected.values():
        digest = entry['sha256']
        if digest in certificates: continue
        data = _read(directory, digest + '.der', CERT_MAX)
        if hashlib.sha256(data).hexdigest() != digest: raise ValueError('Approved service certificate integrity failed')
        _certificate(data); certificates[digest] = data
    if sum(map(len, certificates.values())) > CERT_TOTAL_MAX: raise ValueError('Approved service certificates exceed their bounds')
    return selected, certificates, hashlib.sha256(index).hexdigest()


def _publish(parent, temporary, name):
    # An exclusive directory rename is atomic and cannot replace an existing
    # profile, including an empty directory created after the initial check.
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin': function, flags = library.renameatx_np, 4  # RENAME_EXCL
    elif sys.platform.startswith('linux'): function, flags = library.renameat2, 1  # RENAME_NOREPLACE
    else: raise ValueError('Exclusive local profile publication is unsupported on this platform')
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(parent, os.fsencode(temporary), parent, os.fsencode(name), flags):
        error = ctypes.get_errno(); raise OSError(error, os.strerror(error))


def prepare(repository, title_id, public_profile, collection, destination):
    """Return a new private profile, or None when no local approvals apply.

    collection names a private directory containing index.json and SHA.der files.
    Existing destinations fail without replacement. An approved exact TLS route
    is promoted only in the private result, at the same host and public address.
    Historical binding IPs never select or override the current public address.
    """
    title = _title(title_id)
    if collection is None: return None
    try: directory = _directory(collection)
    except FileNotFoundError: return None
    try: selected, certificates, index_digest = _selected(directory, title)
    finally: os.close(directory)
    if not selected: return None
    # stage remains the strict public exporter: a private result is deliberately
    # not acceptable as an input to it or to this helper on a later invocation.
    with tempfile.TemporaryDirectory(prefix='nextendo-public-') as folder:
        staged = nextendo_services.stage(public_profile, Path(folder) / 'profile', title)
        files = {path.name:path.read_bytes() for path in staged.iterdir()}
    manifest = json.loads(files['manifest.json'])
    value = nextendo_services.contract(repository)
    if set(manifest) != {'formatVersion', 'titleID', 'protocol', 'identity', 'routeCount', 'files'} or set(manifest['files']) != {'routes.tsv', 'provider-ca.der'}:
        raise ValueError('Unexpected public profile manifest fields')
    if manifest.get('protocol') not in (None, 'nex', 'npln', *value.get('families', {})):
        raise ValueError('Unknown public service protocol')
    if files['routes.tsv'] != nextendo_services.rules(value, title, manifest.get('protocol')).encode() or hashlib.sha256(files['provider-ca.der']).hexdigest() != value['provider']['caSHA256']:
        raise ValueError('Public profile differs from the requested repository contract')
    base_routes = files['routes.tsv']; rows = [line.split('\t') for line in base_routes.decode().splitlines()[1:]]
    if type(manifest['routeCount']) is not int or manifest['routeCount'] != len(rows): raise ValueError('Invalid public service route count')
    private_rows = [row[:] for row in rows]
    additions, addresses, peers, promoted = [], {}, [], []
    for host, entry in sorted(selected.items()):
        address = _effective(rows, host); digest = entry['sha256']
        if address in addresses and addresses[address] != (host, digest): raise ValueError('Ambiguous logical service identities for one public address')
        addresses[address] = host, digest
        filename = digest + '.der'; files[filename] = certificates[digest]
        pin = ['pinned-exact', host, address, host, filename, digest]
        exact = next((i for i, row in enumerate(rows) if row[0] == 'exact' and row[1] == host), None)
        if exact is None: additions.append('\t'.join(pin))
        else:
            # The runtime deliberately rejects duplicate exact host identities.
            # The public source stays unchanged; only this approved private row
            # changes its verification policy, never its destination or scope.
            private_rows[exact] = pin; promoted.append(host)
        additions.append('\t'.join(['pinned-address', address, address, host, filename, digest]))
        peers.append({'host':host, 'address':address, **entry})
    if len(rows) + len(additions) > ROUTE_MAX: raise ValueError('Private service profile has too many routes')
    total_certificates = sum(len(files[row[4]]) for row in rows if row[4] != '-') + 2 * sum(len(certificates[entry['sha256']]) for entry in selected.values())
    if total_certificates > CERT_TOTAL_MAX: raise ValueError('Private service profile exceeds runtime certificate bounds')
    files['routes.tsv'] = ('NXNEXTENDO_ROUTES_2\n' + '\n'.join('\t'.join(row) for row in private_rows) + '\n' + '\n'.join(additions) + '\n').encode()
    if len(files['routes.tsv']) > 65536: raise ValueError('Private service profile exceeds route bounds')
    manifest['routeCount'] = len(rows) + len(additions)
    manifest['publicProfile'] = {'manifestSHA256':hashlib.sha256(files['manifest.json']).hexdigest(), 'files':dict(manifest['files'])}
    manifest['localPeers'] = {'formatVersion':1, 'collectionSHA256':index_digest, 'bindings':peers}
    if promoted: manifest['localPeers']['promotedExactHosts'] = promoted
    manifest['files'] = {name:hashlib.sha256(data).hexdigest() for name, data in files.items() if name != 'manifest.json'}
    files['manifest.json'] = (json.dumps(manifest, sort_keys=True) + '\n').encode()
    if len(files['manifest.json']) > 65536: raise ValueError('Private service manifest exceeds its bounds')
    destination = Path(os.path.abspath(destination)); parent = _directory(destination.parent)
    temporary = '.nextendo-peers-' + secrets.token_hex(12)
    created = False
    try:
        try: os.stat(destination.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError: pass
        else: raise FileExistsError('A local service profile destination already exists')
        os.mkdir(temporary, mode=0o700, dir_fd=parent)
        created = True
        output = os.open(temporary, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent)
        published = False
        try:
            for name, data in files.items():
                fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600, dir_fd=output)
                with os.fdopen(fd, 'wb') as stream: stream.write(data); stream.flush(); os.fsync(stream.fileno())
            os.fsync(output)
            _publish(parent, temporary, destination.name)
            published = True
        finally:
            if not published:
                for name in files:
                    try: os.unlink(name, dir_fd=output)
                    except FileNotFoundError: pass
            os.close(output)
        os.fsync(parent)
    finally:
        if created:
            try: os.rmdir(temporary, dir_fd=parent)
            except FileNotFoundError: pass
        os.close(parent)
    return destination
