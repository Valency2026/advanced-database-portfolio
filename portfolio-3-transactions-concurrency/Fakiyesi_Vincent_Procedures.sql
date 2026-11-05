-- =====================================================================
-- Portfolio 3 - Transaction procedures for NairaVault
-- Student: Fakiyesi Vincent (2026/A/MIT/0304)
-- =====================================================================
SET search_path TO vault;

-- ---------------------------------------------------------------------
-- transfer_funds: move money from one wallet to another, atomically.
-- Everything inside runs in ONE transaction. If any step fails the
-- whole thing is rolled back and the caller sees an exception.
--
-- Concurrency control: both accounts are locked with SELECT ... FOR UPDATE
-- in ascending account_id order. Ordered locking guarantees that two
-- transfers A->B and B->A can never deadlock, because both will try to
-- lock the lower id first.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_funds(
    p_source_account      BIGINT,
    p_destination_account BIGINT,
    p_amount              NUMERIC(18,2),
    p_narration           VARCHAR DEFAULT NULL,
    p_channel             VARCHAR DEFAULT 'app'
) RETURNS CHAR(20) AS $$
DECLARE
    v_fee          CONSTANT NUMERIC(18,2) := 10.00;
    v_src_balance  NUMERIC(18,2);
    v_dst_balance  NUMERIC(18,2);
    v_src_status   VARCHAR;
    v_dst_status   VARCHAR;
    v_kyc_tier     SMALLINT;
    v_sent_today   NUMERIC(18,2);
    v_limit        NUMERIC(18,2);
    v_transfer_id  BIGINT;
    v_reference    CHAR(20);
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive' USING ERRCODE = 'check_violation';
    END IF;
    IF p_source_account = p_destination_account THEN
        RAISE EXCEPTION 'Cannot transfer to the same account';
    END IF;

    -- 1. Lock both rows in a fixed order (lower id first) to avoid deadlocks
    IF p_source_account < p_destination_account THEN
        SELECT balance, status INTO v_src_balance, v_src_status
          FROM accounts WHERE account_id = p_source_account FOR UPDATE;
        SELECT balance, status INTO v_dst_balance, v_dst_status
          FROM accounts WHERE account_id = p_destination_account FOR UPDATE;
    ELSE
        SELECT balance, status INTO v_dst_balance, v_dst_status
          FROM accounts WHERE account_id = p_destination_account FOR UPDATE;
        SELECT balance, status INTO v_src_balance, v_src_status
          FROM accounts WHERE account_id = p_source_account FOR UPDATE;
    END IF;

    IF v_src_balance IS NULL OR v_dst_balance IS NULL THEN
        RAISE EXCEPTION 'Account not found';
    END IF;
    IF v_src_status <> 'open' OR v_dst_status <> 'open' THEN
        RAISE EXCEPTION 'Account is % / %', v_src_status, v_dst_status;
    END IF;

    -- 2. Business rule: tier-1 (unverified) customers limited to N50,000 per day
    SELECT c.kyc_tier INTO v_kyc_tier
      FROM accounts a JOIN customers c USING (customer_id)
     WHERE a.account_id = p_source_account;
    v_limit := CASE v_kyc_tier WHEN 1 THEN 50000 WHEN 2 THEN 200000 ELSE 5000000 END;
    SELECT coalesce(sum(amount), 0) INTO v_sent_today
      FROM transactions
     WHERE account_id = p_source_account AND txn_type = 'transfer_out'
       AND created_at >= date_trunc('day', now());
    IF v_sent_today + p_amount > v_limit THEN
        RAISE EXCEPTION 'Daily limit of % exceeded for KYC tier % (already sent % today)',
            v_limit, v_kyc_tier, v_sent_today;
    END IF;

    -- 3. Sufficient funds?  (checked while the row is locked, so it cannot change)
    IF v_src_balance < p_amount + v_fee THEN
        RAISE EXCEPTION 'Insufficient funds: balance %, need %', v_src_balance, p_amount + v_fee
            USING ERRCODE = 'P0001';
    END IF;

    -- 4. Record the business event
    v_reference := 'NV' || to_char(now(), 'YYYYMMDD') || lpad(nextval('transfers_transfer_id_seq')::text, 10, '0');
    INSERT INTO transfers(reference, source_account_id, destination_account_id, amount, fee,
                          narration, status, completed_at)
    VALUES (v_reference, p_source_account, p_destination_account, p_amount, v_fee,
            p_narration, 'completed', now())
    RETURNING transfer_id INTO v_transfer_id;

    -- 5. Debit sender (amount + fee) and write both ledger legs
    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_source_account
        RETURNING balance INTO v_src_balance;
    INSERT INTO transactions(account_id, transfer_id, txn_type, direction, amount, balance_after, channel, description)
    VALUES (p_source_account, v_transfer_id, 'transfer_out', 'DR', p_amount, v_src_balance, p_channel, p_narration);

    UPDATE accounts SET balance = balance - v_fee WHERE account_id = p_source_account
        RETURNING balance INTO v_src_balance;
    INSERT INTO transactions(account_id, transfer_id, txn_type, direction, amount, balance_after, channel, description)
    VALUES (p_source_account, v_transfer_id, 'fee', 'DR', v_fee, v_src_balance, 'system', 'Transfer fee');

    -- 6. Credit receiver
    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_destination_account
        RETURNING balance INTO v_dst_balance;
    INSERT INTO transactions(account_id, transfer_id, txn_type, direction, amount, balance_after, channel, description)
    VALUES (p_destination_account, v_transfer_id, 'transfer_in', 'CR', p_amount, v_dst_balance, 'system', p_narration);

    -- 7. Audit
    INSERT INTO audit_log(actor_type, actor_id, action, entity, entity_id, details)
    VALUES ('system', NULL, 'transfer_completed', 'transfers', v_transfer_id,
            jsonb_build_object('from', p_source_account, 'to', p_destination_account, 'amount', p_amount));

    RETURN v_reference;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- reverse_transfer: undo a completed transfer by posting opposite ledger
-- entries (never by deleting - the ledger is immutable). Used by support.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reverse_transfer(p_reference CHAR(20), p_staff_id INT, p_reason VARCHAR)
RETURNS VOID AS $$
DECLARE
    t  transfers%ROWTYPE;
    v_bal NUMERIC(18,2);
BEGIN
    SELECT * INTO t FROM transfers WHERE reference = p_reference FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Transfer % not found', p_reference; END IF;
    IF t.status <> 'completed' THEN
        RAISE EXCEPTION 'Only completed transfers can be reversed (status is %)', t.status;
    END IF;
    IF t.destination_account_id IS NULL THEN
        RAISE EXCEPTION 'External transfers must be reversed through the bank, not here';
    END IF;

    -- lock in ascending order, same rule as transfer_funds
    PERFORM 1 FROM accounts
     WHERE account_id IN (t.source_account_id, t.destination_account_id)
     ORDER BY account_id FOR UPDATE;

    -- take the money back from the receiver (must still have it)
    UPDATE accounts SET balance = balance - t.amount
     WHERE account_id = t.destination_account_id RETURNING balance INTO v_bal;
    INSERT INTO transactions(account_id, transfer_id, txn_type, direction, amount, balance_after, channel, description)
    VALUES (t.destination_account_id, t.transfer_id, 'reversal', 'DR', t.amount, v_bal, 'system', 'Reversal: ' || p_reason);

    -- give amount + fee back to the sender
    UPDATE accounts SET balance = balance + t.amount + t.fee
     WHERE account_id = t.source_account_id RETURNING balance INTO v_bal;
    INSERT INTO transactions(account_id, transfer_id, txn_type, direction, amount, balance_after, channel, description)
    VALUES (t.source_account_id, t.transfer_id, 'reversal', 'CR', t.amount + t.fee, v_bal, 'system', 'Reversal: ' || p_reason);

    UPDATE transfers SET status = 'reversed', failure_reason = p_reason, reversed_by_staff_id = p_staff_id
     WHERE transfer_id = t.transfer_id;

    INSERT INTO audit_log(actor_type, actor_id, action, entity, entity_id, details)
    VALUES ('staff', p_staff_id, 'transfer_reversed', 'transfers', t.transfer_id,
            jsonb_build_object('reference', p_reference, 'reason', p_reason));
END;
$$ LANGUAGE plpgsql;

-- Pin the schema so the functions work no matter what the caller's search_path is
ALTER FUNCTION transfer_funds(BIGINT, BIGINT, NUMERIC, VARCHAR, VARCHAR) SET search_path = vault, public;
ALTER FUNCTION reverse_transfer(CHAR, INT, VARCHAR) SET search_path = vault, public;
