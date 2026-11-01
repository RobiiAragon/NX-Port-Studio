#!/usr/bin/env python3
"""Import personal Miis using the runtime's canonical C validator.

Structured stdout contains private names/IDs for the calling interface. Do not
copy that output into public build logs. No game, firmware, keys or SDK required.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

ERRORS = {
    -1: ("invalid", "Invalid Mii fields, identity, duplicate IDs, count or file size."),
    -2: ("checksum", "The Mii checksum does not match its data."),
    -3: ("unsupported", "Unsupported Mii format/version. Use CharInfo, StoreData or decrypted NFDB."),
    -4: ("full", "The personal Mii library cannot contain more than 100 records."),
    -5: ("io", "The Mii file could not be read or replaced."),
    -6: ("not_found", "The Mii source file was not found."),
}


def run(args):
    """Compile only the small, SDK-free C importer; remove all build artifacts."""
    repo = Path(__file__).resolve().parents[1]
    compiler = shutil.which("clang") or shutil.which("cc")
    if not compiler:
        return {"schema": 1, "error": {"code": "toolchain", "message": "Install the Xcode command line tools to import Miis."}}
    with tempfile.TemporaryDirectory(prefix="nxport-mii-") as directory:
        tool = Path(directory) / "mii-import"
        built = subprocess.run([compiler, "-std=gnu11", "-O1", "-Wall", "-Wextra", "-Werror", "-o", str(tool),
                                str(repo / "dm/tools/mii_import.c"), str(repo / "dm/host/hle_mii_database.c")],
                               capture_output=True, text=True, timeout=60)
        if built.returncode:
            # Compiler diagnostics can contain private checkout paths. Keep the
            # UI contract structured and never mix them with names or records.
            return {"schema": 1, "error": {"code": "toolchain", "message": "The Mii importer could not be compiled."}}
        command = [str(tool), args.command]
        command += [str(args.source)] if args.command == "inspect" else [str(args.database)]
        if args.command == "import":
            command.append(str(args.source))
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        data = json.loads(result.stdout)
    if data["code"]:
        code, message = ERRORS.get(data["code"], ERRORS[-5])
        return {"schema": 1, "error": {"code": code, "message": message}}
    entries = []
    for value in data["records"]:
        raw = bytes.fromhex(value)
        entries.append({"id": str(uuid.UUID(bytes=raw[:16])), "name": raw[16:38].decode("utf-16-le").split("\0", 1)[0]})
    return {"schema": 1, "count": len(entries), "imported": data["added"], "updated": data["replaced"],
            "duplicates": data["unchanged"], "entries": entries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("inspect").add_argument("--source", type=Path, required=True)
    commands.add_parser("list").add_argument("--database", type=Path, required=True)
    importing = commands.add_parser("import")
    importing.add_argument("--database", type=Path, required=True)
    importing.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = run(args)
    except (OSError, ValueError, subprocess.SubprocessError):
        result = {"schema": 1, "error": {"code": "io", "message": "The Mii importer could not complete the operation."}}
    print(json.dumps(result, ensure_ascii=True))
    return 1 if "error" in result else 0


if __name__ == "__main__":
    sys.exit(main())
