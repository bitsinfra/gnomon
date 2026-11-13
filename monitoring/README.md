# Monitoring

- [`alerts.yml`](alerts.yml): Prometheus alert rules: no clock ticks, versions in default
  partitions, feed consumer lag, dead sink batches, failed merges and thaws, an unsealed ledger,
  branches over quota, conflicts left open.
- [`grafana-dashboard.json`](grafana-dashboard.json): a Grafana dashboard over the same metrics
  (import it and pick the Prometheus data source).

The metrics are `gnomon.metrics()`: `gnomon serve` prints them on `/metrics`, or point
`postgres_exporter` at the function (`gnomon.metrics_text()` returns the text form). They read
catalogs and statistics only. Per-branch series (`gnomon_branch_behind_main`) are off unless asked
for (`gnomon.metrics(per_branch => true)`, `/metrics?per_branch=1`) and capped, to bound
cardinality. Not exposed yet: the result of the last ledger verification and the C module's
counters (they are per session, not in shared memory).
