#!/usr/bin/env bash
# Check the host can cross-build the packages and assemble an image. Nothing is
# installed here: the pacman command to run is printed, because installing on the host
# needs root, which is mkq's call.
set -euo pipefail
PORT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PORT"

# Build-time tools match the PKGBUILDs' makedepends. The image script additionally needs
# pacstrap/arch-chroot (arch-install-scripts) and the filesystem tools.
need=(aarch64-linux-gnu-gcc make bc bison flex python3 dtc fdtget git curl
      pacman repo-add sfdisk mkfs.ext4 mkfs.btrfs btrfs blkid uuidgen lsattr chattr
      losetup pacstrap arch-chroot)
missing=()
for c in "${need[@]}"; do command -v "$c" >/dev/null || missing+=("$c"); done
if (( ${#missing[@]} )); then
  echo "missing:"; printf '  %s\n' "${missing[@]}"
  echo "install: sudo pacman -S --needed base-devel bc bison flex libelf dtc python-pyelftools \\"
  echo "           swig aarch64-linux-gnu-gcc btrfs-progs e2fsprogs arch-install-scripts"
  exit 1
fi

# A cross build needs the *target* distribution's signing keys too: pacman verifies every
# ALARM package it downloads, and a host that only has archlinux-keyring has never heard of
# the ALARM build key. Without this, scripts/03-mkimg.sh downloads ~240 MiB and then fails at
# the last moment with "signature of unknown trust" on filesystem/iana-etc and friends.
if [[ ! -e /usr/share/pacman/keyrings/archlinuxarm.gpg ]]; then
  echo "missing: Arch Linux ARM keyring (ALARM packages will fail the signature check)"
  echo "fix    : bash scripts/fix-alarm-keyring.sh   (stages the package, prints the root commands)"
  exit 1
fi

# Only a hint: package builds work in a container, the image assembly does not, because
# the host's cgroup v2 devices policy denies block devices (losetup fails).
[[ -w /dev/loop-control ]] || echo "note: no /dev/loop-control here; scripts/03-mkimg.sh needs a normal host shell"

n=$(find pkg -maxdepth 1 -name '*.pkg.tar.zst' 2>/dev/null | wc -l)
echo "host     : ok ($(aarch64-linux-gnu-gcc -dumpmachine), pacman $(pacman --version | sed -n 's/.* //p;2q' | head -1))"
echo "packages : $n built in pkg/"
