#!/usr/bin/env python3
"""Validate/stage a private Mii snapshot without putting names into build logs."""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


def _inspect(source):
    tool = Path(__file__).resolve().parents[2] / "scripts/import_miis.py"
    result = subprocess.run([sys.executable, str(tool), "inspect", "--source", str(source)],
                            capture_output=True, text=True, timeout=90)
    data = json.loads(result.stdout)
    if result.returncode or "error" in data:
        raise ValueError(data.get("error", {}).get("message", "The personal Mii snapshot is invalid."))
    return data["count"]


def inspect(source):
    try:
        return _inspect(source)
    except (OSError, ValueError, subprocess.SubprocessError):
        raise ValueError("The personal Mii snapshot could not be validated.") from None


def _stage(source, destination):
    """Validate the exact bounded snapshot copied, not an earlier path lookup."""
    destination = Path(destination)
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 8816:
            raise ValueError("The personal Mii snapshot has an invalid type or size.")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(8817)
        if len(data) != info.st_size:
            raise ValueError("The personal Mii snapshot changed while reading it.")
    finally:
        os.close(fd)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".mii-stage-", delete=False) as temp:
        candidate = Path(temp.name)
        temp.write(data)
    try:
        count = inspect(candidate)
        if not count:
            raise ValueError("The selected personal Mii snapshot contains no records.")
        candidate.replace(destination)
        return count
    finally:
        candidate.unlink(missing_ok=True)


def stage(source, destination):
    try:
        return _stage(source, destination)
    except (OSError, ValueError, subprocess.SubprocessError):
        # A source filename may itself be a private Mii nickname. Do not let
        # OS/compiler exceptions print it into a retained game's build log.
        raise ValueError("The personal Mii snapshot could not be staged.") from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--stage", type=Path)
    args = parser.parse_args()
    try:
        count = stage(args.source, args.stage) if args.stage else inspect(args.source)
    except (OSError, ValueError, subprocess.SubprocessError):
        print("[RED] personal Mii snapshot unavailable: validation or file access failed.", file=sys.stderr)
        return 1
    print(f"Personal Mii snapshot: {count} records validated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
