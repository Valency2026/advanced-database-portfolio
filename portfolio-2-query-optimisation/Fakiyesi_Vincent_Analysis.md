# Portfolio 2 — Query Processing and Optimisation: Analysis

**Student:** Fakiyesi Vincent (2026/A/MIT/0304) · **DBMS:** PostgreSQL 16 ·
**Dataset:** 242,531 ledger rows, 67,245 transfers, 3,719 accounts (from Portfolio 1)

## 1. Method

1. Wrote eight queries that answer real NairaVault business questions
   (`Fakiyesi_Vincent_Queries.sql`).
2. Ran each one on the bare schema (primary keys and unique keys only), five times,
   keeping the median time, and saved `EXPLAIN (ANALYZE, BUFFERS)` output
   (`evidence/plans_before/`).
3. Read the plans, decided which indexes would help and why
   (`Fakiyesi_Vincent_Indexes.sql`).
4. Re-ran everything (`evidence/plans_after/`) and compared
   (`evidence/timing_comparison.md`).

The whole procedure is automated in `Fakiyesi_Vincent_Benchmark.py` so it can be
repeated by anyone.

## 2. Results

| Query | Business question | Before (ms) | After (ms) | Change |
|---|---|---|---|---|
| Q1 statement | One account's history for a month | 15.8 | 0.3 | **53x faster** |
| Q2 failed transfers | Support worklist for last 7 days | 6.4 | 1.4 | 4.7x faster |
| Q3 fee revenue | Daily fee totals for October | 17.6 | 4.2 | 4.2x faster |
| Q4 velocity check | Accounts with 2+ transfers in 10 min | 64.8 | 41.3 | 1.6x faster |
| Q5 reconciliation | Every cached balance vs ledger | 57.4 | 54.4 | no real change |
| Q6 state volume | Top states by transfer value, Q3 | 12.5 | 11.2 | small gain |
| Q7a correlated subquery | Tier-1 customers over ₦50k | **11,070** | 54.2 | **204x faster** |
| Q7b same as join | Tier-1 customers over ₦50k | 20.5 | 21.4 | no change |

(Exact figures vary a little between runs; the ratios are stable. Full table with scan
types in `evidence/timing_comparison.md`.)

## 3. What the execution plans show

### Q1 — the most important query in the app

**Before:** `Parallel Seq Scan on transactions … Rows Removed by Filter: 80842` per
worker, `Buffers: shared hit=3280`. PostgreSQL read all 3,280 pages (~26 MB) of the
ledger and threw away 242,525 of 242,531 rows to find 6. It even started parallel
workers because the scan was so expensive.

**After** `idx_txn_account_created (account_id, created_at DESC)`:
`Bitmap Index Scan … Index Cond: (account_id = 1250 AND created_at >= … AND < …)`,
`Buffers: shared hit=7`. Seven pages read instead of 3,280. The composite index lets the
planner satisfy both the equality (`account_id`) and the range (`created_at`) from the
index. This is the pattern every "show my history" screen depends on, and it is the
reason a fintech with millions of customers can stay responsive.

### Q3 — index-only scan with a covering, partial index

**Before:** parallel sequential scan of the whole ledger.
**After** `idx_txn_fee_created (created_at) INCLUDE (amount) WHERE txn_type = 'fee'`:
`Index Only Scan … Heap Fetches: 0 … Buffers: shared hit=28`.
Two tricks are working together:

- **Partial index** — only fee rows (about 25% of the ledger) are in the index, so it is
  small (1.8 MB).
- **Covering index** — `INCLUDE (amount)` stores the one non-key column the query needs,
  so PostgreSQL never has to visit the table ("Heap Fetches: 0").

### Q2 — partial index on a rare status

Only a minority of transfers fail, and support only asks about failed ones. The partial
index `WHERE status = 'failed'` is just 208 kB and turns the transfers scan into an index
range scan on `initiated_at`. The remaining time is the two joins to `accounts` and
`customers`, which are already fast through their primary keys.

### Q7 — the biggest lesson: query shape matters more than indexes

Q7a and Q7b return identical rows. Q7a uses a correlated subquery that is evaluated
**once per tier-1 customer, and twice for the ones that match** — the plan shows two
`SubPlan`s with `Seq Scan on transfers … loops=1046` and `loops=1023`, i.e. the
67,245-row transfers table was scanned over 2,000 times (~140 million row visits),
hence 11 seconds. Adding `idx_transfers_source_status` and
`idx_accounts_customer` cut it to 54 ms because each inner loop becomes an index lookup.

Q7b, rewritten as a JOIN + GROUP BY + HAVING, was already 20 ms **without any extra
index**, because the planner could use a hash join and a single pass over transfers.
Takeaway: before adding indexes, write the query so the optimiser can see the whole
problem at once. Indexes rescued the bad query; the good query never needed rescuing.

### Q5 — an index does not help, and that is correct

The reconciliation must read **every** ledger row to sum it. There is no filter to
narrow the scan, so the planner keeps the parallel sequential scan with or without
indexes. Trying to force an index here would make it slower (random I/O instead of
streaming reads). The right optimisation for this query is architectural, not an index —
run it on a read replica at night (Portfolio 5) or maintain incremental daily
sub-totals.

### Q4 — window function cost dominates

The index on `transfer_out` rows removes the filter cost, but most of the time is the
window function sorting ~70k rows per account partition. Gain is modest (1.6x). A
further step would be to limit the check to the last 24 hours, which the same index
would then serve with a tiny range scan.

## 4. Cost of the indexes

Seven indexes added **12.7 MB** on top of a 28 MB table (`evidence/timing_comparison.md`).
Every index slows `INSERT` slightly, because each new ledger row must be added to each
index on that table. For a ledger that is written once and read many times this is a
good trade. I avoided indexing columns the queries never filter on (`channel`,
`description`) and used partial indexes so that the write cost only applies to the rows
the index actually contains.

## 5. Other optimisation techniques used

| Technique | Where |
|---|---|
| Composite index with column order matching equality-then-range | Q1 |
| Partial index | Q2, Q3, Q4, Q6 |
| Covering index (`INCLUDE`) → index-only scan | Q3 |
| Indexing foreign-key columns (not automatic in PostgreSQL) | Q2, Q6, Q7 |
| Query rewrite: correlated subquery → join/aggregate | Q7 |
| `ANALYZE` after creating indexes so the planner has fresh statistics | all |
| Median-of-5 timing to remove cache warm-up noise | benchmark |

## 6. Things I would do next in production

- Add `pg_stat_statements` to find the slowest queries from real traffic rather than
  guessing.
- Partition `transactions` by month so that old months can be archived and statement
  queries scan less (demonstrated in Portfolio 5).
- Keep a materialised view of daily fee totals refreshed nightly for finance dashboards.
