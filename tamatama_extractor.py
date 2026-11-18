#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Read Crystal701 NAND and check a bounded restore of stock boot block 3."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import sys

from nand_layout import (BLOCK, BOOT_BLOCKS, LFI_BYTES, LFI_MAGIC, LFI_PAIRS, PAGE,
                         PAGES, RAW_PAGE, SPARE, canonical_stock, digest,
                         interleave_lfi, lfi_directory, verify_boot, verify_stock,
                         word_sum)

HERE = Path(__file__).resolve().parent
UPSTREAM = '91c8f4709c5d36f916baa2109900df6b95dc396f'
TARGET = 3
PROGRAM_PAGES = 128
SECTORS = (1024, 1024, 1024, 1024, SPARE)
LFI_BLOCKS = tuple(block for pair in LFI_PAIRS for block in pair)
LOADERS = {
    'boot': ('nand_boot4mb', 'nand_boot4mb', 2560,
             '4a45ec852481d1ab104d3cffbddd0e695fdfbf7dc53ce5f144b43fc540082985'),
    'raw': ('raw_fast', 'raw_full', 2560,
            '7d9a608adc948cd42a3d54de6ba868cb834e72934bd0dc6b12352ea467f98c81'),
    'lfi': ('ecc_firmware', 'raw_full', 2560,
            'b94a69529245b7ea58a8bdc0c2bdac2b20b8035e51fc48edbc8fc50274d296f1'),
    'verify': ('verify_stock_block', 'raw_full', 2560,
               '8abdb521da3f1be836476ea8b3a77d9af1203dec8a85b9f4749a430abe167fe1'),
    'restore': ('stock_rewrite', 'stock_rewrite', 3072,
                '09b034a918e76b9c6755dac57181d387574870e169c0943ed7ddc2051d1ff476'),
}


def new_dir(path):
    path.mkdir(parents=True, exist_ok=False)
    return path.resolve()


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8'))


def save_json(path, value):
    temp = path.with_suffix('.tmp')
    with temp.open('w', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temp.replace(path)


def get_upstream(checkout):
    path = checkout.resolve(strict=True)
    def git(*argv):
        return subprocess.check_output(['git', '-C', str(path), *argv], text=True).strip()
    if git('rev-parse', 'HEAD') != UPSTREAM or git('status', '--porcelain', '--untracked-files=all'):
        raise ValueError(f'use a clean actions-adfu-tool checkout at {UPSTREAM}')
    sys.path.insert(0, str(path))
    from adfu_tool import codec
    if not Path(codec.__file__).resolve().is_relative_to(path):
        raise ValueError('loaded ADFU codec is outside the pinned checkout')
    return codec


def run_build(stage, argv):
    if os.name == 'nt':
        distro = os.environ.get('TAMATAMA_WSL_DISTRO', 'Ubuntu')
        path = subprocess.check_output(['wsl', '-d', distro, '--', 'wslpath', '-a', stage.as_posix()],
                                       text=True).strip()
        subprocess.run(['wsl', '-d', distro, '--', 'bash', '-c',
                        'cd ' + shlex.quote(path) + ' && ' + shlex.join(argv)], check=True)
    else:
        subprocess.run(argv, cwd=stage, check=True)


def build_loaders(args):
    codec = get_upstream(args.adfu_checkout)
    from adfu_tool.protocol import LOADER_IDENTITY

    out = new_dir(args.output)
    lines = []
    for word, in struct.iter_unpack('<I', LOADER_IDENTITY):
        lines += [f'lui $t0, 0x{word >> 16:04x}', f'ori $t0, $t0, 0x{word & 0xffff:04x}',
                  'sw $t0, 0x88($t2)']
    (out / 'identity.inc').write_text('\n'.join(lines) + '\n', encoding='ascii')
    records = {}
    for name, (source, linker, size, expected_hash) in LOADERS.items():
        assembly = (HERE / f'{source}.S').read_text(encoding='utf-8')
        if name == 'raw':
            # Bound the historical streaming reader to exactly four boot blocks.
            line = 'lui $s2, 0x0010              /* end page, exclusive: 1,048,576 */'
            if assembly.count(line) != 1:
                raise ValueError('raw reader bound does not match the reviewed source')
            assembly = assembly.replace(line, 'ori $s2, $zero, 1024')
        (out / f'{name}.S').write_text(assembly, encoding='utf-8')
        (out / 'loader.ld').write_bytes((HERE / f'{linker}.ld').read_bytes())
        run_build(out, ['mipsel-linux-gnu-as', '-EL', '-mips32', '-o', f'{name}.o', f'{name}.S'])
        run_build(out, ['mipsel-linux-gnu-ld', '-EL', '-T', 'loader.ld', '-o', f'{name}.elf', f'{name}.o'])
        run_build(out, ['mipsel-linux-gnu-objcopy', '-O', 'binary', f'{name}.elf', f'{name}.bin'])
        plain = (out / f'{name}.bin').read_bytes()
        encoded = codec.encode(plain)
        if len(plain) != size or codec.decode(encoded) != plain:
            raise ValueError(f'{name}: loader size or codec round trip differs')
        if digest(encoded) != expected_hash:
            raise ValueError(f'{name}: encoded bytes differ from the reviewed loader: {digest(encoded)}')
        (out / f'{name}.encoded.bin').write_bytes(encoded)
        records[name] = digest(encoded)
    save_json(out / 'loaders.json', records)
    return records


@contextmanager
def start_loader(args, name, magic, required_port=None):
    folder = args.loaders
    records = read_json(folder / 'loaders.json')
    _, _, length, expected_hash = LOADERS[name]
    data = (folder / f'{name}.encoded.bin').read_bytes()
    if len(data) != length or digest(data) != expected_hash or records[name] != expected_hash:
        raise ValueError(f'{name}: loader does not match its reviewed binary')
    get_upstream(args.adfu_checkout)
    from adfu_tool import device, protocol
    import usb.util

    found = device.find_adfu()
    if len(found) != 1:
        raise ValueError('connect exactly one Crystal701 in fresh ADFU mode')
    usb_device = found[0]
    try:
        if usb_device.bDeviceClass == 0xef:
            raise ValueError('the connected device is a composite runtime, not ADFU')
        config = usb_device[0]
        interfaces = [i for i in config if i.bInterfaceClass == 0xff]
        if len(interfaces) != 1:
            raise ValueError('expected exactly one ADFU vendor interface')
        geometry = {e.bEndpointAddress: (e.bmAttributes & 3, e.wMaxPacketSize) for e in interfaces[0]}
        if geometry != {0x01: (2, 64), 0x82: (2, 64)}:
            raise ValueError('NAND loaders require matching 64-byte ADFU bulk endpoints')
        port = [usb_device.bus, list(usb_device.port_numbers or [])]
        if required_port is not None and (not port[1] or port != required_port):
            raise ValueError('reconnect the same unit at the recorded USB port')
        try:
            usb_device.get_active_configuration()
        except usb.core.USBError as error:
            if 'not set' not in str(error).lower():
                raise
            usb_device.set_configuration(config.bConfigurationValue)

        class Transport(protocol.Session):
            def read(self):
                return self.bulk(64, packet_aligned=False)

            def bulk(self, size, packet_aligned=True):
                pending = bytearray()
                deadline = self.clock() + self.operation_timeout
                while len(pending) < size:
                    left = int((deadline - self.clock()) * 1000)
                    if left <= 0:
                        raise ValueError('NAND frame read timed out')
                    packet = bytes(usb_device.read(0x82, size - len(pending),
                                                   timeout=max(1, min(left, self._timeout_ms()))))
                    if not packet or (packet_aligned and len(packet) % 64):
                        raise ValueError('short or unaligned NAND USB packet')
                    pending.extend(packet)
                    if not packet_aligned:
                        break
                return bytes(pending)

        session = Transport(device.UsbDevice(usb_device), overall_timeout=3600, operation_timeout=30)
        identity = session.getinfo(expected=protocol.GETINFO_IDENTITY)
        session.upload(data)
        session.execute()
        header, ordering = protocol.read_execute_response(session, magic, 64)
        yield session, header, {'port': port, 'bootrom_identity': identity.hex(),
                                'loader_sha256': expected_hash, 'reply_order': ordering}
    finally:
        usb.util.dispose_resources(usb_device)


def checked_sector(state, magic, row, sector, length, sequence, corrected):
    tag, page, part, flags, _, dma, size, seq, count = struct.unpack_from('<4s8I', state)
    if (tag, page, part, size, seq) != (magic, row, sector, length, sequence):
        raise ValueError(f'wrong NAND frame at page {row}, sector {sector}')
    if flags != 3 or dma & 1 or (corrected and (count & 255) >= 20):
        raise ValueError(f'controller read failure at page {row}, sector {sector}')
    return count & 255


def read_sector_frame(session, magic, sequence, address):
    frame = session.read_exact(64, 64)
    if frame[:32] != magic or struct.unpack_from('<4I', frame, 32) != (sequence, 1, address, 16):
        raise ValueError(f'wrong boot reader frame {sequence}')
    return frame[48:]


def write_bytes(path, raw):
    with path.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


def read_nand(args):
    name = {'read-boot': 'boot', 'read-boot-raw': 'raw', 'read-lfi': 'lfi'}[args.command]
    out = new_dir(args.output)
    report = {'schema': 1, 'operation': name, 'complete': False, 'pages': 0}
    output = out / 'capture.partial.bin'
    counts = bytearray()
    blocks = LFI_BLOCKS if name == 'lfi' else BOOT_BLOCKS
    try:
        if name == 'boot':
            get_upstream(args.adfu_checkout)
            from adfu_tool.protocol import LOADER_IDENTITY as magic
        else:
            magic = b'RAW1' if name == 'raw' else b'ECC1'
        with start_loader(args, name, magic) as (session, header, metadata), output.open('xb') as stream:
            report.update(metadata, physical_blocks=blocks)
            if name == 'boot':
                from adfu_tool.reader import parse_cpu
                parse_cpu(header, magic)
            else:
                begin, end, page_size = (0, 1024, RAW_PAGE) if name == 'raw' else (82 * PAGES, 84 * PAGES, PAGE)
                if struct.unpack_from('<4s7I', header) != (magic, begin, 0xffffffff, 0, end, 0, page_size, 0):
                    raise ValueError('NAND reader geometry response differs')
            for block in blocks:
                for row in range(block * PAGES, (block + 1) * PAGES):
                    page = bytearray()
                    for sector, size in enumerate(SECTORS if name == 'raw' else SECTORS[:4]):
                        if name == 'boot':
                            first = (report['pages'] * 4 + sector) * 65 + 1
                            page.extend(b''.join(read_sector_frame(session, magic, first + i,
                                              0xB4061A00 + 16 * i) for i in range(64)))
                            flags, _, ecc, dma = struct.unpack('<4I', read_sector_frame(
                                session, magic, first + 64, 0xB4061E00))
                            if flags != 3 or dma & 1 or (ecc & 255) >= 20:
                                raise ValueError(f'boot ECC failure at page {row}, sector {sector}')
                            counts.append(ecc & 255)
                        else:
                            wire_size = (size + 63) // 64 * 64
                            wire = session.bulk(wire_size + 64)
                            count = checked_sector(wire[wire_size:], magic, row, sector, size,
                                                   report['pages'] * (5 if name == 'raw' else 4) + sector + 1,
                                                   name == 'lfi')
                            page.extend(wire[:size])
                            if name == 'lfi':
                                counts.append(count)
                    if name == 'lfi' and report['pages'] == 0 and page[:4] != LFI_MAGIC:
                        raise ValueError('LFI header missing on the reviewed physical map')
                    stream.write(page)
                    report['pages'] += 1
                stream.flush()
                print(f'Physical block {block} captured', file=sys.stderr, flush=True)
            os.fsync(stream.fileno())
        capture = output.read_bytes()
        if name == 'lfi':
            logical = interleave_lfi(capture)
            entries = lfi_directory(logical)
            write_bytes(out / 'lfi.bin', logical)
            save_json(out / 'lfi-files.json', entries)
            report.update(lfi_sha256=digest(logical), lfi_files=len(entries),
                          lfi_files_without_checksum=sum(e['checksum'] is None for e in entries))
        if counts:
            write_bytes(out / 'ecc-counts.bin', counts)
            report['ecc_counts_sha256'] = digest(counts)
        output.rename(out / 'capture.bin')
        report.update(complete=True, capture_sha256=digest(capture))
        return report
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        save_json(out / 'receipt.json', report)


def checked_capture(path, operation):
    report = read_json(path / 'receipt.json')
    raw = (path / 'capture.bin').read_bytes()
    if (report.get('schema'), report.get('operation'), report.get('complete'), report.get('pages')) != (
            1, operation, True, 1024) or report.get('physical_blocks') != list(BOOT_BLOCKS):
        raise ValueError(f'{operation}: expected a complete four-block capture')
    if digest(raw) != report.get('capture_sha256') or report.get('loader_sha256') != LOADERS[operation][3]:
        raise ValueError(f'{operation}: capture or loader hash differs')
    return raw, report


def prepare_restore(args):
    raw, raw_report = checked_capture(args.raw, 'raw')
    boot, boot_report = checked_capture(args.boot, 'boot')
    ecc = (args.boot / 'ecc-counts.bin').read_bytes()
    port = boot_report['port']
    if not port[1] or raw_report['port'] != port or raw_report['bootrom_identity'] != boot_report['bootrom_identity']:
        raise ValueError('both captures must come from the same recorded ADFU port/profile')
    if digest(ecc) != boot_report['ecc_counts_sha256']:
        raise ValueError('boot ECC report hash differs')
    stock = canonical_stock(raw, boot, ecc)
    out = new_dir(args.output)
    write_bytes(out / 'stock-block3.bin', stock)
    write_bytes(out / 'decoded-boot.bin', boot)
    report = dict(schema=1, port=port, target=TARGET, raw_capture_sha256=digest(raw),
                  boot_sha256=digest(boot), stock_sha256=digest(stock))
    save_json(out / 'restore.json', report)
    return report


def restore_inputs(path):
    report = read_json(path / 'restore.json')
    stock = (path / 'stock-block3.bin').read_bytes()
    boot = (path / 'decoded-boot.bin').read_bytes()
    verify_stock(stock)
    verify_boot(boot)
    if (report.get('schema'), report.get('target'), report.get('boot_sha256'), report.get('stock_sha256')) != (
            1, TARGET, digest(boot), digest(stock)) or not report['port'][1]:
        raise ValueError('restore plan does not match the verified stock inputs and port')
    return stock, boot, report


def send_state(session, magic, block=0, checksum=0):
    session.write(struct.pack('<4sII', magic, block, checksum).ljust(64, b'\x00'))


def expect_state(session, magic, page, sector, checksum):
    actual = struct.unpack_from('<4sIII', session.bulk(64))
    if actual != (magic, page, sector, checksum):
        raise ValueError(f'loader returned {actual!r}, expected {magic!r} at page {page} sector {sector}')


def stream_stock(session, raw, program):
    checksum = 0
    offset = 0
    for page in range(PROGRAM_PAGES):
        for sector, size in enumerate(SECTORS):
            data = raw[offset:offset + size]
            offset += size
            for slot in range(0, size, 64):
                session.write(data[slot:slot + 64].ljust(64, b'\x00'))
            checksum = (checksum + word_sum(data)) & 0xffffffff
            expect_state(session, b'ACKW' if program else b'ACKD', page, sector, checksum)
        if program:
            expect_state(session, b'PAGE', page, 4, checksum)
    return checksum


def restore(args):
    stock, _, plan = restore_inputs(args.plan)
    program = args.command == 'restore-stock-block3'
    if program and not args.write:
        raise ValueError('restore requires explicit --write after reviewing the dry run')
    payload = stock[:PROGRAM_PAGES * RAW_PAGE]
    checksum = word_sum(payload)
    out = new_dir(args.output)
    record = dict(schema=1, operation=args.command, target=TARGET, stock_sha256=digest(stock),
                  dry_run_verified=False, write_started=False, programmed=False, readback_verified=False)
    journal = out / 'receipt.json'
    save_json(journal, record)
    try:
        with start_loader(args, 'restore', b'WRP1', plan['port']) as (session, header, metadata):
            record.update(metadata)
            if struct.unpack_from('<4sIII', header) != (b'WRP1', 0, 0, 0):
                raise ValueError('stock writer response differs')
            echo = b'PING' + os.urandom(60)
            session.write(echo)
            if session.bulk(64) != echo:
                raise ValueError('USB echo mismatch')
            send_state(session, b'DRY1', TARGET, checksum)
            expect_state(session, b'RDY1', 0, 0, 0)
            if stream_stock(session, payload, False) != checksum:
                raise ValueError('dry-run transfer checksum differs')
            expect_state(session, b'DRYO', PROGRAM_PAGES, 0, checksum)
            record['dry_run_verified'] = True
            if program:
                record['write_started'] = True
                save_json(journal, record)
                send_state(session, b'CMIT', TARGET, checksum)
                expect_state(session, b'EROK', PROGRAM_PAGES, 0, checksum)
                if stream_stock(session, payload, True) != checksum:
                    raise ValueError('program transfer checksum differs')
                expect_state(session, b'DONE', PROGRAM_PAGES, 0, checksum)
                record['programmed'] = True
        return record
    except Exception as error:
        record['error'] = str(error)
        raise
    finally:
        save_json(journal, record)


def verify_restore(args):
    stock, boot, plan = restore_inputs(args.plan)
    writer = read_json(args.write_receipt)
    if (writer.get('operation') != 'restore-stock-block3' or writer.get('target') != TARGET or
            writer.get('loader_sha256') != LOADERS['restore'][3] or writer.get('dry_run_verified') is not True or
            writer.get('programmed') is not True or writer.get('write_started') is not True or
            writer.get('stock_sha256') != digest(stock) or writer.get('port') != plan['port']):
        raise ValueError('expected a successful program receipt for this restore and USB port')
    out = new_dir(args.output)
    report = dict(schema=1, operation='verify', target=TARGET, readback_verified=False, pages=0)
    readback = bytearray()
    try:
        with start_loader(args, 'verify', b'VER1', plan['port']) as (session, header, metadata):
            report.update(metadata)
            if struct.unpack_from('<4s7I', header) != (b'VER1', 768, 0xffffffff, 0, 1024, 0, PAGE, 0):
                raise ValueError('readback header differs')
            for page in range(PAGES):
                for sector in range(4):
                    wire = session.bulk(1088)
                    checked_sector(wire[1024:], b'VER1', 768 + page, sector, 1024, page * 4 + sector + 1, True)
                    offset = page * PAGE + sector * 1024
                    spare = page * RAW_PAGE + PAGE + sector * 46
                    if wire[:1024] != boot[offset:offset + 1024] or wire[1060:1064] != stock[spare:spare + 4]:
                        raise ValueError(f'boot block 3 readback mismatch at page {page}, sector {sector}')
                    readback.extend(wire[:1024])
                report['pages'] += 1
        write_bytes(out / 'verified-block3.bin', readback)
        report.update(readback_verified=True, data_sha256=digest(readback))
        return report
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        save_json(out / 'receipt.json', report)


def inspect_lfi(args):
    image = args.image.read_bytes()
    entries = lfi_directory(image)
    report = dict(sha256=digest(image), files=entries,
                  bytes_after_last_file=LFI_BYTES - max(e['offset'] + e['size'] for e in entries))
    if args.file:
        name, path = args.file
        matches = [entry for entry in entries if (entry['name'][:8].strip() + '.' + entry['name'][8:].strip()).upper() == name.upper()]
        if len(matches) != 1:
            raise ValueError(f'LFI file not found or ambiguous: {name}')
        entry = matches[0]
        size = Path(path).stat().st_size
        next_start = min((e['offset'] for e in entries if e['offset'] > entry['offset']), default=None)
        report = dict(name=name, start_sector=entry['start_sector'], stock_size=entry['size'],
                      size_field_2=entry['size_field_2'], candidate_size=size,
                      fits_current_file_span=size <= entry['size'],
                      bytes_to_next_file=next_start - entry['offset'] if next_start is not None else None)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)

    def command(name, handler, output=True, usb=False):
        item = commands.add_parser(name)
        item.set_defaults(handler=handler)
        if output:
            item.add_argument('--output', type=Path, required=True, help='new output directory')
        if usb:
            item.add_argument('--loaders', type=Path, required=True)
            item.add_argument('--adfu-checkout', type=Path, required=True)
        return item

    command('build', build_loaders).add_argument('--adfu-checkout', type=Path, required=True)
    for name in ('read-boot', 'read-boot-raw', 'read-lfi'):
        command(name, read_nand, usb=True)
    prepare = command('prepare-restore', prepare_restore)
    for arg in ('--boot', '--raw'):
        prepare.add_argument(arg, type=Path, required=True)
    for name in ('dry-run', 'restore-stock-block3', 'verify-stock-block3'):
        item = command(name, verify_restore if name == 'verify-stock-block3' else restore, usb=True)
        item.add_argument('--plan', type=Path, required=True)
        if name == 'restore-stock-block3':
            item.add_argument('--write', action='store_true', required=True)
        if name == 'verify-stock-block3':
            item.add_argument('--write-receipt', type=Path, required=True)
    inspect = command('inspect-lfi', inspect_lfi, output=False)
    inspect.add_argument('image', type=Path)
    inspect.add_argument('--file', nargs=2, metavar=('LFI_NAME', 'CANDIDATE_PATH'))
    args = parser.parse_args()
    try:
        print(json.dumps(args.handler(args), indent=2))
    except Exception as error:
        parser.exit(1, f'tamatama-extractor: {error}\n')


if __name__ == '__main__':
    main()
