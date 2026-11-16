#!/usr/bin/env bash
# Build every package for aarch64 on this x86_64 host.
# Cross building with makepkg is what Arch Linux ARM itself documents:
#   http://os.archlinuxarm.org/linux/ (uboot-odroid-n2 PKGBUILD comment:
#   "CROSS_COMPILE=aarch64-linux-gnu- CARCH=aarch64 makepkg -srf")
# makepkg never assigns CARCH itself, so the environment decides.
set -euo pipefail
PORT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PORT"
CROSS=${CROSS:-aarch64-linux-gnu-}
# U-Boot before linux is irrelevant; linux is last because it takes longest.
# linux-lubancat4-bsp last: it is the second kernel (Rockchip's vendor driver set) and it costs
# about twenty minutes on top of the mainline one. LBC_PKGS="..." skips it while iterating.
ORDER=(lubancat4-board-config uboot-lubancat4 linux-lubancat4-git linux-lubancat4-bsp)

# Every artifact goes to pkg/; this is the only directory scripts/02-repo.sh reads. Older builds
# also left archives inside pkgs/<name>/, which is how a repository ended up shipping a 6.12.69-1
# kernel while the board ran 6.12.69-2. Those stale files are removed below.
PKGDEST_DIR="$PORT/pkg"

# LBC_PKGS="lubancat4-board-config uboot-lubancat4" builds only those - handy when iterating on
# one package instead of waiting for the kernel every time.
if [[ -n ${LBC_PKGS:-} ]]; then
  read -r -a ORDER <<<"$LBC_PKGS"
  echo "only     : ${ORDER[*]}"
fi

for p in "${ORDER[@]}"; do
  [[ -f pkgs/$p/PKGBUILD ]] || { echo "no pkgs/$p/PKGBUILD"; exit 1; }
done

for p in "${ORDER[@]}"; do
  mapfile -t md < <(makepkg --printsrcinfo -p "pkgs/$p/PKGBUILD" 2>/dev/null |
    awk -F' = ' '/^makedepend/ {print $2}')
  missing=()
  for d in "${md[@]}"; do pacman -Qq "$d" >/dev/null 2>&1 || missing+=("$d"); done
  if (( ${#missing[@]} )); then
    echo "$p: missing host makedepends:"; printf '  %s\n' "${missing[@]}"
    echo "install: sudo pacman -S --needed ${missing[*]}"
    exit 1
  fi
done

# Optional package signing: LBC_SIGN_KEY=<40-digit fingerprint>. makepkg takes the key id
# from GPGKEY; /etc/makepkg.conf has no GPGKEY line on this system (checked with grep), so the
# environment is not overwritten. --sign makes makepkg write <pkg>.pkg.tar.zst.sig next to
# every package; scripts/02-repo.sh then records those in the database (repo-add --include-sigs)
# so pacman can check them at install time.
SIGN_ARGS=()
if [[ -n ${LBC_SIGN_KEY:-} ]]; then
  if ! gpg --batch --list-secret-keys "$LBC_SIGN_KEY" >/dev/null 2>&1; then
    echo "LBC_SIGN_KEY=$LBC_SIGN_KEY : no secret key in this gpg keyring, cannot sign"
    echo "check: gpg --list-secret-keys '$LBC_SIGN_KEY'"
    echo "keys : gpg --list-secret-keys"
    exit 1
  fi
  export GPGKEY="$LBC_SIGN_KEY"
  SIGN_ARGS=(--sign)
  echo "signing: $LBC_SIGN_KEY"
fi

for p in "${ORDER[@]}"; do
  echo "==== $p ===="
  # A signature must never outlive the bytes it signs. repo-add --include-sigs records whatever
  # .sig happens to sit beside a package, so one left over from an earlier build would be filed
  # against a file it does not match, and pacman would then reject a perfectly good package.
  # The old archive is removed as well: makepkg decides a package is current by name, and an
  # archive left behind by an earlier run silently suppresses both the rebuild and the signature.
  rm -f "$PKGDEST_DIR/$p"-*.pkg.tar.zst "$PKGDEST_DIR/$p"-*.pkg.tar.zst.sig
  rm -f "pkgs/$p"/*.pkg.tar.zst "pkgs/$p"/*.pkg.tar.zst.sig
  ( cd "pkgs/$p"
    export CROSS_COMPILE="$CROSS" ARCH=arm64 PKGDEST="$PKGDEST_DIR" SRCDEST="$PORT/src"
    CARCH=aarch64 MAKEFLAGS="-j16" makepkg -sf --noconfirm "${SIGN_ARGS[@]}" )

  # Anything makepkg wrote inside the package directory is moved, not deleted: it is the one
  # copy that exists when PKGDEST in /etc/makepkg.conf points somewhere else than it should.
  if compgen -G "pkgs/$p/*.pkg.tar.zst" >/dev/null; then
    for f in pkgs/"$p"/*.pkg.tar.zst*; do
      [[ -e $f ]] || continue
      mv -f "$f" "$PKGDEST_DIR/"
      echo "moved    : pkgs/$p/$(basename "$f") -> pkg/$(basename "$f")"
    done
  fi

  # makepkg signs the archive it has just written and puts the .sig next to it. A .sig that ends
  # up on its own in the package directory therefore signed nothing in pkg/, so drop it rather
  # than move it next to an archive it does not match.
  rm -f pkgs/"$p"/*.pkg.tar.zst.sig

  # The archive that was just built must have a signature when signing is on, or the release
  # would contain an unchecked package. Every artifact of this build goes to pkg/, so this only
  # reads; it never prints a list that would make the built archives harder to find.
  if (( ${#SIGN_ARGS[@]} )); then
    unsigned=0
    for f in "$PKGDEST_DIR/$p"-*.pkg.tar.zst; do
      [[ -e $f ]] || continue
      [[ -f $f.sig ]] || { echo "no signature next to $(basename "$f")"; unsigned=$((unsigned + 1)); }
    done
    (( unsigned == 0 )) || exit 1
  fi
done

echo "==== built ===="
ls -l "$PKGDEST_DIR"/*.pkg.tar.zst 2>/dev/null || { echo "nothing in pkg/"; exit 1; }
echo "next: scripts/02-repo.sh"
