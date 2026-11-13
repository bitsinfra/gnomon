#!/usr/bin/env bash
# Use the release files as a consumer would, with no source checkout on the import path. Needs Node,
# Python, Ruby, a JDK with Maven, the .NET 8 SDK, PHP with Composer, and Elixir.
set -euo pipefail
out=$(cd "${1:?release directory}" && pwd)
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
(cd "$out" && shasum -a 256 -c checksums.txt)
cd "$scratch"
os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m)
case "$arch" in arm64|aarch64) arch=arm64;; x86_64) arch=amd64;; esac
tar -xzf "$out"/gnomon_*_"${os}_${arch}".tar.gz
v=$(./gnomon version); ver=${v#gnomon }; test -f "$out/gnomon_${ver}_${os}_${arch}.tar.gz"
npm init -y >/dev/null
npm install --no-audit --no-fund "$out"/*.tgz
node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { Gnomon } from '@bitsinfra/gnomon';
import { nodePostgres } from '@bitsinfra/gnomon/pg';
import { claudeAgentServer } from '@bitsinfra/gnomon/claude-agent';
import { createRequire } from 'node:module';
const binding = createRequire(import.meta.url)('@bitsinfra/gnomon-postgres');
for (const fn of [Gnomon, nodePostgres, claudeAgentServer, binding.branchOptions]) assert.equal(typeof fn, 'function');
JS
python3 -m venv venv
venv/bin/python -m pip install --disable-pip-version-check 'psycopg[binary]' "$out"/*.whl
venv/bin/python -I -c 'from gnomon import Gnomon; from gnomon.tools import TOOL_SPECS; assert any(t["name"] == "diff" for t in TOOL_SPECS)'

# The language bindings, from the release files as their READMEs install them. Each puts a session
# on the branch "smoke" and checks the options it builds; no database is needed.

# Ruby: the gem's own files (gnomon.rb doesn't load pg, so pg isn't compiled here)
gem install --silent --local --ignore-dependencies --no-document --install-dir gems "$out/gnomon-postgres-$ver.gem"
ruby -I "gems/gems/gnomon-postgres-$ver/lib" -e 'require "gnomon"; abort "ruby" unless Gnomon.branch_options("smoke").include?("gnomon.branch=smoke")'

# Java: the jar and pom into a Maven repository, then the jar from there
mvn -B -q -Dmaven.repo.local="$scratch/m2" install:install-file -Dfile="$out/gnomon-$ver.jar" -DpomFile="$out/gnomon-$ver.pom"
jar="$scratch/m2/dev/gnomon/gnomon/$ver/gnomon-$ver.jar"
mkdir java && cat > java/Smoke.java <<'JAVA'
public class Smoke {
  public static void main(String[] a) {
    if (!dev.gnomon.Gnomon.jdbcUrl("jdbc:postgresql://db/app", "smoke", false).contains("gnomon.branch%3Dsmoke")) System.exit(1);
  }
}
JAVA
javac -d java -cp "$jar" java/Smoke.java && java -cp "$jar:java" Smoke

# .NET: the three packages from the release directory as a local source, in a cache of their own
(
  export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 NUGET_PACKAGES="$scratch/nuget"
  dotnet new console -o dotnet >/dev/null && cd dotnet
  dotnet new nugetconfig >/dev/null
  dotnet nuget add source "$out" --name release --configfile nuget.config >/dev/null
  for p in Gnomon Gnomon.EntityFrameworkCore Gnomon.Xunit; do dotnet add package "$p" --version "$ver" >/dev/null; done
  cat > Program.cs <<'CS'
if (!Gnomon.GnomonDb.ConnectionString("Host=db;Database=app", "smoke").Contains("gnomon.branch=smoke")) return 1;
_ = typeof(Gnomon.EntityFrameworkCore.GnomonBranchInterceptor);
_ = typeof(Gnomon.Xunit.GnomonBranchFixture);
return 0;
CS
  dotnet run
)

# PHP: the Composer package unpacked into the application, as a path repository
mkdir -p php/packages/gnomon && tar -xzf "$out/gnomon-laravel-$ver.tar.gz" -C php/packages/gnomon
(
  cd php && export COMPOSER_HOME="$scratch/composer" && echo '{}' > composer.json
  composer config repositories.gnomon "{\"type\": \"path\", \"url\": \"packages/gnomon\", \"options\": {\"versions\": {\"gnomon/gnomon\": \"$ver\"}}}"
  composer require -q --no-interaction "gnomon/gnomon:$ver"
  php -r 'require "vendor/autoload.php"; exit(str_contains(Gnomon\Gnomon::dsn("pgsql:host=db;dbname=app", "smoke"), "gnomon.branch=smoke") ? 0 : 1);'
)

# Elixir: the Hex package's contents as a path dependency
mkdir -p elixir/gnomon elixir/app && tar -xOf "$out/gnomon-elixir-$ver.tar" contents.tar.gz | tar -xz -C elixir/gnomon
tar -xOf "$out/gnomon-elixir-$ver.tar" metadata.config | grep -qF "{<<\"version\">>,<<\"$ver\">>}"
cat > elixir/app/mix.exs <<'EX'
defmodule Smoke.MixProject do
  use Mix.Project
  def project, do: [app: :smoke, version: "0.1.0", deps: [{:gnomon, path: "../gnomon"}]]
end
EX
(cd elixir/app && mix run -e 'unless Gnomon.connect_opts([], "smoke")[:parameters][:"gnomon.branch"] == "smoke", do: System.halt(1)')

# dbt: its tarball install takes the common prefix of the names as the package's directory and
# renames it to gnomon_dbt, removing a directory of that name first (dbt_common untar_package)
python3 -I - "$out/gnomon-dbt-$ver.tar.gz" "$ver" <<'PY'
import os, sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as t:
    names = t.getnames()
    top = os.path.commonprefix(names).rstrip("/")
    assert top and "/" not in top and top != "gnomon_dbt", f"top-level directory {top!r}"
    project = t.extractfile(f"{top}/dbt_project.yml").read().decode()
assert f'version: "{sys.argv[2]}"' in project, project
PY
echo "smoke: every release file installs and loads"
