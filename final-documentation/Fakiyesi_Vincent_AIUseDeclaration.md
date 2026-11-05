# AI Use Declaration

**Student:** Fakiyesi Vincent · **Student ID:** 2026/A/MIT/0304 · **Course:** MIT 8103 Advanced Database Systems

In line with Section 11 of the assessment brief, I declare the following use of AI tools.

## 1. AI tool used

Claude (Anthropic), accessed through the Claude app, during November 2026.

## 2. What the AI tool was used for

| Area | How Claude was used |
|---|---|
| Case-study framing | Helped me turn my choice of a Nigerian digital-wallet (fintech) scenario into a written case-study description with users, data and operations |
| Portfolio 1 | Drafted the PostgreSQL schema, the constraint-test script, the seed-data generator, the Mermaid ER diagram source and the normalisation walkthrough from my requirements |
| Portfolio 2 | Drafted the business queries, proposed the indexes after we read the execution plans together, and wrote the benchmark harness that captures before/after plans |
| Portfolio 3 | Drafted the `transfer_funds()` and `reverse_transfer()` procedures and the single- and multi-session demonstration scripts |
| Portfolio 4 | Drafted the document model, the mongosh script, the pymongo migration script and the JSONB demonstration |
| Portfolio 5 | Drafted the replication setup script, the partitioning script and the cloud architecture discussion |
| Documentation | Drafted the README files, analysis documents and this summary; I edited them for accuracy and for my own understanding |
| Debugging | Explained errors that occurred while running the scripts (e.g. a CHECK constraint rejecting generated data, a deadlock, a tie-break bug in sorting ledger entries) and helped correct them |

Claude also executed the scripts in a sandboxed Linux environment with PostgreSQL 16 so that the evidence files in each `evidence/` folder are genuine program output, not fabricated.

## 3. How the output was reviewed, corrected, tested and verified

- Every script in this repository was actually run; the `evidence/` folders contain the unedited terminal output. Where a first run failed, the failure and the fix are described in the relevant README or analysis file (for example the generator bug caught by `chk_transfer_destination`, and the sort tie-break bug found by the cross-model check in Portfolio 4).
- I read each analysis document and checked the claims against the evidence files (row counts, timings, plan node types, replication status) before including them.
- I confirmed I can explain the main design decisions in my own words: the ledger-plus-cached-balance pattern, ordered row locking to prevent deadlocks, partial and covering indexes, embedding versus referencing in the document model, asynchronous versus synchronous replication, and the choice of `account_id` as a shard key.
- Limitations of the environment are stated openly rather than hidden: a MongoDB server could not be installed, so the pymongo demo runs on `mongomock` and its timings are not presented as MongoDB performance figures.

## 4. Responsibility

I understand that using an AI tool does not transfer responsibility for the accuracy,
originality or understanding of this work. I take full responsibility for everything
submitted and am prepared to explain it if selected for verification.

Signed: Fakiyesi Vincent · Date: November 2026
