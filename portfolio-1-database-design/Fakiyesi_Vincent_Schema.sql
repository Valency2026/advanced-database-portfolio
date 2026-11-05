-- =====================================================================
-- NairaVault Digital Wallet - Relational Schema (PostgreSQL 16)
-- Student: Fakiyesi Vincent (2026/A/MIT/0304)
-- Course : MIT 8103 Advanced Database Systems - Portfolio 1
-- Run    : psql -d nairavault -f Fakiyesi_Vincent_Schema.sql
-- =====================================================================

DROP SCHEMA IF EXISTS vault CASCADE;
CREATE SCHEMA vault;
SET search_path TO vault, public;

-- ---------------------------------------------------------------------
-- Reference table: Nigerian banks (CBN 3-digit bank codes)
-- Kept separate so a bank name is stored once, not on every beneficiary.
-- ---------------------------------------------------------------------
CREATE TABLE banks (
    bank_code   CHAR(3)      PRIMARY KEY,
    bank_name   VARCHAR(80)  NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------
-- Back-office staff who perform support / compliance actions
-- ---------------------------------------------------------------------
CREATE TABLE staff (
    staff_id    SERIAL       PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL,
    email       VARCHAR(120) NOT NULL UNIQUE,
    role        VARCHAR(20)  NOT NULL
                CHECK (role IN ('support', 'compliance', 'finance', 'admin')),
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------------
-- Customers (wallet owners)
-- kyc_tier: 1 = phone only, 2 = ID verified, 3 = address + ID verified
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id   BIGSERIAL    PRIMARY KEY,
    full_name     VARCHAR(100) NOT NULL,
    phone         VARCHAR(15)  NOT NULL UNIQUE,
    email         VARCHAR(120) UNIQUE,
    date_of_birth DATE         NOT NULL,
    state_of_residence VARCHAR(30),
    kyc_tier      SMALLINT     NOT NULL DEFAULT 1
                  CHECK (kyc_tier BETWEEN 1 AND 3),
    status        VARCHAR(12)  NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active', 'suspended', 'closed')),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_customer_adult CHECK (date_of_birth <= CURRENT_DATE - INTERVAL '18 years')
);

-- ---------------------------------------------------------------------
-- Accounts (wallets). One customer may hold several wallets.
-- balance is the cached current balance; the ledger (transactions)
-- is the source of truth and is reconciled against it in Portfolio 2.
-- ---------------------------------------------------------------------
CREATE TABLE accounts (
    account_id     BIGSERIAL     PRIMARY KEY,
    customer_id    BIGINT        NOT NULL REFERENCES customers(customer_id),
    account_number CHAR(10)      NOT NULL UNIQUE,
    account_type   VARCHAR(10)   NOT NULL DEFAULT 'wallet'
                   CHECK (account_type IN ('wallet', 'savings')),
    currency       CHAR(3)       NOT NULL DEFAULT 'NGN',
    balance        NUMERIC(18,2) NOT NULL DEFAULT 0.00,
    status         VARCHAR(10)   NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open', 'frozen', 'closed')),
    opened_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT chk_balance_non_negative CHECK (balance >= 0),
    CONSTRAINT chk_account_number_digits CHECK (account_number ~ '^[0-9]{10}$')
);

-- ---------------------------------------------------------------------
-- Transfers: the business event "move money from A to B".
-- A transfer produces two rows in the transactions ledger.
-- ---------------------------------------------------------------------
CREATE TABLE transfers (
    transfer_id            BIGSERIAL     PRIMARY KEY,
    reference              CHAR(20)      NOT NULL UNIQUE,
    source_account_id      BIGINT        NOT NULL REFERENCES accounts(account_id),
    destination_account_id BIGINT        REFERENCES accounts(account_id),  -- NULL for external bank
    external_account_number CHAR(10),
    external_bank_code     CHAR(3)       REFERENCES banks(bank_code),
    amount                 NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    fee                    NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (fee >= 0),
    narration              VARCHAR(140),
    status                 VARCHAR(10)   NOT NULL DEFAULT 'pending'
                           CHECK (status IN ('pending', 'completed', 'failed', 'reversed')),
    failure_reason         VARCHAR(200),
    initiated_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    completed_at           TIMESTAMPTZ,
    reversed_by_staff_id   INT           REFERENCES staff(staff_id),
    -- a transfer is EITHER internal (destination wallet) OR external (bank account)
    CONSTRAINT chk_transfer_destination CHECK (
        (destination_account_id IS NOT NULL AND external_account_number IS NULL AND external_bank_code IS NULL)
        OR
        (destination_account_id IS NULL AND external_account_number IS NOT NULL AND external_bank_code IS NOT NULL)
    ),
    CONSTRAINT chk_not_self_transfer CHECK (source_account_id <> destination_account_id)
);

-- ---------------------------------------------------------------------
-- Transactions: the append-only ledger. Every money movement is a row.
-- balance_after lets us rebuild / audit the balance at any point in time.
-- ---------------------------------------------------------------------
CREATE TABLE transactions (
    transaction_id BIGSERIAL     PRIMARY KEY,
    account_id     BIGINT        NOT NULL REFERENCES accounts(account_id),
    transfer_id    BIGINT        REFERENCES transfers(transfer_id),
    txn_type       VARCHAR(12)   NOT NULL
                   CHECK (txn_type IN ('deposit', 'withdrawal', 'transfer_in',
                                       'transfer_out', 'fee', 'reversal')),
    direction      CHAR(2)       NOT NULL CHECK (direction IN ('DR', 'CR')),
    amount         NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    balance_after  NUMERIC(18,2) NOT NULL CHECK (balance_after >= 0),
    channel        VARCHAR(10)   NOT NULL DEFAULT 'app'
                   CHECK (channel IN ('app', 'ussd', 'web', 'api', 'system')),
    description    VARCHAR(140),
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Beneficiaries: saved payees for a customer
-- ---------------------------------------------------------------------
CREATE TABLE beneficiaries (
    beneficiary_id  BIGSERIAL    PRIMARY KEY,
    customer_id     BIGINT       NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    alias           VARCHAR(50)  NOT NULL,
    account_number  CHAR(10)     NOT NULL,
    bank_code       CHAR(3)      NOT NULL REFERENCES banks(bank_code),
    added_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_beneficiary UNIQUE (customer_id, account_number, bank_code)
);

-- ---------------------------------------------------------------------
-- KYC documents
-- ---------------------------------------------------------------------
CREATE TABLE kyc_documents (
    kyc_id               BIGSERIAL   PRIMARY KEY,
    customer_id          BIGINT      NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    document_type        VARCHAR(20) NOT NULL
                         CHECK (document_type IN ('nin', 'bvn', 'passport', 'drivers_licence',
                                                  'voters_card', 'utility_bill')),
    document_number_masked VARCHAR(30) NOT NULL,   -- e.g. "****6789" (never store full ID)
    status               VARCHAR(10) NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending', 'approved', 'rejected')),
    submitted_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    reviewed_at          TIMESTAMPTZ,
    reviewed_by_staff_id INT         REFERENCES staff(staff_id),
    CONSTRAINT uq_customer_doc_type UNIQUE (customer_id, document_type)
);

-- ---------------------------------------------------------------------
-- Audit log: append-only record of sensitive actions
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    log_id      BIGSERIAL    PRIMARY KEY,
    actor_type  VARCHAR(10)  NOT NULL CHECK (actor_type IN ('customer', 'staff', 'system')),
    actor_id    BIGINT,
    action      VARCHAR(40)  NOT NULL,
    entity      VARCHAR(30)  NOT NULL,
    entity_id   BIGINT,
    details     JSONB,
    logged_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Protect the ledger: no UPDATE or DELETE on transactions, ever.
-- Corrections are done with a new 'reversal' row.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vault.block_ledger_change() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'Ledger rows are immutable. Post a reversal instead.';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_transactions_immutable
BEFORE UPDATE OR DELETE ON transactions
FOR EACH ROW EXECUTE FUNCTION vault.block_ledger_change();

-- ---------------------------------------------------------------------
-- Helpful views
-- ---------------------------------------------------------------------
CREATE VIEW v_account_overview AS
SELECT a.account_id, a.account_number, c.full_name, c.phone, c.kyc_tier,
       a.account_type, a.balance, a.status, a.opened_at
FROM accounts a
JOIN customers c ON c.customer_id = a.customer_id;

COMMENT ON TABLE transactions IS 'Append-only ledger. Source of truth for balances.';
COMMENT ON COLUMN accounts.balance IS 'Cached balance; must equal the last balance_after in the ledger.';
