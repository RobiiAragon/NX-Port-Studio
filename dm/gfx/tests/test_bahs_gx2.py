"""Recognize positive GX2 metadata without accepting unknown or damaged BAHS as empty NVN."""
import contextlib
import io
import os
from pathlib import Path
import struct
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
os.environ.setdefault('DM_GAME', '0100152000022000')
sys.path.insert(0, str(REPO / 'dm/gfx/tools'))
import shader_split as split


def gx2_archive(kinds=(0, 1), shared=False):
    strings = b'fixture\0'
    data = bytearray(b'BAHS' + struct.pack('<IIIII', 9, 0, 5, 0, len(strings)) + strings)
    array = len(data); records = bytearray(); locations = []; first_program = None
    for kind in kinds:
        minimum, size_offset, mode_offset = {0: (0x134, 0xd0, 0xd8), 1: (0xe8, 0xa4, 0xac), 2: (0xb0, 0x4c, 0x5c)}[kind]
        at = array + 8 + len(records) + 16
        body = bytearray(minimum)
        # A second vertex may reuse the first program through a negative
        # serialized relative pointer; it still belongs to a real record tail.
        program = first_program if shared and first_program is not None and kind == 0 else None
        if program is None:
            body += bytes(-(at + len(body)) % 256); program = at + len(body); body += bytes(8)
            if first_program is None and kind == 0: first_program = program
        struct.pack_into('<Ii', body, size_offset, 8, program - at)
        struct.pack_into('<I', body, mode_offset, 2 if kind == 2 else 1)
        if kind == 2:
            body += bytes(-(at + len(body)) % 256); copy_program = at + len(body); body += bytes(8)
            struct.pack_into('<Ii', body, 0x54, 8, copy_program - at)
        locations.append(at)
        records += struct.pack('<IIII', 16 + len(body), kind, 0, len(body)) + body
    data += struct.pack('<II', 8 + len(records), len(kinds)) + records
    name = b'program\0'; mask = sum(1 << kind for kind in set(kinds))
    program_record = struct.pack('<IIII', 16 + len(name), len(name), mask, 0) + name
    data += struct.pack('<II', 8 + len(program_record), 1) + program_record
    struct.pack_into('<I', data, 8, len(data))
    return data, locations


class Gx2Bahs(unittest.TestCase):
    def test_typed_vertex_pixel_and_geometry_are_foreign(self):
        for kinds in ((0, 1), (0, 1, 2), (0, 1, 0, 1)):
            with self.subTest(kinds=kinds), contextlib.redirect_stdout(io.StringIO()) as log:
                data, _ = gx2_archive(kinds, shared=True)
                self.assertEqual(split.bahs_shaders(data, 'synthetic GX2'), [])
                self.assertIn('GX2', log.getvalue())

    def test_malformed_foreign_candidate_remains_an_error(self):
        for mutation in ('pointer', 'length', 'mode', 'kind', 'program mask', 'truncated', 'NVN marker', 'unknown flags'):
            with self.subTest(mutation=mutation):
                data, locations = gx2_archive((0, 1, 2))
                if mutation == 'pointer': struct.pack_into('<i', data, locations[0] + 0xd4, -0x700000)
                elif mutation == 'length': struct.pack_into('<I', data, locations[1] + 0xa4, len(data))
                elif mutation == 'mode': struct.pack_into('<I', data, locations[0] + 0xd8, 0x1234)
                elif mutation == 'kind': struct.pack_into('<I', data, locations[1] - 12, 7)
                elif mutation == 'program mask': struct.pack_into('<I', data, len(data) - len(b'program\0') - 8, 1)
                elif mutation == 'truncated': data.pop()
                elif mutation == 'NVN marker': data[locations[0]:locations[0] + 4] = split.CTL_MAGIC
                else: struct.pack_into('<I', data, 12, 7)
                with self.assertRaises(SystemExit): split.bahs_shaders(data, 'bad foreign candidate')

    def test_real_nvn_schema_keeps_its_shaders(self):
        sys.path.insert(0, str(REPO / 'dm/tools/fuzz'))
        import fuzz_shader_split
        data = bytearray(fuzz_shader_split.bahs())
        struct.pack_into('<III', data, 4, 9, len(data), 5)
        result = split.bahs_shaders(data, 'synthetic NVN')
        self.assertEqual([row[1] for row in result], ['vs', 'ps'])


if __name__ == '__main__':
    unittest.main()
