#!/usr/bin/env python3
"""Read a finished LubanCat-4 image back off the disk and prove what is in it.

This runs at the end of scripts/03-mkimg.sh, after every dd, and it can be run again on a
flashed card (`python3 scripts/check-image.py /dev/sdX ...`) or on an image you downloaded.

Offsets and field positions were not remembered from anything, they were measured against
filesystems created by the same mkfs the build uses:
  ext4  s_magic  at  1024 + 0x38  = 53 ef          (s_blocks_count at +0x04, s_log_block_size at +0x18)
  btrfs signature at 65536 + 0x40 = _BHRfS_M
  btrfs total_bytes at 65536 + 0x70 (verified on 200 MiB and 300 MiB filesystems)
An earlier version of this check read both magics at the start of their region, which is boot
block zero and the btrfs superblock UUID respectively, and so it failed on a good image. It then
printed the FIT header's totalsize as the container's size, which is also wrong: this is an
external-data FIT, so its header is 3072 bytes and its payloads live after it.
"""
import struct
import sys

SEC = 512
EXT4_SB_OFF = 1024          # superblock starts at byte 1024 of the filesystem
EXT4_MAGIC_OFF = 0x38       # s_magic within it
EXT4_BLOCKS_OFF = 0x04      # s_blocks_count_lo
EXT4_LOGBLOCK_OFF = 0x18    # s_log_block_size
BTRFS_SB_OFF = 65536        # first superblock copy
BTRFS_MAGIC_OFF = 0x40
BTRFS_TOTALBYTES_OFF = 0x70


class Check:
    def __init__(self, path):
        self.f = open(path, 'rb')
        self.fails = 0

    def ok(self, label, detail):
        print('  %-9s : %s' % (label, detail))

    def fail(self, label, detail):
        self.fails += 1
        print('  %-9s : %s' % (label, detail))

    def expect(self, cond, label, detail, bad):
        (self.ok if cond else self.fail)(label, detail if cond else bad)
        return cond

    def at(self, off, n):
        self.f.seek(off)
        return self.f.read(n)


def main():
    args = sys.argv[1:]
    if len(args) not in (5, 6):
        print('usage: check-image.py IMAGE BOOT_SECT ROOT_SECT BOOT_MB ROOT_MB [ROCKCHIP_IMG]')
        return 2
    path, boot_sect, root_sect, boot_mb, root_mb = args[:5]
    rockchip_img = args[5] if len(args) == 6 else None
    boot_off, root_off = int(boot_sect) * SEC, int(root_sect) * SEC
    # Includes the pre-partition loader area and partition 1 containing the FIT.
    raw_boot_limit = boot_off - 64 * SEC
    boot_mb, root_mb = int(boot_mb), int(root_mb)
    c = Check(path)

    # --- GPT: the partition table U-Boot's bootdev walks ---
    hdr = c.at(SEC, 96)
    if not c.expect(hdr[:8] == b'EFI PART', 'GPT', 'header ok', 'no GPT header at LBA 1'):
        return 1
    ent, = struct.unpack('<Q', hdr[72:80])          # PartitionEntryLBA
    num, esz = struct.unpack('<II', hdr[80:88])     # entry count, entry size
    attrs = []
    for i in range(min(num, 128)):
        attrs.append(struct.unpack('<Q', c.at(ent * SEC + i * esz + 0x30, 8))[0])
    c.expect(num >= 3, 'GPT', '%d entries at LBA %d' % (num, ent),
             'only %d partition entries, expected 3' % num)
    # Without legacy_bios_bootable on /boot, U-Boot's bootflow skips the partition in silence.
    c.expect(len(attrs) > 1 and attrs[1] & 4, 'GPT',
             'partition 2 is legacy_bios_bootable', 'partition 2 is not legacy_bios_bootable (bit 2)')

    # The binman image is compared byte for byte against the file that was supposed to be
    # written at sector 0x40. A comparison is stronger than checking a header magic.
    def compare(off, path, label, limit):
        if path is None:
            return
        try:
            want = open(path, 'rb').read()
        except OSError as e:
            c.fail(label, 'cannot read %s: %s' % (path, e.strerror))
            return
        if not c.expect(len(want) <= limit, label,
                        '%s is %d bytes, fits the %d KiB partition' % (path.split('/')[-1], len(want), limit // 1024),
                        '%s is %d bytes, larger than the %d KiB partition holding it'
                        % (path.split('/')[-1], len(want), limit // 1024)):
            return
        got = c.at(off, len(want))
        if c.expect(got == want, label,
                    'the %d bytes here are exactly %s' % (len(want), path.split('/')[-1]),
                    '%s does not match what is on disk: %d of %d bytes differ, first at 0x%x'
                    % (label, sum(a != b for a, b in zip(got, want)), len(want),
                       next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), len(want)))):
            return

    # Rockchip binman images start with an RKNS/idbloader header, not the vendor
    # first-stage tag. Their embedded FIT is at the image's internal binman offset.
    compare(0x40 * SEC, rockchip_img, 'rockchip image', raw_boot_limit)

    # --- /boot ---
    sb = c.at(boot_off + EXT4_SB_OFF, 128)
    if c.expect(sb[EXT4_MAGIC_OFF:EXT4_MAGIC_OFF + 2] == b'\x53\xef', '/boot',
                'ext4 superblock', 'no ext4 superblock at the start of the boot partition'):
        blocks, = struct.unpack('<I', sb[EXT4_BLOCKS_OFF:EXT4_BLOCKS_OFF + 4])
        bs = 1024 << struct.unpack('<H', sb[EXT4_LOGBLOCK_OFF:EXT4_LOGBLOCK_OFF + 2])[0]
        cap = blocks * bs
        c.expect(abs(cap - boot_mb * 1048576) <= bs, '/boot',
                 'ext4 %d MiB (%d blocks x %d)' % (cap // 1048576, blocks, bs),
                 'ext4 holds %d MiB but the boot partition was made %d MiB - the wrong image was dd\'d here'
                 % (cap // 1048576, boot_mb))

    # --- rootfs ---
    sb = c.at(root_off + BTRFS_SB_OFF, 1024)
    if c.expect(sb[BTRFS_MAGIC_OFF:BTRFS_MAGIC_OFF + 8] == b'_BHRfS_M', 'rootfs',
                'btrfs superblock', 'no btrfs superblock at the start of the root partition'):
        total, = struct.unpack('<Q', sb[BTRFS_TOTALBYTES_OFF:BTRFS_TOTALBYTES_OFF + 8])
        c.expect(total == root_mb * 1048576, 'rootfs',
                 'btrfs %d MiB' % (total // 1048576),
                 'btrfs is %d MiB but the root partition was made %d MiB - the wrong image was dd\'d here'
                 % (total // 1048576, root_mb))

    if c.fails:
        print('%d check(s) failed in %s' % (c.fails, path))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
