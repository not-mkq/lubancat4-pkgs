#!/usr/bin/env bash
# Assemble a bootable LubanCat-4 image entirely out of packages: pacstrap installs the
# rootfs from repo/, and both boot stages are files that packages put into the rootfs.
# Layout: loader at sector 0x40, /boot at 0x8000, rootfs at 0x88000; see the LAYOUT block below.
# Needs root for losetup/mount, and must run from a normal host shell (no container).
set -euo pipefail
# Deterministic tool output for the checks this script does, and a locale that actually exists
# inside the new root when its scriptlets run: pacstrap passes our environment into the chroot,
# so a host LANGUAGE=zh_CN made every perl scriptlet inside the image warn "Setting locale
# failed" because no zh_CN.UTF-8 is compiled in a fresh root (conf/locale.conf says C.UTF-8,
# which glibc always has).
export LC_ALL=C.UTF-8 LANGUAGE=
PORT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DATE=$(date +%Y%m%d)
OUT=${OUT:-$PORT/dist/lubancat4-$DATE.img}
ROOT_MB=${ROOT_MB:-3072}
# 256 MiB, not 128: /boot holds Image plus the device trees, and it is the one partition on the
# card that cannot be grown from the running board. scripts/03-mkimg.sh measures the payload
# before installing, so a too-small BOOT_MB fails here instead of inside pacman's transaction.
BOOT_MB=${BOOT_MB:-256}
PKGLIST=${PKGLIST:-$PORT/pkglist/lubancat4.txt}
REPO=${REPO:-$PORT/repo}
SEC=512; LOADER_SECT=64; UBOOT_SECT=16384; UBOOT_SECTSZ=16384
BOOT_SECT=32768; BOOT_SECTSZ=$(( BOOT_MB * 2048 )); ROOT_SECT=$(( BOOT_SECT + BOOT_SECTSZ ))
GPT_BACKUP_RESERVE=34

# The image is built under a .partial name and only becomes $OUT once every check has passed.
# Before this, a run that aborted at any of the checks below left a full-size $OUT whose only
# content was a partition table: it flashes cleanly, the board falls back to eMMC, and everyone
# spends an hour suspecting the card reader. The final self-check could not help - it runs after
# the dd that fills the partitions in, so it never ran at all.
OUT_PART=$OUT.partial
OUT_FAILED=$OUT_PART.failed
img='' mnt='' bootmnt='' BOOT_IMG='' ROOT_IMG='' PCONF='' STAGE='' DONE=0
# Everything this script writes needs root only because losetup and mount do, so hand it back
# on the way out. Under rootless podman/distrobox, files created by the container's root show up
# on the host side as nobody:nobody - which is how dist/ became a directory the build machine
# could not write into, and the next non-root step (git add, a build log, deleting a stale
# image) then failed somewhere that had nothing to do with what actually happened.
give_back() {
  [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]] || return 0
  local f
  for f in "$@"; do
    if [[ -e $f ]]; then chown "$SUDO_UID:$SUDO_GID" "$f"; fi
  done
  return 0
}
# Unmount in bind-then-image order, retrying. A mount held by some shell's current directory
# frees the moment that shell leaves it, and EBUSY on a loop-backed btrfs is worth waiting a
# moment for: the version before this one gave up on the first EBUSY and then deleted the file
# that the still-mounted loop device was reading from, leaving a loop pointing at "(deleted)".
# pacman verifies package signatures through gpgme, and gpg lets gpg auto-launch gpg-agent as a
# detached daemon (our own `pacman-key --populate-from` step reaches gpg the same way). Inside a
# chroot that is a trap: the daemon inherits arch-chroot's root directory, outlives pacman, and
# keeps a socket open under $mnt - the mount then answers EBUSY forever while fuser shows nothing
# but an idle "gpg-agent" doing no I/O at all. GnuPG's documented shutdown is gpgconf --kill, and
# it has to run with the same root directory the agent was started in, because that is the path
# the agent registered its socket under. HOME/PATH are set explicitly so this can never address
# the agent on the host that signs our packages.
close_signature_agents() {
  [[ -n ${mnt:-} ]] || return 0
  mountpoint -q "$mnt" 2>/dev/null || return 0
  local hd
  for hd in /root/.gnupg /etc/pacman.d/gnupg; do   # pacman-key's keyring, and pacman's own
    arch-chroot "$mnt" env -i HOME=/root PATH=/usr/bin:/bin \
      gpgconf --homedir "$hd" --kill all >/dev/null 2>&1 || true
  done
}

unmount_all() {
  local left='' d t
  close_signature_agents
  for t in 1 2 3 4 5; do
    left=''
    for d in "${mnt:+$mnt/boot}" "${bootmnt:-}" "${mnt:-}" "${img:-}"; do
      [[ -n $d ]] || continue
      mountpoint -q "$d" 2>/dev/null || continue
      umount -R "$d" 2>/dev/null || left+=" $d"
    done
    [[ -z $left ]] && return 0
    (( t == 1 )) && echo "  held by something, retrying the unmount (5 s apart):$left"
    sleep 5
  done
  echo "  still held after 5 tries:$left"
  command -v fuser >/dev/null && fuser -vm $left 2>&1 | sed 's/^/    /'
  return 1
}
cleanup() { # $1 = the exit status we are unwinding with
  local rc=$1
  unmount_all || true
  # The staged boot stages are cleaned up here and nowhere else. An rm in the middle of the
  # script put that five lines ahead of the read-back check that reads those two files, and the
  # check then reported "cannot read /tmp/tmpXXX/u-boot-rockchip.bin" about an image whose bytes at 0x40
  # were correct. The trap runs after everything else, on every exit path, so it cannot get ahead
  # of a reader.
  [[ -z ${STAGE:-} ]] || rm -rf "$STAGE"
  (( DONE )) && return $rc
  if mountpoint -q "${mnt:-/nonexistent}" || mountpoint -q "${img:-/nonexistent}"; then
    echo "aborted (exit $rc) with the temp mounts still up - leaving every temp file in place"
    echo "  free it:  sudo fuser -vm ${mnt:-} ${img:-}"
    echo "  then:     sudo umount ${mnt:-} ${img:-} && sudo losetup -d \$(losetup -j ${ROOT_IMG:-/nonexistent} -n -O NAME)"
    return $rc
  fi
  echo "aborted (exit $rc) before the image was finished"
  # Keep the evidence instead of destroying it. Every failure this script has had this evening
  # was in the script, not the image, and each time the artifact was deleted the only way to look
  # again was another seven-minute run. The name cannot be confused with a finished image.
  if mv -f "$OUT_PART" "$OUT_FAILED" 2>/dev/null; then
    echo "  kept as $OUT_FAILED - never flash that name"
    give_back "$OUT_FAILED" ${BOOT_IMG:-} ${ROOT_IMG:-} "$PORT/dist"
    echo "  clean up with:  rm -f $OUT_FAILED ${BOOT_IMG:-} ${ROOT_IMG:-}"
  else
    rm -f "$OUT_PART" ${BOOT_IMG:+"$BOOT_IMG"} ${ROOT_IMG:+"$ROOT_IMG"} ${PCONF:+"$PCONF"}
  fi
  return $rc
}
trap 'cleanup $?' EXIT

(( EUID == 0 )) || { echo "needs root for losetup/mount: sudo -E bash scripts/03-mkimg.sh"; exit 1; }
command -v pacstrap >/dev/null || { echo "need arch-install-scripts"; exit 1; }
[[ -s $REPO/lubancat4.db.tar.zst ]] || { echo "no $REPO, run scripts/01-build.sh then scripts/02-repo.sh"; exit 1; }
[[ -f $PKGLIST ]] || { echo "no $PKGLIST"; exit 1; }
if ! losetup -f >/dev/null 2>&1; then
  echo "no loop device access here (usually a container without block-device write access)"
  echo "run this script from a normal host shell (sudo -E bash scripts/03-mkimg.sh)"
  exit 1
fi

ROOT_SECTSZ=$(( ROOT_MB * 1024 * 1024 / SEC ))
IMG_MB=$(( ( (ROOT_SECT + ROOT_SECTSZ + GPT_BACKUP_RESERVE) * SEC + 1048575 ) / 1048576 ))
echo "layout : loader@0x$(printf %x $LOADER_SECT) container@0x$(printf %x $UBOOT_SECT) boot@0x$(printf %x $BOOT_SECT)(${BOOT_MB}MiB) root@0x$(printf %x $ROOT_SECT)(${ROOT_MB}MiB) image=${IMG_MB}MiB"
# A previously finished $OUT is kept until this run has earned the right to replace it.
mkdir -p "$PORT/dist"
rm -f "$OUT_PART" "$OUT_PART.boot.ext4" "$OUT_PART.rootfs.btrfs"
truncate -s "${IMG_MB}M" "$OUT_PART"

declare -A SUUID
if [[ -s $PORT/dist/last-uuids.env ]]; then
  source "$PORT/dist/last-uuids.env"; SUUID=([uboot]=$UBOOT_UUID [boot]=$BOOT_UUID [root]=$ROOT_UUID)
  echo "reusing partition UUIDs (must match the flashed card)"
else
  for k in uboot boot root; do SUUID[$k]=$(uuidgen); done
fi
UBOOT_UUID=${SUUID[uboot]} BOOT_UUID=${SUUID[boot]} ROOT_UUID=${SUUID[root]}
TY=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
{ printf 'label: gpt\nlabel-id: %s\n' "$(uuidgen)"
  printf 'start=%d, size=%d, type=%s, uuid=%s, name="uboot"\n' $UBOOT_SECT $UBOOT_SECTSZ $TY ${SUUID[uboot]}
  printf 'start=%d, size=%d, type=%s, uuid=%s, name="boot", attrs=LegacyBIOSBootable\n' $BOOT_SECT $BOOT_SECTSZ $TY ${SUUID[boot]}
  printf 'start=%d, size=%d, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=%s, name="rootfs"\n' $ROOT_SECT $ROOT_SECTSZ ${SUUID[root]}
} | sfdisk -q -W never "$OUT_PART"
# U-Boot's bootdev iteration only visits partitions marked legacy_bios_bootable (or of the
# EFI System Partition type); without it bootflow silently skips /boot.
[[ "$(sfdisk --part-attrs "$OUT_PART" 2 2>/dev/null)" == *LegacyBIOSBootable* ]] || {
  echo "partition 2 has no LegacyBIOSBootable attribute"; exit 1; }

BOOT_IMG=$OUT_PART.boot.ext4
ROOT_IMG=$OUT_PART.rootfs.btrfs
dd if=/dev/zero of=$BOOT_IMG bs=$SEC count=$BOOT_SECTSZ status=none
mke2fs -q -F -t ext4 -L lubancat_boot $BOOT_IMG
dd if=/dev/zero of=$ROOT_IMG bs=1M count=$ROOT_MB status=none
mkfs.btrfs -q -f -L lubancat_root -U $ROOT_UUID $ROOT_IMG
BOOT_PU=${BOOT_UUID,,} ROOT_PU=${ROOT_UUID,,}

img=$(mktemp -d); mount -o loop $ROOT_IMG $img
btrfs subvolume create $img/@     >/dev/null
btrfs subvolume create $img/@home >/dev/null
mnt=$(mktemp -d); mount -o loop,compress=zstd:3,subvol=/@ $ROOT_IMG $mnt
mkdir -p $mnt/boot
bootmnt=$(mktemp -d); mount -o loop $BOOT_IMG $bootmnt
# /boot is a separate filesystem, and the packages write into it directly, so it has to be
# mounted at the right place before pacman starts. Bind instead of mounting at $mnt/boot:
# pacman's scriptlets and pacstrap resolve paths through the root.
mount --bind $bootmnt $mnt/boot

# Fail here rather than after 240 MiB of downloads: pacman checks the signature of every ALARM
# package, and a host without the archlinuxarm keyring reports them all as unknown trust /
# corrupt at the very end of the transaction.
[[ -e /usr/share/pacman/keyrings/archlinuxarm.gpg ]] || {
  echo "host has no Arch Linux ARM keyring: /usr/share/pacman/keyrings/archlinuxarm.gpg is missing"
  echo "run: bash scripts/fix-alarm-keyring.sh   (it stages the package and prints the root commands)"
  exit 1
}

# If the repository carries package signatures, pacman will check them while installing, and a
# key that is merely *present* but not trusted fails just as hard as a missing one. Say so
# before downloading 240 MiB. The fingerprint is read out of the signature with --status-fd,
# never out of translated prose.
if compgen -G "$REPO/*.pkg.tar.zst.sig" >/dev/null; then
  sigs=("$REPO"/*.pkg.tar.zst.sig); one=${sigs[0]}   # not "ls | head -1": that pipeline dies of SIGPIPE under pipefail
  # both arguments: gpg only strips one suffix, so "$one" alone would give "no signed data"
  # '|| true': awk stops after the first VALIDSIG, gpg then dies of SIGPIPE, and pipefail would
  # turn that into a silent abort before the message below - the empty-string check is the real test.
  issuer=$(gpg --batch --status-fd 1 --verify "$one" "${one%.sig}" 2>/dev/null |
           awk '/^\[GNUPG:\] VALIDSIG/{print $3; exit}' || true)
  if [[ -z $issuer ]]; then
    echo "cannot read a signature out of $one (gpg itself cannot verify it: import the public key, see BOARD.md)"
    exit 1
  fi
  KDIR=${GnupgDir:-/etc/pacman.d/gnupg}   # same directory pacman.conf names
  if ! gpg --homedir "$KDIR" --list-keys "$issuer" >/dev/null 2>&1; then
    echo "packages are signed with $issuer, but the pacman keyring does not know that key"
    echo "fix: sudo pacman-key --add keys/<that-key>.asc && sudo pacman-key --lsign-key $issuer"
    echo "     keyring: $KDIR"
    echo "     (pacstrap copies that keyring into the image, so the board inherits it)"
    exit 1
  fi
  echo "signing  : $issuer is in the pacman keyring (packages will be verified)"
fi

mapfile -t PACKAGES < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PKGLIST")
echo "install  : ${#PACKAGES[@]} packages from $REPO"

# Target keyring before pacman runs, not after.
#
# The local repository may carry package signatures (scripts/01-build.sh signs when
# LBC_SIGN_KEY is set, scripts/02-repo.sh records them). pacman then verifies them while
# installing, inside the target root, using the target's /etc/pacman.d/gnupg. If "mkq"'s key is
# not there, every one of our packages fails as "invalid or corrupted package (PGP signature)",
# and the only reason the retry succeeds is that the first attempt already installed
# archlinuxarm-keyring, whose hook populates the keyring. Doing it up front removes that
# dependency on attempt order.
#
# pacman-key only needs gpg, which the host has, so --populate-from reads the keyring data the
# packages carry; no aarch64 binary runs on the host. archlinux-keyring and
# archlinuxarm-keyring both land during pacstrap, so the data exists once pacstrap has run;
# running it again afterwards is harmless and covers upgrades.
populate_target_keyring() {
  [[ -d $mnt/usr/share/pacman/keyrings ]] || return 0
  pacman-key --gpgdir "$mnt/etc/pacman.d/gnupg" \
    --populate-from "$mnt/usr/share/pacman/keyrings" --populate archlinux archlinuxarm >/dev/null 2>&1 || true
}

# Signing is optional. When the repository has package signatures, the key that made them has to
# be in the target keyring or pacman rejects every package. Import the public half into the
# target keyring only (no ownertrust needed: SigLevel Optional checks the signature and this is
# a local repository), so a signed repo installs without touching the host keyring.
import_repo_signer() {
  local one issuer
  compgen -G "$REPO/*.pkg.tar.zst.sig" >/dev/null || return 0
  mkdir -p "$mnt/etc/pacman.d/gnupg"
  for one in "$REPO"/*.pkg.tar.zst.sig; do
    issuer=$(gpg --batch --status-fd 1 --verify "$one" "${one%.sig}" 2>/dev/null |
             awk '/^\[GNUPG:\] VALIDSIG/{print $3; exit}' || true)
    [[ -n $issuer ]] || { echo "cannot read a signature out of $one"; exit 1; }
    gpg --homedir "$mnt/etc/pacman.d/gnupg" --list-keys "$issuer" >/dev/null 2>&1 && continue
    if gpg --batch --export "$issuer" 2>/dev/null |
         gpg --homedir "$mnt/etc/pacman.d/gnupg" --batch --import >/dev/null 2>&1; then
      echo "keyring  : imported $issuer into the target keyring (repo signer)"
    else
      echo "packages are signed with $issuer but it is not in the host gpg keyring, so it"
      echo "cannot be exported into the target keyring. Either import the public key on the"
      echo "host (gpg --import <key>.asc) or build without LBC_SIGN_KEY. "
      exit 1
    fi
  done
}
PCONF=$(mktemp)
sed "s|@REPO@|$REPO|" "$PORT/conf/pacman.aarch64.conf.in" > "$PCONF"

# repo-add does not copy packages next to the database, and a file:// server reads them from
# there, so a package that is only in pkg/ installs as "Could not open file". Check that
# before pacman starts fetching hundreds of MiB from the network.
mapfile -t listed < <(tar -xOf "$REPO/lubancat4.db.tar.zst" --wildcards '*/desc' |
                      awk '/^%FILENAME%$/{getline; print}')
# An empty list would make the loop below pass without checking anything, which is the one
# outcome worse than a failure.
(( ${#listed[@]} )) || { echo "no %FILENAME% entries in $REPO/lubancat4.db.tar.zst - run scripts/02-repo.sh"; exit 1; }
bad=0
for f in "${listed[@]}"; do
  [[ -f "$REPO/$f" ]] || { echo "missing in $REPO: $f (run scripts/02-repo.sh)"; bad=1; }
done
(( bad == 0 )) || { rm -f "$PCONF"; exit 1; }

# A dropped download used to abort the whole install. -c makes pacman use the host package
# cache: fetched files then survive a retry (so attempt 2 does not re-download attempt 1), and
# /boot gets filled by the kernel package (Image + every device tree) and by uboot-lubancat4
# (u-boot-rockchip.bin). Measure that out of the packages instead of letting pacman run out of space
# halfway through a transaction - which is what happened with a 128 MiB /boot and 1666 dtbs:
#   错误：分区 .../boot 已用满：需要 172572 个块，可用 107887 个块
# Sizes are read from `tar -tvf` with LC_ALL=C so the date column always splits into the same
# number of fields; only packages in $REPO are looked at, and nothing pulled from the Arch
# Linux ARM mirrors owns /boot (firmware lands in /usr/lib/firmware).
boot_b=0; found_img=0
for pk in "$REPO"/*.pkg.tar.zst; do
  [[ -f $pk ]] || continue
  # \n matters: `read` returns 1 when the last line has no delimiter, and that kills a
  # set -e script even though the variables were assigned correctly.
  # has_img, not img: `img` is the tmpdir the whole btrfs volume is mounted at, and reusing its
  # name here turned "umount $img" into "umount 0" and leaked that mount plus its loop device.
  read -r n has_img < <(LC_ALL=C tar -tvf "$pk" 2>/dev/null |
    awk '$1 ~ /^-/ && $6 ~ /^boot\//{s += $3; if ($6 == "boot/Image") has=1} END{printf "%d %d\n", s+0, has+0}') || true
  boot_b=$(( boot_b + n )); found_img=$(( found_img + has_img ))
done
(( found_img )) || { echo "no package in $REPO owns boot/Image - the kernel is not in the repository"; exit 1; }
BOOT_AVAIL=$(( BOOT_MB * 1048576 ))
echo "boot   : $(( boot_b / 1048576 )) MiB of /boot payload -> ${BOOT_MB} MiB partition ($(( boot_b * 100 / BOOT_AVAIL ))%)"
(( boot_b * 110 / 100 < BOOT_AVAIL )) || {
  echo "/boot would be over 90% full. Either BOOT_MB=512 sudo -E bash scripts/03-mkimg.sh"
  echo "or stop shipping device trees of other vendors (see the dtbs trim in the kernel PKGBUILD)"
  exit 1
}

# they stay out of the image - without -c, pacstrap passes --cachedir=$newroot/var/cache/pacman/pkg
# and every downloaded .pkg.tar.zst ends up baked into the root filesystem.
for try in 1 2 3; do
  # The target keyring is populated after pacstrap, because the keyring data comes from packages
  # installed into the target. When the repository is signed, the signer's public key is put into
  # the target keyring between attempts, so a signed repo does not depend on the first attempt
  # failing and populating it for the retry.
  (( try == 1 )) || { populate_target_keyring; import_repo_signer; }
  # -u: signature verification inside the new root must use that root's keyring, never the host's
  # GnuPG state (and never the identity this repository signs with, which sudo -E may have passed).
  if env -u GNUPGHOME -u GPGAGENTINFO -u GPGKEY \
       pacstrap -C "$PCONF" -c -M "$mnt" "${PACKAGES[@]}"; then
    break
  fi
  if (( try == 3 )); then
    echo "pacstrap failed 3 times - the last error above is the one worth reading"
    echo "if a mirror is the problem, reorder Servers in conf/pacman.aarch64.conf.in and rerun"
    rm -f "$PCONF"; exit 1
  fi
  echo "pacstrap attempt $try failed; retrying in 10 s (already fetched packages are in the host cache)"
  sleep 10
done
rm -f "$PCONF"
# Populate the target keyring from the keyring packages just installed, and make sure the signer of
# the local repository is present too. The board then has a working pacman keyring from first boot,
# and the image only contains packages whose signatures pacman accepted.
populate_target_keyring
import_repo_signer
# The image installs both kernels, so /usr/lib/modules holds more than one directory. One of
# them is the mainline kernel the extlinux template names (@KVER@); depmod runs for all.
mapfile -t KVER_ALL < <(find "$mnt/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
(( ${#KVER_ALL[@]} )) || { echo "no kernel modules under $mnt/usr/lib/modules"; exit 1; }
# The mainline kernel is the one without the -bsp suffix; the BSP package sets LOCALVERSION=-bsp.
# Picking the first entry alphabetically would make "default bsp" whenever 6.12.69-bsp sorts
# before 7.4.0-rc2, which is the opposite of what the template says.
if [[ -n ${LBC_MAIN_KVER:-} ]]; then
  MAIN_KVER=$LBC_MAIN_KVER
else
  mapfile -t _main < <(printf '%s\n' "${KVER_ALL[@]}" | grep -v -- '-bsp$' || true)
  (( ${#_main[@]} )) || { echo "no mainline kernel found under /usr/lib/modules"; exit 1; }
  (( ${#_main[@]} == 1 )) || {
    echo "more than one non-BSP kernel under /usr/lib/modules: ${_main[*]}"
    echo "set LBC_MAIN_KVER=<release> to choose which one the mainline entry names"; exit 1; }
  MAIN_KVER=${_main[0]}
fi
[[ -d $mnt/usr/lib/modules/$MAIN_KVER ]] ||
  { echo "LBC_MAIN_KVER=$MAIN_KVER is not installed"; exit 1; }
echo "kernels  : ${KVER_ALL[*]} (extlinux mainline entry: $MAIN_KVER)"

# pacman-key only needs gpg, which the host has, so the target keyring is initialised here
# instead of by a first-boot script. --populate-from reads the keyring package data that
# pacman just installed; no aarch64 binary runs on this host.
pacman-key --gpgdir "$mnt/etc/pacman.d/gnupg" \
  --populate-from "$mnt/usr/share/pacman/keyrings" --populate archlinux archlinuxarm >/dev/null
(( $(pacman-key --gpgdir "$mnt/etc/pacman.d/gnupg" -l 2>/dev/null | grep -c .) > 20 )) || {
  echo "keyring looks empty after populate"; exit 1; }

# kmod's 60-depmod.hook cannot help here: pacman hands hooks target-relative paths and the
# host must not run depmod for a foreign kernel. Later kernel upgrades on the board are
# covered by that hook on its own. Every installed kernel needs its own depmod run, otherwise
# the modules of the second one have no modules.dep and modprobe finds nothing.
for kver in "${KVER_ALL[@]}"; do
  depmod -b "$mnt" -a "$kver"
  [[ -s $mnt/usr/lib/modules/$kver/modules.dep.bin ]] ||
    { echo "depmod wrote no modules.dep.bin for $kver"; exit 1; }
done

# Per-image identity and mirrors. Deliberately not package content: a package that owns
# /etc/hostname overwrites the board's own edits on every upgrade, and a package that owns
# /etc/pacman.d/mirrorlist collides with pacman-mirrorlist, which makes pacman refuse the
# whole transaction ("/etc/pacman.d/mirrorlist exists in both 'pacman-mirrorlist' and
# 'lubancat4-board-config'"). Writing it here is a local edit, so a later
# pacman-mirrorlist upgrade leaves mirrorlist.pacnew behind, which is how Arch wants it.
install -Dm644 "$PORT/conf/hostname"              "$mnt/etc/hostname"
install -Dm644 "$PORT/conf/locale.conf"            "$mnt/etc/locale.conf"
install -Dm644 "$PORT/conf/mirrorlist.lubancat4"   "$mnt/etc/pacman.d/mirrorlist"
grep -q '^Server' "$mnt/etc/pacman.d/mirrorlist" ||
  { echo "mirrorlist has no active Server line"; exit 1; }

# Root password, so the serial console and ssh ask for one instead of the image autologging in
# or shipping an empty password. The hash is computed on the host and written straight into the
# target /etc/shadow: chpasswd -R tries to run pam_chauthtok() through the target's PAM config,
# which cannot work from a host of another architecture ("Module is unknown") and would need the
# target's pam libraries to be reachable.
[[ -n ${LBC_ROOT_PASSWORD:-root} ]] || { echo "LBC_ROOT_PASSWORD is empty"; exit 1; }
_root_hash=$(printf '%s\n' "${LBC_ROOT_PASSWORD:-root}" |
             openssl passwd -6 -stdin 2>/dev/null) || {
  echo "cannot hash the root password (openssl passwd -6)"; exit 1; }
unset LBC_ROOT_PASSWORD
[[ ${_root_hash:0:3} == '$6$' ]] || { echo "unexpected password hash: $_root_hash"; exit 1; }
awk -v h="$_root_hash" 'BEGIN { FS = OFS = ":"; done = 0 }
  $1 == "root" { $2 = h; done = 1 }
  { print }
  END { exit !done }' "$mnt/etc/shadow" > "$mnt/etc/shadow.new" || {
  rm -f "$mnt/etc/shadow.new"; echo "no root entry in $mnt/etc/shadow"; exit 1; }
chmod 600 "$mnt/etc/shadow.new"
mv -f "$mnt/etc/shadow.new" "$mnt/etc/shadow"
unset _root_hash
[[ $(awk -F: '$1 == "root" { print $2 }' "$mnt/etc/shadow") != '!' ]] ||
  { echo "root is still locked in /etc/shadow"; exit 1; }

# openssh ships PermitRootLogin prohibit-password: root may log in with a key but not with the
# password just set. A drop-in is used rather than editing sshd_config, so a later openssh
# upgrade leaves the shipped file intact. sshd re-reads the whole directory on every start.
install -Dm644 "$PORT/conf/sshd-lubancat4.conf" "$mnt/etc/ssh/sshd_config.d/10-lubancat4.conf"

# Enable services the supported way. Not .wants symlinks baked into a package: those come
# back on the next upgrade after someone runs `systemctl disable` on the board, which
# overrides what the administrator asked for. systemctl against the mounted root writes
# exactly the symlinks the board itself would write.
#
# The serial getty is not enabled here on purpose. console=ttyS2 on the kernel command line
# makes systemd's getty-generator create serial-getty@ttyS2.service already, and root has a
# password (below), so it prompts for one instead of autologging in. That also drops the
# per-baud override lubancat4-board-config used to install: agetty takes the baud from the
# console= parameter, which already says 1500000.
systemctl --root="$mnt" enable systemd-networkd systemd-resolved sshd ||
  { echo "systemctl --root enable failed (is openssh installed?)"; exit 1; }
for u in systemd-networkd.service systemd-resolved.service sshd.service; do
  # Ask systemd instead of looking for a symlink in a directory we guessed. systemd-resolved is
  # wanted by sysinit.target, sshd by multi-user.target and serial-getty@ by getty.target, and
  # those belong to the unit files, not to us: a run died on "not enabled:
  # multi-user.target.wants/systemd-resolved.service" in the same breath in which it had
  # created sysinit.target.wants/systemd-resolved.service. is-enabled also says "masked" for a
  # symlink to /dev/null, so the hand-rolled mask check is not needed either.
  st=$(systemctl --root="$mnt" is-enabled "$u" 2>&1) || true
  [[ $st == enabled ]] || { echo "$u: expected 'enabled', systemd says '$st'"; exit 1; }
  echo "enabled  : $u"
done

# Everything below is per-image data: the two filesystem UUIDs.
DTB=rockchip/rk3588s-lubancat4-npu.dtb
# binman produces one Rockchip boot image: external DDR TPL + SPL + FIT at its
# documented sector-64 offset. Its embedded FIT begins at disk sector 0x4000,
# inside partition 1; the combined image must end before /boot at 16 MiB.
ROCKCHIP_IMG=$bootmnt/u-boot-rockchip.bin
for f in "$ROCKCHIP_IMG" "$bootmnt/Image" "$bootmnt/dtbs/$DTB"; do
  [[ -s $f ]] || { echo "packages did not install $f"; exit 1; }
done
[[ -s "$mnt/etc/ssh/sshd_config.d/10-lubancat4.conf" ]] ||
  { echo "sshd drop-in was not written"; exit 1; }
# Stage the binman image outside the mounts before unmounting them.
STAGE=$(mktemp -d)
cp -L "$ROCKCHIP_IMG" "$STAGE/u-boot-rockchip.bin"
ROCKCHIP_IMG=$STAGE/u-boot-rockchip.bin
(( $(stat -c%s "$ROCKCHIP_IMG") <= (BOOT_SECT - LOADER_SECT) * SEC )) || {
  echo 'binman image overlaps the /boot partition'; exit 1; }
sed -e "s|@BOOT_PU@|$BOOT_PU|" -e "s|@ROOT_PU@|$ROOT_PU|" \
  "$mnt/usr/share/lubancat4/fstab.in" > "$mnt/etc/fstab"
chmod 644 "$mnt/etc/fstab"
mkdir -p "$bootmnt/extlinux"
# Which entry is the default follows the package order, not a hardcoded label: the last of
# linux-lubancat4-git / linux-lubancat4-bsp that pkglist lists wins, because that is the order
# pacstrap installs them and the order the extlinux entries are written below. Editing the
# pkglist is therefore enough to change the default. Runtime changes are explicit through
# lubancat4-set-default and are not tied to package installation order.
BSP_INSTALLED=0
[[ -s $bootmnt/bsp/Image && -s $bootmnt/bsp/dtbs/rockchip/rk3588s-lubancat-4-v1.dtb ]] && BSP_INSTALLED=1
DEFAULT_ENTRY=arch
if (( BSP_INSTALLED )); then
  last_kernel=$(printf '%s\n' "${PACKAGES[@]}" | grep -E '^linux-lubancat4-(git|bsp)$' | tail -1)
  [[ $last_kernel == linux-lubancat4-bsp ]] && DEFAULT_ENTRY=bsp
fi
sed -e "s|@ROOT_PU@|$ROOT_PU|" -e "s|@KVER@|$MAIN_KVER|" -e "s|^default .*|default $DEFAULT_ENTRY|" \
  "$mnt/usr/share/lubancat4/extlinux.conf.in" > "$bootmnt/extlinux/extlinux.conf"
echo "extlinux : default entry is $DEFAULT_ENTRY"
grep -q "fdt /dtbs/$DTB" "$bootmnt/extlinux/extlinux.conf" || {
  echo "extlinux lost its devicetree line"; exit 1; }
grep -q "root=PARTUUID=$ROOT_PU rootflags=subvol=@" "$bootmnt/extlinux/extlinux.conf" || {
  echo "extlinux root= is not the PARTUUID of the new rootfs"; exit 1; }

# Device tree overlays: the replacement for the vendor /uEnv/uEnv.txt + dtfile switch.
# The wanted list lives in /etc/lubancat4/overlays (from lubancat4-board-config, edited
# later on the board with lubancat4-overlay); U-Boot applies each .dtbo to the kernel
# devicetree before booting. Paths are relative to the boot filesystem root.
#
# Two kernels, two overlay sets, two directories. Each list is checked against the directory
# its own entry names, so a mainline overlay can never end up on the BSP tree or vice versa.
add_overlays() {  # $1 = label, $2 = list file, $3 = dtbo dir, $4 = uboot dir
  local label=$1 list=$2 dir=$3 ubootdir=$4 names=() name ovl
  [[ -s $list ]] || return 0
  mapfile -t names < <(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e '/^$/d' "$list")
  (( ${#names[@]} )) || return 0
  ovl="    fdtoverlays"
  for name in "${names[@]}"; do
    [[ -s $dir/$name.dtbo ]] || {
      echo "$list lists $name but $dir/$name.dtbo is not installed"; exit 1; }
    ovl+=" $ubootdir/$name.dtbo"
  done
  # Insert only inside this entry: after its fdt line, before the next label.
  awk -v want="$label" -v line="$ovl" '
    /^[[:space:]]*label[[:space:]]/ { cur = $2 }
    cur != want { print; next }
    /^[[:space:]]*fdtoverlays[[:space:]]/ { next }
    { print }
    !done && /^[[:space:]]*fdt[[:space:]]/ { print line; done = 1 }
    END { if (cur == want && !done) print line }
  ' "$bootmnt/extlinux/extlinux.conf" > "$bootmnt/extlinux/extlinux.conf.new"
  mv "$bootmnt/extlinux/extlinux.conf.new" "$bootmnt/extlinux/extlinux.conf"
}

add_overlays arch "$mnt/etc/lubancat4/overlays"     "$bootmnt/overlays"     /overlays

# Second entry: the Rockchip BSP kernel. Only written when both the kernel and a board tree
# for this board are installed - an entry pointing at a missing file is a boot that ends with
# "no such fdt" and no way back except a card reader.
BSP_IMAGE=$bootmnt/bsp/Image
BSP_DTB=$bootmnt/bsp/dtbs/rockchip/rk3588s-lubancat-4-v1.dtb
if (( BSP_INSTALLED )); then
  BSP_KVER=$(strings "$BSP_IMAGE" | sed -n 's/^Linux version \([^ ]*\) .*/\1/p' | head -1)
  [[ -n $BSP_KVER ]] || BSP_KVER=bsp
  sed -e "s|@ROOT_PU@|$ROOT_PU|" -e "s|@BSP_KVER@|$BSP_KVER|" \
    "$mnt/usr/share/lubancat4/extlinux-bsp.conf.in" >> "$bootmnt/extlinux/extlinux.conf"
  add_overlays bsp "$mnt/etc/lubancat4/overlays-bsp" "$bootmnt/bsp/overlays" /bsp/overlays
  echo "extlinux : mainline + BSP ($BSP_KVER) entries"
else
  echo "extlinux : mainline entry only (no BSP kernel or board tree installed)"
fi

# journald on btrfs: the journal is a preallocated append-only file, so CoW makes each fsync
# rewrite whole extents. Btrfs refuses NOCOW on an existing file, and a new inode only
# inherits the flag from its parent directory, so set it now, before journald writes one.
# https://btrfs.readthedocs.io/en/latest/chattr.html
install -d -m755 "$mnt/var/log/journal"
chattr +C "$mnt/var/log/journal"
[[ $(lsattr -d "$mnt/var/log/journal" | awk '{print $1}') == *C* ]] || {
  echo "NOCOW flag did not stick on /var/log/journal"; exit 1; }
for f in etc/fstab etc/machine-id etc/locale.conf; do
  [[ -e $mnt/$f ]] || { echo "rootfs lacks /$f"; exit 1; }
done

# Both boot stages are the packaged files. They could not be written before pacman ran.
dd if="$ROCKCHIP_IMG" of="$OUT_PART" bs=$SEC seek=$LOADER_SECT conv=notrunc status=none

sync
unmount_all || { echo "close whatever holds the mount (fuser output above) and rerun"; exit 1; }
rmdir $bootmnt $mnt $img
dd if=$BOOT_IMG of="$OUT_PART" bs=$SEC seek=$BOOT_SECT  conv=notrunc status=none
dd if=$ROOT_IMG of="$OUT_PART" bs=$SEC seek=$ROOT_SECT  conv=notrunc status=none
rm -f $BOOT_IMG $ROOT_IMG
printf 'UBOOT_UUID=%s\nBOOT_UUID=%s\nROOT_UUID=%s\n' $UBOOT_UUID $BOOT_UUID $ROOT_UUID > $PORT/dist/last-uuids.env

[[ -s $ROCKCHIP_IMG ]] || { echo "the staged Rockchip boot image is missing before the read-back check"; exit 1; }

# Read the finished artifact back and prove the binman image was written byte for byte.
python3 "$PORT/scripts/check-image.py" "$OUT_PART" $BOOT_SECT $ROOT_SECT $BOOT_MB $ROOT_MB "$ROCKCHIP_IMG"

mv -f "$OUT_PART" "$OUT"; DONE=1
give_back "$OUT" "$PORT/dist/last-uuids.env" "$PORT/dist"
du -sh "$OUT"
# Read back exactly the bytes we wrote: head -c stops at the image size, so a bigger card is
# fine, and a single stream beats dd bs=1 (which took ten minutes to say the same thing).
echo "sha256   : $(sha256sum "$OUT" | cut -d' ' -f1)"
echo "check    : sudo head -c $(stat -c%s "$OUT") /dev/sdX | sha256sum   (after flashing)"
echo "rootfs   : $ROOT_MB MiB (grow it on the board: sfdisk --part-size 3:0, then btrfs filesystem resize max /)"
echo "packages : $(tar -xOf "$REPO/lubancat4.db.tar.zst" --wildcards '*/desc' |
  awk '/^%NAME%$/{getline; printf "%s ", $0}')"
echo "next     : flash it, then 'Growing the root partition' in README.md"
