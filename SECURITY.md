# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately through GitHub's
private vulnerability reporting: the **Report a vulnerability** button under this repository's
**Security** tab. Include the gnomon version (`select extversion from pg_extension where extname =
'gnomon'`), the PostgreSQL version, whether the C module is loaded, and the smallest SQL or steps
that show the problem.

Fixes are released as soon as they are ready, and the release notes credit the reporter unless
they prefer otherwise.

## Supported versions

Security fixes go into the latest 1.x release. Upgrade with `ALTER EXTENSION gnomon UPDATE` to
get them.

## What counts

Gnomon runs much of its work in `SECURITY DEFINER` functions and relies on roles, row-level
security and confinement to keep branches apart. Reports of particular interest:

- a role writing main, or a branch it may not write, or merging or undoing without
  `gnomon_merger`;
- a confined role reading a branch outside its access list, or a masked role reading the real
  value of a masked column;
- a way to call a definer function that runs SQL or touches objects the caller could not reach
  by hand;
- history changed without the ledger's verification noticing;
- the HTTP servers (`gnomon serve`, `gnomon mcp --http`): authentication, agent tokens, CSRF, or
  acting as another role.

[docs/security.md](docs/security.md) describes the model, every definer path and the check inside
it, and the trust it assumes (for example, that the owners of tracked tables are trusted). A
report that one of those stated assumptions can be broken is in scope too.
