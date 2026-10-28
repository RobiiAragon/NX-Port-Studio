"""The survey sees blocking HLE takeovers as implementations, without changing forced=False."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import nso_syms


class HostHookTests(unittest.TestCase):
    def test_wait_takeovers_are_visible_to_profile_survey(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = Path(tmp) / "host"
            host.mkdir()
            (host / "hle_example.c").write_text(
                'HLE_FORCE_WAIT("guest_wait", "waits", int, wait_impl, int fd) {}\n'
                'HLE_FORCE_BIG("guest_big", "large stack", int, big_impl, void) {}\n'
                'HLE("guest_weak", int, weak_impl, void) {}\n'
            )
            self.assertEqual(nso_syms.host_hooks(str(host)), {"guest_wait", "guest_big", "guest_weak"})
            self.assertEqual(nso_syms.host_hooks(str(host), forced=False), {"guest_weak"})


if __name__ == "__main__":
    unittest.main()
