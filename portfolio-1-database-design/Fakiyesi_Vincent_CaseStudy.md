# Portfolio 1 — Selected Case Study

**Student:** Fakiyesi Vincent  
**Student ID:** 2026/A/MIT/0304  
**Course:** MIT 8103 Advanced Database Systems  
**Case study type:** Bank / Fintech Platform (simulated organisation)

## 1. Organisation

**NairaVault** is a simulated Nigerian digital wallet and payments platform. It is
modelled on the kind of licensed mobile-money / fintech wallet that many Nigerians
use daily: a customer opens a wallet with a phone number, completes KYC (Know Your
Customer) verification to unlock higher limits, funds the wallet by bank deposit,
and then sends money to other NairaVault users or to external bank accounts.

The same case study is used for all five portfolio activities.

## 2. Nature of the business / system

NairaVault is an online transaction processing (OLTP) system. Its core job is to
record money movements correctly, quickly and only once. The business rules that
matter most for the database are:

1. A wallet balance must never go negative.
2. A transfer must either fully happen (debit sender, credit receiver, record both
   legs) or not happen at all.
3. Every money movement must leave an audit trail that cannot be silently edited.
4. Customers who have not completed KYC are limited to small daily amounts.
5. Failed transfers must be reversible, and reversals must themselves be recorded.

## 3. Users of the database

| User group | What they do with the data |
|---|---|
| Customers (via mobile app / USSD) | Open wallet, deposit, withdraw, transfer, view history, add beneficiaries |
| Customer support staff | Look up customers, investigate failed transfers, raise reversals |
| Compliance officers | Review and approve KYC documents, flag suspicious transactions |
| Finance / reconciliation team | Daily balance audits, fee reports, settlement with partner banks |
| System processes | Scheduled jobs that apply fees, expire pending transfers, archive logs |

## 4. Major data stored

- **Customers** — identity, contact details, KYC tier, account status
- **Accounts (wallets)** — account number, currency, current balance, status
- **Transactions** — the ledger: every debit and credit with running balance
- **Transfers** — a transfer is a business event that produces two ledger entries
- **Beneficiaries** — saved payees (internal wallets or external bank accounts)
- **Banks** — reference list of Nigerian banks with CBN bank codes
- **KYC documents** — uploaded identity documents and their verification status
- **Staff** — support and compliance users who perform back-office actions
- **Audit log** — who did what, to which record, and when

## 5. Key operations the database must support

| Operation | Portfolio where it is implemented |
|---|---|
| Open an account and record KYC | Portfolio 1 (schema), Portfolio 4 (document model) |
| Transfer funds between wallets | Portfolio 3 (transaction with commit / rollback) |
| Reverse a failed transfer | Portfolio 3 |
| Audit account balances against the ledger | Portfolio 2 (queries and optimisation) |
| Generate customer statement / transaction history | Portfolio 2, Portfolio 4 |
| Detect suspicious activity (many transfers in a short window) | Portfolio 2 |
| Serve read traffic from a replica, keep data available | Portfolio 5 |
| Partition a large ledger table by month | Portfolio 5 |

## 6. Why this case study

A fintech wallet is a good test of advanced database ideas because money is
unforgiving. The transfer operation needs real ACID transactions and shows
concurrency problems (two withdrawals at the same time) very clearly. The ledger
grows fast, so indexing, query plans and partitioning matter. Transaction history
and notifications map naturally onto a document (NoSQL) model, and the need for
24/7 availability makes replication and cloud deployment a genuine requirement
rather than an academic exercise.
