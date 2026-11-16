# LubanCat-4 Arch Linux port

Package build and TF card image for the EmbedFire (野火) LubanCat-4. Board under test: EBF410116 V1R1,
RK3588S2, 8 GiB LPDDR4X. The system uses an ext4 `/boot`, a Btrfs root and extlinux, with no
initramfs.

The image carries two kernels: mainline Linux and Rockchip BSP 6.12. The boot chain is a single
Rockchip image assembled by U-Boot binman: Rockchip DDR training, U-Boot SPL, open-source TF-A
BL31 and U-Boot. DDR training is still a closed-source blob.

[中文版](README.zh-CN.md)

This is a board port, not an official Arch Linux ARM board image.

## Board interfaces

Names below are SoC GPIO names from the device tree, not 40-pin header numbers. `GPIO4_A2` is
bit 2 of group A in bank 4; A/B/C/D have 8 bits each. Power, ground and pinmux on the header are
in the schematic for the matching revision.

| Signal | DSI0 non-V1 | DSI0 V1 | DSI1 non-V1 | DSI1 V1 (tested) |
|---|---|---|---|---|
| Display path | VP2 → DSI0 | same | VP3 → DSI1 | same |
| Panel reset | GPIO0_B7 | GPIO1_A1 | GPIO0_D3 | GPIO0_D3 |
| Panel power enable | GPIO1_D2 | GPIO1_D2 | GPIO1_D3 | GPIO1_D3 |
| Backlight PWM | PWM2/m0 | same | PWM6/m0 | same |
| GT911 bus | I2C5/m3 | same | I2C6/m3 | same |
| GT911 IRQ | GPIO0_C5 | GPIO0_C5 | GPIO3_C4 | GPIO4_A1 |
| GT911 reset | GPIO0_C0 | GPIO1_A0 | GPIO3_C5 | GPIO4_A2 |

Pin definitions live in `pkgs/linux-lubancat4-git/rk3588s-lubancat4-dsi*.dtso`; the vendor
equivalents are in the BSP package under `vendor-dts/rockchip/`. GT911 sits at address `0x5d`.
The panel used for testing here is an EBF410173, 7 inch 1024×600, on DSI1. Any other panel has to
be ported; what the repository already carries is listed below.

### Panel device trees in this repository

**Mainline (`pkgs/linux-lubancat4-git/`) only has the EBF410173**, four overlays covering
DSI0/DSI1 × the two board revisions:

| overlay | purpose |
|---|---|
| `dsi0-ebf410173.dtso` / `-v1.dtso` | DSI0, VP2 |
| `dsi1-ebf410173.dtso` / `-v1.dtso` | DSI1, VP3 (the set used for testing) |

**The BSP (`pkgs/linux-lubancat4-bsp/vendor-dts/rockchip/`) has five panels**, each with a DSI0
and a DSI1 variant, installed to `/boot/bsp/overlays/`:

| Panel | Resolution | Driver compatible |
|---|---|---|
| EBF410173 | 1024×600 | `embedfire,ebf410173` (the new mainline driver) |
| EBF410125 | 1080×1920 | vendor `simple-panel-dsi` |
| EBF410177 | 800×1280 | vendor `simple-panel-dsi` |
| S8001280B1060B | 800×1280 | vendor `simple-panel-dsi` |
| `generic` | from the EEPROM | vendor auto-detect |

### Using a different panel

**BSP kernel**: enable the vendor overlay directly.

```sh
lubancat4-overlay -k bsp list
lubancat4-overlay -k bsp clear
lubancat4-overlay -k bsp enable rk3588s-lubancat-4-dsi1-vp3-800x1280-10.1inch-ebf410177-overlay
reboot
```

**Mainline**: no ready-made material, so it has to be ported. Take the vendor `.dtsi`, move its
`panel-init-sequence`, `display-timings` and DSI parameters into a new overlay, then point
`compatible` at a driver:

- when the init commands fit the generic `simple-panel` delays (`prepare-delay-ms`,
  `init-delay-ms`), `panel-simple` may be enough;
- when the panel needs DCS commands sent one by one, write a driver modelled on
  `panel-embedfire-ebf410173.c`;
- run `check-overlays.py` for the static checks, then read `dmesg` and look at the screen.

The V1/non-V1 pin differences are in the table above; V1 device trees end in `-v1`. Picking the
wrong revision makes two drivers fight over the same pin.

| Other interfaces | Notes |
|---|---|
| Debug UART | 1500000 8N1; mainline uses ttyS2, BSP uses ttyFIQ0 |
| TF card | controller fe2c0000.mmc; device names change, identify by PARTUUID and medium type |
| XL9535 expander | I2C6, address 0x21; IRQ is GPIO1_A0 on non-V1, GPIO0_C0 on V1 |
| XL9535 inputs | internal lines 3/4/5 are keys, 7 is encoder press, 12/13/14 are encoder inputs |
| HDMI | HDMI0; audio needs the overlay and a connected sink |
| Onboard Ethernet | GMAC + RTL8211F; the network test used a USB CDC adapter |
| Camera | the vendor tree carries several sensor overlays; no camera was tested |

V1 and non-V1 overlays describe different pinmux, so pick by board revision. BSP overlays are
compiled against the vendor tree and mainline ones against the mainline tree; they are not
interchangeable.

## Packages

| Directory | Purpose |
|---|---|
| `pkgs/linux-lubancat4-git` | tracks mainline Linux, adds board NPU/RGA config, 7 overlays and the EBF410173 panel driver; also produces a headers package |
| `pkgs/linux-lubancat4-bsp` | Rockchip develop-6.12 kernel with the vendor Mali/RKNPU/MPP/RGA interfaces; ships EmbedFire board DTS files and vendor overlays into `/boot/bsp` |
| `pkgs/uboot-lubancat4` | U-Boot 2026.10, open-source TF-A BL31, binman boot image, plus the DDR and BL32 binary inputs |
| `pkgs/lubancat4-board-config` | network and serial defaults, fstab/extlinux templates, overlay/status/flash tools |

Build scripts: `00-hostdeps.sh`, `01-build.sh`, `02-repo.sh`, `03-mkimg.sh`. Packages land in
`pkg/`, the local pacman repository in `repo/`, images in `dist/`.

## Two kernels side by side

The image installs both kernels. Each package writes its own directories:

```text
/boot/Image                 /boot/bsp/Image                 kernel
/boot/dtbs/rockchip/        /boot/bsp/dtbs/rockchip/        device trees
/boot/overlays/             /boot/bsp/overlays/             overlays
```

`/boot/extlinux/extlinux.conf` holds one `label` per kernel, and each section's `linux`, `fdt`
and `fdtoverlays` apply only inside that section. U-Boot's extlinux bootmeth walks the selected
label line by line, so choosing `arch` uses only the mainline device tree and overlays, and
choosing `bsp` uses only the BSP ones.

The BSP board trees come from EmbedFire's vendor tree; the BSP package compiles and installs them
itself, next to the 76 Rockchip reference boards. The `append` lines differ too: mainline uses
`console=ttyS2`, BSP uses `console=ttyFIQ0`.

Overlay switching is scoped per label, with one list per kernel
(`/etc/lubancat4/overlays`, `/etc/lubancat4/overlays-bsp`):

```sh
lubancat4-overlay list                  # default kernel
lubancat4-overlay -k bsp list           # BSP
lubancat4-overlay -k bsp enable rk3588s-lubancat-4-dsi1-vp3-1024x600-7inch-ebf410173-overlay
```

`03-mkimg.sh` appends the BSP entry only when both `/boot/bsp/Image` and the board DTB exist;
otherwise it writes the mainline entry alone.

Each kernel package ships a pacman install scriptlet that sets the global `default` line to its
own entry, so installing or removing a kernel moves the default boot entry with it. The script
touches only that one line and leaves everything else untouched; if the label or the file is
absent (during pacstrap) it prints a note and exits 0, so the transaction is never aborted.

## Build

```sh
bash scripts/00-hostdeps.sh
bash scripts/01-build.sh
bash scripts/02-repo.sh
sudo bash scripts/03-mkimg.sh <output path> <size>
```

`01-build.sh` runs with `MAKEFLAGS=-j16` and deletes old archives and signatures in `pkg/` and
`pkgs/<name>/` first, so a package is rebuilt even when its version did not change. DDR training
and BL32 are SHA256-pinned inputs inside the U-Boot package; no firmware package needs to be
installed on the build host.

`03-mkimg.sh` needs root plus loop and mount support and runs from a host shell. Confirm the
target device before writing. To flash (`/dev/sdX` is the whole card, not a partition):

```sh
sudo dd if=dist/<image>.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

### Growing the root partition

The image's rootfs is 3072 MiB by default (`ROOT_MB`); on a larger card the rest stays unused.
Two ways to change that:

**Pick the size at build time**:

```sh
sudo ROOT_MB=$((119*1024)) bash scripts/03-mkimg.sh <output path> <size>
```

**Grow a card that is already flashed, online from the board** (no unmount, partitions 1 and 2
untouched):

```sh
# /dev/mmcblk1 is the TF card; confirm first
lsblk -o NAME,SIZE,MODEL
sudo sfdisk --part-size 3:0 --no-tell-kernel /dev/mmcblk1
sudo partprobe /dev/mmcblk1
sudo btrfs filesystem resize max /
df -h /
```

`--part-size 3:0` extends only partition 3 to the end of the disk. The start sector and the
partition UUID are kept, so the `PARTUUID=` references in `extlinux.conf` and `/etc/fstab` stay
valid.

Do not delete and recreate partition 3. Tested on a scratch image: rewriting the table makes
sgdisk/sfdisk generate new UUIDs for every partition, while `extlinux.conf` and `/etc/fstab`
refer to them by `PARTUUID`, so the board would not find its root filesystem after reboot.

### Package mirrors

Both the build host and the finished image use the **USTC mirror by default**
(`https://mirrors.ustc.edu.cn/archlinuxarm/`), with TUNA second and the official Arch Linux ARM
server last. Two files hold that order:

| File | Where it ends up |
|---|---|
| `conf/pacman.aarch64.conf.in` | pacman config used only while `03-mkimg.sh` runs `pacstrap` on the host |
| `conf/mirrorlist.lubancat4` | the image's `/etc/pacman.d/mirrorlist` |

To use a different mirror, edit those two files and rebuild the image; nothing else references a
server address. On a running board the fastest way is `reflector` or a manual edit of
`/etc/pacman.d/mirrorlist`, since that file belongs to the image, not to a package.

## Usage

Insert the card and power on. Serial is 1500000 8N1; alternatively plug in Ethernet.

### Login

| Field | Value |
|---|---|
| User | `root` |
| Password | `root` (set at build time with `LBC_ROOT_PASSWORD`) |

Serial shows `lubancat4 login:` once the boot log settles. SSH works as soon as the board has a
DHCP address:

```sh
ssh root@<board IP>
```

Take the address from the router's DHCP leases, or `ip -4 addr show` on the serial console.

### Change the root password

```sh
passwd
```

### Turn off password login for root over SSH

The image installs `conf/sshd-lubancat4.conf` as `/etc/ssh/sshd_config.d/10-lubancat4.conf`:

```
PermitRootLogin yes
PasswordAuthentication yes
```

**Key-only root login**: install the key first, then change the setting, or you lock yourself out.

```sh
ssh-copy-id root@<board IP>
# after confirming the key works:
sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' \
  /etc/ssh/sshd_config.d/10-lubancat4.conf
sshd -t && systemctl reload sshd
```

**No root login over SSH at all**: create a normal user, log in as that user, then `su -` or use
`sudo`.

```sh
useradd -m -G wheel <user>
passwd <user>
printf 'PermitRootLogin no\n' >> /etc/ssh/sshd_config.d/10-lubancat4.conf
sshd -t && systemctl reload sshd
```

Files in `sshd_config.d` are read in order and the first value wins, so a `PermitRootLogin no`
appended to this file overrides the `yes` above it.

**No SSH at all**:

```sh
systemctl disable --now sshd
```

`sshd -t` checks the syntax before the reload; a bad line is refused and the running daemon keeps
its current configuration. Verify from a second terminal before closing the first one.
