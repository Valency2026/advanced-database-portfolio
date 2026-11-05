# Portfolio 1 — Database Design and Modelling

Case study: **NairaVault**, a simulated Nigerian digital wallet (fintech) platform.

## Files

| File | Purpose |
|---|---|
| `Fakiyesi_Vincent_CaseStudy.md` | Organisation, users, data stored, operations supported |
| `Fakiyesi_Vincent_ERDiagram.mmd` / `.png` | Entity-relationship diagram (Mermaid source + rendered image) |
| `Fakiyesi_Vincent_Schema.sql` | Full DDL: 9 tables, keys, CHECK constraints, immutable-ledger trigger, view |
| `Fakiyesi_Vincent_SeedData.py` | Generates a consistent test dataset (3,000 customers, 242k ledger rows) |
| `Fakiyesi_Vincent_ConstraintTests.sql` | 11 invalid statements that the DB must reject + balance reconciliation |
| `Fakiyesi_Vincent_Normalisation.md` | Keys, constraints, UNF → 1NF → 2NF → 3NF/BCNF walkthrough |
| `evidence/` | Captured terminal output of each step |

## How it was implemented and tested

```bash
createdb nairavault
psql -d nairavault -f Fakiyesi_Vincent_Schema.sql            # evidence/01
python3 Fakiyesi_Vincent_SeedData.py "dbname=nairavault"     # evidence/02
psql -d nairavault -f Fakiyesi_Vincent_ConstraintTests.sql   # evidence/03
```

Result: all 11 invalid operations were rejected by the database, and the cached
balance of every one of the 3,719 accounts matched the ledger.

## Row counts after seeding

| Table | Rows |
|---|---|
| customers | 3,000 |
| accounts | 3,719 |
| transfers | 67,245 |
| transactions | 242,531 |
| beneficiaries | 3,319 |
| kyc_documents | 3,496 |
| audit_log | 3,166 |
