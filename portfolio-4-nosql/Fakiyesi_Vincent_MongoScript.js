// =====================================================================
// NairaVault document model - mongosh script
// Student: Fakiyesi Vincent (2026/A/MIT/0304) - MIT 8103 Portfolio 4
// Run:  mongosh "mongodb://localhost:27017" Fakiyesi_Vincent_MongoScript.js
//   or paste into the Atlas shell. Works on MongoDB 6.x / 7.x.
// =====================================================================
db = db.getSiblingDB("nairavault");
db.dropDatabase();

// ---------- 1. Collections with JSON Schema validation ---------------
// Document stores are schema-flexible, but money data still needs rules.
db.createCollection("customers", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["fullName", "phone", "kyc", "accounts", "createdAt"],
    properties: {
      fullName: { bsonType: "string" },
      phone:    { bsonType: "string", pattern: "^0[789][01][0-9]{8}$" },
      kyc: { bsonType: "object", required: ["tier", "status"],
             properties: { tier: { bsonType: "int", minimum: 1, maximum: 3 },
                           status: { enum: ["active", "suspended", "closed"] } } },
      accounts: { bsonType: "array", minItems: 1, maxItems: 5,
        items: { bsonType: "object", required: ["accountNumber", "balance", "status"],
                 properties: { accountNumber: { bsonType: "string", pattern: "^[0-9]{10}$" },
                               balance: { bsonType: ["double", "decimal", "int", "long"], minimum: 0 },
                               status: { enum: ["open", "frozen", "closed"] } } } }
    } } }
});
db.createCollection("transactions", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["accountNumber", "customerId", "type", "direction", "amount", "balanceAfter", "createdAt"],
    properties: {
      type: { enum: ["deposit", "withdrawal", "transfer_in", "transfer_out", "fee", "reversal"] },
      direction: { enum: ["DR", "CR"] },
      amount: { bsonType: ["double", "decimal", "int", "long"], minimum: 0.01 },
      balanceAfter: { bsonType: ["double", "decimal", "int", "long"], minimum: 0 }
    } } }
});
db.createCollection("daily_limits");
db.createCollection("notifications");

// ---------- 2. Indexes --------------------------------------------------
db.customers.createIndex({ phone: 1 }, { unique: true });
db.customers.createIndex({ "accounts.accountNumber": 1 }, { unique: true }); // multikey on embedded array
db.customers.createIndex({ state: 1, "kyc.tier": 1 });
db.transactions.createIndex({ accountNumber: 1, createdAt: -1 });              // statement query
db.transactions.createIndex({ customerId: 1, createdAt: -1 });
db.transactions.createIndex({ type: 1, createdAt: 1 });                        // fee report
db.daily_limits.createIndex({ expiresAt: 1 }, { expireAfterSeconds: 0 });      // TTL: auto-delete after midnight
db.notifications.createIndex({ customerId: 1, read: 1, createdAt: -1 });

// ---------- 3. Sample documents ----------------------------------------
db.customers.insertMany([
  { _id: 1250, fullName: "Chioma Okafor", phone: "08034567890", email: "chioma.okafor@example.com",
    dateOfBirth: new Date("1991-04-12"), state: "Lagos",
    kyc: { tier: 2, status: "active",
           documents: [ { type: "bvn", numberMasked: "****4471", status: "approved",
                          reviewedBy: "Adaeze Okonkwo", reviewedAt: new Date("2026-02-03T10:14:00Z") } ] },
    accounts: [
      { accountNumber: "2010001537", type: "wallet",  currency: "NGN", balance: 42850.00,  status: "open", openedAt: new Date("2025-11-02T08:00:00Z") },
      { accountNumber: "2010001538", type: "savings", currency: "NGN", balance: 150000.00, status: "open", openedAt: new Date("2025-11-02T08:00:00Z") } ],
    beneficiaries: [ { alias: "Mum", accountNumber: "0123456789", bankCode: "058", bankName: "GTBank" } ],
    createdAt: new Date("2025-11-02T08:00:00Z") },
  { _id: 1251, fullName: "Emeka Bello", phone: "07012345678", state: "Enugu",
    kyc: { tier: 1, status: "active", documents: [] },
    accounts: [ { accountNumber: "2010001539", type: "wallet", currency: "NGN", balance: 3200.00, status: "open", openedAt: new Date() } ],
    beneficiaries: [], createdAt: new Date() }
]);

db.transactions.insertMany([
  { accountNumber: "2010001537", customerId: 1250, type: "deposit",      direction: "CR", amount: 50000, balanceAfter: 50000, channel: "app", createdAt: new Date("2026-10-14T08:00:00Z") },
  { accountNumber: "2010001537", customerId: 1250, type: "transfer_out", direction: "DR", amount: 5000,  balanceAfter: 45000, channel: "app",
    transfer: { reference: "NV202610150000061234", counterparty: "2010001539", narration: "School fees" }, createdAt: new Date("2026-10-15T09:21:44Z") },
  { accountNumber: "2010001537", customerId: 1250, type: "fee",          direction: "DR", amount: 10,    balanceAfter: 44990, channel: "system",
    transfer: { reference: "NV202610150000061234" }, createdAt: new Date("2026-10-15T09:21:44Z") },
  { accountNumber: "2010001539", customerId: 1251, type: "transfer_in",  direction: "CR", amount: 5000,  balanceAfter: 8200,  channel: "system",
    transfer: { reference: "NV202610150000061234", counterparty: "2010001537", narration: "School fees" }, createdAt: new Date("2026-10-15T09:21:44Z") }
]);

// ---------- 4. Validation in action (this insert must FAIL) -----------
try {
  db.customers.insertOne({ _id: 9999, fullName: "Bad Doc", phone: "123", kyc: { tier: 7, status: "active" },
                           accounts: [ { accountNumber: "ABC", balance: -5, status: "open" } ], createdAt: new Date() });
} catch (e) { print("Validation rejected bad document: " + e.message.split("\n")[0]); }

// ---------- 5. Queries ---------------------------------------------------
// 5a. Home screen: one read gives profile + wallets + beneficiaries
printjson(db.customers.findOne({ phone: "08034567890" }, { fullName: 1, "kyc.tier": 1, accounts: 1, beneficiaries: 1 }));

// 5b. Find the customer who owns a wallet (query inside the embedded array)
printjson(db.customers.findOne({ "accounts.accountNumber": "2010001539" }, { fullName: 1, phone: 1 }));

// 5c. Statement for one wallet, newest first (uses the compound index)
printjson(db.transactions.find({ accountNumber: "2010001537",
                                 createdAt: { $gte: new Date("2026-10-01"), $lt: new Date("2026-11-01") } })
                         .sort({ createdAt: -1 }).toArray());

// 5d. Tier-1 customers in a state (covered by the { state, kyc.tier } index)
printjson(db.customers.find({ state: "Enugu", "kyc.tier": 1 }, { fullName: 1, phone: 1 }).toArray());

// ---------- 6. Updates ---------------------------------------------------
// 6a. Add a beneficiary (push into embedded array) - atomic on the document
db.customers.updateOne({ _id: 1251 }, { $push: { beneficiaries: { alias: "Landlord", accountNumber: "0987654321", bankCode: "044", bankName: "Access Bank" } } });

// 6b. Upgrade KYC tier and append the approved document in one atomic update
db.customers.updateOne({ _id: 1251 },
  { $set: { "kyc.tier": 2 },
    $push: { "kyc.documents": { type: "bvn", numberMasked: "****9031", status: "approved", reviewedBy: "Adaeze Okonkwo", reviewedAt: new Date() } } });

// 6c. Key-value daily limit counter: atomic $inc with upsert
db.daily_limits.updateOne({ _id: "2010001537:2026-10-15" },
  { $inc: { sentToday: 5000 }, $setOnInsert: { expiresAt: new Date("2026-10-16T00:00:00Z") } }, { upsert: true });
printjson(db.daily_limits.findOne({ _id: "2010001537:2026-10-15" }));

// 6d. Notification with a free-form payload
db.notifications.insertOne({ customerId: 1251, kind: "credit_alert", read: false, createdAt: new Date(),
  payload: { amount: 5000, from: "Chioma Okafor", narration: "School fees", newBalance: 8200 } });

// ---------- 7. Aggregation pipelines -------------------------------------
// 7a. Daily fee revenue (the Q3 report from Portfolio 2)
printjson(db.transactions.aggregate([
  { $match: { type: "fee", createdAt: { $gte: new Date("2026-10-01"), $lt: new Date("2026-11-01") } } },
  { $group: { _id: { $dateToString: { format: "%Y-%m-%d", date: "$createdAt" } },
              feeCount: { $sum: 1 }, feeRevenue: { $sum: "$amount" } } },
  { $sort: { _id: 1 } }
]).toArray());

// 7b. Total wallet balance per state (unwind the embedded accounts)
printjson(db.customers.aggregate([
  { $unwind: "$accounts" },
  { $match: { "accounts.status": "open" } },
  { $group: { _id: "$state", wallets: { $sum: 1 }, totalBalance: { $sum: "$accounts.balance" } } },
  { $sort: { totalBalance: -1 } }, { $limit: 5 }
]).toArray());

// 7c. Join-like lookup: transactions with the owner's name
printjson(db.transactions.aggregate([
  { $match: { type: "transfer_out" } },
  { $lookup: { from: "customers", localField: "customerId", foreignField: "_id", as: "owner" } },
  { $unwind: "$owner" },
  { $project: { _id: 0, accountNumber: 1, amount: 1, "transfer.reference": 1, ownerName: "$owner.fullName" } }
]).toArray());

// ---------- 8. Explain: prove the index is used -------------------------
printjson(db.transactions.find({ accountNumber: "2010001537" }).sort({ createdAt: -1 })
            .explain("executionStats").executionStats);
