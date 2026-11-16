#!/usr/bin/env bash
# Turn pkg/*.pkg.tar.zst into a pacman repository that pacstrap can install from.
set -euo pipefail
PORT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PORT"
shopt -s nullglob
pkgs=(pkg/*.pkg.tar.zst)
(( ${#pkgs[@]} )) || { echo "nothing in pkg/, run scripts/01-build.sh"; exit 1; }
mkdir -p repo
command -v vercmp >/dev/null || { echo "vercmp missing (pacman-contrib? no, it ships with pacman)"; exit 1; }

# Which package is an artifact? Ask the artifact, not its filename. Filenames are a convention;
# .PKGINFO is what pacman reads. Prefix-matching filenames is exactly how the rename bit us:
# "linux-lubancat4" is a prefix of "linux-lubancat4-git", so the new kernel was pruned as if it
# were the retired package, and the freshly built database then listed files that had just been
# deleted. || true because awk's 'exit' can leave tar holding a broken pipe, and a 141 from a
# command substitution would end this script under set -e.
name_of() { tar -xOf "$1" .PKGINFO 2>/dev/null | awk -F' = ' '/^pkgname/{print $2; exit}' || true; }
ver_of()  { tar -xOf "$1" .PKGINFO 2>/dev/null | awk -F' = ' '/^pkgver/{print $2; exit}' || true; }
rel_of()  { tar -xOf "$1" .PKGINFO 2>/dev/null | awk -F' = ' '/^pkgrel/{print $2; exit}' || true; }
RETIRED=(linux-lubancat4)

declare -A KEEP_OF          # package name -> the one artifact of it that this repo will ship
for pk in "${pkgs[@]}"; do
  n=$(name_of "$pk")
  [[ -n $n ]] || { echo "$pk: cannot read pkgname from .PKGINFO"; exit 1; }
  if [[ " ${RETIRED[*]} " == *" $n "* ]]; then
    rm -f "$pk" "$pk.sig"; echo "drop     : $(basename "$pk") ($n is retired)"; continue
  fi
  cur=${KEEP_OF[$n]:-}
  if [[ -z $cur ]]; then KEEP_OF[$n]=$pk; continue; fi
  if [[ $(vercmp "$(ver_of "$pk")" "$(ver_of "$cur")") -gt 0 ]] ||
     { [[ $(vercmp "$(ver_of "$pk")" "$(ver_of "$cur")") -eq 0 ]] &&
       [[ $(vercmp "$(rel_of "$pk")" "$(rel_of "$cur")") -ge 0 ]]; }; then
    rm -f "$cur" "$cur.sig"; echo "drop     : $(basename "$cur") (superseded by $(basename "$pk"))"
    KEEP_OF[$n]=$pk
  else
    rm -f "$pk" "$pk.sig"; echo "drop     : $(basename "$pk") (older than $(basename "$cur"))"
  fi
done
pkgs=()
for n in "${!KEEP_OF[@]}"; do pkgs+=("${KEEP_OF[$n]}"); done
(( ${#pkgs[@]} )) || { echo "every artifact in pkg/ was dropped; nothing to publish"; exit 1; }
mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort)

# A .sig that does not verify against the artifact actually going out is an orphan of a build that
# no longer exists, and this happened for real: the kernel was rebuilt unsigned at the SAME version
# and filename (7.4.0.rc2.r1506753-1), so nothing was "superseded" by name and the dedupe above
# never ran, yet the signature left next to it belonged to the signed build it replaced. Keeping it
# means a hard failure here, or a database that records a signature pacman rejects at install time.
# Drop it, say so, and let the counts below report a repository with zero signatures.
for pk in "${pkgs[@]}"; do
  [[ -f "$pk.sig" ]] || continue
  if ! gpg --batch --status-fd 1 --verify "$pk.sig" "$pk" 2>/dev/null | grep -q '^\[GNUPG:\] GOODSIG'; then
    rm -f "$pk.sig"
    echo "drop     : $(basename "$pk").sig (orphan: does not verify against the artifact beside it)"
  fi
done

# The database is rebuilt from these files on every run rather than patched. repo-add only ever
# adds, so an incremental database keeps entries for packages that no longer exist - which is
# what produced "file not found" for a database naming a kernel we had just deleted.
rm -f repo/lubancat4.db repo/lubancat4.files repo/lubancat4.db.tar.zst* repo/lubancat4.files.tar.zst*
# repo-add only records the filename in the database; it does not copy anything. For a
# file:// server pacman then reads each package out of the directory that holds the database,
# so a package that lives only in pkg/ is invisible at install time - and pacman notices that
# only at the end, after downloading everything else (this is exactly how a pacstrap run dies
# with "Could not open file .../repo/linux-lubancat4-git-...pkg.tar.zst"). Hardlink first, since
# the kernel package is 70 MB on the same filesystem; fall back to a copy across filesystems.
rm -f repo/*.pkg.tar.zst repo/*.pkg.tar.zst.sig
for pk in "${pkgs[@]}"; do
  ln "$pk" "repo/$(basename "$pk")" 2>/dev/null || cp "$pk" "repo/$(basename "$pk")"
  # A package signature is only usable from a repository if it is either next to the file or
  # recorded in the database; --include-sigs below does the latter, and the copy keeps
  # "gpg --verify <file>.sig <file>" working by hand.
  [[ -f "$pk.sig" ]] && { ln "$pk.sig" "repo/$(basename "$pk").sig" 2>/dev/null || cp "$pk.sig" "repo/$(basename "$pk").sig"; }
done

# repo-add's man page: --include-sigs includes the package PGP signatures in the database,
# which is what pacman verifies. Without it the .sig files sit next to the packages unused.
REPO_ARGS=()
shopt -s nullglob
sigs=(pkg/*.pkg.tar.zst.sig)
# Check every signature against the exact file it is supposed to cover before any of it goes
# into the database. Both arguments are required: 'gpg --verify X.sig' alone fails with
# "no signed data" for names ending in .tar.zst.sig, because gpg only strips one suffix.
for sg in "${sigs[@]}"; do
  pk=${sg%.sig}
  if ! gpg --batch --status-fd 1 --verify "$sg" "$pk" 2>/dev/null | grep -q '^\[GNUPG:\] GOODSIG'; then
    echo "signature $sg does not verify against $(basename "$pk") - rebuild signed (scripts/01-build.sh)"
    exit 1
  fi
  echo "pkg sig  : $(basename "$pk") <- $(gpg --batch --status-fd 1 --verify "$sg" "$pk" 2>/dev/null | awk '/VALIDSIG/{print substr($3,33,16); exit}')"
done
if (( ${#sigs[@]} )); then
  REPO_ARGS+=(--include-sigs)
  echo "sigs     : ${#sigs[@]} package signatures will be recorded"
fi
# -s signs the database itself with GPGKEY/-k. Our repo config is DatabaseOptional, so this is
# belt and braces, but it is what makes a copied repo directory tamper-evident.
if [[ -n ${LBC_SIGN_KEY:-} ]]; then
  export GPGKEY="$LBC_SIGN_KEY"
  REPO_ARGS+=(-s -k "$LBC_SIGN_KEY")
  echo "db       : will be signed by $LBC_SIGN_KEY"
fi

repo-add "${REPO_ARGS[@]}" repo/lubancat4.db.tar.zst "${pkgs[@]}"
echo "added    : ${pkgs[*]/*\//}"
echo "repo     : $PORT/repo"
ls -l repo/
echo "packages : $(tar -xOf repo/lubancat4.db.tar.zst --wildcards '*/desc' |
  awk '/^%NAME%$/{getline; printf "%s ", $0}')"

# Same check scripts/03-mkimg.sh runs, so an inconsistency is caught here rather than in the
# middle of a 500 MiB install. tar is run once, output reused, because it is the same archive.
mapfile -t listed < <(tar -xOf repo/lubancat4.db.tar.zst --wildcards '*/desc' |
  awk '/^%FILENAME%$/{getline; print}')
bad=0
for f in "${listed[@]}"; do
  [[ -f "repo/$f" ]] || { echo "database lists $f but repo/ has no such file"; bad=1; }
done
(( bad == 0 )) || { echo "repository is inconsistent"; exit 1; }
# repo-add keeps "<db>.tar.zst.old" (and its .sig) behind. A stale signature sitting in the
# directory we serve is exactly the orphan that gets mistaken for a current one, so drop them.
rm -f repo/*.old repo/*.old.sig

echo "verified : ${#listed[@]} files listed in the database are all present in repo/"

if (( ${#sigs[@]} )); then
  n=$(tar -xOf repo/lubancat4.db.tar.zst --wildcards '*/desc' | grep -c '^%PGPSIG%$' || true)  # grep -c exits 1 on zero hits
  echo "in db    : $n %PGPSIG% entries (one per signed package)"
  (( n == ${#sigs[@]} )) || { echo "expected ${#sigs[@]} signatures in the database"; exit 1; }
fi
if [[ -s repo/lubancat4.db.tar.zst.sig ]]; then
  if gpg --batch --status-fd 1 --verify repo/lubancat4.db.tar.zst.sig repo/lubancat4.db.tar.zst 2>/dev/null |
     grep -q '^\[GNUPG:\] GOODSIG'; then
    echo "db sig   : good ($(gpg --batch --status-fd 1 --verify repo/lubancat4.db.tar.zst.sig repo/lubancat4.db.tar.zst 2>/dev/null |
      awk '/VALIDSIG/{print substr($3,33,40); exit}'))"
  else
    echo "db sig   : present but cannot be verified with this keyring (import the key, see BOARD.md)"
  fi
fi
