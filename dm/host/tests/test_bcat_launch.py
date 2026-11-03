"""Run the real launch selector/downloader with original synthetic HTTPS data.

No provider connection, account, Nintendo resource or app is used. The private
runtime copy differs only in its test signing pin and synthetic XML digest.
Each invocation is a NEW process, so a cached launch cannot skip revalidation.
"""
from pathlib import Path
import base64
import hashlib
import io
import json
import os
import shlex
import struct
import subprocess
import tempfile
import time
import zipfile
from datetime import datetime, timezone

REPO = Path(__file__).resolve().parents[3]
SOURCE = REPO / 'dm/host/hle_bcat_apple.m'
PIN = 'xI+atR6VesrCH89ZDZD4t3WQLcYOFEhk5F0HLMzgWk4='
XML = b'<setting><original-fixture/></setting>'


def run(title='0100f8f0000a2000'):
    s3=title=='0100c2500fc20000'
    version='11.3.0' if s3 else '5.5.2'
    with tempfile.TemporaryDirectory(prefix='bcat-launch-') as temp:
        root = Path(temp).resolve()
        crypto = subprocess.check_output([os.environ.get('PYTHON', 'python3'), str(REPO / 'dm/tools/apple_crypto.py'), 'macos'], text=True).strip()
        openssl = os.environ.get('OPENSSL_TOOL', '/opt/homebrew/opt/openssl@4/bin/openssl')
        secret = bytes.fromhex('302e020100300506032b657004220420') + bytes([7]) + bytes(31)
        (root / 'key.der').write_bytes(secret)
        public = subprocess.check_output([openssl, 'pkey', '-inform', 'DER', '-in', str(root / 'key.der'), '-pubout', '-outform', 'DER'])[-32:]
        def signed(enabled=True):
            now = int(time.time())
            def fmt(value):
                return datetime.fromtimestamp(value, timezone.utc).isoformat().replace('+00:00', 'Z')
            payload = json.dumps({'document_type': 'game_catalog', 'schema_version': 1, 'revision': 4,
                                 'issued_at': fmt(now - 60), 'expires_at': fmt(now + 3600),
                                 'games': [{'title_ids': [title], 'enabled': enabled,
                                            'required_capabilities': ['versions.exact.v1'], 'versions': {'policy': 'exact', 'accepted': [version]}}]}, separators=(',', ':')).encode()
            (root / 'payload').write_bytes(payload)
            sig = subprocess.check_output([openssl, 'pkeyutl', '-sign', '-rawin', '-keyform', 'DER', '-inkey', str(root / 'key.der'), '-in', str(root / 'payload')])
            return json.dumps({'key_id': 'catalog-key-1', 'payload': base64.b64encode(payload).decode(), 'signature': base64.b64encode(sig).decode()}).encode()
        (root / 'catalog.json').write_bytes(signed())
        (root / 'invalid.json').write_bytes(signed(False))
        (root / 'static.xml').write_bytes(XML)
        (root / 'dummy.txt').write_bytes(b'0')
        names = ['coopdata/CoopSetting.byaml', 'vsdata/VSSetting_0.byaml', 'vsdata/VSSetting_1.byaml', 'fesdata/Festival.byaml', 'fesdata/HapTexture.bfres', 'fesdata/IconTexture.bfres', 'fesdata/PanelTexture.bfres']
        if s3:
            names=[f'{region}/{name}' for region in ('ap-default','eu-default','jp-default','us-default')
                   for name in ('base.pack.zs.enc','bh.pack.zs.enc','wa.pack.zs.enc','wb.pack.zs.enc','wc.pack.zs.enc','summary.yml')]
        for marker in [1, 2]:
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                for name in names:
                    if s3:
                        # Only a synthetic opaque envelope, not an encrypted game payload.
                        data=(b'FestID: ORIGINAL-1\nFestResourceID: original-001\nFestResourceRevision: abcdef\n'
                              if name.endswith('.yml') else struct.pack('<I',17)+bytes(31)+bytes([marker]))
                    else:
                        data = (b'YB\x02\0' + bytes(27) if name.endswith('.byaml') else b'FRES' + bytes(27)) + bytes([marker])
                    archive.writestr(name, data)
            (root / f'v{marker}.zip').write_bytes(buf.getvalue())
        (root / 'corrupt.zip').write_bytes(b'not a ZIP')
        scope = 'us-default' if s3 else 'vsdata'
        with zipfile.ZipFile(root / 'v1.zip') as archive:
            expected_scope_bytes = sum(f.file_size for f in archive.infolist() if f.filename.startswith(scope + '/'))
        source = SOURCE.read_text()
        old_xml = '8d8d21a93dce2f8eab1659a3bf5cdca10f61df83d50bc0a34784b1629dd215fa'
        assert source.count(PIN) == source.count(old_xml) == 1
        source = source.replace(PIN, base64.b64encode(public).decode()).replace(old_xml, hashlib.sha256(XML).hexdigest())
        runtime = root / 'fixture-runtime.inc'
        runtime.write_text(source)
        binary = root / 'launch'
        # make's sanitizer target passes SAN to its recipes. This fixture builds
        # a fresh, test-keyed runtime, so it must retain those flags as well.
        # Parse argv directly: shell metacharacters are never evaluated here.
        sanitizer_flags = shlex.split(os.environ.get('SAN', ''))
        print('BCAT launch fixture build: ' + ('with inherited SAN flags' if sanitizer_flags else 'default flags'), flush=True)
        subprocess.run(['clang', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-Wno-unused-parameter', '-Wno-deprecated-declarations', '-fobjc-arc', *sanitizer_flags,
                        '-I' + str(REPO / 'dm/host'), '-I' + str(Path(crypto) / 'include'), '-DDM_BCAT_RUNTIME_INCLUDE="' + str(runtime) + '"',
                        str(REPO / 'dm/host/tests/t_bcat_launch.m'), str(Path(crypto) / 'lib/libcrypto.a'), '-lz', '-framework', 'Foundation', '-o', str(binary)], check=True)
        runtime_env = os.environ.copy()
        if sanitizer_flags:
            # UBSan can otherwise print a finding and return zero. Make every
            # instrumented child fail rather than hide its captured stderr.
            for option in ('ASAN_OPTIONS', 'UBSAN_OPTIONS'):
                runtime_env[option] = runtime_env.get(option, '') + ':halt_on_error=1'
        cache = root / 'cache'
        def launch(mode, expected, *, use_cache=cache):
            completed = subprocess.run([str(binary), str(root), mode, str(use_cache),title], capture_output=True, text=True, timeout=20, env=runtime_env)
            assert completed.returncode == 0, (mode, completed.returncode, completed.stderr)
            value = json.loads(completed.stdout)
            assert value['firstCalendarMarker'] == expected, (mode, value, completed.stderr)
            assert not value['acceptedMissingScope'] and not value['acceptedInvalidScope'] and value['scopeExtraRequests'] == (2 if mode == 'scoped-refresh' else 0), (mode, value)
            if mode in ('v1', 'v2', '304', 'noetag', 'scoped-refresh'):
                assert value['hasScopedObserver'] and value['scopeStatus'] == 9 and value['scopeResult'] == 0 and value['scopeBytes'] == expected_scope_bytes, (mode, value)
            else:
                assert not value['hasScopedObserver'] and value['scopeBytes'] == 0, (mode, value)
            if mode != 'offline':
                assert value['catalogRequests'] == (2 if mode == 'scoped-refresh' else 1), (mode, value)
            else:
                assert value['requests'] == 0 and not value['freshAttempt'], value
            print(mode, json.dumps(value, sort_keys=True), flush=True)
            return value
        first = launch('v1', 1)
        assert first['result'] == 0 and first['archiveRequests'] == 1
        again = launch('304', 1)
        assert again['result'] == 0 and again['conditionalRequests'] == 1
        changed = launch('v2', 2)
        assert changed['result'] == 0 and changed['conditionalRequests'] == 1
        scoped = launch('scoped-refresh', 1, use_cache=root / 'scoped-cache')
        assert scoped['asyncScopePassed'] and scoped['archiveRequests'] == 2, scoped
        plain_cache = root / 'cache-without-etag'
        for _ in range(2):
            plain = launch('noetag', 1, use_cache=plain_cache)
            assert plain['result'] == 0 and plain['archiveRequests'] == 1 and plain['conditionalRequests'] == 0
        pointer = (cache / 'current.json').read_bytes()
        inventory = {str(p.relative_to(cache)): hashlib.sha256(p.read_bytes()).hexdigest() for p in cache.rglob('*') if p.is_file()}
        for mode in ['error', 'corrupt', 'invalid', 'timeout']:
            result = launch(mode, 2)
            assert result['result'] != 0
            if mode == 'timeout':
                assert 11 <= result['elapsed'] <= 14, result
                assert result['archiveRequests'] == 1, result
            assert (cache / 'current.json').read_bytes() == pointer
            assert {str(p.relative_to(cache)): hashlib.sha256(p.read_bytes()).hexdigest() for p in cache.rglob('*') if p.is_file()} == inventory
        launch('offline', 2)
        launch('offline', 0, use_cache=root / 'empty-cache')
        process = subprocess.Popen([str(binary), str(root), 'interrupt', str(cache),title], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=runtime_env)
        try:
            deadline = time.monotonic() + 5
            while not (root / 'interrupt-ready').exists():
                assert process.poll() is None and time.monotonic() < deadline
                time.sleep(0.01)
            process.terminate()
            process.communicate(timeout=3)
            assert process.returncode != 0
            assert (cache / 'current.json').read_bytes() == pointer
            assert {str(p.relative_to(cache)): hashlib.sha256(p.read_bytes()).hexdigest() for p in cache.rglob('*') if p.is_file()} == inventory
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=3)
        print(f'BCAT launch refresh {title}: 13 new-process scenarios passed; first open/scoped async refresh/fallback/304/no-ETag/shared deadline/interruption validated')


if __name__ == '__main__':
    run()
    run('0100c2500fc20000')
