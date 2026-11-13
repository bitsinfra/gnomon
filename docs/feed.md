# The change feed

Every change Gnomon records is also a stream: exactly the versions between two moments, in commit
order, with no gaps and no duplicates.

```sql
select * from gnomon.changes(since => 'tag:last-run');
```

| | |
|---|---|
| `tbl`, `key`, `op` | The table, the row's key, and `insert`, `update`, `delete` or `truncate` |
| `new`, `old` | The row after and before, when you ask for images |
| `xid`, `role` | The transaction and who made it |
| `vkey`, `vlsn` | The change's exact position, for picking up where you left off |

Because a feed window is defined by coordinates rather than by a timestamp, reading it twice gives
the same answer, and a consumer that crashes mid-batch loses nothing.

## Consumers

A consumer keeps its own position in the database:

```sql
select gnomon.feed_create('etl', since => 'now');
select * from gnomon.feed_poll('etl', 1000);     -- the next batch; the position moves with it
```

Each page continues from the last change returned, so draining a large backlog costs what the
backlog is, not what the window is.

## Sinks

A sink is a consumer the daemon delivers for you:

```sql
select gnomon.sink_add('warehouse', 'kafka',
  '{"brokers": "localhost:9092", "topic": "gnomon.changes"}');
```

| Sink | Notes |
|---|---|
| `webhook` | HMAC signature and an `Idempotency-Key` per batch. |
| `kafka` | An idempotent producer, the row's key as the message key, so a partition keeps order and a retry writes once. |
| `nats` | `Nats-Msg-Id` per change. |
| `file`, `parquet` | One file per batch, in a directory or an object store (`s3://`, `gs://`). |

Messages come out in Gnomon's own shape, or as Debezium or CloudEvents (`format =>`). Delivery is
at least once, and the delivery state is saved in the same transaction that moves the position, so
a kill mid-stream leaves the sink exactly where it was.

```bash
gnomon daemon        # runs the sinks, thaws, scheduled merges and notifications
gnomon sink list
gnomon sink replay warehouse --since 'tag:yesterday'
```

## Into a warehouse

For tables that belong in a warehouse as slowly changing dimensions, Gnomon writes the type-2 view
for you:

```sql
select gnomon.scd2('customers');                    -- customers_history
select * from gnomon.scd2_changes('customers', since => 'tag:last-load');
```

The dbt package keeps a table in dbt's snapshot shape straight from the feed, including deleted
rows, so a model can read the database as it stood at any moment.

[The dbt package →](../dbt/gnomon_dbt/README.md) · [History →](history.md)
