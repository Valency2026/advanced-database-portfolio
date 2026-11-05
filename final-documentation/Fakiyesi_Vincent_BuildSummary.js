// Builds Fakiyesi_Vincent_PortfolioSummary.docx (2-3 page LMS submission)
const fs = require("fs");
const { Document, Packer, Paragraph, TextRun, HeadingLevel, Table, TableRow, TableCell,
        WidthType, ShadingType, AlignmentType, ImageRun, LevelFormat, BorderStyle } = require("docx");

const GITHUB = process.env.GITHUB_URL || "https://github.com/<your-username>/advanced-database-portfolio";
const F = "Arial";
const p = (text, opts = {}) => new Paragraph({ spacing: { after: 100 }, ...opts,
  children: [new TextRun({ text, font: F, size: 20, ...(opts.run || {}) })] });
const h1 = (t) => new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun({ text: t, font: F })] });
const h2 = (t) => new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun({ text: t, font: F })] });
const bullet = (t, bold) => new Paragraph({ numbering: { reference: "b", level: 0 }, spacing: { after: 60 },
  children: typeof t === "string" ? [new TextRun({ text: t, font: F, size: 20 })] :
    [new TextRun({ text: t[0], font: F, size: 20, bold: true }), new TextRun({ text: t[1], font: F, size: 20 })] });

const cell = (t, w, head) => new TableCell({ width: { size: w, type: WidthType.DXA },
  shading: head ? { type: ShadingType.CLEAR, fill: "D9E2F3", color: "auto" } : undefined,
  margins: { top: 60, bottom: 60, left: 100, right: 100 },
  children: [new Paragraph({ children: [new TextRun({ text: t, font: F, size: 18, bold: !!head })] })] });
const table = (rows, widths) => new Table({ columnWidths: widths, width: { size: widths.reduce((a, b) => a + b), type: WidthType.DXA },
  rows: rows.map((r, i) => new TableRow({ children: r.map((c, j) => cell(c, widths[j], i === 0)) })) });

const er = fs.readFileSync("../portfolio-1-database-design/Fakiyesi_Vincent_ERDiagram.png");

const doc = new Document({
  styles: { default: { document: { run: { font: F, size: 20 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { font: F, size: 26, bold: true, color: "1F3864" }, paragraph: { spacing: { before: 200, after: 80 }, keepNext: true } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { font: F, size: 21, bold: true }, paragraph: { spacing: { before: 120, after: 60 }, keepNext: true } } ] },
  numbering: { config: [{ reference: "b", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
    style: { paragraph: { indent: { left: 360, hanging: 240 } } } }] }] },
  sections: [{
    properties: { page: { size: { width: 11906, height: 16838 }, margin: { top: 900, bottom: 900, left: 1000, right: 1000 } } },
    children: [
      new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 40 },
        children: [new TextRun({ text: "MIT 8103 Advanced Database Systems — Portfolio Summary", font: F, size: 30, bold: true, color: "1F3864" })] }),
      new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 40 },
        children: [new TextRun({ text: "Fakiyesi Vincent  ·  Student ID 2026/A/MIT/0304  ·  M.Sc. Information Technology, Miva Open University", font: F, size: 19 })] }),
      new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 160 }, border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: "1F3864", space: 4 } },
        children: [new TextRun({ text: "2026/2027 First Semester Continuous Assessment  ·  GitHub repository: ", font: F, size: 19 }),
                   new TextRun({ text: GITHUB, font: F, size: 19, color: "0563C1", underline: {} })] }),

      h1("1. Selected organisation"),
      p("NairaVault is a simulated Nigerian digital-wallet (fintech) platform: customers open a wallet with a phone number, complete KYC to unlock higher limits, fund the wallet, and transfer money to other users or to external bank accounts. The users of the database are customers (app/USSD), support staff, compliance officers, the finance/reconciliation team and scheduled system jobs. The major data are customers, accounts (wallets), an append-only transaction ledger, transfers, beneficiaries, banks, KYC documents, staff and an audit log. The key operations are opening accounts, transferring funds atomically, reversing failed transfers, auditing balances against the ledger, producing statements and detecting suspicious activity. The same case study is used in all five portfolios. All relational work was done on PostgreSQL 16; the test dataset holds 3,000 customers, 3,719 wallets, 67,245 transfers and 242,531 ledger rows."),

      h1("2. The five portfolio activities"),
      h2("Portfolio 1 — Database design and modelling"),
      p("I designed a nine-table schema in 3NF/BCNF with a deliberate, documented denormalisation: accounts.balance caches what the ledger can derive, and transactions.balance_after lets that cache be audited. Business rules live in the engine: CHECK constraints (non-negative balances, adult customers, internal-or-external transfer, no self-transfer), UNIQUE natural keys, foreign keys without cascading deletes on financial history, and a BEFORE UPDATE OR DELETE trigger that makes the ledger immutable. Eleven deliberately invalid statements were all rejected, and the cached balance of every wallet reconciled with its ledger. Evidence: schema, ER diagram (Figure 1), constraint-test output, normalisation document."),
      h2("Portfolio 2 — Query processing and optimisation"),
      p("Eight business queries were timed and their EXPLAIN (ANALYZE, BUFFERS) plans captured on the bare schema, then again after indexes chosen from the plans. A composite (account_id, created_at) index cut the customer-statement query from 15.8 ms to 0.3 ms (3,280 pages read → 7). A partial covering index turned the fee report into an index-only scan with zero heap fetches. A correlated subquery that scanned the transfers table over 2,000 times (11 s) dropped to 54 ms with foreign-key indexes — while the same question written as a JOIN/GROUP BY/HAVING was already 20 ms with no extra index, showing that query shape matters as much as indexing. The full-ledger reconciliation query correctly stayed a sequential scan."),
      h2("Portfolio 3 — Transactions and concurrency"),
      p("transfer_funds() performs the debit, fee, credit, ledger and audit writes in one PL/pgSQL transaction, locking both accounts with SELECT … FOR UPDATE in ascending id order. Single-session demos show COMMIT, ROLLBACK, automatic rollback on an insufficient-funds exception (0 ledger rows written), SAVEPOINT partial rollback, a compensating reversal, and the KYC daily limit refusing a transfer. Two-session demos on real threads show a lost update (₦4,000 vanished), the FOR UPDATE fix, a non-repeatable read under READ COMMITTED that REPEATABLE READ prevents, a deadlock detected by PostgreSQL after 1 s, and zero deadlocks for the same pattern through the ordered-locking procedure. A 16-thread stress test completed 794 transfers with no negative balance and every account reconciled."),
      h2("Portfolio 4 — NoSQL and advanced data models"),
      p("NairaVault was remodelled for MongoDB: one customer document with embedded wallets, beneficiaries (bank name denormalised) and KYC; one document per ledger entry with a compound (accountNumber, createdAt) index; a key-value daily-limit collection using atomic $inc upserts and a TTL index; and schema-free notifications. A mongosh script with JSON Schema validation, indexes, updates, aggregation pipelines and $lookup is provided for a real server, and a pymongo script migrates the live PostgreSQL data and runs the same queries. Because a MongoDB server could not be installed in my environment, that script runs on mongomock, which is stated openly and whose timings are not presented as MongoDB performance. The same document model was also built inside PostgreSQL with JSONB, where a GIN index turned a containment query from a 1.87 ms sequential scan into a 0.07 ms index scan. The assessment is that documents suit the read-heavy experience layer while the ledger stays relational (polyglot persistence)."),
      h2("Portfolio 5 — Distributed and cloud database exercise"),
      p("A real streaming replica was built with pg_basebackup -R and a replication slot. pg_stat_replication showed state = streaming with ~7–30 ms replay lag; a write on the primary appeared on the replica; the replica refused an INSERT (read-only); a transfer replicated with its balances; the heavy reconciliation query was offloaded to the replica; and pg_ctl promote turned the replica into a writable primary in two seconds. The ledger was then partitioned by month (the October report was pruned to one of twelve partitions; a month of history was detached in a millisecond) and by hash of account_id into four shards (balanced within 4%; a per-account query hit one shard, a cross-account report fanned out to all four). The report discusses asynchronous versus synchronous replication for a ledger, read-your-own-writes, CAP choices per data type, and a Multi-AZ RDS + Atlas cloud design with a note on Nigerian data residency."),

      h1("3. Evidence"),
      new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 40 },
        children: [new ImageRun({ type: "png", data: er, transformation: { width: 470, height: 522 } })] }),
      new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 120 },
        children: [new TextRun({ text: "Figure 1. NairaVault entity-relationship diagram (Portfolio 1).", font: F, size: 18, italics: true })] }),
      p("Selected measurements captured from the evidence files in the repository:"),
      table([
        ["Portfolio", "Measurement", "Result"],
        ["1", "Invalid statements rejected / balances reconciled", "11 of 11 / 3,719 of 3,719"],
        ["2", "Statement query, before → after composite index", "15.8 ms → 0.3 ms (3,280 → 7 pages)"],
        ["2", "Correlated subquery, before → after FK indexes", "11,070 ms → 54 ms"],
        ["3", "Naive concurrent withdrawals / with FOR UPDATE", "₦4,000 lost / correct"],
        ["3", "Stress test: 794 concurrent transfers", "0 negative balances, 0 ledger mismatches"],
        ["4", "JSONB containment query, Seq Scan → GIN index", "1.87 ms → 0.07 ms"],
        ["5", "Replication state / replay lag / bytes behind after 2,000 inserts", "streaming / ~7 ms / 0"],
        ["5", "Failover: promote replica and write to it", "pg_is_in_recovery() = f, INSERT succeeded"],
      ], [1100, 5000, 3800]),
      p("Every folder in the repository has a README explaining how the work was implemented and tested and an evidence/ folder with the unedited terminal output, execution plans, logs and exported documents.", { spacing: { before: 120, after: 100 } }),

      h1("4. Individual technical reflection"),
      p("Design choices. The decision I am most confident about is treating the ledger as the source of truth and the balance as a cache with a running balance_after column. It let me prove consistency with one query after every experiment, and that query caught two real bugs: a seed-data row that violated a CHECK constraint, and a sort tie-break error (a transfer's debit and fee rows share a timestamp) that showed up only in the document-model check. I also chose to put business rules — limits, status checks, funds checks — inside the database transaction rather than in application code, so that the check and the write are covered by the same lock."),
      p("Challenges. The hardest part was concurrency. Seeing a withdrawal silently disappear in the lost-update demo made the theory concrete, and the deadlock log — both sessions 'waiting' and then PostgreSQL killing one exactly one second later — explained why the transfer procedure locks accounts in a fixed order. The second challenge was environmental: I could not install a MongoDB server, so I had to decide between faking evidence and being transparent; I chose to run the real driver code on a compatible test engine, say so clearly, and back it with a JSONB implementation on a real engine."),
      p("Lessons learned. Indexes are not magic: the reconciliation query got no faster because it must read every row, and the correlated subquery was better fixed by rewriting it. Distribution is a trade, not a free upgrade: hash partitioning made the per-account query faster and the cross-account report slower, which is exactly why the shard key must follow the dominant access pattern. Finally, building replication by hand made managed cloud services make sense — Multi-AZ is a synchronous standby plus the failover I ran manually, with monitoring and fencing around it."),

      h1("5. References and AI-use declaration"),
      p("Full references are in final-documentation/Fakiyesi_Vincent_References.md (Elmasri & Navathe 2017; Silberschatz, Korth & Sudarshan 2019; Kleppmann 2017; PostgreSQL 16 and MongoDB documentation; CBN mobile-money framework; NDPA 2023; AWS RDS documentation)."),
      p("AI use: Claude (Anthropic) was used to draft scripts, documentation and explanations from my case-study decisions, to run the scripts in a sandbox so that the evidence is genuine output, and to help debug failures. I reviewed every analysis against the evidence files, corrected and re-ran scripts where needed, and can explain the design decisions in my own words. The full declaration is in final-documentation/Fakiyesi_Vincent_AIUseDeclaration.md. I take full responsibility for the accuracy and originality of this submission."),
    ] }] });

Packer.toBuffer(doc).then(b => { fs.writeFileSync("Fakiyesi_Vincent_PortfolioSummary.docx", b); console.log("written"); });
