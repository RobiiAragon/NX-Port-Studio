"""nso_code.text_runs / data_blocks on synthetic bytes: embedded text in the text segment is data, code is not."""
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import nso_code


class TextRuns(unittest.TestCase):
    pem = b'-----BEGIN CERTIFICATE-----\n' + b'MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw\n' * 6 + b'-----END CERTIFICATE-----\n'

    def test_a_pem_after_code_is_one_block_including_its_padded_last_word(self):
        code = struct.pack('<4I', 0xa9bf7bf3, 0x91018013, 0x94000000, 0xd65f03c0)   # stp, add, bl, ret
        img = bytearray(code + self.pem + b'\0' * (-len(self.pem) % 4) + code)
        start, end = len(code), len(code) + (len(self.pem) + 3) & ~3
        self.assertEqual(nso_code.text_runs(img, 0, len(img)), [(start, end)])

    def test_short_strings_and_code_are_not_data(self):
        code = struct.pack('<I', 0xd503201f) * 256   # nop
        self.assertEqual(nso_code.text_runs(bytearray(code), 0, len(code)), [])
        short = bytearray(code + b'hello world, short\0\0' + code)
        self.assertEqual(nso_code.text_runs(short, 0, len(short)), [])

    def test_merge_joins_overlapping_blocks(self):
        self.assertEqual(nso_code.merge([(0x2000, 0x3000), (0x100, 0x200), (0x2800, 0x4000)]), [(0x100, 0x200), (0x2000, 0x4000)])


if __name__ == '__main__': unittest.main()
