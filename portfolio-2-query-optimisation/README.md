# Portfolio 2 — Query Processing and Optimisation

## Files

| File | Purpose |
|---|---|
| `Fakiyesi_Vincent_Queries.sql` | 8 business queries (statement, support worklist, fee report, velocity check, reconciliation, state volume, two versions of a compliance query) |
| `Fakiyesi_Vincent_Indexes.sql` | Indexes chosen after reading the plans — composite, partial, covering, FK indexes — each with a comment explaining why |
| `Fakiyesi_Vincent_Benchmark.py` | Harness: runs every query before and after indexing, 5 runs each, saves plans and results |
| `Fakiyesi_Vincent_Analysis.md` | Plain-language reading of the plans and what changed |
| `evidence/plans_before/` | `EXPLAIN (ANALYZE, BUFFERS)` output + first rows of each result, bare schema |
| `evidence/plans_after/` | Same after indexing |
| `evidence/timing_comparison.md` | Before/after table, scan types, index sizes |
| `evidence/benchmark_run_output.txt` | Raw console output of the benchmark run |

## How to reproduce

```bash
python3 Fakiyesi_Vincent_Benchmark.py "dbname=nairavault"
```

## Headline results

- Account statement query: **15.8 ms → 0.3 ms** (composite index, 3,280 pages read → 7)
- Fee report: sequential scan → **index-only scan** with a partial covering index
- Correlated subquery: **11 s → 54 ms** with FK indexes; the JOIN rewrite was 20 ms with no index at all
- Reconciliation query: unchanged — correctly stays a sequential scan because it must read every row
