# Portfolio 1 — Relational Schema, Keys, Constraints and Normalisation

**Student:** Fakiyesi Vincent (2026/A/MIT/0304) · **DBMS:** PostgreSQL 16

## 1. Relational schema (summary)

Primary keys are underlined in the SQL (`PRIMARY KEY`); foreign keys are marked FK.

| Relation | Attributes (PK in bold, FK in italics) |
|---|---|
| banks | **bank_code**, bank_name |
| staff | **staff_id**, full_name, email, role, is_active |
| customers | **customer_id**, full_name, phone, email, date_of_birth, state_of_residence, kyc_tier, status, created_at |
| accounts | **account_id**, *customer_id*, account_number, account_type, currency, balance, status, opened_at |
| transfers | **transfer_id**, reference, *source_account_id*, *destination_account_id*, external_account_number, *external_bank_code*, amount, fee, narration, status, failure_reason, initiated_at, completed_at, *reversed_by_staff_id* |
| transactions | **transaction_id**, *account_id*, *transfer_id*, txn_type, direction, amount, balance_after, channel, description, created_at |
| beneficiaries | **beneficiary_id**, *customer_id*, alias, account_number, *bank_code*, added_at |
| kyc_documents | **kyc_id**, *customer_id*, document_type, document_number_masked, status, submitted_at, reviewed_at, *reviewed_by_staff_id* |
| audit_log | **log_id**, actor_type, actor_id, action, entity, entity_id, details (JSONB), logged_at |

Full DDL: `Fakiyesi_Vincent_Schema.sql`. Diagram: `Fakiyesi_Vincent_ERDiagram.png`.

## 2. Keys

- **Surrogate primary keys** (`BIGSERIAL`) on every operational table. Money tables use
  `BIGINT` because a ledger can exceed 2 billion rows over the life of a fintech.
- **Natural / candidate keys** are enforced with `UNIQUE`: `customers.phone`,
  `customers.email`, `accounts.account_number`, `transfers.reference`, `banks.bank_name`.
  A customer can therefore be looked up by phone (as in USSD) without exposing the
  internal id.
- **Composite unique keys** stop logical duplicates:
  `beneficiaries(customer_id, account_number, bank_code)` and
  `kyc_documents(customer_id, document_type)`.
- **Foreign keys** connect every child to its parent. `ON DELETE CASCADE` is used only
  for data that has no meaning without the customer (beneficiaries, KYC documents).
  It is deliberately **not** used on accounts or transactions — financial history must
  never disappear because a customer record is removed.

## 3. Constraints that encode business rules

| Rule from the case study | How it is enforced |
|---|---|
| Balance can never be negative | `CHECK (balance >= 0)` on accounts and `CHECK (balance_after >= 0)` on transactions |
| Customers must be adults | `CHECK (date_of_birth <= CURRENT_DATE - 18 years)` |
| A transfer goes to a wallet OR an external bank, never both/neither | `chk_transfer_destination` — a multi-column CHECK |
| No transfer to yourself | `CHECK (source_account_id <> destination_account_id)` |
| Amounts and fees are sensible | `CHECK (amount > 0)`, `CHECK (fee >= 0)` |
| Status / type fields only take allowed values | `CHECK (... IN (...))` on every status and type column |
| Account numbers are 10 digits | `CHECK (account_number ~ '^[0-9]{10}$')` |
| The ledger is immutable | `BEFORE UPDATE OR DELETE` trigger raises an exception |
| Never store full ID numbers | Column is named `document_number_masked`; the app stores only the last 4 digits |

Evidence that each rule is enforced is in `evidence/03_constraint_tests_output.txt`
(eleven deliberately invalid statements, each rejected by PostgreSQL).

## 4. Normalisation

I designed the schema straight into Third Normal Form, then checked it rule by rule.
The easiest way to show the reasoning is to start from how the data would look if it
were kept in one flat spreadsheet, which is how many small Nigerian businesses actually
start.

### 4.1 Unnormalised form (UNF)

A single "Transactions" sheet:

```
customer_name, phone, kyc_tier, account_number, balance, bank_name_of_beneficiary,
beneficiary_accounts (list), txn_date, txn_type, amount, staff_who_reviewed_kyc
```

Problems: `beneficiary_accounts` is a repeating group; customer details are repeated on
every row; changing a customer's phone means editing thousands of rows.

### 4.2 First Normal Form (1NF) — atomic values, no repeating groups

- `beneficiary_accounts` is pulled into its own table `beneficiaries`, one row per payee.
- Every column holds a single value (e.g. `full_name` is one string; `details` in
  `audit_log` is JSONB, which PostgreSQL treats as a single typed value, used only for
  free-form metadata that is never joined on).

### 4.3 Second Normal Form (2NF) — no partial dependency on part of a composite key

All operational tables use a single-column surrogate key, so partial dependency cannot
occur. The one composite unique key, `beneficiaries(customer_id, account_number,
bank_code)`, has no non-key attribute that depends on only part of it — `alias` and
`added_at` describe the whole saved payee.

### 4.4 Third Normal Form (3NF) — no transitive dependency

Transitive dependencies in the flat sheet, and how they were removed:

| Transitive dependency | Fix |
|---|---|
| `account_number → customer_id → full_name, phone, kyc_tier` | Customer attributes moved to `customers`; `accounts` keeps only `customer_id` |
| `bank_code → bank_name` on every beneficiary / external transfer | `banks` reference table; others store only `bank_code` |
| `reviewed_by_staff_id → staff name, role` | `staff` table |
| `transfer_id → amount, fee, narration, status` repeated on both ledger legs | `transfers` holds the business event once; `transactions` rows point to it |

### 4.5 Boyce–Codd Normal Form (BCNF)

Every determinant in every table is a candidate key (`customer_id`, `phone`, `email` in
customers; `account_id`, `account_number` in accounts; etc.), so the schema also
satisfies BCNF.

### 4.6 A deliberate, documented denormalisation

`accounts.balance` duplicates information that can be derived from the ledger
(`SUM(CR) - SUM(DR)` per account). Strictly this is redundant. I kept it because:

1. Every transfer must check the balance; summing 240,000+ ledger rows on each check
   would be far too slow (Portfolio 2 measures this).
2. The redundancy is **controlled**: `transactions.balance_after` records the running
   balance, so the cached value can be audited at any time. The reconciliation query in
   `Fakiyesi_Vincent_ConstraintTests.sql` confirms all 3,719 accounts match.
3. In Portfolio 3 the balance update and the ledger insert happen inside one
   transaction, so they cannot drift apart.

This is the standard "ledger + cached balance" pattern used by real payment systems.

## 5. Design decisions worth noting

- `NUMERIC(18,2)` rather than `FLOAT` for money — floating point cannot represent
  ₦0.10 exactly and rounding errors accumulate.
- `TIMESTAMPTZ` everywhere, so times are unambiguous whether the server is in Lagos
  (WAT) or a cloud region abroad.
- `transfers` vs `transactions`: one business event, two ledger legs. This mirrors
  double-entry bookkeeping and makes "reverse a failed transfer" a clean operation.
- The schema lives in its own PostgreSQL schema `vault`, separate from `public`, which
  is good practice for permissions and for running several apps on one server.
