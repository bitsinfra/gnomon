-- Catalog for agents, quotas, role assignments, runs, review comments, merge policies, the
-- run record, scheduled merges, notifications, sinks, thaw requests, scenarios, metrics, links,
-- attempts, action tables and history checkpoints.
-- Every statement here is written IF NOT EXISTS: src/upgrade/001_catalog.sql includes this file
-- whole, so an upgrade creates exactly what a fresh install does. No default or check calls
-- gnomon code (upgrades drop and re-create the code).

-- An agent: a confined database role with a name, a token for HTTP, its branch.
create table if not exists gnomon.agent (
  name       text primary key check (name ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'),
  role       name not null unique,
  token_hash bytea,                        -- sha256 of the bearer token (the token is shown once)
  status     text not null default 'active' check (status in ('active', 'stopped')),
  branch     int references gnomon.branch on delete set null,
  calls_per_minute int,                    -- budgets the server enforces
  max_result_rows  int,
  max_result_bytes int,
  created_by name not null default session_user,
  created_at timestamptz not null default now(),
  note       text
);

-- Quotas: scope default (name ''), role (a role name) or branch (a branch name).
create table if not exists gnomon.quota (
  scope        text not null check (scope in ('default', 'role', 'branch')),
  name         text not null default '',
  max_branches int,        -- open branches a role may have
  max_rows     bigint,     -- keys a branch may touch
  max_age      interval,   -- how long a branch may live
  max_children int,        -- open children a branch may have
  primary key (scope, name)
);

-- A role assigned to a branch: its sessions start on it.
create table if not exists gnomon.assignment (
  role        name primary key,
  branch      int not null references gnomon.branch on delete cascade,
  db          name not null default current_database(),
  assigned_by name not null default session_user,
  assigned_at timestamptz not null default now()
);

-- Agent runs started by an application: a branch the runs login may write.
create table if not exists gnomon.run (
  branch     int primary key references gnomon.branch on delete cascade,
  task       text,
  actor      text,
  runs_role  name not null,
  created_by name not null default session_user,
  created_at timestamptz not null default now(),
  ended_at   timestamptz,
  outcome    text,
  login      name                         -- the run's own login, when one was asked for (run.url, run.connection)
);
alter table gnomon.run add column if not exists login name;

-- Comments on a change request, anchored to a row or a field.
create table if not exists gnomon.review_comment (
  id          bigserial primary key,
  cr          bigint not null references gnomon.change_request on delete cascade,
  tbl         regclass,
  key         jsonb,
  col         text,
  body        text not null,
  author      name not null default session_user,
  at          timestamptz not null default now(),
  resolved_by name,
  resolved_at timestamptz
);
create index if not exists review_comment_cr on gnomon.review_comment (cr, id);

-- Auto-merge policies: who may merge what without gnomon_merger.
create table if not exists gnomon.merge_policy (
  name       text primary key,
  target     int not null default 0 references gnomon.branch,
  agents     name[] not null default '{}',     -- roles it covers; '{}' covers none
  rules      jsonb not null default '{}',
  enabled    bool not null default true,
  created_by name not null default session_user,
  created_at timestamptz not null default now()
);

-- The run record: every tool call of an agent run, hash-chained per run.
create table if not exists gnomon.agent_call (
  run       text not null,
  seq       int not null,
  agent     text,
  tool      text not null,
  args      jsonb,
  branch    text,
  coord     text,                 -- the coordinate a read ran at (exact replay)
  xid       xid8,                 -- the transaction a write ran in
  rows      bigint,
  digest    text,                 -- sha256 of the rows a read returned
  error     text,
  at        timestamptz not null default now(),
  prev_hash bytea,
  hash      bytea not null,
  primary key (run, seq)
);

-- Scheduled merges, run by the job loop as a merger.
create table if not exists gnomon.scheduled_merge (
  id             bigserial primary key,
  branch         int not null references gnomon.branch on delete cascade,
  at             timestamptz not null,
  close          bool not null default false,
  require_checks bool not null default true,
  created_by     name not null default session_user,
  created_at     timestamptz not null default now(),
  status         text not null default 'pending' check (status in ('pending', 'merged', 'conflicts', 'failed', 'cancelled')),
  merge_id       bigint,
  error          text,
  ran_at         timestamptz
);

-- Telling a person: targets and the notifications the job loop delivers.
create table if not exists gnomon.notify_target (
  name       text primary key,
  kind       text not null check (kind in ('webhook', 'channel')),
  config     jsonb not null default '{}',     -- webhook: url, secret; channel: a NOTIFY channel
  events     text[] not null default '{change_request}',
  created_by name not null default session_user
);
create table if not exists gnomon.notification (
  id         bigserial primary key,
  target     text not null,
  event      text not null,
  payload    jsonb not null,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  attempts   int not null default 0,
  last_error text
);
create index if not exists notification_unsent on gnomon.notification (id) where sent_at is null;

-- Change feed sinks, delivered by the job loop.
create table if not exists gnomon.sink (
  name       text primary key,
  kind       text not null check (kind in ('webhook', 'file', 'nats', 'kafka', 'parquet')),
  config     jsonb not null default '{}',
  state      jsonb not null default '{}',    -- the sink's own delivery state (Kafka: producer id, epoch, sequences)
  consumer   text not null,
  tables     text[],
  format     text not null default 'gnomon' check (format in ('gnomon', 'debezium', 'cloudevents')),
  status     text not null default 'active' check (status in ('active', 'paused')),
  last_error text,
  failures   int not null default 0,
  delivered  bigint not null default 0,
  created_by name not null default session_user,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table gnomon.sink add column if not exists state jsonb not null default '{}';
alter table gnomon.sink drop constraint if exists sink_kind_check;
alter table gnomon.sink add constraint sink_kind_check check (kind in ('webhook', 'file', 'nats', 'kafka', 'parquet'));
create table if not exists gnomon.sink_dead (
  id    bigserial primary key,
  sink  text not null,
  batch jsonb not null,
  error text,
  at    timestamptz not null default now()
);

-- Thaw requests for archived partitions, restored by the job loop.
create table if not exists gnomon.thaw_request (
  id           bigserial primary key,
  tbl          regclass not null,
  part         int4 not null,
  requested_by name not null default session_user,
  requested_at timestamptz not null default now(),
  status       text not null default 'pending' check (status in ('pending', 'thawing', 'thawed', 'failed', 'refrozen')),
  bytes        bigint,
  thawed_at    timestamptz,
  expires_at   timestamptz,
  error        text
);
create unique index if not exists thaw_request_open on gnomon.thaw_request (tbl, part) where status in ('pending', 'thawing', 'thawed');

-- Scenarios and metrics.
create table if not exists gnomon.scenario (
  name       text primary key,
  parent     text,
  branch     int references gnomon.branch on delete set null,
  base       text,                  -- the parent's coordinate at creation: the baseline
  note       text,
  created_by name not null default session_user,
  created_at timestamptz not null default now()
);
create table if not exists gnomon.scenario_step (
  scenario text not null references gnomon.scenario on delete cascade,
  seq      int not null,
  sql      text not null,
  xid      xid8,
  at       timestamptz not null default now(),
  primary key (scenario, seq)
);
create table if not exists gnomon.metric (
  name       text primary key,
  sql        text not null,
  unit       text,
  created_by name not null default session_user
);
create table if not exists gnomon.metric_run (
  id       bigserial primary key,
  scenario text,
  metric   text not null,
  value    numeric,
  coord    text,
  at       timestamptz not null default now()
);

-- Relationships that are not foreign keys.
create table if not exists gnomon.link (
  name      text primary key,
  from_tbl  regclass not null,
  from_cols text[] not null,
  to_tbl    regclass not null,
  to_cols   text[] not null,
  filter    text
);

-- Parallel attempts: branches made at one coordinate.
create table if not exists gnomon.attempt (
  grp    text not null,
  branch int not null references gnomon.branch on delete cascade,
  seq    int not null,
  primary key (grp, branch)
);

-- Action tables: outbox tables whose rows are side effects that run on merge.
create table if not exists gnomon.action_table (
  rel     regclass primary key,
  channel text not null
);

-- History checkpoints: full images of a table at a coordinate.
create table if not exists gnomon.history_checkpoint (
  tbl        int not null references gnomon.tracked on delete cascade,
  id         int not null,
  coord      gnomon.coord not null,
  kx         int8 not null,           -- gnomon._kxmax(coord)
  rows       bigint,
  bytes      bigint,
  cleared_key int8,                 -- taken by a TRUNCATE on main: that marker's key
  created_at timestamptz not null default now(),
  primary key (tbl, id)
);

-- Schema versions: a named shape of the tracked tables, main's plus an ordered list of
-- changes made on a branch.
create table if not exists gnomon.schema_version (
  id                serial primary key,
  parent            int references gnomon.schema_version,
  created_on_branch int references gnomon.branch on delete set null,
  status            text not null default 'open' check (status in ('open', 'merged', 'dropped')),
  created_at        timestamptz not null default now()
);
create table if not exists gnomon.schema_change (
  id         bigserial primary key,
  version    int not null references gnomon.schema_version on delete cascade,
  seq        int not null,
  sql        text not null,
  op         text not null,           -- add_column, create_table, create_index, comment
  tbl        text,                    -- schema.table the operation is on (null for a comment)
  detail     jsonb not null default '{}',
  created_at timestamptz not null default now(),
  unique (version, seq)
);
-- Values of branch-only columns: versioned like branch history (a row per write, stamped),
-- read at each lineage level's cutoff.
create table if not exists _gnomon.branch_column (
  change  bigint not null references gnomon.schema_change on delete cascade,
  branch  int not null,
  key     jsonb not null,
  value   jsonb not null,             -- the value as JSON ('null' for an explicit NULL)
  gn_key  int8 not null,
  gn_xoff int4 not null,
  primary key (change, key, branch, gn_key)
);

-- Crypto-shredding of archives: a table's data subject, the columns the archiver encrypts
-- per subject, and a key per subject (only in the database: deleting it erases the subject from
-- every archive, including stores that cannot rewrite a file).
create table if not exists gnomon.subject (
  tbl         int primary key references gnomon.tracked on delete cascade,
  subject_col name not null,
  columns     name[] not null,
  created_by  name not null default session_user,
  created_at  timestamptz not null default now()
);
create table if not exists _gnomon.subject_key (
  tbl        int not null references gnomon.tracked on delete cascade,
  subject    text not null,
  key        bytea not null,
  created_at timestamptz not null default now(),
  primary key (tbl, subject)
);
create table if not exists gnomon.subject_erased (
  tbl       int not null,
  subject   text not null,
  reason    text,
  erased_by name not null default session_user,
  erased_at timestamptz not null default now(),
  primary key (tbl, subject)
);

-- Engines that read an archive file in place, as a foreign partition of the version table (3.3
-- part 3): the CREATE FOREIGN TABLE text, with {table}, {parent}, {from}, {to}, {location} (a
-- quoted literal) and {duckdb_read}; the file format the engine reads; SQL that prepares the
-- server, run once.
create table if not exists gnomon.archive_engine (
  name            text primary key,
  format          text not null check (format in ('parquet', 'csv')),
  create_template text not null,
  setup           text,
  note            text
);
insert into gnomon.archive_engine(name, format, create_template, setup, note) values
  ('pg_lake', 'parquet',
   'create foreign table {table} partition of {parent} for values from ({from}) to ({to}) server pg_lake options (path {location})',
   null, 'pg_lake (self-hosted, Snowflake Postgres): Parquet in object storage. Untested template, written from its documentation.'),
  ('duckdb_fdw', 'parquet',
   'create foreign table {table} partition of {parent} for values from ({from}) to ({to}) server duckdb_server options (table {duckdb_read})',
   null, 'duckdb_fdw with a server named duckdb_server. Untested template, written from its documentation.'),
  ('file_fdw', 'csv',
   'create foreign table {table} partition of {parent} for values from ({from}) to ({to}) server gnomon_file options (filename {location}, format ''csv'', header ''true'', null ''\N'')',
   'create extension if not exists file_fdw; create server if not exists gnomon_file foreign data wrapper file_fdw',
   'PostgreSQL''s file_fdw over a CSV copy the archiver writes next to the Parquet file (a path the server can read).')
on conflict (name) do nothing;
grant select on gnomon.archive_engine to public;

-- A gnomon.ddl in progress in a backend: the shadow's catalog before the statement.
create table if not exists _gnomon.ddl_pending (
  pid     int primary key,
  version int not null,
  branch  int not null,
  shadow  text not null,
  nsp     name not null,
  who     text not null,
  before  jsonb not null,
  idx     text[] not null,
  comments jsonb not null,
  fp      text not null,
  cons    jsonb not null default '[]',   -- the shadow's constraints before the statement
  up      text,                          -- a type change's expressions (gnomon.ddl's up and down)
  down    text
);
alter table _gnomon.ddl_pending add column if not exists cons jsonb not null default '[]';
alter table _gnomon.ddl_pending add column if not exists up text;
alter table _gnomon.ddl_pending add column if not exists down text;

-- Who reads what: catalog rows are public unless they hold secrets or what an agent did.
grant select on gnomon.quota, gnomon.assignment, gnomon.run, gnomon.review_comment, gnomon.merge_policy,
  gnomon.scheduled_merge, gnomon.thaw_request, gnomon.scenario, gnomon.scenario_step, gnomon.metric,
  gnomon.metric_run, gnomon.link, gnomon.attempt, gnomon.action_table, gnomon.history_checkpoint,
  gnomon.schema_version, gnomon.schema_change, gnomon.subject to public;
grant select on gnomon.subject_erased to gnomon_admin;
grant select on _gnomon.branch_column to gnomon_reader;
grant select (name, role, status, branch, calls_per_minute, max_result_rows, max_result_bytes, created_by, created_at, note)
  on gnomon.agent to public;
grant select on gnomon.agent_call, gnomon.sink, gnomon.sink_dead, gnomon.notify_target, gnomon.notification to gnomon_admin;
grant select on gnomon.agent_call to gnomon_merger;

-- The ledger's verifications: gnomon.verify_ledger records each run, for the
-- metrics and the failed-verification alert. The last hundred are kept.
create table if not exists gnomon.ledger_verification (
  id           bigserial primary key,
  at           timestamptz not null default now(),
  blocks       int not null,
  failed       int not null,
  first_failed bigint
);
grant select on gnomon.ledger_verification to gnomon_admin;

-- Saved views of the review app's graph page: a start row, a depth, a branch and a
-- moment, under a name everyone who may read the table sees.
create table if not exists gnomon.graph_view (
  name       text primary key,
  tbl        text not null,
  key        jsonb not null,
  depth      int not null default 1 check (depth between 1 and 5),
  branch     text,
  at         text,
  note       text,
  created_by name not null,
  created_at timestamptz not null default now()
);
