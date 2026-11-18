# SPDX-License-Identifier: GPL-2.0-or-later
import contextlib
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import nand_layout as layout
import tamatama_extractor as tool


class LayoutTests(unittest.TestCase):
    def test_lfi_second_size_field_can_be_smaller_than_read_span(self):
        volume = bytearray(layout.LFI_BYTES)
        volume[:4] = layout.LFI_MAGIC
        volume[0x200:0x20b] = b'FWINFO  BIN'
        struct.pack_into('<5I', volume, 0x20c, 0, 2, 512, 500, 1)
        volume[1024] = 1
        self.assertEqual(layout.lfi_directory(volume)[0]['size_field_2'], 500)
        volume[1024] = 2
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            layout.lfi_directory(volume)

    def test_wrong_ecc_sequence_and_uncorrectable_reads_are_rejected(self):
        header = bytearray(64)
        struct.pack_into('<4s8I', header, 0, b'ECC1', 16, 0, 3, 0, 0, 1024, 3, 0)
        self.assertEqual(tool.checked_sector(header, b'ECC1', 16, 0, 1024, 3, True), 0)
        with self.assertRaisesRegex(ValueError, 'wrong NAND frame'):
            tool.checked_sector(header, b'ECC1', 16, 0, 1024, 4, True)
        struct.pack_into('<I', header, 32, 24)
        with self.assertRaisesRegex(ValueError, 'controller read failure'):
            tool.checked_sector(header, b'ECC1', 16, 0, 1024, 3, True)


class RestorationTests(unittest.TestCase):
    def run_model(self, directory, command, breaks=False):
        transactions = []

        class Device:
            def write(self, data):
                transactions.append(data)

            def bulk(self, size):
                return transactions[-1]

        @contextlib.contextmanager
        def start(*args):
            yield Device(), b'WRP1' + bytes(60), {'port': [1, [2]]}

        def reply(session, magic, page, sector, checksum):
            if magic == b'DRYO' and breaks:
                raise ValueError('bad checksum from device')
            if magic == b'EROK':
                report = tool.read_json(directory / 'receipt.json')
                self.assertTrue(report['dry_run_verified'])
                self.assertTrue(report['write_started'])

        args = SimpleNamespace(plan=None, command=command, write=True, output=directory)
        with patch.object(tool, 'restore_inputs', return_value=(bytes(layout.RAW_BLOCK), None, {'port': [1, [2]]})), \
             patch.object(tool, 'start_loader', start), patch.object(tool, 'expect_state', reply):
            if breaks:
                with self.assertRaisesRegex(ValueError, 'bad checksum'):
                    tool.restore(args)
            else:
                tool.restore(args)
        return [data[:4] for data in transactions], tool.read_json(directory / 'receipt.json')

    def test_dry_run_never_sends_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            sent, result = self.run_model(Path(directory) / 'out', 'dry-run')
        self.assertIn(b'DRY1', sent)
        self.assertNotIn(b'CMIT', sent)
        self.assertTrue(result['dry_run_verified'])
        self.assertFalse(result['write_started'])

    def test_restore_stops_on_bad_dry_run(self):
        with tempfile.TemporaryDirectory() as directory:
            sent, result = self.run_model(Path(directory) / 'out', 'restore-stock-block3', True)
        self.assertNotIn(b'CMIT', sent)
        self.assertFalse(result['write_started'])

    def test_restore_targets_block_three_and_requires_readback(self):
        with tempfile.TemporaryDirectory() as directory:
            sent, result = self.run_model(Path(directory) / 'out', 'restore-stock-block3')
        self.assertEqual(sent.count(b'CMIT'), 1)
        self.assertEqual(result['target'], 3)
        self.assertTrue(result['programmed'])
        self.assertFalse(result['readback_verified'])


if __name__ == '__main__':
    unittest.main()
