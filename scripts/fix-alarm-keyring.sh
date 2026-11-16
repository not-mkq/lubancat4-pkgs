#!/usr/bin/env bash
# One place that explains and stages the Arch Linux ARM keyring the host needs.
#
# Why this exists: ALARM builds every package with
#   68B3537F39A313B3E574D06777193F152BDBE6A6  "Arch Linux ARM Build System <builder@archlinuxarm.org>"
# (rsa4096, created 2014-01-18, no expiry). That fingerprint is taken from the keyring
# package's own trust file - /usr/share/pacman/keyrings/archlinuxarm-trusted lists it with
# ownertrust 4 (ultimate) - and the key inside archlinuxarm.gpg hashes to the same value,
# checked locally. pacman's default SigLevel (Required ... TrustedOnly) accepts a signature
# only from a key that is both in the keyring AND trusted, so on a plain Arch host - which
# ships archlinux-keyring only, see /usr/share/pacman/keyrings - every ALARM package fails
# as "signature of unknown trust", which pacman then reports as "package is corrupt". The
# import prompt pacman offers ("import PGP public key 77193F152BDBE6A6?") does not help:
# a key fetched from a keyserver has unknown validity, so the next run fails the same way.
#
# This script does not install anything and does not need root. It downloads the keyring
# package, checks it against the hash in ALARM's own database, and prints the root commands.
set -euo pipefail
export LC_ALL=C          # the output parsed below is machine-readable only in the C locale
MIRROR=${MIRROR:-https://mirrors.ustc.edu.cn/archlinuxarm}
KEYID=77193F152BDBE6A6
FPR=68B3537F39A313B3E574D06777193F152BDBE6A6
WORK=$(mktemp -d /tmp/alarm-keyring.XXXXXX)

echo "workdir: $WORK"
curl -fsSL -m 120 -o "$WORK/core.db" "$MIRROR/aarch64/core/core.db"

# Read the name and the expected hash straight out of the repository database, so the
# download cannot be silently swapped for something else by a bad mirror.
mapfile -t meta < <(python3 - "$WORK/core.db" <<'PY'
import sys, tarfile
tf = tarfile.open(sys.argv[1])
for m in tf.getmembers():
    if m.isdir() or not m.name.endswith("/desc"):
        continue
    if m.name.rsplit("/", 1)[0].rsplit("-", 2)[0] != "archlinuxarm-keyring":
        continue
    L = tf.extractfile(m).read().decode().splitlines()
    g = lambda k: next((L[i + 1] for i, x in enumerate(L) if x.strip() == k), "")
    print(g("%FILENAME%")); print(g("%SHA256SUM%")); break
PY
)
[[ ${#meta[@]} -eq 2 && -n ${meta[0]} ]] || { echo "could not find archlinuxarm-keyring in $MIRROR/aarch64/core"; exit 1; }
file_want=${meta[0]}; sha_want=${meta[1]}

echo "fetching : $file_want"
curl -fsSL -m 120 -o "$WORK/$file_want" "$MIRROR/aarch64/core/$file_want"
echo "sha256   : $(sha256sum "$WORK/$file_want" | cut -d' ' -f1)"
echo "expected : $sha_want"
[[ $(sha256sum "$WORK/$file_want" | cut -d' ' -f1) == "$sha_want" ]] || {
  echo "hash mismatch - refusing to go on"; exit 1; }

tar -xf "$WORK/$file_want" -C "$WORK" usr/share/pacman/keyrings
K=$WORK/usr/share/pacman/keyrings
# Prove the keyring we are about to trust really contains the key ALARM says it does.
# --with-colons is machine-readable and locale-independent; parsing gpg's prose instead broke
# under sudo on a zh_CN host (the sentence is translated, so the fingerprint never matched and
# the variable came back empty).
raw=$(GNUPGHOME=$(mktemp -d) gpg --batch --quiet --with-colons \
        --import-options show-only --import "$K/archlinuxarm.gpg" 2>&1)
have=$(printf '%s\n' "$raw" | awk -F: '$1 == "fpr" { print $10; exit }' || true)  # awk exits early -> SIGPIPE on printf
if [[ -z $have ]]; then
  echo "could not read a fingerprint out of $K/archlinuxarm.gpg; gpg said:"
  printf '%s\n' "$raw"
  exit 1
fi
[[ $have == "$FPR" ]] || { echo "keyring holds $have, expected $FPR"; exit 1; }
grep -q "^$FPR:" "$K/archlinuxarm-trusted" || { echo "$FPR not listed as trusted"; exit 1; }
echo "keyring  : contains $FPR ($KEYID), and its own trust file marks that ultimately trusted"

cat <<EOF

Now run these (root - this is the part that writes the system keyring, so it is yours):

  sudo pacman-key --populate-from $WORK/usr/share/pacman/keyrings archlinuxarm
  sudo pacman -U --needed $WORK/$file_want

--populate-from is the option for exactly this: it loads <name>.gpg and applies <name>-trusted
from any directory, so the chicken-and-egg (the package carrying the key is signed by that
key) breaks without putting untracked files into the filesystem. Do NOT cp the keyring files
into /usr/share/pacman/keyrings first - pacman then refuses the install with "exists in
filesystem", because those files are not owned by any package yet. If they are already there
from an older attempt, remove the three of them before the -U.

Check afterwards:

  gpg --homedir /etc/pacman.d/gnupg --list-keys $KEYID

Then re-run scripts/03-mkimg.sh. If it asks to delete files marked corrupt, answer n - the
downloads are fine, only the signature could not be trusted, and re-downloading changes
nothing until the keyring is in place.
EOF
