#!/usr/bin/env bash
# install.sh – install the getdr binary from GitHub Releases.
# Part of the getdr skill by Index Pages: https://index-pages.com/getdr
#
# Usage: install.sh [VERSION]          default VERSION: 0.1.0
#        PREFIX=/usr/local install.sh  installs to $PREFIX/bin (default ~/.local/bin)
#
# Downloads getdr_<version>_<os>_<arch>.tar.gz and checksums.txt, verifies the
# SHA-256 of the archive, extracts only the getdr binary and copies it into
# place. Nothing downloaded is executed. Linux and macOS, amd64 and arm64; on
# Windows take the zip from the Releases page.
#
# Needs bash, curl, tar and sha256sum or shasum.

set -eu

RELEASES_URL="https://github.com/index-pages/getdr/releases/download"

version=${1:-0.1.0}
version=${version#v}
dest=${PREFIX:-$HOME/.local}/bin

die() {
	printf 'install.sh: %s\n' "$*" >&2
	exit 1
}

case $version in
*[!0-9A-Za-z.-]* | "") die "invalid version \"$version\"" ;;
esac

case $(uname -s) in
Linux) os=linux ;;
Darwin) os=darwin ;;
*) die "unsupported OS $(uname -s); download getdr from https://index-pages.com/getdr" ;;
esac
case $(uname -m) in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) die "unsupported CPU $(uname -m); download getdr from https://index-pages.com/getdr" ;;
esac

command -v curl >/dev/null 2>&1 || die "needs curl"
command -v tar >/dev/null 2>&1 || die "needs tar"
if command -v sha256sum >/dev/null 2>&1; then
	sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
	sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
	die "needs sha256sum or shasum"
fi

archive=getdr_${version}_${os}_${arch}.tar.gz
base=$RELEASES_URL/v$version
tmp=$(mktemp -d "${TMPDIR:-/tmp}/getdr-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fetch() {
	curl -q -fsSL --proto '=https' --tlsv1.2 --max-time 120 -o "$tmp/$2" "$1" ||
		die "download failed: $1"
}
echo "downloading $base/$archive"
fetch "$base/$archive" "$archive"
fetch "$base/checksums.txt" checksums.txt

want=$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1 }' "$tmp/checksums.txt")
[ -n "$want" ] || die "$archive is not listed in checksums.txt"
got=$(sha256 "$tmp/$archive")
[ "$got" = "$want" ] || die "checksum mismatch for $archive: expected $want, got $got"
echo "checksum ok"

mkdir "$tmp/x"
tar -xzf "$tmp/$archive" -C "$tmp/x" getdr || die "no getdr binary in $archive"
if [ ! -f "$tmp/x/getdr" ] || [ -L "$tmp/x/getdr" ]; then die "no getdr binary in $archive"; fi

mkdir -p "$dest"
cp "$tmp/x/getdr" "$dest/getdr.new"
chmod 0755 "$dest/getdr.new"
mv -f "$dest/getdr.new" "$dest/getdr"
echo "installed $dest/getdr ($version)"

case ":$PATH:" in
*":$dest:"*) ;;
*) echo "note: $dest is not on your PATH; add it to use getdr from anywhere" ;;
esac
