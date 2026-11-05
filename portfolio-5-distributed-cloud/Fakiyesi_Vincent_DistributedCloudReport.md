# Portfolio 5 — Distributed and Cloud Database Exercise

**Student:** Fakiyesi Vincent (2026/A/MIT/0304) · **Case study:** NairaVault

## 1. Why NairaVault needs a distributed database

A wallet that is down is a wallet nobody trusts. Two forces push NairaVault beyond a
single database server:

- **Availability** — customers pay at market stalls at 6 a.m. and send school fees at
  midnight. A single server means every patch, disk failure or power problem is an
  outage.
- **Scale** — the ledger grows by every deposit, fee and transfer. Reads (statements,
  dashboards, compliance reports) will outnumber writes 10:1 and should not slow the
  transfer path.

This portfolio demonstrates the three building blocks with real evidence, then designs a
cloud deployment around them.

## 2. What I built and proved

### 2.1 Streaming replication: primary + hot standby (`Fakiyesi_Vincent_ReplicationSetup.sh`, `evidence/01_replication_setup_output.txt`)

| Step | Evidence |
|---|---|
| Replica built from a base backup with a replication slot | `pg_basebackup … -R -S nairavault_replica_1`, `standby.signal` created, `primary_conninfo` written |
| Replication live | `pg_stat_replication` on the primary: `state = streaming`, `sync_state = async`, all four LSNs equal, `replay_lag ≈ 29 ms` |
| Replica confirms it is a standby | `pg_is_in_recovery() = t` |
| Write on primary → visible on replica | Customer "Replication Test" inserted on 5432, read back on 5433 one second later |
| Replica is read-only | `ERROR: cannot execute INSERT in a read-only transaction` |
| A real transfer replicates | `transfer_funds(100, 200, 500)` on the primary; the transfer row and both new balances appear on the replica |
| Lag under load | 2,000 inserts on the primary; `bytes_behind = 0`, `replay_lag ≈ 7 ms` |
| Read scaling | The full-ledger reconciliation query from Portfolio 2 ran on the replica (90 ms) without touching the primary |
| **Failover** | `pg_ctl promote` → `pg_is_in_recovery() = f` → an INSERT on the former replica succeeds |

This is **asynchronous** replication (`sync_state = async`): the primary commits
without waiting for the replica. For the ledger that is a risk — if the primary dies
in the few milliseconds before the WAL reaches the replica, a committed transfer could
be lost on failover. The production fix is `synchronous_commit = on` with
`synchronous_standby_names` set, so a transfer is only acknowledged once a standby has
written it. I kept it asynchronous here because it shows the lag measurement clearly,
and I discuss the trade-off in section 3.

### 2.2 Partitioning — sharding on one node (`Fakiyesi_Vincent_Partitioning.sql`, `evidence/02_partitioning_output.txt`)

**Range by month.** The ledger was split into 12 monthly partitions (13k–27k rows each).
- *Partition pruning:* the October fee report's plan shows `Seq Scan on
  transactions_2026_10` only — the other 11 partitions were never opened.
- *Archiving:* `DETACH PARTITION transactions_2026_01` removed 13,115 rows from the live
  table in about a millisecond, with no `DELETE` and no bloat; `ATTACH` put them back.
  This is how a fintech keeps seven years of history for regulators without slowing the
  hot table.
- *Honest finding:* on this small dataset the unpartitioned table with its partial
  covering index (3.4 ms) still beat the pruned partition's sequential scan (6.3 ms).
  Pruning narrows *which* data is read; it does not replace a good index. At 100× the
  volume the picture flips, because the covering index on one month's partition stays
  tiny.

**Hash by account.** Four partitions with `MODULUS 4` — exactly the split a sharded
cluster (Citus, MongoDB sharding, Vitess) would use.
- Rows spread evenly: 60.6k–63.2k rows and 918–941 accounts per shard.
- A customer statement hit **one** shard (`Index Scan on transactions_shard_0`, 0.05 ms).
- A cross-account report had to `Append` all four shards (77 ms). That is the cost of
  sharding: anything not keyed by the shard key fans out to every node.

The shard key choice follows directly: **account_id** (or customer_id). Every
customer-facing query is keyed by it, and a transfer between two accounts on different
shards is the one operation that becomes a distributed transaction — which is why
Portfolio 3's single-node transaction is worth protecting.

## 3. Consistency, availability and the CAP trade-off for a ledger

| Data | Required guarantee | Choice |
|---|---|---|
| Account balances, transfers, ledger | Strong consistency: a balance read right after a transfer must be correct | Single primary, synchronous replica. Writes go to one place; during a failover we accept a few seconds of unavailability rather than risk a double-spend (CP) |
| Statements, dashboards, notifications | Eventual consistency is acceptable: a statement that is 50 ms stale is fine | Served from async read replicas and the document store (Portfolio 4) (AP-leaning) |
| Daily-limit counters | Must not under-count | Kept on the primary or in a strongly consistent key-value store |

Replication lag has a concrete product consequence: if the app reads a balance from
a replica immediately after a transfer, the customer may see the old balance. The
standard fix is *read-your-own-writes*: route a customer's reads to the primary for a
few seconds after they write, then back to the replica.

## 4. Cloud deployment design

```
                 Lagos users ─────────┐                    ┌───────── Abuja / Kano users
                                      ▼                    ▼
                           ┌──────────────────────────────────────┐
                           │  Load balancer + API (stateless)     │
                           └───────┬───────────────────┬──────────┘
                                   │ writes            │ reads
                       ┌───────────▼───────────┐  ┌────▼───────────────────┐
                       │ PostgreSQL PRIMARY     │  │ Read replicas ×2       │
                       │ (AZ-a)  sync standby ──┼─▶│ async (AZ-b, AZ-c)     │
                       │ ledger, accounts       │  │ statements, reports    │
                       └───────────┬───────────┘  └────────────────────────┘
                                   │ change feed
                       ┌───────────▼───────────┐
                       │ MongoDB Atlas (3-node  │
                       │ replica set) customer  │
                       │ docs, notifications    │
                       └────────────────────────┘
```

**Managed services I would choose and why**

- **Database:** Amazon RDS for PostgreSQL (or Azure Database for PostgreSQL) in a
  Multi-AZ deployment. Multi-AZ gives exactly what section 2.1 built by hand — a
  synchronous standby in a second availability zone with automatic failover — but
  managed: patching, backups, point-in-time recovery to any second in the last 35 days,
  and encrypted storage. Read replicas are added with one click and serve the
  reporting traffic shown in step 9 of the replication demo.
- **Region:** AWS *af-south-1* (Cape Town) or Azure *South Africa North* are the
  closest regions to Nigeria today; neither is in Nigeria. Nigeria's Data Protection
  Act and CBN guidance push towards local residency for financial data, so a realistic
  design keeps a replica or the primary with a Nigerian provider (e.g. a Lagos
  colocation data centre) and uses the cloud region for disaster recovery. This is a
  live compliance question, not a technical one, and must be settled with legal
  counsel before launch.
- **Document store:** MongoDB Atlas M10+ as a 3-node replica set (majority write
  concern), sharded by `customerId` once documents exceed ~1 TB.
- **Backups:** automated daily snapshots + continuous WAL archiving to object storage
  (S3) for point-in-time recovery; cross-region copy of snapshots for DR.
- **Targets:** RPO (data loss) = 0 for the ledger (synchronous standby), RTO (time
  to recover) ≤ 60 s via automatic failover. Reporting replicas: RPO seconds, RTO
  minutes.

**Operational practices**
- Connection pooling (PgBouncer / RDS Proxy) so failover does not drop thousands of
  mobile sessions.
- Partition the ledger monthly from day one (section 2.2) so archiving never becomes
  an emergency.
- Monitor `pg_stat_replication.replay_lag` and alert above 1 s; a lagging replica
  silently serves stale balances.
- Rehearse failover quarterly, exactly as in step 10 of the replication script.

## 5. What I learned

Building the replica by hand made the managed-service features concrete: Multi-AZ
*is* a synchronous standby plus `pg_ctl promote` with monitoring around it. The
failover step was the most instructive — promotion took two seconds, but it also
showed the need to fence the old primary, otherwise both servers accept writes and the
ledger forks (split-brain). Partitioning taught me that distribution is a trade: the
per-account query got faster and the cross-account report got slower, and no amount of
tuning changes that — only choosing the shard key carefully does.
