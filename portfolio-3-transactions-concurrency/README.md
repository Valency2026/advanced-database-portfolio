# Portfolio 3 — Transactions and Concurrency

## Files

| File | Purpose |
|---|---|
| `Fakiyesi_Vincent_Procedures.sql` | `transfer_funds()` and `reverse_transfer()` — atomic PL/pgSQL functions with ordered row locking, KYC limit and funds checks |
| `Fakiyesi_Vincent_TransactionDemo.sql` | Single-session demos: COMMIT, ROLLBACK, auto-rollback on error, SAVEPOINT, reversal, limit enforcement |
| `Fakiyesi_Vincent_ConcurrencyDemo.py` | Multi-session demos on real threads: lost update, FOR UPDATE fix, READ COMMITTED vs REPEATABLE READ, deadlock detection, deadlock prevention, 800-transfer stress test |
| `Fakiyesi_Vincent_TransactionsReport.md` | Explanation of the results against ACID and concurrency-control theory |
| `evidence/01_procedures_created.txt` | Procedure creation output |
| `evidence/02_transaction_demo_output.txt` | Full psql output of the transaction demos |
| `evidence/03_concurrency_demo_output.txt` | Timestamped two-session logs |

## How to reproduce

```bash
psql -d nairavault -f Fakiyesi_Vincent_Procedures.sql
psql -d nairavault -f Fakiyesi_Vincent_TransactionDemo.sql
python3 Fakiyesi_Vincent_ConcurrencyDemo.py "dbname=nairavault"
```

## Headline results

- Failed transfer: exception → rollback → **0** ledger rows, balances untouched
- Naive concurrent withdrawals **lost ₦4,000**; with `SELECT … FOR UPDATE` the result was correct
- READ COMMITTED showed a non-repeatable read; REPEATABLE READ did not
- Deliberate A→B / B→A locking produced `deadlock detected` after 1 s; the same pattern through `transfer_funds()` gave 0 deadlocks in 100 opposing transfers
- Stress test: 794 concurrent transfers, 0 negative balances, every account reconciled, money lost = fees exactly
