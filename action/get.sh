#!/usr/bin/env bash
# Fetch the gnomon CLI for this runner: a released binary, checked against the
# release's checksums; GNOMON_VERSION=source builds it from the checkout (needs Go), which is also
# the fallback when no release exists yet.
set -euo pipefail
out=$1
ver=${GNOMON_VERSION:-latest}
repo=${GNOMON_REPO:-${GITHUB_ACTION_REPOSITORY:-bitsinfra/gnomon}}
os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m)
case "$arch" in x86_64|amd64) arch=amd64;; arm64|aarch64) arch=arm64;; esac
build() {
  command -v go >/dev/null || { echo "gnomon: no release to download and no Go to build with" >&2; exit 1; }
  (cd "$ACTION_PATH/../cli" && go build -trimpath -o "$out" ./cmd/gnomon)
}
if [ "$ver" = source ]; then build; exit 0; fi
if [ "$ver" = latest ]; then
  ver=$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null || true)
  [ -n "$ver" ] || { echo "gnomon: no release found; building from source"; build; exit 0; }
fi
tmp=$(mktemp -d)
asset="gnomon_${ver#v}_${os}_${arch}.tar.gz"
gh release download "$ver" --repo "$repo" --pattern "$asset" --pattern checksums.txt --dir "$tmp"
(cd "$tmp" && grep " $asset\$" checksums.txt | sha256sum -c -)
tar -xzf "$tmp/$asset" -C "$tmp" gnomon
install -m 0755 "$tmp/gnomon" "$out"
"$out" version
