#!/usr/bin/env bash
# Build into a new directory, from a clean checkout. Requires PGXS, Go, npm and python -m build.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:?pass a new output directory}; mkdir "$out"; out=$(cd "$out" && pwd)
v=$(sed -n "s/^default_version = '\(.*\)'/\1/p" gnomon.control)
export RELEASE_VERSION="$v"
python3 - <<'PY'
import json, os, pathlib, tomllib
v = os.environ["RELEASE_VERSION"]
for p in ("sdk/ts", "integrations/node"):
    assert json.loads(pathlib.Path(p,"package.json").read_text())["version"] == v, p
assert tomllib.loads(pathlib.Path("integrations/python/pyproject.toml").read_text())["project"]["version"] == v
PY
for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64; do
  os=${target%/*}; arch=${target#*/}; exe=gnomon; [[ $os != windows ]] || exe+=.exe
  (cd cli && CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags "-s -w -X main.version=$v" -o "$out/$exe" ./cmd/gnomon)
  tar -C "$out" -czf "$out/gnomon_${v}_${os}_${arch}.tar.gz" "$exe"; rm "$out/$exe"
done
tools/build_install_forms.sh
tools/build_upgrade.sh 1.0.0
cp "sql/gnomon--1.0.0--$v.sql" "build/dist/gnomon-plain--1.0.0--$v.sql" "build/dist/gnomon-pgtle--1.0.0--$v.sql" "$out/"
cp "build/dist/gnomon-plain--$v.sql" "build/dist/gnomon-pgtle--$v.sql" "$out/"
(cd sdk/ts && npm ci --no-audit --no-fund && npm pack --pack-destination "$out")
(cd integrations/node && npm pack --pack-destination "$out")
python3 -m build --outdir "$out" integrations/python
python3 - "$out" "$v" <<'PY'
import hashlib, pathlib, sys
out = pathlib.Path(sys.argv[1])
v = sys.argv[2]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
base = f"https://github.com/bitsinfra/gnomon/releases/download/v{v}"
lines = ['class Gnomon < Formula', '  desc "CLI for versioning data inside PostgreSQL"', '  homepage "https://gnomon.bitsinfra.com/"', f'  version "{v}"', '  license "PostgreSQL"']
for os, brew_os in [('darwin','macos'), ('linux','linux')]:
    lines.append(f'  on_{brew_os} do')
    for arch, brew_arch in [('arm64','arm'), ('amd64','intel')]:
        f = f'gnomon_{v}_{os}_{arch}.tar.gz'
        lines += [f'    on_{brew_arch} do', f'      url "{base}/{f}"', f'      sha256 "{sha(out/f)}"', '    end']
    lines.append('  end')
lines += ['  def install', '    bin.install "gnomon"', '  end', '  test do', '    assert_equal "gnomon #{version}", shell_output("#{bin}/gnomon version").strip', '  end', 'end']
(out/'gnomon.rb').write_text('\n'.join(lines)+'\n')
checks = ''.join(f'{sha(p)}  {p.name}\n' for p in sorted(out.iterdir()))
(out/'checksums.txt').write_text(checks)
PY
