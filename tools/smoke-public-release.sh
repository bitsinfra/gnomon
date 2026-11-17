#!/usr/bin/env bash
# Check the installation guide against public artifacts, never local builds or registry credentials.
# Requires Docker, Node 22.6+, Python 3.11+, curl and shasum. Pass a version, or use gnomon.control.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
version=${1:-$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$root/gnomon.control")}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a release version, got: $version" >&2; exit 1; }
scratch=$(mktemp -d)
containers=()
cleanup() {
  for container in ${containers[@]+"${containers[@]}"}; do
    docker rm -fv "$container" >/dev/null 2>&1 || true
  done
  rm -rf "$scratch"
}
trap cleanup EXIT

# Keep the selected Docker daemon, but use an empty config so GHCR pulls are anonymous.
export DOCKER_HOST=${DOCKER_HOST:-$(docker context inspect --format '{{(index .Endpoints "docker").Host}}')}
export DOCKER_CONFIG="$scratch/docker"
unset DOCKER_CONTEXT
mkdir "$DOCKER_CONFIG"
cd "$scratch"
fetch() { curl -q --fail --silent --show-error --location --retry 5 --retry-all-errors --retry-delay 2 --max-time 120 "$1" -o "$2"; }
base="https://github.com/bitsinfra/gnomon/releases/download/v$version"
os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m)
case "$arch" in arm64|aarch64) arch=arm64;; x86_64) arch=amd64;; esac
archive="gnomon_${version}_${os}_${arch}.tar.gz"
files=("$archive" "gnomon-plain--$version.sql" "gnomon-pgtle--$version.sql")
fetch "$base/checksums.txt" checksums.txt
for file in "${files[@]}"; do
  fetch "$base/$file" "$file"
  awk -v file="$file" '$2 == file { print; found = 1 } END { if (!found) exit 1 }' checksums.txt > selected-checksum.txt
  shasum -a 256 -c selected-checksum.txt
done
tar -xzf "$archive"
test "$(./gnomon version)" = "gnomon $version"

# Both module tags must resolve through the public Go proxy, as the documented go install does.
for module in cli integrations/go; do
  fetch "https://proxy.golang.org/github.com/bitsinfra/gnomon/$module/@v/v$version.info" go-version.json
done

# The guide's unpinned installs must give users the same version as the CLI and SQL downloads.
# Registries can accept publication before their install indexes update. Retry actual installs in
# fresh projects: metadata endpoints can show the new version while npm/pip still install the old.
# Each command propagates failures explicitly because this function is called in an until condition.
install_sdks() (
install=$(mktemp -d "$scratch/sdks.XXXXXX") || return
cd "$install" || return
mkdir npm || return
(
  cd npm || return
  export NPM_CONFIG_USERCONFIG="$scratch/npmrc" NPM_CONFIG_GLOBALCONFIG="$scratch/global-npmrc"
  export NPM_CONFIG_CACHE="$install/npm-cache"
  touch "$NPM_CONFIG_USERCONFIG" "$NPM_CONFIG_GLOBALCONFIG" || return
  npm init -y >/dev/null || return
  npm install --registry=https://registry.npmjs.org --no-audit --no-fund @bitsinfra/gnomon @bitsinfra/gnomon-postgres || return
  node --input-type=module - "$version" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Gnomon } from '@bitsinfra/gnomon';
import { nodePostgres } from '@bitsinfra/gnomon/pg';
import { createRequire } from 'node:module';
const binding = createRequire(import.meta.url)('@bitsinfra/gnomon-postgres');
for (const name of ['gnomon', 'gnomon-postgres']) {
  const pkg = JSON.parse(readFileSync(`node_modules/@bitsinfra/${name}/package.json`, 'utf8'));
  assert.equal(pkg.version, process.argv[2]);
}
for (const fn of [Gnomon, nodePostgres, binding.branchOptions]) assert.equal(typeof fn, 'function');
JS
) || return
python3 -m venv venv || return
venv/bin/python -m pip --isolated install --no-cache-dir --disable-pip-version-check --index-url https://pypi.org/simple gnomon-postgres || return
venv/bin/python -I - "$version" <<'PY'
import sys
from importlib.metadata import version
from gnomon import Gnomon
assert version('gnomon-postgres') == sys.argv[1]
assert callable(Gnomon)
PY
)
deadline=$((SECONDS + 600))
until install_sdks; do
  if (( SECONDS >= deadline )); then
    echo "Public SDK installs did not pass for $version within ten minutes" >&2
    exit 1
  fi
  echo "Waiting for public SDK installs of $version; retrying in 15 seconds"
  sleep 15
done

start_database() {
  local image=$1
  docker pull "$image"
  container=$(docker run -d -e POSTGRES_PASSWORD=public-install-test "$image")
  containers+=("$container")
  for i in {1..60}; do
    if docker exec "$container" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then return; fi
    sleep 1
  done
  docker logs "$container" >&2
  return 1
}
quickstart() {
  docker exec -i "$container" psql -X -U postgres -v ON_ERROR_STOP=1 <<'SQL'
create function pg_temp.check_result(ok boolean, message text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception '%', message; end if;
end $$;
create table orders (id integer primary key, status text not null);
insert into orders values (4182, 'paid');
select gnomon.track('orders');
select gnomon.create_branch('agent/refunds');
select gnomon.use('agent/refunds');
update orders set status = 'refunded' where id = 4182;
select pg_temp.check_result((select status = 'refunded' from orders where id = 4182), 'branch sees its write');
select pg_temp.check_result((select count(*) = 1 from gnomon.diff('agent/refunds')), 'diff shows one changed field');
select gnomon.use('main');
select pg_temp.check_result((select status = 'paid' from orders where id = 4182), 'main stays unchanged before merge');
select gnomon.merge('agent/refunds') as merge_id \gset
select pg_temp.check_result((select status = 'refunded' from orders where id = 4182), 'merge updates main');
select gnomon.undo_merge(:merge_id);
select pg_temp.check_result((select status = 'paid' from orders where id = 4182), 'undo restores main');
SQL
}

start_database "ghcr.io/bitsinfra/gnomon/postgres:v$version"
test "$(docker exec "$container" gnomon version)" = "gnomon $version"
test "$(docker exec "$container" psql -X -At -U postgres -c "select extversion from pg_extension where extname = 'gnomon'")" = "$version"
quickstart

# Install the public plain-SQL file on stock Postgres with no Gnomon extension files or C module.
start_database postgres:18-bookworm
docker exec -i "$container" psql -X -q -U postgres -v ON_ERROR_STOP=1 < "gnomon-plain--$version.sql"
quickstart
echo "public install: Gnomon $version downloads, registries, anonymous image and quickstarts passed"
