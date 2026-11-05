-- =====================================================================
-- Portfolio 2 - Indexes added after reading the execution plans
-- Student: Fakiyesi Vincent (2026/A/MIT/0304)
-- Each index is justified by a specific query's plan (see Analysis.md)
-- =====================================================================
SET search_path TO vault;

-- Q1: statement lookup filters on account_id and a date range, orders by created_at.
-- A composite B-tree index lets PostgreSQL jump straight to the account's rows
-- in date order, so the ORDER BY needs no separate sort.
CREATE INDEX idx_txn_account_created ON transactions (account_id, created_at DESC);

-- Q2: only ~15% of transfers are 'failed', and support only ever asks about failed ones.
-- A PARTIAL index stores only those rows - small, fast, cheap to maintain.
CREATE INDEX idx_transfers_failed_recent ON transfers (initiated_at DESC)
    WHERE status = 'failed';

-- Q3: fee report filters on txn_type = 'fee' and a date range and only reads amount.
-- A partial, COVERING index (INCLUDE amount) means the query never touches the table
-- at all - an "Index Only Scan".
CREATE INDEX idx_txn_fee_created ON transactions (created_at) INCLUDE (amount)
    WHERE txn_type = 'fee';

-- Q4: velocity check scans every transfer_out ordered by account then time.
CREATE INDEX idx_txn_transfer_out ON transactions (account_id, created_at)
    WHERE txn_type = 'transfer_out';

-- Q2 / Q6 / Q7: joins from transfers to accounts and from accounts to customers.
-- Foreign key columns are NOT indexed automatically in PostgreSQL.
CREATE INDEX idx_transfers_source_status ON transfers (source_account_id, status);
CREATE INDEX idx_accounts_customer ON accounts (customer_id);

-- Q6: completed transfers in a date range
CREATE INDEX idx_transfers_completed_initiated ON transfers (initiated_at)
    WHERE status = 'completed';

-- Update planner statistics so it knows about the new indexes and data shape
ANALYZE transactions;
ANALYZE transfers;
ANALYZE accounts;
ANALYZE customers;
