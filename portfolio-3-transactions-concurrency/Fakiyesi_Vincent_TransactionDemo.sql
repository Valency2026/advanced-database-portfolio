-- =====================================================================
-- Portfolio 3 - Single-session transaction demonstrations
-- Student: Fakiyesi Vincent (2026/A/MIT/0304)
-- Shows: COMMIT, ROLLBACK, automatic rollback on error, SAVEPOINT,
--        reversal, and that the ledger stays consistent throughout.
-- Run:  psql -d nairavault -f Fakiyesi_Vincent_TransactionDemo.sql
-- =====================================================================
SET search_path TO vault;
\set ON_ERROR_STOP off

-- Two test accounts set to known starting balances THROUGH the ledger
-- (a raw UPDATE would break the balance/ledger reconciliation)
DO $$
DECLARE r RECORD; v_diff NUMERIC(18,2);
BEGIN
  FOR r IN SELECT * FROM (VALUES (10, 100000.00), (20, 5000.00)) AS t(id, target) LOOP
    SELECT r.target - balance INTO v_diff FROM accounts WHERE account_id = r.id;
    IF v_diff <> 0 THEN
      UPDATE accounts SET balance = r.target, status = 'open' WHERE account_id = r.id;
      INSERT INTO transactions(account_id, txn_type, direction, amount, balance_after, channel, description)
      VALUES (r.id, CASE WHEN v_diff > 0 THEN 'deposit' ELSE 'withdrawal' END,
              CASE WHEN v_diff > 0 THEN 'CR' ELSE 'DR' END, abs(v_diff), r.target, 'system', 'Demo balance reset');
    END IF;
  END LOOP;
END $$;
\echo '=== Starting balances ==='
SELECT account_id, balance FROM accounts WHERE account_id IN (10, 20) ORDER BY 1;

-- ---------------------------------------------------------------------
\echo ''
\echo '=== DEMO 1: successful transfer -> COMMIT ==='
BEGIN;
SELECT transfer_funds(10, 20, 25000.00, 'Rent for November') AS reference;
SELECT account_id, balance FROM accounts WHERE account_id IN (10, 20) ORDER BY 1;
COMMIT;
\echo 'After COMMIT (10 should be 74,990 = 100,000 - 25,000 - 10 fee; 20 should be 30,000):'
SELECT account_id, balance FROM accounts WHERE account_id IN (10, 20) ORDER BY 1;

-- ---------------------------------------------------------------------
\echo ''
\echo '=== DEMO 2: manual ROLLBACK - changes vanish ==='
BEGIN;
UPDATE accounts SET balance = balance - 1000 WHERE account_id = 10;
\echo 'Inside the transaction, balance of 10 looks reduced:'
SELECT account_id, balance FROM accounts WHERE account_id = 10;
ROLLBACK;
\echo 'After ROLLBACK, balance of 10 is back to 74,990:'
SELECT account_id, balance FROM accounts WHERE account_id = 10;

-- ---------------------------------------------------------------------
\echo ''
\echo '=== DEMO 3: insufficient funds -> exception -> automatic rollback ==='
\echo 'Account 20 has 30,000; try to send 50,000'
BEGIN;
SELECT transfer_funds(20, 10, 50000.00, 'Too much');
COMMIT;
\echo 'Balances unchanged, and no half-written ledger rows:'
SELECT account_id, balance FROM accounts WHERE account_id IN (10, 20) ORDER BY 1;
SELECT count(*) AS ledger_rows_for_failed_transfer
FROM transactions WHERE account_id IN (10,20) AND description = 'Too much';

-- ---------------------------------------------------------------------
\echo ''
\echo '=== DEMO 4: SAVEPOINT - partial rollback inside one transaction ==='
BEGIN;
SELECT transfer_funds(10, 20, 1000.00, 'First gift') AS ref1;
SAVEPOINT after_first_gift;
SELECT transfer_funds(10, 20, 2000.00, 'Second gift') AS ref2;
\echo 'Both gifts applied (10 = 74,990 - 1,010 - 2,010 = 71,970):'
SELECT account_id, balance FROM accounts WHERE account_id IN (10, 20) ORDER BY 1;
ROLLBACK TO SAVEPOINT after_first_gift;
\echo 'Second gift undone, first kept (10 = 73,980):'
SELECT account_id, balance FROM accounts WHERE account_id IN (10, 20) ORDER BY 1;
COMMIT;

-- ---------------------------------------------------------------------
\echo ''
\echo '=== DEMO 5: reversal of a completed transfer by support staff ==='
SELECT reference, status, amount, fee FROM transfers
WHERE narration = 'Rent for November' ORDER BY transfer_id DESC LIMIT 1 \gset
\echo 'Reversing:' :reference
SELECT reverse_transfer(:'reference', 2, 'Customer sent to wrong account');
SELECT reference, status, failure_reason, reversed_by_staff_id FROM transfers WHERE reference = :'reference';
\echo 'Sender gets amount + fee back; receiver debited:'
SELECT account_id, balance FROM accounts WHERE account_id IN (10, 20) ORDER BY 1;
\echo 'Ledger shows the original legs AND the reversal legs (nothing deleted):'
SELECT t.account_id, t.txn_type, t.direction, t.amount, t.balance_after
FROM transactions t JOIN transfers tr USING (transfer_id)
WHERE tr.reference = :'reference' ORDER BY t.transaction_id;

-- ---------------------------------------------------------------------
\echo ''
\echo '=== DEMO 6: reversing twice is refused ==='
SELECT reverse_transfer(:'reference', 2, 'Trying again');

-- ---------------------------------------------------------------------
\echo ''
\echo '=== DEMO 7: daily KYC limit enforced inside the transaction ==='
\echo 'Account 10 belongs to a tier-1 customer? ->'
SELECT a.account_id, c.kyc_tier FROM accounts a JOIN customers c USING (customer_id) WHERE a.account_id = 10;
UPDATE customers SET kyc_tier = 1 WHERE customer_id = (SELECT customer_id FROM accounts WHERE account_id = 10);
SELECT transfer_funds(10, 20, 49000.00, 'Big one');
\echo '(above should fail: 26,000 already sent today + 49,000 > 50,000 tier-1 limit)'

\echo ''
\echo '=== Final consistency check: every balance still matches its ledger ==='
SELECT count(*) AS accounts, count(*) FILTER (WHERE a.balance = s.net) AS consistent
FROM accounts a
JOIN (SELECT account_id, sum(CASE WHEN direction='CR' THEN amount ELSE -amount END) AS net
      FROM transactions GROUP BY account_id) s USING (account_id);
