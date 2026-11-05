"""
Portfolio 2 benchmark harness
Student: Fakiyesi Vincent (2026/A/MIT/0304)

1. Drops any Portfolio-2 indexes so we start from the bare schema
2. Runs every query in Fakiyesi_Vincent_Queries.sql 5 times, keeps the median
   and saves the EXPLAIN (ANALYZE, BUFFERS) plan  -> evidence/plans_before/
3. Applies Fakiyesi_Vincent_Indexes.sql
4. Repeats step 2                                 -> evidence/plans_after/
5. Writes evidence/timing_comparison.md

Usage: python3 Fakiyesi_Vincent_Benchmark.py "dbname=nairavault host=/tmp user=postgres"
"""
import re, sys, time, statistics, pathlib
import psycopg2

DSN = sys.argv[1] if len(sys.argv) > 1 else "dbname=nairavault host=/tmp user=postgres"
HERE = pathlib.Path(__file__).parent
EV = HERE / "evidence"
RUNS = 5

def load_queries():
    text = (HERE / "Fakiyesi_Vincent_Queries.sql").read_text()
    parts = re.split(r"--\s*name:\s*(\w+)", text)
    queries = {}
    for i in range(1, len(parts), 2):
        name, body = parts[i], parts[i + 1]
        sql = re.sub(r"--.*", "", body).strip().rstrip(";")
        queries[name] = sql
    return queries

def run_one(cur, name, sql, outdir):
    times, rows = [], None
    for _ in range(RUNS):
        t0 = time.perf_counter()
        cur.execute(sql)
        rows = cur.fetchall()
        times.append((time.perf_counter() - t0) * 1000)
    cur.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) " + sql)
    plan = "\n".join(r[0] for r in cur.fetchall())
    (outdir / f"{name}.txt").write_text(
        f"-- {name}\n-- median client time: {statistics.median(times):.2f} ms over {RUNS} runs\n"
        f"-- rows returned: {len(rows)}\n\n{sql};\n\n{plan}\n")
    # first lines of result for the evidence folder
    (outdir / f"{name}_result.txt").write_text(
        "\n".join(str(r) for r in rows[:15]) + (f"\n... ({len(rows)} rows total)" if len(rows) > 15 else ""))
    return statistics.median(times), len(rows), plan

def summarise(plan):
    """pull the headline node type and buffers from the plan"""
    first = plan.splitlines()[0]
    node = re.sub(r"\s+\(cost.*", "", first).strip()
    m = re.search(r"Execution Time: ([\d.]+) ms", plan)
    exec_ms = float(m.group(1)) if m else None
    scans = sorted(set(re.findall(r"(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan|Parallel Seq Scan)", plan)))
    return node, exec_ms, ", ".join(scans)

def main():
    conn = psycopg2.connect(DSN)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET search_path TO vault")
    queries = load_queries()

    # ---- before ----
    cur.execute("""SELECT indexname FROM pg_indexes WHERE schemaname='vault'
                   AND indexname LIKE 'idx\\_%'""")
    for (ix,) in cur.fetchall():
        cur.execute(f"DROP INDEX IF EXISTS vault.{ix}")
    cur.execute("ANALYZE")
    before = {}
    d = EV / "plans_before"; d.mkdir(parents=True, exist_ok=True)
    for name, sql in queries.items():
        before[name] = run_one(cur, name, sql, d)
        print(f"before  {name:28s} {before[name][0]:9.2f} ms  rows={before[name][1]}")

    # ---- indexes ----
    cur.execute((HERE / "Fakiyesi_Vincent_Indexes.sql").read_text())

    # ---- after ----
    after = {}
    d = EV / "plans_after"; d.mkdir(parents=True, exist_ok=True)
    for name, sql in queries.items():
        after[name] = run_one(cur, name, sql, d)
        print(f"after   {name:28s} {after[name][0]:9.2f} ms  rows={after[name][1]}")

    # ---- index sizes ----
    cur.execute("""SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid))
                   FROM pg_stat_user_indexes WHERE schemaname='vault' AND indexrelname LIKE 'idx%'
                   ORDER BY indexrelname""")
    sizes = cur.fetchall()
    cur.execute("SELECT pg_size_pretty(pg_total_relation_size('vault.transactions'))")
    txn_size = cur.fetchone()[0]

    # ---- report ----
    lines = ["# Timing comparison: before vs after indexing", "",
             f"Median of {RUNS} runs each, measured from the client (PostgreSQL 16, local socket).",
             "Planner execution time is taken from EXPLAIN ANALYZE.", "",
             "| Query | Rows | Before (ms) | After (ms) | Speed-up | Scan type before | Scan type after |",
             "|---|---|---|---|---|---|---|"]
    for name in queries:
        b, a = before[name], after[name]
        _, _, sb = summarise(b[2]); _, _, sa = summarise(a[2])
        speed = b[0] / a[0] if a[0] else float("inf")
        lines.append(f"| {name} | {b[1]} | {b[0]:.2f} | {a[0]:.2f} | {speed:.1f}x | {sb} | {sa} |")
    lines += ["", "## Index sizes", "", "| Index | Size |", "|---|---|"]
    lines += [f"| {n} | {s} |" for n, s in sizes]
    lines += ["", f"Total size of the transactions table including indexes: {txn_size}"]
    (EV / "timing_comparison.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))

if __name__ == "__main__":
    main()
