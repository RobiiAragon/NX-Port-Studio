"""SARC byte order, bounded names and member ranges; synthetic archives only."""
import os
from pathlib import Path
import struct
import sys
import unittest

os.environ.setdefault('DM_GAME', '0100152000022000')
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import shader_split as split


def archive(order='<', entries=(('first.bin', b'123'), ('second.bin', b'abcd'))):
    names = bytearray(); table = bytearray(); payload = bytearray()
    for name, value in entries:
        attr = 0 if name is None else 0x1000000 | len(names) // 4
        if name is not None:
            names += name.encode() + b'\0'; names += bytes(-len(names) % 4)
        table += struct.pack(order + 'IIII', 0, attr, len(payload), len(payload) + len(value))
        payload += value
    doff = 0x14 + 12 + len(table) + 8 + len(names)
    return bytearray(b'SARC' + struct.pack(order + 'HHIIHH', 0x14, 0xfeff, doff + len(payload), doff, 0x100, 0) +
                     b'SFAT' + struct.pack(order + 'HHI', 12, len(entries), 101) + table +
                     b'SFNT' + struct.pack(order + 'HH', 8, 0) + names + payload)


class Sarc(unittest.TestCase):
    def test_both_orders_and_anonymous_members(self):
        values = [('first.bin', b'123'), ('a/b.bin', b'abcd'), (None, b'')]
        for order in ('<', '>'):
            with self.subTest(order=order):
                self.assertEqual(list(split.sarc_members(archive(order, values))), [('first.bin', b'123'), ('a/b.bin', b'abcd'), ('#2', b'')])

    def test_nested_archive_keeps_member_bytes_and_names(self):
        inner = archive('<', [('inside.bin', b'payload')])
        outer = archive('>', [('inner.sarc', inner)])
        name, data = next(split.sarc_members(outer))
        self.assertEqual(name, 'inner.sarc')
        self.assertEqual(list(split.sarc_members(data)), [('inside.bin', b'payload')])

    def test_corrupt_metadata_fails_in_both_orders(self):
        for order in ('<', '>'):
            mutations = {
                'BOM': (6, b'\0\0'),
                'header size': (4, struct.pack(order + 'H', 0x1400)),
                'declared size': (8, struct.pack(order + 'I', 0x100000)),
                'data before table': (12, struct.pack(order + 'I', 0x20)),
                'SFAT magic': (0x14, b'BAD!'),
                'SFAT length': (0x18, struct.pack(order + 'H', 16)),
                'entry count': (0x1a, struct.pack(order + 'H', 0x7fff)),
                'name offset': (0x24, struct.pack(order + 'I', 0x1ffffff)),
                'member end': (0x2c, struct.pack(order + 'I', 0x100000)),
                'SFNT magic': (0x40, b'BAD!'),
            }
            for label, (offset, value) in mutations.items():
                with self.subTest(order=order, mutation=label):
                    data = archive(order); data[offset:offset + len(value)] = value
                    with self.assertRaises(SystemExit): list(split.sarc_members(data, 'fixture'))

    def test_unterminated_name_cannot_run_into_payload(self):
        for order in ('<', '>'):
            data = archive(order, [('name', b'\0payload')])
            doff = struct.unpack_from(order + 'I', data, 12)[0]
            data[0x38:doff] = b'x' * (doff - 0x38)
            with self.assertRaises(SystemExit): list(split.sarc_members(data, 'fixture'))

    def test_truncated_header_is_a_named_failure(self):
        data = archive()
        for end in range(20):
            with self.subTest(end=end), self.assertRaises(SystemExit) as error:
                list(split.sarc_members(data[:end], 'truncated fixture'))
            self.assertIn('truncated fixture', str(error.exception))


if __name__ == '__main__':
    unittest.main()
