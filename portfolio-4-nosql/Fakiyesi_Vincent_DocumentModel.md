# Portfolio 4 — NoSQL and Advanced Data Models

**Student:** Fakiyesi Vincent (2026/A/MIT/0304) · **Case study:** NairaVault (same as Portfolios 1–3)

## 1. Which NoSQL model, and why

NairaVault's data has two very different access patterns:

| Pattern | Example | Best fit |
|---|---|---|
| "Give me everything about this customer, now" | App home screen: profile + all wallets + saved beneficiaries + KYC status, in one round trip | **Document** model |
| "Append a fact, then read it back by account and time" | Ledger entries, notifications | **Document** model (time-series style collection) |
| Fast counters with expiry | Daily transfer total per account, OTP codes, sessions | **Key-value** model |
| Strict money movement | The transfer itself | Stays **relational** (Portfolio 3) |

I therefore modelled NairaVault for **MongoDB** (document store) and show a key-value
pattern inside it. The relational database remains the system of record for balances;
the document store serves the read-heavy, customer-facing views. This split — SQL for
the ledger, NoSQL for the experience layer — is how many real fintechs are built
(polyglot persistence).

## 2. Document design

### 2.1 `customers` collection — one document per customer, wallets embedded

```json
{
  "_id": 1250,
  "fullName": "Chioma Okafor",
  "phone": "08034567890",
  "email": "chioma.okafor1250@example.com",
  "dateOfBirth": "1991-04-12",
  "state": "Lagos",
  "kyc": { "tier": 2, "status": "active",
           "documents": [ { "type": "bvn", "numberMasked": "****4471", "status": "approved",
                            "reviewedBy": "Adaeze Okonkwo", "reviewedAt": "2026-02-03T10:14:00Z" } ] },
  "accounts": [
    { "accountNumber": "2010001537", "type": "wallet",  "currency": "NGN",
      "balance": 42850.00, "status": "open", "openedAt": "2025-11-02T08:00:00Z" },
    { "accountNumber": "2010001538", "type": "savings", "currency": "NGN",
      "balance": 150000.00, "status": "open", "openedAt": "2025-11-02T08:00:00Z" }
  ],
  "beneficiaries": [
    { "alias": "Mum", "accountNumber": "0123456789", "bankCode": "058", "bankName": "GTBank" }
  ],
  "createdAt": "2025-11-02T08:00:00Z"
}
```

**Embedding decisions** (the central NoSQL design question):

- *Accounts* are embedded: a customer has 1–2 of them, they are always shown together,
  and they never need to be queried without the customer. The relational model needed
  a JOIN for this; the document needs none.
- *Beneficiaries* are embedded for the same reason (bounded list, read with the owner).
  `bankName` is **denormalised** into each beneficiary — a deliberate duplication so
  the app never has to look up the banks table. Bank names almost never change.
- *KYC documents* are embedded under `kyc`.
- *Transactions* are **not** embedded. A customer can have thousands; MongoDB documents
  are capped at 16 MB and an ever-growing array is an anti-pattern. They get their own
  collection and reference the account by `accountNumber`.

### 2.2 `transactions` collection — one document per ledger entry

```json
{
  "_id": ObjectId("..."),
  "accountNumber": "2010001537",
  "customerId": 1250,
  "type": "transfer_out", "direction": "DR",
  "amount": 5000.00, "balanceAfter": 37850.00,
  "channel": "app",
  "transfer": { "reference": "NV202610150000061234", "counterparty": "2010002201",
                "narration": "School fees" },
  "createdAt": ISODate("2026-10-15T09:21:44Z")
}
```

Compound index `{ accountNumber: 1, createdAt: -1 }` — the same index strategy that gave
the 50x speed-up in Portfolio 2, expressed in MongoDB terms. `customerId` is
denormalised so a "statement across all my wallets" query needs no lookup.

### 2.3 `daily_limits` collection — key-value pattern

```json
{ "_id": "2010001537:2026-10-15", "sentToday": 26000.00, "expiresAt": ISODate("2026-10-16T00:00:00Z") }
```

Key = `accountNumber:date`. Updated with an atomic `$inc` upsert; a TTL index on
`expiresAt` deletes the document automatically after midnight. This replaces the
`SUM(...) WHERE created_at >= today` scan inside `transfer_funds()` with a single O(1)
read — exactly what Redis would be used for, done inside MongoDB.

### 2.4 `notifications` collection

Push / SMS notifications per customer; schema-free `payload` because notification
types change often and no two types share the same fields. This is where the
flexible schema of a document store is an advantage rather than a risk.

## 3. Relational vs document — side by side

| Concern | PostgreSQL (Portfolios 1–3) | MongoDB (this portfolio) |
|---|---|---|
| Customer home screen | 4-table JOIN | 1 document read |
| Schema changes (new KYC doc type) | `ALTER TABLE` / new CHECK | Add a field; old docs untouched |
| Transfer (debit + credit + ledger) | One ACID transaction, row locks | Multi-document transactions exist (4.0+) but are slower and need a replica set; not the natural strength |
| Enforcing `balance >= 0` | CHECK constraint in the engine | JSON Schema validator (shown in script) or application code |
| Horizontal scaling | Read replicas + partitioning (Portfolio 5) | Native sharding by `customerId` / `accountNumber` |
| Reporting (fees by day) | GROUP BY | Aggregation pipeline `$match → $group → $sort` |

## 4. Suitability — honest assessment

**Good fit** for NairaVault:
- Customer profile and dashboard reads (embedding removes joins).
- Transaction history and notifications (append-mostly, queried by account + time,
  easy to shard and to expire).
- Daily counters and other key-value needs.

**Poor fit**:
- The money-moving transaction itself. The ledger needs the strongest consistency
  available, immutable rows, and CHECK constraints the engine enforces. Multi-document
  ACID in MongoDB works but is bolted on; PostgreSQL does it natively and faster.

**Conclusion**: keep PostgreSQL as the system of record and use MongoDB as a read model
fed from it (the migration script in this portfolio is exactly that feed). This is the
CQRS / polyglot-persistence pattern.

## 5. Implementation evidence

- `Fakiyesi_Vincent_MongoScript.js` — full mongosh script: collections, JSON Schema
  validation, indexes (compound, TTL), inserts, queries, aggregation pipelines,
  `$inc` upsert. Runs unchanged against any MongoDB 6/7 server or Atlas cluster.
- `Fakiyesi_Vincent_MongoDemo.py` — migrates the live PostgreSQL data (3,000 customers,
  242k ledger rows) into documents using the official **pymongo** API and runs the same
  queries and pipelines. Because a MongoDB server could not be installed in my
  environment, the script uses **mongomock**, an in-memory MongoDB-compatible engine
  that implements the pymongo interface (queries, update operators, indexes,
  aggregation). Switching to a real server is one line (`MongoClient(uri)`), and the
  exported JSON files can be loaded with `mongoimport`.
- `Fakiyesi_Vincent_JSONB.sql` — the same document model inside PostgreSQL using
  `JSONB` with a GIN index, showing that a relational engine can also hold documents
  (the "advanced data model" the course describes).
- `evidence/` — outputs of all of the above and sample exported documents.
