#!/usr/bin/env python3
"""Run asset-free fixtures and preserve useful public CI failure annotations."""
import argparse
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=("discovery", "relay"))
    options = parser.parse_args()
    commands = {
        "discovery": ["make", "-C", "dm/host/tests", "net-discovery", "net-discovery-sanitize"],
        "relay": ["make", "-C", "dm/net", "test", "test-sanitize"],
    }
    result = subprocess.run(commands[options.suite], cwd=Path(__file__).resolve().parents[2],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(result.stdout, end="", flush=True)
    if result.returncode and os.environ.get("GITHUB_ACTIONS") == "true":
        # These fixtures contain synthetic data only. Escape workflow-command
        # syntax so a diagnostic remains one annotation, including multiline errors.
        detail = f"{options.suite} fixtures exited {result.returncode}\n" + "\n".join(result.stdout.splitlines()[-30:])
        escaped = detail.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error title=Network fixture failure::{escaped}", flush=True)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
