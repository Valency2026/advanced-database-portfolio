-- =====================================================================
-- Portfolio 2 - Business queries for NairaVault
-- Student: Fakiyesi Vincent (2026/A/MIT/0304)
-- Each query answers a real question the business asks every day.
-- Run on its own:  psql -d nairavault -f Fakiyesi_Vincent_Queries.sql
-- =====================================================================
SET search_path TO vault;

-- Q1. Customer statement: all ledger entries for one account in a month.
--     (Most frequent query in the app: "show my history")
-- name: q1_statement
SELECT created_at, txn_type, direction, amount, balance_after, description
FROM transactions
WHERE account_id = 1250
  AND created_at >= '2026-06-01' AND created_at < '2026-07-01'
ORDER BY created_at DESC;

-- Q2. Failed transfers in the last 7 days of the dataset, with customer contact
--     (Support team's daily worklist)
-- name: q2_failed_transfers
SELECT t.reference, c.full_name, c.phone, t.amount, t.failure_reason, t.initiated_at
FROM transfers t
JOIN accounts  a ON a.account_id = t.source_account_id
JOIN customers c ON c.customer_id = a.customer_id
WHERE t.status = 'failed'
  AND t.initiated_at >= '2026-10-24'
ORDER BY t.initiated_at DESC;

-- Q3. Daily fee revenue for October 2026 (Finance report)
-- name: q3_fee_revenue
SELECT date_trunc('day', created_at)::date AS day,
       count(*)                            AS fee_count,
       sum(amount)                         AS fee_revenue_ngn
FROM transactions
WHERE txn_type = 'fee'
  AND created_at >= '2026-10-01' AND created_at < '2026-11-01'
GROUP BY 1
ORDER BY 1;

-- Q4. Suspicious activity: accounts that made 2+ outgoing transfers within
--     any 10-minute window (Compliance monitoring, uses a window function)
-- name: q4_velocity_check
WITH outgoing AS (
    SELECT account_id, created_at,
           count(*) OVER (PARTITION BY account_id
                          ORDER BY created_at
                          RANGE BETWEEN INTERVAL '10 minutes' PRECEDING AND CURRENT ROW) AS n_in_window
    FROM transactions
    WHERE txn_type = 'transfer_out'
)
SELECT o.account_id, a.account_number, c.full_name, c.kyc_tier,
       max(o.n_in_window) AS max_transfers_in_10_min
FROM outgoing o
JOIN accounts  a ON a.account_id = o.account_id
JOIN customers c ON c.customer_id = a.customer_id
WHERE o.n_in_window >= 2
GROUP BY o.account_id, a.account_number, c.full_name, c.kyc_tier
ORDER BY max_transfers_in_10_min DESC, o.account_id
LIMIT 20;

-- Q5. Balance reconciliation: cached balance vs ledger for every account
--     (Finance runs this nightly; must be exact)
-- name: q5_reconciliation
SELECT a.account_id, a.balance,
       coalesce(l.net, 0) AS ledger_balance,
       a.balance - coalesce(l.net, 0) AS difference
FROM accounts a
LEFT JOIN (
    SELECT account_id,
           sum(CASE WHEN direction = 'CR' THEN amount ELSE -amount END) AS net
    FROM transactions
    GROUP BY account_id
) l ON l.account_id = a.account_id
WHERE a.balance <> coalesce(l.net, 0);

-- Q6. Top 5 states by transfer volume in Q3 2026 (Marketing)
-- name: q6_state_volume
SELECT c.state_of_residence,
       count(*)      AS transfers,
       sum(t.amount) AS total_ngn
FROM transfers t
JOIN accounts  a ON a.account_id = t.source_account_id
JOIN customers c ON c.customer_id = a.customer_id
WHERE t.status = 'completed'
  AND t.initiated_at >= '2026-07-01' AND t.initiated_at < '2026-10-01'
GROUP BY c.state_of_residence
ORDER BY total_ngn DESC
LIMIT 5;

-- Q7. Customers with pending KYC who have transferred more than N50,000 in total
--     (Compliance: tier-1 customers over their limit) - written two ways
--     7a: correlated subquery (slow style)
-- name: q7a_pending_kyc_subquery
SELECT c.customer_id, c.full_name, c.phone,
       (SELECT sum(t.amount) FROM transfers t
        JOIN accounts a ON a.account_id = t.source_account_id
        WHERE a.customer_id = c.customer_id AND t.status = 'completed') AS total_sent
FROM customers c
WHERE c.kyc_tier = 1
  AND (SELECT sum(t.amount) FROM transfers t
       JOIN accounts a ON a.account_id = t.source_account_id
       WHERE a.customer_id = c.customer_id AND t.status = 'completed') > 50000
ORDER BY total_sent DESC;

--     7b: same result, rewritten as a join + GROUP BY + HAVING
-- name: q7b_pending_kyc_join
SELECT c.customer_id, c.full_name, c.phone, sum(t.amount) AS total_sent
FROM customers c
JOIN accounts  a ON a.customer_id = c.customer_id
JOIN transfers t ON t.source_account_id = a.account_id AND t.status = 'completed'
WHERE c.kyc_tier = 1
GROUP BY c.customer_id, c.full_name, c.phone
HAVING sum(t.amount) > 50000
ORDER BY total_sent DESC;
