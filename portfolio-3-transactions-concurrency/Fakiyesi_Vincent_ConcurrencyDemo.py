"""
Portfolio 3 - Concurrency demonstrations with two (or more) real database sessions
Student: Fakiyesi Vincent (2026/A/MIT/0304)

Each demo opens separate PostgreSQL connections (Session A, Session B) and runs
them on separate threads so the interleaving really happens inside the DBMS.
Output is timestamped so the order of events is visible.

Demos
  1. LOST UPDATE  - naive read-then-write from two sessions loses money
  2. FIX          - SELECT ... FOR UPDATE (pessimistic lock) makes it correct
  3. ISOLATION    - READ COMMITTED vs REPEATABLE READ: non-repeatable read
  4. DEADLOCK     - two sessions lock A->B and B->A; PostgreSQL detects it
  5. NO DEADLOCK  - the ordered locking in transfer_funds() avoids it
  6. STRESS TEST  - 16 threads, 800 transfers, then full ledger reconciliation

Usage: python3 Fakiyesi_Vincent_ConcurrencyDemo.py "dbname=nairavault host=/tmp user=postgres"
"""
import sys, time, threading, random
from decimal import Decimal
import psycopg2, psycopg2.errors

DSN = sys.argv[1] if len(sys.argv) > 1 else "dbname=nairavault host=/tmp user=postgres"
T0 = time.perf_counter()
_lock = threading.Lock()

def log(session, msg):
    with _lock:
        print(f"[{(time.perf_counter()-T0)*1000:8.1f} ms] {session:9s} {msg}", flush=True)

def connect(autocommit=False):
    c = psycopg2.connect(DSN)
    c.autocommit = autocommit
    cur = c.cursor()
    cur.execute("SET search_path TO vault")
    if not autocommit:
        c.commit()
    return c

def balance(acct):
    c = connect(True); cur = c.cursor()
    cur.execute("SELECT balance FROM accounts WHERE account_id=%s", (acct,))
    b = cur.fetchone()[0]; c.close(); return b

def set_balance(acct, amount):
    """reset through the ledger so reconciliation still holds"""
    c = connect(True); cur = c.cursor()
    # compare against the LEDGER, not the cached balance, so that the naive
    # UPDATEs in demo 1 (which deliberately bypass the ledger) get repaired too
    cur.execute("""SELECT coalesce(sum(CASE WHEN direction='CR' THEN amount ELSE -amount END),0)
                   FROM transactions WHERE account_id=%s""", (acct,))
    diff = Decimal(amount) - cur.fetchone()[0]
    cur.execute("UPDATE accounts SET balance=%s, status='open' WHERE account_id=%s", (amount, acct))
    if diff != 0:
        cur.execute("""INSERT INTO transactions(account_id,txn_type,direction,amount,balance_after,channel,description)
                       VALUES (%s,%s,%s,%s,%s,'system','Demo balance reset')""",
                    (acct, 'deposit' if diff > 0 else 'withdrawal', 'CR' if diff > 0 else 'DR', abs(diff), amount))
    c.close()

def banner(title):
    print("\n" + "=" * 78 + f"\n{title}\n" + "=" * 78)

# ---------------------------------------------------------------------------
def demo_lost_update(with_lock):
    acct = 30
    set_balance(acct, 10000)
    banner(f"DEMO {'2: SAME SCENARIO WITH SELECT ... FOR UPDATE' if with_lock else '1: LOST UPDATE (naive read-then-write)'}")
    print(f"Account {acct} starts at 10,000. Session A withdraws 3,000, Session B withdraws 4,000.")
    print(f"Correct final balance: 3,000.\n")
    barrier = threading.Barrier(2)

    def worker(name, amount):
        c = connect(); cur = c.cursor()
        log(name, "BEGIN")
        cur.execute("SELECT balance FROM accounts WHERE account_id=%s" + (" FOR UPDATE" if with_lock else ""), (acct,))
        bal = cur.fetchone()[0]
        log(name, f"read balance = {bal}" + ("  (row is now locked)" if with_lock else ""))
        barrier.wait(timeout=5) if not with_lock else None   # make both read before either writes
        time.sleep(0.2)
        new = bal - amount
        cur.execute("UPDATE accounts SET balance=%s WHERE account_id=%s", (new, acct))
        log(name, f"UPDATE balance = {bal} - {amount} = {new}")
        c.commit()
        log(name, "COMMIT")
        c.close()

    ta = threading.Thread(target=worker, args=("Session A", 3000))
    tb = threading.Thread(target=worker, args=("Session B", 4000))
    ta.start(); time.sleep(0.05); tb.start(); ta.join(); tb.join()
    final = balance(acct)
    verdict = "CORRECT" if final == 3000 else f"WRONG - a withdrawal was LOST ({10000-final} deducted instead of 7,000)"
    print(f"\nFinal balance: {final}  ->  {verdict}")
    # tidy the ledger for the reconciliation at the end
    set_balance(acct, 10000)

# ---------------------------------------------------------------------------
def demo_isolation():
    acct = 40
    set_balance(acct, 5000)
    for level in ("READ COMMITTED", "REPEATABLE READ"):
        banner(f"DEMO 3: ISOLATION LEVEL {level}")
        print(f"Session A reads account {acct} twice inside one transaction.")
        print(f"Between the two reads, Session B deposits 1,000 and commits.\n")
        a = connect(); ca = a.cursor()
        ca.execute(f"SET TRANSACTION ISOLATION LEVEL {level}")
        ca.execute("SELECT balance FROM accounts WHERE account_id=%s", (acct,))
        r1 = ca.fetchone()[0]
        log("Session A", f"BEGIN ({level}); first read  = {r1}")

        b = connect(); cb = b.cursor()
        cb.execute("UPDATE accounts SET balance = balance + 1000 WHERE account_id=%s", (acct,))
        cb.execute("""INSERT INTO transactions(account_id,txn_type,direction,amount,balance_after,channel,description)
                      SELECT %s,'deposit','CR',1000,balance,'system','Isolation demo' FROM accounts WHERE account_id=%s""",
                   (acct, acct))
        b.commit(); b.close()
        log("Session B", "deposited 1,000 and COMMITTED")

        ca.execute("SELECT balance FROM accounts WHERE account_id=%s", (acct,))
        r2 = ca.fetchone()[0]
        log("Session A", f"second read = {r2}")
        a.commit(); a.close()
        if r1 == r2:
            print(f"\n-> Same value both times: {level} gives a consistent snapshot (no non-repeatable read).")
        else:
            print(f"\n-> Value changed from {r1} to {r2} inside one transaction: a NON-REPEATABLE READ,")
            print(  "   which READ COMMITTED allows. Fine for a dashboard, dangerous for a balance check.")
        set_balance(acct, 5000)

# ---------------------------------------------------------------------------
def demo_deadlock():
    a1, a2 = 50, 60
    set_balance(a1, 10000); set_balance(a2, 10000)
    banner("DEMO 4: DEADLOCK - Session A locks 50 then 60, Session B locks 60 then 50")
    results = {}

    def worker(name, first, second):
        c = connect(); cur = c.cursor()
        try:
            cur.execute("SELECT balance FROM accounts WHERE account_id=%s FOR UPDATE", (first,))
            log(name, f"locked account {first}")
            time.sleep(0.3)
            log(name, f"waiting for account {second} ...")
            cur.execute("SELECT balance FROM accounts WHERE account_id=%s FOR UPDATE", (second,))
            log(name, f"locked account {second}")
            c.commit(); results[name] = "committed"
            log(name, "COMMIT")
        except psycopg2.errors.DeadlockDetected as e:
            results[name] = "deadlock victim"
            log(name, "ERROR: " + str(e).splitlines()[0])
            c.rollback()
            log(name, "ROLLBACK (PostgreSQL chose this session as the victim)")
        finally:
            c.close()

    ta = threading.Thread(target=worker, args=("Session A", a1, a2))
    tb = threading.Thread(target=worker, args=("Session B", a2, a1))
    ta.start(); tb.start(); ta.join(); tb.join()
    print(f"\nOutcome: {results}")
    print("PostgreSQL's deadlock detector (deadlock_timeout = 1 s) broke the cycle by aborting one session.")

# ---------------------------------------------------------------------------
def demo_no_deadlock():
    a1, a2 = 50, 60
    set_balance(a1, 10000); set_balance(a2, 10000)
    banner("DEMO 5: SAME PATTERN THROUGH transfer_funds() - ordered locking, no deadlock")
    print("Session A: transfer 50 -> 60.  Session B: transfer 60 -> 50.  Both at the same moment, 50 times each.\n")
    errors = []
    def worker(name, src, dst):
        c = connect(); cur = c.cursor()
        for _ in range(50):
            try:
                cur.execute("SELECT transfer_funds(%s,%s,%s,%s)", (src, dst, 100, f"{name} ping"))
                c.commit()
            except Exception as e:
                errors.append((name, str(e).splitlines()[0])); c.rollback()
        c.close()
    ta = threading.Thread(target=worker, args=("Session A", a1, a2))
    tb = threading.Thread(target=worker, args=("Session B", a2, a1))
    ta.start(); tb.start(); ta.join(); tb.join()
    print(f"Deadlock errors: {len([e for e in errors if 'deadlock' in e[1].lower()])}   other errors: {len(errors)}")
    print(f"Balances: 50 = {balance(a1)}, 60 = {balance(a2)}  (each sent 5,000 + 500 fees and received 5,000 -> 9,500 each)")

# ---------------------------------------------------------------------------
def demo_stress():
    banner("DEMO 6: STRESS TEST - 16 threads x 50 random transfers through transfer_funds()")
    c = connect(True); cur = c.cursor()
    cur.execute("SELECT account_id FROM accounts WHERE status='open' AND balance > 20000 ORDER BY account_id LIMIT 200")
    pool = [r[0] for r in cur.fetchall()]
    cur.execute("SELECT sum(balance) FROM accounts"); total_before = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM transactions"); ledger_before = cur.fetchone()[0]
    c.close()
    ok, insufficient, limit, other = [0], [0], [0], []
    def worker(seed):
        rnd = random.Random(seed)
        c = connect(); cur = c.cursor()
        for _ in range(50):
            s, d = rnd.sample(pool, 2)
            try:
                cur.execute("SELECT transfer_funds(%s,%s,%s,'stress')", (s, d, rnd.choice([500, 1000, 2500, 5000])))
                c.commit(); ok[0] += 1
            except psycopg2.Error as e:
                c.rollback()
                m = str(e).splitlines()[0]
                if "Insufficient" in m: insufficient[0] += 1
                elif "Daily limit" in m: limit[0] += 1
                else: other.append(m)
        c.close()
    t_start = time.perf_counter()
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(16)]
    [t.start() for t in threads]; [t.join() for t in threads]
    elapsed = time.perf_counter() - t_start

    c = connect(True); cur = c.cursor()
    cur.execute("SELECT sum(balance) FROM accounts"); total_after = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM transactions"); ledger_after = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM accounts WHERE balance < 0"); negatives = cur.fetchone()[0]
    cur.execute("""SELECT count(*) FILTER (WHERE a.balance <> s.net), count(*)
                   FROM accounts a JOIN (SELECT account_id, sum(CASE WHEN direction='CR' THEN amount ELSE -amount END) net
                                         FROM transactions GROUP BY account_id) s USING (account_id)""")
    mismatched, checked = cur.fetchone()
    c.close()
    fees = Decimal(ok[0]) * 10
    print(f"Completed: {ok[0]}   insufficient funds: {insufficient[0]}   daily-limit: {limit[0]}   "
          f"other errors: {len(other)}   time: {elapsed:.2f}s  ({ok[0]/elapsed:.0f} transfers/s)")
    if other: print("  other:", other[:3])
    print(f"Total money in system before: {total_before}   after: {total_after}   "
          f"difference: {total_before-total_after} (= fees collected, expected {fees})")
    print(f"Ledger rows added: {ledger_after-ledger_before} (expected {ok[0]*3})")
    print(f"Accounts with negative balance: {negatives}")
    print(f"Accounts whose balance disagrees with their ledger: {mismatched} of {checked}")
    print("\nVERDICT:", "ALL CONSISTENT" if negatives == 0 and mismatched == 0
          and total_before - total_after == fees else "INCONSISTENCY FOUND")

if __name__ == "__main__":
    demo_lost_update(with_lock=False)
    demo_lost_update(with_lock=True)
    demo_isolation()
    demo_deadlock()
    demo_no_deadlock()
    demo_stress()
