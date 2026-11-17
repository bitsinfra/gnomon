# Contributing to Gnomon

Bug reports, fixes, documentation and new integrations are welcome. For anything larger than a
fix, open an issue first so the approach can be agreed before you write it.

## Setting up

You need PostgreSQL 15-18 with its server headers (`pg_config` on the `PATH`), Go for the CLI,
and, for the SDKs and bindings, the language toolchains you want to test. On macOS, keep `LC_ALL`
set (`en_US.UTF-8`): the postmaster refuses to start without a valid locale.

```bash
make                           # sql/gnomon--<version>.sql from src/sql
make dev                       # install it into build/ext for the dev cluster
tools/devcluster.sh start      # a throwaway cluster in build/pgdata (port 54329)
make -C src/c                  # the optional C module
(cd cli && go build -o gnomon ./cmd/gnomon)
```

## Running the tests

The SQL and C suites share the dev clusters, so run them one at a time.

```bash
make test                      # SQL suites + shell tests (history checker, concurrency, dump/restore, ...)
src/c/test/run.sh              # the same suite with the C module loaded, plus the module's own tests
tools/matrix.sh 15             # either suite on another PostgreSQL major (15-18)
(cd cli && go test ./...)      # CLI, MCP agent flow, archiver, sinks
bash action/test.sh            # the GitHub Action's script
(cd sdk/ts && npm install && npm test)   # the TypeScript SDK; GNOMON_SDK_PORT=54330 for the C module
(cd integrations/node && npm install && npm test)   # node-postgres, Prisma and Drizzle
(cd integrations/go && go test ./...)    # the Go binding
integrations/java/test.sh      # the Java binding (javac and the JUnit jars in ~/.m2; or mvn test)
integrations/elixir/test.sh    # the Elixir binding
rspec -I integrations/ruby/lib integrations/ruby/spec   # with pg, rspec and activerecord installed
examples/tutorial.sh shop      # the tutorial as written (a database seeded with examples/shop.sql)
```

The Python package and its tests:

```bash
python3 -m venv build/venv
build/venv/bin/pip install -e 'integrations/python[sqlalchemy,django,asyncpg,test]'
build/venv/bin/python -m pytest integrations/python/tests
```

`test/run.sh 03_merge` runs the suites whose names match. The shell tests in `test/shell/` start
throwaway clusters of their own where they need them (standbys, pg_upgrade, logical cutover,
poolers, pg_tle, the other language bindings) and skip, saying why, when a tool they need is not
installed. The three that reach outside PostgreSQL — `bindings.sh` (the Java, Elixir, .NET and
PHP toolchains), `kafka.sh` (brokers in Docker) and `dbt.sh` (a dbt install) — also skip when
`GNOMON_SKIP_EXTERNAL` is set, which is how CI runs them in steps of their own.
`.github/workflows/ci.yml` runs the same scripts.

## Conventions

- **SQL.** `src/sql/*.sql` is concatenated in file order into the install script. Every SQL test
  runs twice in CI, in the SQL core and with the C module, so a change must keep both passing.
  SQL-language functions must not call a gnomon function defined in a later file (the plain-SQL
  install form checks function bodies): `python3 tools/check_forward_refs.py`.
- **Catalog changes.** New catalog tables go in `src/sql/05_catalog_features.sql`, written
  `IF NOT EXISTS`, which upgrades include whole. Any other change to a table, type or sequence
  needs a migration in `src/upgrade` ([src/upgrade/README.md](src/upgrade/README.md)).
- **Errors.** Every `raise exception` carries a stable `[gnomon:<slug>]` in its hint:
  `python3 tools/add_error_slugs.py` adds missing ones, and `python3 tools/error_codes.py --write`
  regenerates the error table in [docs/errors.md](docs/errors.md).
- **Python SDK.** `integrations/python/gnomon/client.py` is generated from `aio.py`: edit `aio.py`
  and run `python3 tools/unasync.py`.
- **Go.** `gofmt` and `go vet`.
- **Comments and docs.** Plain prose that says what the code does and why. Update
  [docs/sql-reference.md](docs/sql-reference.md) and the other docs in the same change as the
  behaviour.

## The documentation site

The pages in `docs/` are the site at <https://gnomon.bitsinfra.com/>. Each one is ordinary
Markdown that starts with a single `# Title`; the SDK, binding and Action READMEs are pages too,
mapped in `docs/tooling/navigation.mjs`, which is also where the sidebar lives. Add a page by
writing the file and naming it there.

```bash
cd docs
npm install
npm run dev        # http://localhost:3000, reloading as you write
npm run build      # a static site in docs/out/, as CI builds it
npm run preview    # serve that build
```

Links between pages are relative paths to the real files (`../action/README.md`,
`sql-reference.md`): they work on GitHub, and the build rewrites them to site URLs.

## Pull requests

Keep a pull request to one change, with the tests that show it working, and describe what it
changes for users. CI must pass on every PostgreSQL major it runs. Performance changes should say
which `bench/` script measured them and how (see [docs/benchmarks.md](docs/benchmarks.md) for how
numbers are taken).

By contributing, you agree that your contributions are licensed under the project's
[PostgreSQL License](LICENSE).

## Releasing

Run the **release** workflow manually from the default branch for a rehearsal. It builds the
five CLI archives, both SQL install forms, a Homebrew formula, the two npm tarballs, the Python
wheel and sdist, and the other bindings' packages: the Ruby gem, the Java jar and pom, the three
.NET packages, the Elixir Hex package, the Laravel and dbt archives. It checks the archives,
installs every package in a fresh consumer project as its README says, runs the container with
PostgreSQL, and leaves the files under the run's **gnomon-release** artifact. Manual runs do not
publish. Locally, use Python 3.11+ with `build`, Go, Node 24, PostgreSQL server headers, Ruby,
Maven with a JDK 17+, the .NET 8 SDK, Elixir with Hex, and PHP with Composer:
`tools/package-release.sh /new/output`, then `tools/smoke-release.sh /new/output`.

Before the first public release, register `gnomon-postgres` as a pending PyPI publisher for
`bitsinfra/gnomon`, workflow `release.yml`, environment `pypi`. Bootstrap the two npm packages
`@bitsinfra/gnomon` and `@bitsinfra/gnomon-postgres` with prerelease versions under the
`next` dist-tag, then configure their trusted publisher for the same workflow, environment
`npm`, with publish permission. The registry administrator completes these steps on the
respective accounts. No registry tokens belong in the repository.

When CI and the rehearsal are green for the intended commit, make the repository public,
set `GNOMON_RELEASE_SSH_SIGNERS` to the authorized SSH allowed-signers entry and
`GNOMON_PUBLIC_RELEASE_ENABLED=true`. Write the GitHub release notes in
`.github/release-notes/<version>.md`. Tag the same commit on main with `cli/v<version>` and
`integrations/go/v<version>` so Go can resolve both modules. Push those tags together with the
signed, annotated `v<version>` tag.
The version must match the extension and SDKs. The tag builds and tests the release files. Separate jobs publish the container to
`ghcr.io/bitsinfra/gnomon/postgres`, the tested npm and Python packages, and the GitHub
release with the signed provenance, binaries, formula and checksums. A final `public-install` job
downloads the public CLI and SQL installers, checks both Go module tags through the public proxy,
waits up to ten minutes for registry publication to become visible, installs the SDKs from npm
and PyPI in fresh environments, and pulls the image anonymously. It runs
branch, diff, merge and undo against both that image and the public plain-SQL installer on stock
Postgres. Run the same check locally with `bash tools/smoke-public-release.sh <version>` (Docker,
Node 22.6+, Python 3.11+, curl and shasum). New GHCR packages may need public visibility before
this check passes. Wait for the entire release workflow, including this job, before promoting the
product page and docs; a green manual rehearsal has not published anything. Keep installation
examples on the last publicly verified version until the new release passes. The other bindings'
packages are attached to the GitHub release, with their checksums in `checksums.txt`.
