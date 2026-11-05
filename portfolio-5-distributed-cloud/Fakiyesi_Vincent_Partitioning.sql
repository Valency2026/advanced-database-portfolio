-- =====================================================================
-- Portfolio 5 - Partitioning the ledger (the single-node form of sharding)
-- Student: Fakiyesi Vincent (2026/A/MIT/0304)
--
-- Two partitioning strategies on the 240k-row ledger:
--   A. RANGE by month  -> old months can be detached / archived; statement
--      queries for one month touch one partition (partition pruning)
--   B. HASH by account_id -> the same split a sharded cluster would use to
--      spread accounts across 4 nodes; every account's rows live together
-- Run: psql -d nairavault -f Fakiyesi_Vincent_Partitioning.sql
-- =====================================================================
SET search_path TO vault;
\timing on

-- ---------- A. Range partitioning by month -----------------------------
DROP TABLE IF EXISTS transactions_by_month CASCADE;
CREATE TABLE transactions_by_month (
    transaction_id BIGINT        NOT NULL,
    account_id     BIGINT        NOT NULL,
    transfer_id    BIGINT,
    txn_type       VARCHAR(12)   NOT NULL,
    direction      CHAR(2)       NOT NULL,
    amount         NUMERIC(18,2) NOT NULL,
    balance_after  NUMERIC(18,2) NOT NULL,
    channel        VARCHAR(10)   NOT NULL,
    description    VARCHAR(140),
    created_at     TIMESTAMPTZ   NOT NULL,
    PRIMARY KEY (transaction_id, created_at)      -- partition key must be in the PK
) PARTITION BY RANGE (created_at);

-- one partition per month, Jan 2026 .. Dec 2026, plus a default for strays
DO $$
DECLARE m DATE := DATE '2026-01-01';
BEGIN
  WHILE m < DATE '2027-01-01' LOOP
    EXECUTE format('CREATE TABLE transactions_%s PARTITION OF transactions_by_month
                    FOR VALUES FROM (%L) TO (%L)',
                   to_char(m, 'YYYY_MM'), m, m + INTERVAL '1 month');
    m := m + INTERVAL '1 month';
  END LOOP;
END $$;
CREATE TABLE transactions_default PARTITION OF transactions_by_month DEFAULT;

-- same index strategy as Portfolio 2, now created on every partition automatically
CREATE INDEX idx_tbm_account_created ON transactions_by_month (account_id, created_at DESC);

INSERT INTO transactions_by_month SELECT * FROM transactions;

\echo ''
\echo '--- Rows per partition'
SELECT c.relname AS partition, pg_size_pretty(pg_relation_size(c.oid)) AS size,
       (xpath('/row/cnt/text()', query_to_xml('SELECT count(*) AS cnt FROM vault.' || c.relname, false, true, '')))[1]::text::int AS rows
FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'vault.transactions_by_month'::regclass
ORDER BY c.relname;

\echo ''
\echo '--- PARTITION PRUNING: October fee report reads ONE partition'
EXPLAIN (ANALYZE, BUFFERS)
SELECT date_trunc('day', created_at)::date AS day, sum(amount)
FROM transactions_by_month
WHERE txn_type = 'fee' AND created_at >= '2026-10-01' AND created_at < '2026-11-01'
GROUP BY 1 ORDER BY 1;

\echo ''
\echo '--- Same report on the unpartitioned table (for comparison, both have an index)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT date_trunc('day', created_at)::date AS day, sum(amount)
FROM transactions
WHERE txn_type = 'fee' AND created_at >= '2026-10-01' AND created_at < '2026-11-01'
GROUP BY 1 ORDER BY 1;

\echo ''
\echo '--- Archiving: detach January 2026 in milliseconds (no DELETE of 20k rows)'
ALTER TABLE transactions_by_month DETACH PARTITION transactions_2026_01;
SELECT count(*) AS rows_still_visible_in_parent FROM transactions_by_month WHERE created_at < '2026-02-01';
SELECT count(*) AS rows_in_detached_archive FROM transactions_2026_01;
ALTER TABLE transactions_by_month ATTACH PARTITION transactions_2026_01
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');

-- ---------- B. Hash partitioning by account (sharding simulation) --------
\echo ''
\echo '=== B. HASH partitioning by account_id into 4 "shards"'
DROP TABLE IF EXISTS transactions_by_shard CASCADE;
CREATE TABLE transactions_by_shard (LIKE transactions INCLUDING DEFAULTS)
    PARTITION BY HASH (account_id);
CREATE TABLE transactions_shard_0 PARTITION OF transactions_by_shard FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE transactions_shard_1 PARTITION OF transactions_by_shard FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE transactions_shard_2 PARTITION OF transactions_by_shard FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE transactions_shard_3 PARTITION OF transactions_by_shard FOR VALUES WITH (MODULUS 4, REMAINDER 3);
CREATE INDEX idx_tbs_account_created ON transactions_by_shard (account_id, created_at DESC);
INSERT INTO transactions_by_shard SELECT * FROM transactions;

\echo '--- Even distribution across shards (hash spreads accounts evenly)'
SELECT tableoid::regclass AS shard, count(*) AS rows, count(DISTINCT account_id) AS accounts
FROM transactions_by_shard GROUP BY 1 ORDER BY 1;

\echo ''
\echo '--- A statement query goes to exactly ONE shard (the one holding account 1250)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT created_at, txn_type, amount FROM transactions_by_shard
WHERE account_id = 1250 ORDER BY created_at DESC LIMIT 20;

\echo ''
\echo '--- A cross-account report must touch ALL shards (the cost of sharding)'
EXPLAIN (ANALYZE, SUMMARY)
SELECT txn_type, count(*), sum(amount) FROM transactions_by_shard GROUP BY txn_type ORDER BY 1;

-- tidy up (keep the monthly table as evidence, drop the shard copy)
DROP TABLE transactions_by_shard CASCADE;
