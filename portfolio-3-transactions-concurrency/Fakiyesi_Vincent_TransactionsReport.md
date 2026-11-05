# Portfolio 3 — Transactions and Concurrency

**Student:** Fakiyesi Vincent (2026/A/MIT/0304) · **DBMS:** PostgreSQL 16 (MVCC)

## 1. The transaction at the heart of NairaVault

A wallet transfer touches four tables (accounts twice, transfers, transactions three
times, audit_log once). If the process crashes halfway, money is either created or
destroyed. So the whole operation is wrapped in a single PL/pgSQL function,
`transfer_funds()` (`Fakiyesi_Vincent_Procedures.sql`), which runs as one atomic
transaction. The steps are:

1. Lock both account rows with `SELECT … FOR UPDATE`, lower `account_id` first.
2. Check both accounts are open.
3. Check the sender's KYC-tier daily limit.
4. Check sufficient funds (amount + ₦10 fee) — *while the row is locked*.
5. Insert the `transfers` event, update sender balance, write `transfer_out` and `fee`
   ledger rows, update receiver balance, write `transfer_in` row, write audit row.
6. Any `RAISE EXCEPTION` at any step aborts everything.

`reverse_transfer()` undoes a completed transfer by posting opposite ledger entries;
the original rows are never touched, because the ledger is immutable (trigger from
Portfolio 1).

## 2. ACID properties demonstrated (`evidence/02_transaction_demo_output.txt`)

| Property | Demo | What the evidence shows |
|---|---|---|
| **Atomicity** | Demo 3: insufficient funds | Exception → `ROLLBACK`; balances unchanged, **0** ledger rows written for the failed transfer |
| **Consistency** | Every demo ends with reconciliation | 3,719 of 3,719 accounts match their ledger after all demos |
| **Isolation** | Demo 2: ROLLBACK | Inside the transaction the balance looks reduced; after ROLLBACK it is back to 74,990 |
| **Durability** | Demo 1: COMMIT | Balances read back after COMMIT from a new statement show the committed values |
| Partial rollback | Demo 4: SAVEPOINT | Second gift undone with `ROLLBACK TO SAVEPOINT`, first gift kept, then COMMIT |
| Compensating transaction | Demo 5: reversal | Sender refunded amount + fee; both original and reversal legs visible in the ledger |
| Business rule in transaction | Demo 6, 7 | Double reversal refused; tier-1 daily limit (₦50,000) refused a ₦49,000 transfer because ₦26,000 was already sent that day |

## 3. Concurrency problems and their control (`evidence/03_concurrency_demo_output.txt`)

These demos use **separate database connections on separate threads**, so the
interleaving happens inside PostgreSQL, not in the script.

### 3.1 Lost update (Demo 1 → Demo 2)

Account starts at ₦10,000. Session A withdraws 3,000; Session B withdraws 4,000.

- **Naive read-then-write:** both sessions read 10,000, B writes 6,000, A then writes
  7,000. Final balance **7,000 — B's withdrawal vanished**. The timestamps show A's
  UPDATE landing 0.1 ms after B's COMMIT.
- **With `SELECT … FOR UPDATE`:** A locks the row at 288 ms; B's read is blocked until
  A commits at 491 ms, then B reads the *new* value 7,000 and writes 3,000. Final
  balance **3,000 — correct**. This is pessimistic (lock-based) concurrency control
  and is what `transfer_funds()` uses.

### 3.2 Isolation levels (Demo 3)

Session A reads a balance twice in one transaction; Session B deposits ₦1,000 in
between and commits.

| Isolation level | First read | Second read | Anomaly |
|---|---|---|---|
| READ COMMITTED (PostgreSQL default) | 5,000 | 6,000 | **Non-repeatable read** |
| REPEATABLE READ | 5,000 | 5,000 | none — snapshot taken at first read |

PostgreSQL implements isolation with MVCC (multi-version concurrency control): readers
never block writers. Under REPEATABLE READ the transaction keeps seeing the snapshot
from its first statement. For NairaVault, READ COMMITTED is fine for the app's history
screen, but balance decisions must be made under a row lock (3.1) or in a REPEATABLE
READ / SERIALIZABLE transaction.

### 3.3 Deadlock (Demo 4 → Demo 5)

Session A locks account 50 then asks for 60; Session B locks 60 then asks for 50.
Each waits for the other forever. The log shows both "waiting" at ~1,060 ms, and at
~2,060 ms — exactly `deadlock_timeout` (1 s) later — PostgreSQL's deadlock detector
aborts Session A with `ERROR: deadlock detected`; B then completes.

Demo 5 runs the same opposing pattern (50→60 and 60→50, 50 times each, simultaneously)
**through `transfer_funds()`** and gets **0 deadlocks**, because the function always
locks the lower account id first. Ordered locking is the standard prevention technique:
if every transaction acquires locks in the same global order, a cycle cannot form.

### 3.4 Stress test (Demo 6)

16 threads × 50 random transfers between 200 accounts, all through `transfer_funds()`:

- 794 completed, 6 correctly refused by the daily-limit rule, 0 unexpected errors,
  ~1,800 transfers/second on a laptop-class container.
- Money in the system fell by exactly the fees collected (₦7,940 = 794 × ₦10) — nothing
  created or lost.
- Ledger rows added = 3 × completed transfers.
- **0** negative balances, **0** accounts out of step with their ledger.

## 4. Design decisions

- **Pessimistic locking (`FOR UPDATE`) over optimistic.** Transfers on the same account
  are rare but when they clash the cost of a wrong balance is high; a short row lock
  is cheap.
- **Lock ordering** rather than relying on deadlock detection. Detection works, but the
  victim transaction has to be retried by the app; prevention avoids that.
- **Business rules inside the transaction** (limits, status, funds) so that the check
  and the write are protected by the same lock. Checking in the app and then writing
  would reopen the lost-update window.
- **Compensating transactions for reversals** so that the audit trail is complete.

## 5. Limitations and next steps

- `SERIALIZABLE` isolation was not needed here, but it would be the right choice for
  reports that must be internally consistent across many tables.
- A real deployment would add a retry loop in the application for the rare
  `serialization_failure` / `deadlock_detected` errors.
- Idempotency keys on the API (so a retried mobile request does not transfer twice)
  would be the next control to add; the UNIQUE `reference` column is the hook for it.
