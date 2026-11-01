"""Personal Mii CLI/staging, using original synthetic records and no console data."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
import zlib

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "dm/tools"))
import mii_resources


def fixture(height=0):
    raw = bytearray(88)
    raw[:16] = uuid.UUID("12000000-0000-1000-8000-000000000001").bytes
    raw[16:28] = "Test \u732b".encode("utf-16-le")
    raw[0x29] = height
    raw[0x41] = 3
    return bytes(raw)


class PersonalMiis(unittest.TestCase):
    def command(self, *arguments, success=True):
        result = subprocess.run([sys.executable, str(REPO / "scripts/import_miis.py"), *map(str, arguments)],
                                capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def test_cli_persists_original_identity_and_rejects_invalid_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, database = root / "personal.charinfo", root / "shared/library.dmii"
            source.write_bytes(fixture())
            viewed = self.command("inspect", "--source", source)
            self.assertEqual(viewed["schema"], 1)
            self.assertEqual(viewed["entries"], [{"id": "12000000-0000-1000-8000-000000000001", "name": "Test \u732b"}])
            imported = self.command("import", "--source", source, "--database", database)
            self.assertEqual((imported["count"], imported["imported"], imported["updated"], imported["duplicates"]), (1, 1, 0, 0))
            data = database.read_bytes()
            self.assertEqual(data[:12], struct.pack("<4sHHI", b"DMII", 1, 88, 1))
            self.assertEqual(data[16:], fixture())
            self.assertEqual(struct.unpack_from("<I", data, 12)[0], zlib.crc32(data[:12] + data[16:]))
            again = self.command("import", "--source", source, "--database", database)
            self.assertEqual((again["imported"], again["updated"], again["duplicates"]), (0, 0, 1))
            self.assertEqual(self.command("list", "--database", database)["entries"], viewed["entries"])
            source.write_bytes(fixture()[:-1])
            failure = self.command("import", "--source", source, "--database", database, success=False)
            self.assertIn("error", failure)
            self.assertNotIn("Test", json.dumps(failure))
            self.assertEqual(database.read_bytes(), data)

    def test_staging_validates_the_snapshot_and_preserves_previous_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, destination = root / "personal.charinfo", root / "app/dm/mii_database.dmii"
            source.write_bytes(fixture())
            self.assertEqual(mii_resources.stage(source, destination), 1)
            self.assertEqual(destination.read_bytes(), fixture())
            source.write_bytes(b"NFIF" + bytes(4840))
            with self.assertRaises(ValueError):
                mii_resources.stage(source, destination)
            self.assertEqual(destination.read_bytes(), fixture())
            self.assertEqual(list(destination.parent.glob(".mii-stage-*")), [])
            source.unlink()
            source.symlink_to(destination)
            with self.assertRaises(ValueError):
                mii_resources.stage(source, destination)

    def test_ios_preparation_stages_selected_snapshot_and_removes_stale_private_data(self):
        script = (REPO / "dm/ios/tools/build_ipa.sh").read_text()
        start = script.index("rm -f Gen/dm/mii_database.dmii\n")
        stop = script.index("python3 tools/gen_build.py", start)
        fragment = 'set -eu\ndie() { echo "$*" >&2; exit 1; }\n' + script[start:stop]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Gen/dm").mkdir(parents=True)
            source = root / "original.charinfo"
            source.write_bytes(fixture())
            env = dict(os.environ, DM=str(REPO / "dm"), DM_MII_DATABASE_SOURCE=str(source))
            def prepare():
                return subprocess.run(["/bin/bash", "-c", fragment], cwd=root, env=env,
                                      capture_output=True, text=True, timeout=90)
            self.assertEqual(prepare().returncode, 0)
            staged = root / "Gen/dm/mii_database.dmii"
            self.assertEqual(staged.read_bytes(), fixture())
            env.pop("DM_MII_DATABASE_SOURCE")
            self.assertEqual(prepare().returncode, 0)
            self.assertFalse(staged.exists())
            env["DM_MII_DATABASE_SOURCE"] = str(source)
            source.write_bytes(b"invalid")
            result = prepare()
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("original.charinfo", result.stdout + result.stderr)
            self.assertFalse(staged.exists())


if __name__ == "__main__":
    unittest.main()
