"""
NairaVault seed data generator
Student: Fakiyesi Vincent (2026/A/MIT/0304) - MIT 8103 Portfolio 1

Generates a realistic, internally consistent dataset:
  * every ledger row keeps a correct running balance (balance_after)
  * accounts.balance equals the last balance_after for that account
  * every internal transfer produces a DR leg, a CR leg and a fee row
Usage:  python3 Fakiyesi_Vincent_SeedData.py "dbname=nairavault host=/tmp user=postgres"
"""
import random, sys, io, datetime as dt
from decimal import Decimal
import psycopg2

random.seed(8103)
DSN = sys.argv[1] if len(sys.argv) > 1 else "dbname=nairavault host=/tmp user=postgres"

N_CUSTOMERS   = 3000
N_EVENTS      = 150_000          # deposits / withdrawals / transfers
START         = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
END           = dt.datetime(2026, 10, 31, tzinfo=dt.timezone.utc)
FEE_INTERNAL  = Decimal("10.00")
FEE_EXTERNAL  = Decimal("26.88")  # typical NIP fee for transfers under N50k

BANKS = [("044","Access Bank"),("058","GTBank"),("057","Zenith Bank"),("011","First Bank"),
         ("033","United Bank for Africa"),("070","Fidelity Bank"),("032","Union Bank"),
         ("214","FCMB"),("035","Wema Bank"),("050","Ecobank"),("232","Sterling Bank"),
         ("221","Stanbic IBTC"),("068","Standard Chartered"),("100","SunTrust Bank"),
         ("301","Jaiz Bank"),("076","Polaris Bank"),("082","Keystone Bank"),
         ("030","Heritage Bank"),("023","Citibank"),("101","Providus Bank")]

STAFF = [("Adaeze Okonkwo","adaeze.okonkwo@nairavault.ng","compliance"),
         ("Tunde Bakare","tunde.bakare@nairavault.ng","support"),
         ("Halima Yusuf","halima.yusuf@nairavault.ng","support"),
         ("Chidi Nwosu","chidi.nwosu@nairavault.ng","finance"),
         ("Bola Adeyemi","bola.adeyemi@nairavault.ng","admin")]

FIRST = ["Adebayo","Chioma","Emeka","Funke","Ibrahim","Kemi","Ngozi","Oluwaseun","Tolu","Uche",
         "Yusuf","Zainab","Amaka","Bashir","Damilola","Efe","Gbenga","Hauwa","Ifeoma","Jide",
         "Kunle","Lola","Musa","Nkechi","Obinna","Peace","Rasheed","Sade","Temitope","Victor"]
LAST  = ["Adeyemi","Okafor","Bello","Eze","Mohammed","Okoro","Adewale","Nwachukwu","Abubakar",
         "Ogunleye","Chukwu","Lawal","Obi","Olawale","Umar","Igwe","Balogun","Oyelaran","Sani","Nnamdi"]
STATES = ["Lagos","Ogun","Oyo","Rivers","Kano","Kaduna","Enugu","Anambra","Delta","FCT","Edo","Ondo"]
NARRATIONS = ["Rent","School fees","Data subscription","Food","Transport","Church offering",
              "Ajo contribution","Birthday gift","Salary","POS withdrawal","Electricity bill","Loan repayment"]

def rand_ts(a, b):
    return a + (b - a) * random.random()

def main():
    conn = psycopg2.connect(DSN)
    cur = conn.cursor()
    cur.execute("SET search_path TO vault")

    cur.executemany("INSERT INTO banks VALUES (%s,%s)", BANKS)
    cur.executemany("INSERT INTO staff(full_name,email,role) VALUES (%s,%s,%s)", STAFF)

    # ---- customers --------------------------------------------------
    customers = []
    for i in range(1, N_CUSTOMERS + 1):
        name = f"{random.choice(FIRST)} {random.choice(LAST)}"
        phone = f"080{random.randint(10000000, 99999999)}" if i % 2 else f"070{random.randint(10000000, 99999999)}"
        phone = phone[:11] + str(i).zfill(4)[-4:]      # guarantee uniqueness
        email = f"{name.lower().replace(' ', '.')}{i}@example.com"
        dob = dt.date(random.randint(1960, 2006), random.randint(1, 12), random.randint(1, 28))
        tier = random.choices([1, 2, 3], weights=[35, 45, 20])[0]
        status = random.choices(["active", "suspended", "closed"], weights=[94, 4, 2])[0]
        created = rand_ts(dt.datetime(2024, 1, 1, tzinfo=dt.timezone.utc), START)
        customers.append((name, phone, email, dob, random.choice(STATES), tier, status, created))
    buf = io.StringIO()
    for c in customers:
        buf.write("\t".join(str(x) for x in c) + "\n")
    buf.seek(0)
    cur.copy_from(buf, "customers",
                  columns=("full_name","phone","email","date_of_birth","state_of_residence",
                           "kyc_tier","status","created_at"))

    # ---- accounts ---------------------------------------------------
    accounts = []       # (customer_id, account_number, type, opened_at)
    acct_no = 2010000000
    for cid in range(1, N_CUSTOMERS + 1):
        n = random.choices([1, 2], weights=[75, 25])[0]
        for k in range(n):
            acct_no += 1
            accounts.append((cid, str(acct_no), "wallet" if k == 0 else "savings", customers[cid-1][7]))
    buf = io.StringIO()
    for a in accounts:
        buf.write("\t".join(str(x) for x in a) + "\n")
    buf.seek(0)
    cur.copy_from(buf, "accounts", columns=("customer_id","account_number","account_type","opened_at"))
    conn.commit()

    cur.execute("SELECT account_id FROM accounts ORDER BY account_id")
    acct_ids = [r[0] for r in cur.fetchall()]
    balance = {a: Decimal("0.00") for a in acct_ids}

    # ---- ledger events (chronological) ------------------------------
    times = sorted(rand_ts(START, END) for _ in range(N_EVENTS))
    txn_rows, transfer_rows = [], []
    transfer_seq = 0
    channels = ["app","app","app","ussd","web","api"]

    for t in times:
        kind = random.choices(["deposit","withdrawal","transfer_int","transfer_ext"],
                              weights=[35, 20, 35, 10])[0]
        src = random.choice(acct_ids)
        ch = random.choice(channels)
        if kind == "deposit":
            amt = Decimal(random.choice([1000,2000,5000,10000,20000,50000,100000]))
            balance[src] += amt
            txn_rows.append((src, None, "deposit", "CR", amt, balance[src], ch, "Wallet funding", t))
        elif kind == "withdrawal":
            amt = Decimal(random.choice([500,1000,2000,5000,10000,20000]))
            if balance[src] >= amt:
                balance[src] -= amt
                txn_rows.append((src, None, "withdrawal", "DR", amt, balance[src], ch, "Cash withdrawal", t))
        else:
            amt = Decimal(random.choice([500,1000,1500,2000,3000,5000,7500,10000,15000,25000,50000]))
            fee = FEE_INTERNAL if kind == "transfer_int" else FEE_EXTERNAL
            transfer_seq += 1
            ref = f"NV{t.strftime('%Y%m%d')}{transfer_seq:010d}"
            narr = random.choice(NARRATIONS)
            if balance[src] < amt + fee:
                # insufficient funds -> failed transfer, no ledger rows
                if kind == "transfer_ext":
                    transfer_rows.append((ref, src, None, str(random.randint(1000000000, 9999999999)),
                                          random.choice(BANKS)[0], amt, fee, narr, "failed",
                                          "Insufficient funds", t, None, None))
                else:
                    dst = random.choice(acct_ids)
                    while dst == src:
                        dst = random.choice(acct_ids)
                    transfer_rows.append((ref, src, dst, None, None, amt, fee, narr,
                                          "failed", "Insufficient funds", t, None, None))
                continue
            if kind == "transfer_int":
                dst = random.choice(acct_ids)
                while dst == src:
                    dst = random.choice(acct_ids)
                tid = len(transfer_rows) + 1
                transfer_rows.append((ref, src, dst, None, None, amt, fee, narr, "completed", None, t, t, None))
                balance[src] -= amt
                txn_rows.append((src, tid, "transfer_out", "DR", amt, balance[src], ch, narr, t))
                balance[src] -= fee
                txn_rows.append((src, tid, "fee", "DR", fee, balance[src], "system", "Transfer fee", t))
                balance[dst] += amt
                txn_rows.append((dst, tid, "transfer_in", "CR", amt, balance[dst], "system", narr, t))
            else:
                bank = random.choice(BANKS)[0]
                ext = str(random.randint(1000000000, 9999999999))
                tid = len(transfer_rows) + 1
                transfer_rows.append((ref, src, None, ext, bank, amt, fee, narr, "completed", None, t, t, None))
                balance[src] -= amt
                txn_rows.append((src, tid, "transfer_out", "DR", amt, balance[src], ch, narr, t))
                balance[src] -= fee
                txn_rows.append((src, tid, "fee", "DR", fee, balance[src], "system", "NIP transfer fee", t))

    # fix transfer_id references for failed rows (they have no ledger rows, ids still sequential)
    def fmt(v):
        return "\\N" if v is None else str(v)

    buf = io.StringIO()
    for r in transfer_rows:
        buf.write("\t".join(fmt(x) for x in r) + "\n")
    buf.seek(0)
    cur.copy_from(buf, "transfers",
                  columns=("reference","source_account_id","destination_account_id",
                           "external_account_number","external_bank_code","amount","fee","narration",
                           "status","failure_reason","initiated_at","completed_at","reversed_by_staff_id"))

    buf = io.StringIO()
    for r in txn_rows:
        buf.write("\t".join(fmt(x) for x in r) + "\n")
    buf.seek(0)
    cur.copy_from(buf, "transactions",
                  columns=("account_id","transfer_id","txn_type","direction","amount","balance_after",
                           "channel","description","created_at"))

    # ---- cached balances -------------------------------------------
    buf = io.StringIO()
    for a, b in balance.items():
        buf.write(f"{a}\t{b}\n")
    buf.seek(0)
    cur.execute("CREATE TEMP TABLE tmp_bal(account_id BIGINT, bal NUMERIC(18,2))")
    cur.copy_from(buf, "tmp_bal", columns=("account_id","bal"))
    cur.execute("UPDATE accounts a SET balance = t.bal FROM tmp_bal t WHERE t.account_id = a.account_id")

    # ---- beneficiaries & KYC ---------------------------------------
    ben = []
    for cid in range(1, N_CUSTOMERS + 1):
        for _ in range(random.choices([0,1,2,3], weights=[30,40,20,10])[0]):
            ben.append((cid, random.choice(FIRST), str(random.randint(1000000000, 9999999999)),
                        random.choice(BANKS)[0]))
    cur.executemany("INSERT INTO beneficiaries(customer_id,alias,account_number,bank_code) "
                    "VALUES (%s,%s,%s,%s) ON CONFLICT DO NOTHING", ben)

    kyc = []
    for cid, c in enumerate(customers, start=1):
        tier = c[5]
        docs = ["bvn"] if tier >= 2 else []
        if tier == 3:
            docs += ["nin", "utility_bill"]
        if tier == 1 and random.random() < 0.3:
            docs = ["nin"]      # submitted but still pending
        for d in docs:
            status = "approved" if tier >= 2 else "pending"
            reviewer = random.randint(1, 5) if status == "approved" else None
            kyc.append((cid, d, "****" + str(random.randint(1000, 9999)), status, reviewer))
    cur.executemany("INSERT INTO kyc_documents(customer_id,document_type,document_number_masked,"
                    "status,reviewed_by_staff_id) VALUES (%s,%s,%s,%s,%s)", kyc)

    cur.execute("""INSERT INTO audit_log(actor_type, actor_id, action, entity, entity_id, details)
                   SELECT 'staff', reviewed_by_staff_id, 'kyc_approved', 'kyc_documents', kyc_id,
                          jsonb_build_object('document_type', document_type)
                   FROM kyc_documents WHERE status = 'approved'""")
    conn.commit()

    for tbl in ["banks","staff","customers","accounts","transfers","transactions",
                "beneficiaries","kyc_documents","audit_log"]:
        cur.execute(f"SELECT count(*) FROM {tbl}")
        print(f"{tbl:15s} {cur.fetchone()[0]:>9,} rows")
    conn.close()

if __name__ == "__main__":
    main()
