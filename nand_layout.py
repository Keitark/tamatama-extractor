# SPDX-License-Identifier: GPL-2.0-or-later
"""Crystal701 capture formats and stock boot-image checks."""

from hashlib import sha256
import struct

PAGE = 4096
SPARE = 224
RAW_PAGE = PAGE + SPARE
PAGES = 256
BLOCK = PAGE * PAGES
RAW_BLOCK = RAW_PAGE * PAGES
BOOT_BLOCKS = (0, 1, 2, 3)
LFI_PAIRS = ((82, 83), (3850, 3851), (3854, 3855), (3858, 3859),
             (3862, 3863), (3866, 3867), (3870, 3871), (3874, 3875),
             (3878, 3879), (3882, 3883), (1900, 1901))
LFI_BYTES = len(LFI_PAIRS) * BLOCK * 2
LFI_MAGIC = bytes.fromhex('55aaf20f')
BOOT_SHA = '02763c8973574ef90c21752a31b92cf304cc63411cbd71dd12a29e0c435a0404'
STOCK_SHA = '788710f547d9ce32e431cea0fb1046306caafbbb379e1f1cf04412d3a6c119cb'


def digest(data):
    return sha256(data).hexdigest()


def word_sum(data):
    length = len(data) & ~3
    return sum(word for word, in struct.iter_unpack('<I', memoryview(data)[:length])) & 0xffffffff


def lfi_directory(image):
    """Parse the recorded LFI format and validate the captured file contents."""
    if len(image) != LFI_BYTES or image[:4] != LFI_MAGIC:
        raise ValueError('expected the captured 22 MiB Crystal701 LFI profile')
    entries = []
    for offset in range(0x200, 0x2000, 32):
        record = image[offset:offset + 32]
        name = record[:11]
        if not name.strip(b' \x00\xff') or any(c < 32 or c > 126 for c in name):
            break
        flags, sector, size, size_field_2, checksum = struct.unpack_from('<5I', record, 12)
        start = sector * 512
        if start < offset + 32 or start + size > len(image):
            raise ValueError(f'invalid LFI extent for {name!r} at {offset:#x}')
        if checksum and word_sum(memoryview(image)[start:start + size]) != checksum:
            raise ValueError(f'LFI checksum mismatch for {name!r}')
        entries.append(dict(name=name.decode('ascii'), start_sector=sector, offset=start,
                            size=size, size_field_2=size_field_2, flags=flags,
                            checksum=f'{checksum:08x}' if checksum else None))
    if not entries or min(entry['offset'] for entry in entries) < 0x200 + 32 * len(entries):
        raise ValueError('invalid or missing LFI directory')
    by_offset = sorted(entries, key=lambda entry: entry['offset'])
    if any(left['offset'] + left['size'] > right['offset']
           for left, right in zip(by_offset, by_offset[1:])):
        raise ValueError('LFI file allocations overlap')
    return entries


def interleave_lfi(physical):
    if len(physical) != LFI_BYTES:
        raise ValueError('expected 22 complete physical blocks')
    logical = bytearray(LFI_BYTES)
    for pair in range(len(LFI_PAIRS)):
        base = pair * 2 * BLOCK
        for page in range(PAGES):
            for side in (0, 1):
                read = base + side * BLOCK + page * PAGE
                write = base + (page * 2 + side) * PAGE
                logical[write:write + PAGE] = physical[read:read + PAGE]
    return logical


def verify_boot(boot):
    if len(boot) != len(BOOT_BLOCKS) * BLOCK or digest(boot) != BOOT_SHA:
        raise ValueError('decoded boot copies do not match the verified stock revision')
    if any(boot[i * BLOCK:(i + 1) * BLOCK] != boot[:BLOCK] for i in BOOT_BLOCKS[1:]):
        raise ValueError('the four decoded boot copies must match')


def verify_stock(stock):
    if len(stock) != RAW_BLOCK or digest(stock) != STOCK_SHA:
        raise ValueError('raw payload does not match the verified stock boot block')
    if stock[128 * RAW_PAGE:] != b'\xff' * (128 * RAW_PAGE):
        raise ValueError('stock boot block erased tail differs')


def canonical_stock(raw, decoded, ecc_counts):
    """Reconstruct the known stock boot block from clean captured codewords."""
    verify_boot(decoded)
    if len(raw) != 4 * RAW_BLOCK or len(ecc_counts) != 4 * PAGES * 4:
        raise ValueError('raw boot data or ECC sector counts are incomplete')
    output = bytearray(b'\xff' * RAW_BLOCK)
    for page in range(128):
        for sector in range(4):
            start = page * RAW_PAGE + sector * 1024
            spare = page * RAW_PAGE + PAGE + sector * 46
            codewords = []
            for block in BOOT_BLOCKS:
                base = block * RAW_BLOCK
                codewords.append(raw[base + start:base + start + 1024] +
                                 raw[base + spare:base + spare + 46])
            clean = [block for block in BOOT_BLOCKS
                     if ecc_counts[(block * PAGES + page) * 4 + sector] == 0]
            if not clean:
                raise ValueError(f'no ECC-clean copy for page {page}, sector {sector}')

            def distance(block):
                return sum((a ^ b).bit_count() for other in codewords
                           for a, b in zip(codewords[block], other))

            chosen = codewords[min(clean, key=distance)]
            output[start:start + 1024] = chosen[:1024]
            output[spare:spare + 46] = chosen[1024:]
    verify_stock(output)
    return output
