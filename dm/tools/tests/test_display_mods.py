"""Native execution of the camera/UI stubs using synthetic memory, no game files."""
import importlib.util
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'dm/tools'))
spec = importlib.util.spec_from_file_location('mk8_display', ROOT / 'dm/games/0100152000022000/patches.py')
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class Context:
    state = 0x20000
    render_scale = 0

    def __init__(self):
        self.code, self.sites, self.puts = [], [], []

    def here(self): return 0x10000 + 4 * len(self.code)
    def emit(self, word): self.code.append(word)
    def site(self, offset, original): self.sites.append((offset, original))
    def put(self, offset, words, reason): self.puts.append((offset, words, reason))


class DisplayModTests(unittest.TestCase):
    def test_registration_and_original_bytes(self):
        self.assertEqual(set(profile.DISPLAY_ASPECT), {'fe941ed5ba14be5d505698da1bbf4fe7'})
        ctx = Context(); profile.display_aspect(ctx)
        self.assertEqual(ctx.sites, [(0x3cb1b4, '2018201e20b100bd'), (0x8c7034, '211c0a94')])
        self.assertEqual([p[0] for p in ctx.puts], [0x3cb1b4, 0x8c7034])
        self.assertEqual(ctx.render_scale, 0)  # neither resolution nor frame-step patches

    @unittest.skipUnless(sys.platform == 'darwin' and platform.machine() == 'arm64', 'native Apple arm64 execution fixture')
    def test_projection_and_hud_execute_with_defaults_and_wide_ratios(self):
        ctx = Context(); profile.display_aspect(ctx)
        # The HUD hook is the destination of the second installed BL.
        callsite, words, _ = ctx.puts[1]
        immediate = words[0] & 0x3ffffff
        if immediate & 0x2000000: immediate -= 0x4000000
        hud = callsite + immediate * 4
        native = Path(__file__).with_name('display_mod_check.c').read_text()
        native = native.replace('CODE_WORDS', ','.join(hex(w) for w in ctx.code)).replace('HUD_OFFSET', hex(hud))
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source, exe = folder / 'fixture.c', folder / 'fixture'
            source.write_text(native)
            compiled = subprocess.run(['xcrun', 'clang', '-O1', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(exe)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('native camera and HUD stubs passed', result.stdout)


if __name__ == '__main__': unittest.main()
