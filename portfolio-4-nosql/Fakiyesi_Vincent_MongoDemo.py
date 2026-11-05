"""
Portfolio 4 - NairaVault document model: migration + queries with the pymongo API
Student: Fakiyesi Vincent (2026/A/MIT/0304)

What this does
  1. Reads the relational data from PostgreSQL (Portfolios 1-3)
  2. Builds MongoDB documents (customers with embedded accounts/beneficiaries/KYC,
     one document per ledger entry, daily-limit key-value docs, notifications)
  3. Inserts them through the official pymongo API
  4. Creates indexes and runs find / update / aggregation queries, timing them
  5. Exports sample documents to evidence/ as JSON (loadable with mongoimport)

Engine: set MONGO_URI to use a real MongoDB server / Atlas cluster, e.g.
    MONGO_URI="mongodb+srv://user:pass@cluster.mongodb.net" python3 Fakiyesi_Vincent_MongoDemo.py
Without MONGO_URI it falls back to mongomock, an in-memory MongoDB-compatible engine
that implements the pymongo interface (used because a MongoDB server could not be
installed in my environment). The code is identical either way.
"""
import os, sys, json, time, pathlib, datetime as dt
from decimal import Decimal
import psycopg2, psycopg2.extras

PG_DSN = sys.argv[1] if len(sys.argv) > 1 else "dbname=nairavault host=/tmp user=postgres"
EV = pathlib.Path(__file__).parent / "evidence"; EV.mkdir(exist_ok=True)

if os.environ.get("MONGO_URI"):
    from pymongo import MongoClient
    client = MongoClient(os.environ["MONGO_URI"]); ENGINE = "MongoDB server"
else:
    import mongomock
    client = mongomock.MongoClient(); ENGINE = "mongomock (in-memory, pymongo-compatible)"
from pymongo import ASCENDING, DESCENDING

db = client["nairavault"]
for c in ("customers", "transactions", "daily_limits", "notifications"):
    db[c].drop()

def f(x):            # Decimal -> float for BSON
    return float(x) if isinstance(x, Decimal) else x

def say(*a):
    print(*a, flush=True)

say(f"Engine: {ENGINE}\n")

# ---------------------------------------------------------------- 1. read SQL
pg = psycopg2.connect(PG_DSN); cur = pg.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
cur.execute("SET search_path TO vault")
cur.execute("SELECT * FROM customers ORDER BY customer_id");       customers = cur.fetchall()
cur.execute("SELECT * FROM accounts ORDER BY account_id");          accounts = cur.fetchall()
cur.execute("""SELECT b.*, k.bank_name FROM beneficiaries b JOIN banks k USING (bank_code)"""); bens = cur.fetchall()
cur.execute("""SELECT k.*, s.full_name AS reviewer FROM kyc_documents k
               LEFT JOIN staff s ON s.staff_id = k.reviewed_by_staff_id"""); kyc = cur.fetchall()
cur.execute("""SELECT t.*, a.account_number, a.customer_id, tr.reference, tr.narration,
                      CASE WHEN tr.source_account_id = t.account_id THEN d.account_number ELSE s.account_number END AS counterparty
               FROM transactions t
               JOIN accounts a ON a.account_id = t.account_id
               LEFT JOIN transfers tr ON tr.transfer_id = t.transfer_id
               LEFT JOIN accounts s ON s.account_id = tr.source_account_id
               LEFT JOIN accounts d ON d.account_id = tr.destination_account_id
               ORDER BY t.transaction_id""" + ("" if os.environ.get("MONGO_URI") else " DESC LIMIT 25000"))
txns = cur.fetchall()
if not os.environ.get("MONGO_URI"):
    txns.reverse()
    say("NOTE: mongomock is a pure-Python test double, so only the most recent 25,000 ledger rows are migrated\n"
        "      and timings below are NOT representative of MongoDB. Set MONGO_URI for a full run on a real server.")
pg.close()
say(f"Read from PostgreSQL: {len(customers)} customers, {len(accounts)} accounts, {len(txns)} ledger rows")

# ---------------------------------------------------------------- 2. build docs
acc_by_cust, ben_by_cust, kyc_by_cust = {}, {}, {}
for a in accounts:
    acc_by_cust.setdefault(a["customer_id"], []).append({
        "accountNumber": a["account_number"], "type": a["account_type"], "currency": a["currency"],
        "balance": f(a["balance"]), "status": a["status"], "openedAt": a["opened_at"]})
for b in bens:
    ben_by_cust.setdefault(b["customer_id"], []).append({
        "alias": b["alias"], "accountNumber": b["account_number"], "bankCode": b["bank_code"],
        "bankName": b["bank_name"]})
for k in kyc:
    kyc_by_cust.setdefault(k["customer_id"], []).append({
        "type": k["document_type"], "numberMasked": k["document_number_masked"], "status": k["status"],
        "reviewedBy": k["reviewer"], "reviewedAt": k["reviewed_at"]})

cust_docs = [{
    "_id": c["customer_id"], "fullName": c["full_name"], "phone": c["phone"], "email": c["email"],
    "dateOfBirth": dt.datetime.combine(c["date_of_birth"], dt.time()), "state": c["state_of_residence"],
    "kyc": {"tier": c["kyc_tier"], "status": c["status"], "documents": kyc_by_cust.get(c["customer_id"], [])},
    "accounts": acc_by_cust.get(c["customer_id"], []),
    "beneficiaries": ben_by_cust.get(c["customer_id"], []),
    "createdAt": c["created_at"]} for c in customers]

txn_docs = []
for t in txns:
    d = {"accountNumber": t["account_number"], "customerId": t["customer_id"], "type": t["txn_type"],
         "direction": t["direction"], "amount": f(t["amount"]), "balanceAfter": f(t["balance_after"]),
         "channel": t["channel"], "createdAt": t["created_at"]}
    if t["reference"]:
        d["transfer"] = {"reference": t["reference"].strip(), "counterparty": t["counterparty"],
                         "narration": t["narration"]}
    txn_docs.append(d)

# ---------------------------------------------------------------- 3. insert
t0 = time.perf_counter()
db.customers.insert_many(cust_docs)
db.transactions.insert_many(txn_docs)
say(f"Inserted {db.customers.count_documents({})} customer documents and "
    f"{db.transactions.count_documents({})} transaction documents in {time.perf_counter()-t0:.2f}s")

# ---------------------------------------------------------------- 4. indexes
db.customers.create_index([("phone", ASCENDING)], unique=True)
# unique=True on this multikey index works on a real server (see the mongosh script);
# mongomock does not support unique multikey indexes, so it is plain here
db.customers.create_index([("accounts.accountNumber", ASCENDING)])
db.customers.create_index([("state", ASCENDING), ("kyc.tier", ASCENDING)])
db.transactions.create_index([("accountNumber", ASCENDING), ("createdAt", DESCENDING)])
db.transactions.create_index([("customerId", ASCENDING), ("createdAt", DESCENDING)])
db.transactions.create_index([("type", ASCENDING), ("createdAt", ASCENDING)])
db.daily_limits.create_index([("expiresAt", ASCENDING)], expireAfterSeconds=0)
say("\nIndexes on transactions:", list(db.transactions.index_information().keys()))

# ---------------------------------------------------------------- 5. queries
def timed(label, fn):
    t0 = time.perf_counter(); r = fn(); ms = (time.perf_counter() - t0) * 1000
    say(f"\n--- {label}  ({ms:.1f} ms)")
    return r

sample_acct = cust_docs[1249]["accounts"][0]["accountNumber"]
sample_phone = cust_docs[1249]["phone"]

home = timed("5a. Home screen: ONE document read = profile + wallets + beneficiaries + KYC",
             lambda: db.customers.find_one({"phone": sample_phone},
                                           {"fullName": 1, "kyc.tier": 1, "accounts": 1, "beneficiaries": 1}))
say(json.dumps(home, default=str, indent=2)[:900])

owner = timed("5b. Who owns wallet " + sample_acct + "? (query inside embedded array)",
              lambda: db.customers.find_one({"accounts.accountNumber": sample_acct}, {"fullName": 1, "phone": 1}))
say(owner)

stmt = timed("5c. Statement for " + sample_acct + ", October 2026, newest first",
             lambda: list(db.transactions.find({"accountNumber": sample_acct,
                                                "createdAt": {"$gte": dt.datetime(2026, 10, 1, tzinfo=dt.timezone.utc),
                                                              "$lt": dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)}})
                          .sort([("createdAt", DESCENDING), ("_id", DESCENDING)])))
for r in stmt[:6]:
    say(f"  {r['createdAt']:%Y-%m-%d %H:%M}  {r['type']:12s} {r['direction']} {r['amount']:>10,.2f}  bal {r['balanceAfter']:>12,.2f}")
say(f"  ({len(stmt)} entries)")

tier1 = timed("5d. Tier-1 customers in Enugu (compound index on state + kyc.tier)",
              lambda: db.customers.count_documents({"state": "Enugu", "kyc.tier": 1}))
say(f"  {tier1} customers")

# ---------------------------------------------------------------- 6. updates
cid = cust_docs[1249]["_id"]
res = timed("6a. Add a beneficiary ($push into embedded array)",
            lambda: db.customers.update_one({"_id": cid},
                {"$push": {"beneficiaries": {"alias": "Landlord", "accountNumber": "0987654321",
                                             "bankCode": "044", "bankName": "Access Bank"}}}))
say(f"  matched={res.matched_count} modified={res.modified_count}; beneficiaries now:",
    [b["alias"] for b in db.customers.find_one({"_id": cid})["beneficiaries"]])

today = dt.datetime.now(dt.timezone.utc).date()
key = f"{sample_acct}:{today}"
timed("6b. Daily-limit counter: atomic $inc upsert (key-value pattern)",
      lambda: [db.daily_limits.update_one({"_id": key}, {"$inc": {"sentToday": amt},
               "$setOnInsert": {"expiresAt": dt.datetime.combine(today + dt.timedelta(days=1), dt.time())}}, upsert=True) for amt in (5000, 2500, 10000)])
say("  ", db.daily_limits.find_one({"_id": key}))

db.notifications.insert_one({"customerId": cid, "kind": "credit_alert", "read": False,
                             "createdAt": dt.datetime.now(dt.timezone.utc),
                             "payload": {"amount": 5000, "from": "Emeka Bello", "narration": "School fees"}})
db.notifications.insert_one({"customerId": cid, "kind": "kyc_reminder", "read": False,
                             "createdAt": dt.datetime.now(dt.timezone.utc),
                             "payload": {"missing": ["utility_bill"], "deadline": "2026-12-01"}})
say("\n--- 6c. Two notifications with different payload shapes in one collection (schema flexibility):")
for n in db.notifications.find({"customerId": cid}, {"_id": 0, "kind": 1, "payload": 1}):
    say("  ", n)

# ---------------------------------------------------------------- 7. aggregation
fees = timed("7a. Daily fee revenue for October 2026 (aggregation pipeline)",
    lambda: list(db.transactions.aggregate([
        {"$match": {"type": "fee", "createdAt": {"$gte": dt.datetime(2026, 10, 1, tzinfo=dt.timezone.utc),
                                                 "$lt": dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)}}},
        {"$group": {"_id": {"$dateToString": {"format": "%Y-%m-%d", "date": "$createdAt"}},
                    "feeCount": {"$sum": 1}, "feeRevenue": {"$sum": "$amount"}}},
        {"$sort": {"_id": 1}}])))
for r in fees[:5]: say(f"  {r['_id']}  fees={r['feeCount']:4d}  revenue={r['feeRevenue']:,.2f}")
say(f"  ... {len(fees)} days, total = {sum(r['feeRevenue'] for r in fees):,.2f}")

states = timed("7b. Total open-wallet balance per state ($unwind embedded accounts)",
    lambda: list(db.customers.aggregate([
        {"$unwind": "$accounts"}, {"$match": {"accounts.status": "open"}},
        {"$group": {"_id": "$state", "wallets": {"$sum": 1}, "totalBalance": {"$sum": "$accounts.balance"}}},
        {"$sort": {"totalBalance": -1}}, {"$limit": 5}])))
for r in states: say(f"  {r['_id']:8s} wallets={r['wallets']:4d}  balance={r['totalBalance']:>16,.2f}")

lookup = timed("7c. $lookup (join-like): last 3 transfer_out rows with owner's name",
    lambda: list(db.transactions.aggregate([
        {"$match": {"type": "transfer_out"}}, {"$sort": {"createdAt": -1}}, {"$limit": 3},
        {"$lookup": {"from": "customers", "localField": "customerId", "foreignField": "_id", "as": "owner"}},
        {"$unwind": "$owner"},
        {"$project": {"_id": 0, "accountNumber": 1, "amount": 1, "ref": "$transfer.reference", "owner": "$owner.fullName"}}])))
for r in lookup: say("  ", r)

# ---------------------------------------------------------------- 8. consistency check across models
say("\n--- 8. Cross-model check: embedded balance == last ledger balanceAfter, for every wallet")
mism = 0
checked = 0
for c in db.customers.find({}, {"accounts": 1}).limit(300):
    for a in c["accounts"]:
        # tie-break on _id: a transfer's debit and fee rows share the same timestamp
        last = db.transactions.find_one({"accountNumber": a["accountNumber"]}, sort=[("createdAt", DESCENDING), ("_id", DESCENDING)])
        if last:
            checked += 1
            if abs(last["balanceAfter"] - a["balance"]) > 0.005:
                mism += 1
say(f"  wallets checked: {checked}, mismatches: {mism}")

# ---------------------------------------------------------------- 9. export samples
with open(EV / "sample_customers.json", "w") as fh:
    for d in db.customers.find().limit(5):
        fh.write(json.dumps(d, default=str) + "\n")
with open(EV / "sample_transactions.json", "w") as fh:
    for d in db.transactions.find({"accountNumber": sample_acct}).sort("createdAt", DESCENDING).limit(20):
        d["_id"] = str(d["_id"]); fh.write(json.dumps(d, default=str) + "\n")
say("\nExported evidence/sample_customers.json and evidence/sample_transactions.json "
    "(one document per line - mongoimport format)")
