#!/usr/bin/env bash
# Build into a new directory, from a clean checkout. Requires PGXS, Go, npm, python -m build, and
# for the language bindings Ruby (gem), Maven, the .NET 8 SDK and Elixir with Hex.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:?pass a new output directory}; mkdir "$out"; out=$(cd "$out" && pwd)
v=$(sed -n "s/^default_version = '\(.*\)'/\1/p" gnomon.control)
export RELEASE_VERSION="$v"
python3 - <<'PY'
import json, os, pathlib, re, tomllib, xml.etree.ElementTree as ET
v = os.environ["RELEASE_VERSION"]
for p in ("sdk/ts", "integrations/node"):
    assert json.loads(pathlib.Path(p,"package.json").read_text())["version"] == v, p
assert tomllib.loads(pathlib.Path("integrations/python/pyproject.toml").read_text())["project"]["version"] == v
def one(path, pattern):
    found = re.findall(pattern, pathlib.Path(path).read_text(), re.M)
    assert found == [v], f"{path}: version {found}, expected {v}"
one("integrations/ruby/gnomon.gemspec", r'^\s*s\.version\s*=\s*"([^"]+)"')
one("integrations/elixir/mix.exs", r'^\s*version:\s*"([^"]+)"')
one("dbt/gnomon_dbt/dbt_project.yml", r'^version:\s*"([^"]+)"')
for p in ("Gnomon", "Gnomon.EntityFrameworkCore", "Gnomon.Xunit"):
    one(f"integrations/dotnet/src/{p}/{p}.csproj", r"<Version>([^<]+)</Version>")
pom = ET.parse("integrations/java/pom.xml").getroot()
assert pom.findtext("{http://maven.apache.org/POM/4.0.0}version") == v, "integrations/java/pom.xml"
PY
for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64; do
  os=${target%/*}; arch=${target#*/}; exe=gnomon; [[ $os != windows ]] || exe+=.exe
  (cd cli && CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags "-s -w -X main.version=$v" -o "$out/$exe" ./cmd/gnomon)
  tar -C "$out" -czf "$out/gnomon_${v}_${os}_${arch}.tar.gz" "$exe"; rm "$out/$exe"
done
tools/build_install_forms.sh
for old in $(sed -n 's/^PREVIOUS_VERSIONS *= *//p' Makefile); do
  tools/build_upgrade.sh "$old"
  cp "sql/gnomon--$old--$v.sql" "build/dist/gnomon-plain--$old--$v.sql" "build/dist/gnomon-pgtle--$old--$v.sql" "$out/"
done
cp "build/dist/gnomon-plain--$v.sql" "build/dist/gnomon-pgtle--$v.sql" "$out/"
(cd sdk/ts && npm ci --no-audit --no-fund && npm pack --pack-destination "$out")
(cd integrations/node && npm pack --pack-destination "$out")
python3 -m build --outdir "$out" integrations/python
# The language bindings, installed as each binding's README says.
(cd integrations/ruby && gem build --silent gnomon.gemspec --output "$out/gnomon-postgres-$v.gem")
mvn -B -q -f integrations/java/pom.xml -Dmaven.test.skip=true clean package
cp "integrations/java/target/gnomon-$v.jar" "$out/"
cp integrations/java/pom.xml "$out/gnomon-$v.pom"
for p in Gnomon Gnomon.EntityFrameworkCore Gnomon.Xunit; do
  dotnet pack "integrations/dotnet/src/$p/$p.csproj" -c Release --nologo -v quiet -o "$out"
done
(cd integrations/elixir && mix hex.build --output "$out/gnomon-elixir-$v.tar")
# Plain archives. Composer's path repository takes the package's root. dbt's tarball install renames
# the one top-level directory to the package's name, and removes it first if it already has that
# name, so the directory is gnomon_dbt-<version>. COPYFILE_DISABLE and --no-xattrs keep macOS
# metadata out of a local build.
export COPYFILE_DISABLE=1
tar --no-xattrs -C integrations/laravel -czf "$out/gnomon-laravel-$v.tar.gz" README.md composer.json phpunit.xml src tests
stage=$(mktemp -d); mkdir "$stage/gnomon_dbt-$v"
cp -R dbt/gnomon_dbt/README.md dbt/gnomon_dbt/dbt_project.yml dbt/gnomon_dbt/macros "$stage/gnomon_dbt-$v/"
tar --no-xattrs -C "$stage" -czf "$out/gnomon-dbt-$v.tar.gz" "gnomon_dbt-$v"; rm -rf "$stage"
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
