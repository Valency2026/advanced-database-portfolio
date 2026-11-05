# AI Use Declaration

**Student:** Fakiyesi Vincent · **Student ID:** 2026/A/MIT/0304 · **Course:** MIT 8103 Advanced Database Systems

In line with Section 11 of the assessment brief, I declare that an AI tool was used as a
learning and productivity aid in preparing this portfolio, as permitted.

## 1. Tool

Claude (Anthropic), November 2026.

## 2. My own work

- I selected the case study (a Nigerian digital-wallet / fintech platform) and defined the
  organisation, its users, the data it stores and the operations it must support.
- I made the design decisions that run through all five portfolios: treating the ledger as
  the source of truth with a cached balance; placing business rules (limits, status and
  funds checks) inside the database transaction; locking accounts in a fixed order to
  prevent deadlocks; embedding wallets and beneficiaries in the customer document while
  keeping ledger entries separate; keeping the money-moving transaction relational and
  using the document store for the read-heavy customer views; and choosing `account_id`
  as the partition / shard key.
- I reviewed every analysis document against the evidence files (row counts, timings,
  execution-plan node types, replication status) and corrected the write-ups where they
  did not match.
- I am able to explain the work and its reasoning in my own words.

## 3. What the AI tool was used for

- Drafting SQL, Python and shell scripts to implement the designs above.
- Explaining errors that occurred during testing (for example a CHECK constraint
  rejecting generated data, a deadlock, and a sort tie-break bug in ledger ordering) and
  helping to correct them.

## 4. Verification

Every script was executed and its output captured. Where a first run failed, the cause
and the fix are recorded in the relevant README or analysis file. Limitations are stated
openly: a MongoDB server could not be installed, so the pymongo demonstration runs on
`mongomock`, and its timings are not presented as MongoDB performance.

## 5. Responsibility

I take full responsibility for the accuracy, originality and understanding of this
submission and am prepared to explain it if selected for verification.

Signed: Fakiyesi Vincent · Date: November 2026
