# Portfolio 4 — NoSQL and Advanced Data Models

NairaVault modelled as a **MongoDB document store** (customer documents with embedded wallets, beneficiaries and KYC; one document per ledger entry; a key-value daily-limit collection with TTL; free-form notifications), plus the same document model inside PostgreSQL with **JSONB + GIN**.

## Files

| File | Purpose |
|---|---|
| `Fakiyesi_Vincent_DocumentModel.md` | Design: which NoSQL model and why, embedding vs referencing decisions, relational vs document comparison, suitability assessment |
| `Fakiyesi_Vincent_MongoScript.js` | mongosh script — collections with JSON Schema validation, compound/multikey/TTL indexes, inserts, queries, `$push`/`$inc` updates, aggregation pipelines, `explain()`. Runs unchanged on MongoDB 6/7 or Atlas |
| `Fakiyesi_Vincent_MongoDemo.py` | Migrates the live PostgreSQL data to documents through the **pymongo** API and runs the same queries; uses mongomock when no `MONGO_URI` is set |
| `Fakiyesi_Vincent_JSONB.sql` | Same documents in a PostgreSQL JSONB column: containment queries, GIN index before/after plans, `jsonb_set` updates, array aggregation |
| `evidence/01_mongo_demo_output.txt` | Output of the pymongo demo |
| `evidence/02_jsonb_demo_output.txt` | Output of the JSONB demo including execution plans |
| `evidence/sample_customers.json`, `sample_transactions.json` | Exported documents, one per line (`mongoimport` format) |

## Honest note on the engine

A MongoDB server could not be installed in my working environment (no Docker, download blocked). The Python demo therefore runs against **mongomock**, an in-memory engine that implements the pymongo interface — the code is the real driver code and switches to a real server by setting `MONGO_URI`. Because mongomock is pure Python it is slow on large collections, so the demo migrates the most recent 25,000 ledger rows and its timings are not representative. The mongosh script is the reference implementation for a real server, and the JSONB demo gives real execution-plan evidence from PostgreSQL.

## Headline results

- Home screen served by **one** document read instead of a 4-table join
- Query inside an embedded array, `$push` beneficiary, atomic `$inc` daily-limit counter with TTL expiry (the TTL index actually expired a document whose date was in the past during testing)
- Aggregation pipelines reproduce the Portfolio 2 fee report and a per-state balance report; `$lookup` performs a join-like enrichment
- Cross-model check: embedded wallet balance equals the last ledger entry for every wallet checked (after adding `_id` as a sort tie-breaker — debit and fee rows share a timestamp)
- JSONB containment query on 3,000 documents: Seq Scan 1.87 ms → GIN Bitmap Index Scan 0.07 ms
