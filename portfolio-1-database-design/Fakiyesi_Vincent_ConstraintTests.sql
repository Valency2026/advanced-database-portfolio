-- =====================================================================
-- Portfolio 1 - Constraint / integrity tests
-- Each statement below is EXPECTED TO FAIL. The error message proves
-- the database is enforcing the business rule.
-- Run: psql -d nairavault -f Fakiyesi_Vincent_ConstraintTests.sql
-- =====================================================================
SET search_path TO vault;
\set ON_ERROR_STOP off
\echo '--- 1. Balance can never go negative'
UPDATE accounts SET balance = -50 WHERE account_id = 1;

\echo '--- 2. Customer must be 18 or older'
INSERT INTO customers(full_name, phone, date_of_birth)
VALUES ('Too Young', '08199999999', CURRENT_DATE - INTERVAL '15 years');

\echo '--- 3. Duplicate phone number rejected (UNIQUE)'
INSERT INTO customers(full_name, phone, date_of_birth)
SELECT 'Duplicate Phone', phone, '1990-01-01' FROM customers WHERE customer_id = 1;

\echo '--- 4. Account must belong to an existing customer (FOREIGN KEY)'
INSERT INTO accounts(customer_id, account_number) VALUES (999999, '2099999999');

\echo '--- 5. Account number must be exactly 10 digits'
INSERT INTO accounts(customer_id, account_number) VALUES (1, 'ABC123');

\echo '--- 6. Transfer must be internal OR external, not both'
INSERT INTO transfers(reference, source_account_id, destination_account_id,
                      external_account_number, external_bank_code, amount)
VALUES ('NVTEST000000000001', 1, 2, '0123456789', '044', 100);

\echo '--- 7. Cannot transfer to yourself'
INSERT INTO transfers(reference, source_account_id, destination_account_id, amount)
VALUES ('NVTEST000000000002', 1, 1, 100);

\echo '--- 8. Transfer amount must be positive'
INSERT INTO transfers(reference, source_account_id, destination_account_id, amount)
VALUES ('NVTEST000000000003', 1, 2, -500);

\echo '--- 9. Ledger rows cannot be edited (trigger)'
UPDATE transactions SET amount = 1 WHERE transaction_id = 1;

\echo '--- 10. Ledger rows cannot be deleted (trigger)'
DELETE FROM transactions WHERE transaction_id = 1;

\echo '--- 11. Invalid txn_type rejected'
INSERT INTO transactions(account_id, txn_type, direction, amount, balance_after)
VALUES (1, 'bribe', 'DR', 100, 0);

\echo ''
\echo '=== Reconciliation: cached balance vs last ledger balance_after ==='
SELECT count(*) AS accounts_checked,
       count(*) FILTER (WHERE a.balance = l.balance_after) AS matching,
       count(*) FILTER (WHERE a.balance <> l.balance_after) AS mismatched
FROM accounts a
JOIN LATERAL (
    SELECT balance_after FROM transactions t
    WHERE t.account_id = a.account_id
    ORDER BY created_at DESC, transaction_id DESC LIMIT 1
) l ON true;

\echo '=== Ledger self-consistency: sum of CR minus DR equals balance ==='
SELECT count(*) AS accounts_with_ledger,
       count(*) FILTER (WHERE a.balance = s.net) AS consistent
FROM accounts a
JOIN (SELECT account_id,
             sum(CASE WHEN direction = 'CR' THEN amount ELSE -amount END) AS net
      FROM transactions GROUP BY account_id) s USING (account_id);
