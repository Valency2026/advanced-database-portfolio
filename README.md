# Advanced Database Systems Portfolio — NairaVault

**Student:** Fakiyesi Vincent · **Student ID:** 2026/A/MIT/0304 · **Email:** v.fakiyesi0101@miva.edu.ng  
**Programme:** M.Sc. Information Technology, Miva Open University  
**Course:** MIT 8103 Advanced Database Systems — 2026/2027 First Semester Continuous Assessment  
**Case study:** NairaVault, a simulated Nigerian digital wallet / fintech platform (used consistently in all five portfolios)

## What this repository contains

| Folder | Portfolio | Main evidence |
|---|---|---|
| `portfolio-1-database-design/` | Database Design and Modelling | Case study, ER diagram (PNG), 9-table schema with constraints and immutable-ledger trigger, 242k-row seed data, 11 constraint tests, normalisation to 3NF/BCNF |
| `portfolio-2-query-optimisation/` | Query Processing and Optimisation | 8 business queries, `EXPLAIN ANALYZE` plans before/after indexing, timing table (up to 200x), analysis |
| `portfolio-3-transactions-concurrency/` | Transactions and Concurrency | `transfer_funds()` / `reverse_transfer()` procedures, COMMIT/ROLLBACK/SAVEPOINT demos, two-session lost-update, isolation-level, deadlock and 800-transfer stress test logs |
| `portfolio-4-nosql/` | NoSQL and Advanced Data Models | MongoDB document model, mongosh script, pymongo migration + aggregation demo, PostgreSQL JSONB + GIN demo |
| `portfolio-5-distributed-cloud/` | Distributed and Cloud Database Exercise | Real primary + streaming-replica setup with failover, monthly and hash partitioning, cloud architecture and consistency discussion |
| `final-documentation/` | Final Documentation | 2–3 page summary (DOCX/PDF), technical reflection, AI-use declaration, references |

Every folder has its own `README.md` explaining how the work was implemented and tested, and an `evidence/` folder with the captured terminal output.

## Technology

- PostgreSQL 16 (all relational work, replication, partitioning, JSONB)
- Python 3 with `psycopg2` and `pymongo` (data generation, benchmarks, concurrency tests, document migration)
- MongoDB document model: `mongosh` script for a real server; `mongomock` used as a pymongo-compatible stand-in where no server was available (explained in Portfolio 4)
- Mermaid for the ER diagram

## Running everything from scratch

```bash
createdb nairavault
cd portfolio-1-database-design
psql -d nairavault -f Fakiyesi_Vincent_Schema.sql
python3 Fakiyesi_Vincent_SeedData.py "dbname=nairavault"
psql -d nairavault -f Fakiyesi_Vincent_ConstraintTests.sql

cd ../portfolio-2-query-optimisation
python3 Fakiyesi_Vincent_Benchmark.py "dbname=nairavault"

cd ../portfolio-3-transactions-concurrency
psql -d nairavault -f Fakiyesi_Vincent_Procedures.sql
psql -d nairavault -f Fakiyesi_Vincent_TransactionDemo.sql
python3 Fakiyesi_Vincent_ConcurrencyDemo.py "dbname=nairavault"

cd ../portfolio-4-nosql
python3 Fakiyesi_Vincent_MongoDemo.py "dbname=nairavault"        # or MONGO_URI=... for a real server
psql -d nairavault -f Fakiyesi_Vincent_JSONB.sql

cd ../portfolio-5-distributed-cloud
bash Fakiyesi_Vincent_ReplicationSetup.sh                          # as the postgres OS user
psql -d nairavault -f Fakiyesi_Vincent_Partitioning.sql
```

Python dependencies: `pip install psycopg2-binary pymongo mongomock`

## Academic integrity

This is individual work.
`final-documentation/Fakiyesi_Vincent_AIUseDeclaration.md`. All external sources are
listed in `final-documentation/Fakiyesi_Vincent_References.md`.
