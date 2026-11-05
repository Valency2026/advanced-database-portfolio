-- =====================================================================
-- Portfolio 4 - The document model INSIDE PostgreSQL using JSONB
-- Student: Fakiyesi Vincent (2026/A/MIT/0304)
-- Shows that a relational engine can also act as a document store:
-- build the same customer documents, index them with GIN, query them
-- with JSON operators, and compare the plan with and without the index.
-- Run: psql -d nairavault -f Fakiyesi_Vincent_JSONB.sql
-- =====================================================================
SET search_path TO vault;
\timing on

DROP TABLE IF EXISTS customer_documents;
CREATE TABLE customer_documents (
    customer_id BIGINT PRIMARY KEY,
    doc         JSONB  NOT NULL
);

-- 1. Build one document per customer from the relational tables (same shape
--    as the MongoDB 'customers' collection)
INSERT INTO customer_documents
SELECT c.customer_id,
       jsonb_build_object(
         'fullName', c.full_name, 'phone', c.phone, 'email', c.email,
         'state', c.state_of_residence,
         'kyc', jsonb_build_object('tier', c.kyc_tier, 'status', c.status,
                 'documents', coalesce((SELECT jsonb_agg(jsonb_build_object(
                       'type', k.document_type, 'numberMasked', k.document_number_masked, 'status', k.status))
                     FROM kyc_documents k WHERE k.customer_id = c.customer_id), '[]'::jsonb)),
         'accounts', (SELECT jsonb_agg(jsonb_build_object(
                       'accountNumber', a.account_number, 'type', a.account_type,
                       'balance', a.balance, 'status', a.status))
                     FROM accounts a WHERE a.customer_id = c.customer_id),
         'beneficiaries', coalesce((SELECT jsonb_agg(jsonb_build_object(
                       'alias', b.alias, 'accountNumber', b.account_number,
                       'bankCode', b.bank_code, 'bankName', k.bank_name))
                     FROM beneficiaries b JOIN banks k USING (bank_code)
                     WHERE b.customer_id = c.customer_id), '[]'::jsonb),
         'createdAt', c.created_at)
FROM customers c;

SELECT count(*) AS documents, pg_size_pretty(pg_total_relation_size('customer_documents')) AS size
FROM customer_documents;

\echo ''
\echo '--- 2. One document read = whole home screen'
SELECT jsonb_pretty(doc) FROM customer_documents WHERE customer_id = 1250;

\echo ''
\echo '--- 3. Query inside the embedded array: who owns wallet 2010001537? (no index yet)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, doc->>'fullName'
FROM customer_documents
WHERE doc @> '{"accounts": [{"accountNumber": "2010001537"}]}';

\echo ''
\echo '--- 4. Add a GIN index on the whole document, re-run'
CREATE INDEX idx_customer_documents_gin ON customer_documents USING GIN (doc jsonb_path_ops);
ANALYZE customer_documents;
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, doc->>'fullName'
FROM customer_documents
WHERE doc @> '{"accounts": [{"accountNumber": "2010001537"}]}';

\echo ''
\echo '--- 5. Containment query on nested field: tier-1 customers in Enugu'
SELECT count(*) FROM customer_documents
WHERE doc @> '{"state": "Enugu", "kyc": {"tier": 1}}';

\echo ''
\echo '--- 6. Update inside the document: push a beneficiary (atomic, like $push)'
UPDATE customer_documents
SET doc = jsonb_set(doc, '{beneficiaries}',
          (doc->'beneficiaries') || '{"alias":"Landlord","accountNumber":"0987654321","bankCode":"044","bankName":"Access Bank"}'::jsonb)
WHERE customer_id = 1250;
SELECT jsonb_array_length(doc->'beneficiaries') AS beneficiaries, doc->'beneficiaries'->-1 AS last_added
FROM customer_documents WHERE customer_id = 1250;

\echo ''
\echo '--- 7. Aggregate over embedded arrays (like $unwind + $group): balance per state'
SELECT doc->>'state' AS state, count(*) AS wallets, sum((a->>'balance')::numeric) AS total_balance
FROM customer_documents, jsonb_array_elements(doc->'accounts') a
WHERE a->>'status' = 'open'
GROUP BY 1 ORDER BY 3 DESC LIMIT 5;

\echo ''
\echo '--- 8. Schema flexibility: a field that only some documents have'
UPDATE customer_documents SET doc = doc || '{"referralCode": "NV-CHIOMA-22"}' WHERE customer_id = 1250;
SELECT customer_id, doc->>'referralCode' FROM customer_documents WHERE doc ? 'referralCode';
