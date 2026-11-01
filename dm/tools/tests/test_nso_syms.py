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

    def test_network_macro_hooks_keep_their_takeover_kind(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = Path(tmp) / "host"
            host.mkdir()
            (host / "hle_network.c").write_text(
                '#define AGAIN(symbol, impl, ...) SKW(symbol, impl, __VA_ARGS__)\n'
                '#define SKF(symbol, impl, ...) HLE_FORCE(symbol, "socket", int, impl, __VA_ARGS__)\n'
                '#define SKW(symbol, impl, ...) HLE_FORCE_WAIT(symbol, "wait", int, impl, __VA_ARGS__)\n'
                '#define CONTINUED(symbol, impl, ...) \\\n    SKW(symbol, impl, __VA_ARGS__)\n'
                '#define WEAK(symbol, impl, ...) HLE(symbol, int, impl, __VA_ARGS__)\n'
                'SKF("guest_socket", socket_impl, int family) {}\n'
                'SKW("guest_poll", poll_impl, int fd) {}\n'
                'AGAIN("guest_nested_wait", wait_impl, int fd) {}\n'
                'CONTINUED("guest_continued_wait", wait_impl, int fd) {}\n'
                'WEAK("guest_weak", weak_impl, void) {}\n'
                '#define OTHER(symbol, impl) ordinary_call(symbol, impl)\n'
                'OTHER("not_a_hook", ordinary_impl)\n'
                '#define REVERSED(impl, symbol) HLE_FORCE(symbol, "not first", int, impl, void)\n'
                'REVERSED("also_not_a_hook", "actual_symbol")\n'
            )
            self.assertEqual(nso_syms.host_hooks(str(host)),
                             {"guest_socket", "guest_poll", "guest_nested_wait", "guest_continued_wait", "guest_weak"})
            self.assertEqual(nso_syms.host_hooks(str(host), forced=False), {"guest_weak"})


if __name__ == "__main__":
    unittest.main()
