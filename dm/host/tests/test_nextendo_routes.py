#!/usr/bin/env python3
"""Exercise immutable route configuration and real scoped TLS using ephemeral fixtures."""
import argparse
import contextlib
import hashlib
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
import threading

from test_ssl_transport import command


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    executable = parser.parse_args().executable.resolve()
    with tempfile.TemporaryDirectory(prefix="nxnative-routes-") as folder:
        root = Path(folder)
        os.chmod(root, 0o700)
        command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "1", "-subj", "/CN=nxnative ephemeral route test CA"], folder)
        command(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key", "-out", "server.csr", "-subj", "/CN=localhost"], folder)
        (root / "extensions.cnf").write_text("subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
        command(["openssl", "x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "server.pem", "-days", "1", "-extfile", "extensions.cnf"], folder)
        command(["openssl", "x509", "-in", "ca.pem", "-outform", "der", "-out", "ca.der"], folder)
        for path in root.iterdir():
            path.chmod(0o600)
        digest = hashlib.sha256((root / "ca.der").read_bytes()).hexdigest()
        header = "NXNEXTENDO_ROUTES_1\n"
        line = f"api.console.invalid\t127.0.0.1\tlocalhost\tca.der\t{digest}\n"
        text = header + line + f"wrong.console.invalid\t127.0.0.1\twrong.invalid\tca.der\t{digest}\n" + "nncs2-lp1.n.n.srv.nintendo.net\t127.0.0.1\t-\t-\t-\n"
        config = root / "routes.tsv"
        config.write_text(text)
        config.chmod(0o600)
        cases = [("-", 1), (str(root / "missing.tsv"), 1), (str(config), 0)]

        def add(name, value, status, mode=0o600):
            path = root / name
            path.write_bytes(value if isinstance(value, bytes) else value.encode())
            path.chmod(mode)
            cases.append((str(path), status))

        add("empty.tsv", header, 2)
        add("bad-header.tsv", "NXNEXTENDO_ROUTES_2\n" + line, 2)
        add("duplicate.tsv", text + line.replace("api.console.invalid", "API.CONSOLE.INVALID."), 2)
        add("wildcard.tsv", header + line.replace("api.console.invalid", "*.console.invalid"), 2)
        add("multicast.tsv", header + line.replace("127.0.0.1", "224.1.2.3"), 2)
        add("bad-address.tsv", header + line.replace("127.0.0.1", "localhost"), 2)
        add("numeric-host.tsv", header + line.replace("api.console.invalid", "127.0.0.1."), 2)
        add("bad-peer.tsv", header + line.replace("localhost", "https://localhost"), 2)
        add("not-tls.tsv", header + line.replace("localhost", "-"), 2)
        add("bad-hash.tsv", text.replace(digest, "0" * 64), 5)
        add("missing-ca.tsv", text.replace("ca.der", "missing.der"), 5)
        add("traversal-ca.tsv", text.replace("ca.der", "../ca.der"), 5)
        add("writable.tsv", text, 3, 0o666)
        add("nul.tsv", text.encode() + b"\x00", 2)
        add("huge.tsv", header + "#" * 65536, 4)
        add("many.tsv", header + "".join(line.replace("api.console.invalid", f"api{i}.console.invalid") for i in range(129)), 4)
        (root / "not.der").write_bytes(b"not a certificate")
        bad_digest = hashlib.sha256((root / "not.der").read_bytes()).hexdigest()
        add("invalid-der.tsv", (header + line).replace("ca.der", "not.der").replace(digest, bad_digest), 5)
        (root / "alias.der").symlink_to(root / "ca.der")
        add("symlink-ca.tsv", text.replace("ca.der", "alias.der"), 5)
        alias = root / "alias.tsv"
        alias.symlink_to(config)
        cases.append((str(alias), 3))

        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.minimum_version = tls.maximum_version = ssl.TLSVersion.TLSv1_2
        tls.load_cert_chain(root / "server.pem", root / "server.key")
        names = []
        tls.set_servername_callback(lambda connection, name, context: names.append(name))
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(4)
        listener.settimeout(0.1)
        stop = threading.Event()

        def serve():
            while not stop.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                with connection, contextlib.suppress(OSError, ssl.SSLError):
                    connection.settimeout(3)
                    with tls.wrap_socket(connection, server_side=True) as stream:
                        stream.sendall(b"HELLO")
                        if stream.recv(4) == b"PING":
                            stream.sendall(b"PONG")

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        total = 0
        try:
            for path, status in cases:
                args = [str(executable), path, str(status)]
                if path == str(config):
                    args.append(str(listener.getsockname()[1]))
                result = subprocess.run(args, text=True, capture_output=True, timeout=15)
                if result.returncode:
                    raise AssertionError(f"route case {Path(path).name}: {result.stdout}\n{result.stderr}")
                match = re.search(r"routes: (\d+) checks, 0 failures", result.stdout)
                if not match:
                    raise AssertionError(result.stdout)
                total += int(match[1])
            if "localhost" not in names or "wrong.invalid" not in names:
                raise AssertionError("actual TLS did not observe both configured SNI names")
            print(f"Nextendo route policy: {len(cases)} configurations, {total} checks, 0 failures; actual scoped-CA TLS/SNI verified, no user credentials")
        finally:
            stop.set()
            listener.close()
            thread.join(1)


if __name__ == "__main__":
    main()
