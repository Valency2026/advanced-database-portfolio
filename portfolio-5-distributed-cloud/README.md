# Portfolio 5 — Distributed and Cloud Database Exercise

A real **primary + streaming hot-standby** PostgreSQL pair was built and tested (replication, read-only enforcement, lag measurement, read offloading, promotion/failover), the ledger was **partitioned** by month (archiving, partition pruning) and by hash of account (sharding simulation), and a cloud deployment was designed around the results.

## Files

| File | Purpose |
|---|---|
| `Fakiyesi_Vincent_ReplicationSetup.sh` | Builds a replica on port 5433 with `pg_basebackup -R`, verifies replication, measures lag, promotes the replica |
| `Fakiyesi_Vincent_Partitioning.sql` | Range partitioning by month + hash partitioning by account, with plans |
| `Fakiyesi_Vincent_DistributedCloudReport.md` | Findings, consistency/availability trade-offs, cloud architecture, data-residency note |
| `evidence/01_replication_setup_output.txt` | Full output: `pg_stat_replication`, read-only error, lag figures, promotion |
| `evidence/02_partitioning_output.txt` | Partition row counts, pruned plans, shard distribution |

## How to reproduce

```bash
# as the postgres OS user, with the primary running on 5432 and an empty $REPLICA dir
bash Fakiyesi_Vincent_ReplicationSetup.sh
psql -d nairavault -f Fakiyesi_Vincent_Partitioning.sql
```

## Headline results

- `pg_stat_replication`: `state = streaming`, replay lag ~7–30 ms; 0 bytes behind after 2,000 inserts
- Replica: `pg_is_in_recovery() = t`; INSERT → `cannot execute INSERT in a read-only transaction`
- Promotion: `pg_ctl promote` → replica becomes writable in ~2 s
- October report pruned to **one** of 12 monthly partitions; detaching a month of history took ~1 ms
- Hash shards balanced within 4%; per-account query hit one shard, cross-account report fanned out to all four
