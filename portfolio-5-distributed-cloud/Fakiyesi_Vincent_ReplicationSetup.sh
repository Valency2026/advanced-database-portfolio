#!/usr/bin/env bash
# =====================================================================
# Portfolio 5 - PostgreSQL streaming replication: primary + hot standby
# Student: Fakiyesi Vincent (2026/A/MIT/0304)
#
# Builds a read replica of the NairaVault database on port 5433 from the
# primary on 5432, then proves: replication is live, the replica is read-only,
# writes on the primary appear on the replica, lag is measurable, and the
# replica can be promoted (failover).
#
# Assumes: primary already running (PGDATA=$PRIMARY, socket dir /tmp, user postgres)
#          and $REPLICA exists, is empty and is owned by postgres.
# Run as the postgres OS user:  bash Fakiyesi_Vincent_ReplicationSetup.sh
# =====================================================================
set -u
PGBIN=/usr/lib/postgresql/16/bin
PRIMARY=${PRIMARY:-/home/claude/pgdata}
REPLICA=${REPLICA:-/home/claude/pgdata_replica}
LOG=${LOG:-/home/claude/pglog}
P() { psql -h /tmp -p 5432 -U postgres -d nairavault -X "$@"; }   # primary
R() { psql -h /tmp -p 5433 -U postgres -d nairavault -X "$@"; }   # replica

echo "=== 1. Primary configuration (WAL level, senders, replication slot)"
P -c "SHOW wal_level;" -c "SHOW max_wal_senders;" -c "SHOW hot_standby;"
P -c "SELECT pg_create_physical_replication_slot('nairavault_replica_1');" 2>/dev/null || echo "(slot already exists)"
grep -q "^host *replication" $PRIMARY/pg_hba.conf || echo "host replication all 127.0.0.1/32 trust" >> $PRIMARY/pg_hba.conf
grep -q "^local *replication" $PRIMARY/pg_hba.conf || echo "local replication all trust" >> $PRIMARY/pg_hba.conf
P -c "SELECT pg_reload_conf();" >/dev/null

echo
echo "=== 2. Take a base backup of the primary to build the replica"
$PGBIN/pg_ctl -D $REPLICA stop -m fast >/dev/null 2>&1 || true
# (the replica directory must exist, be owned by postgres, and be EMPTY - pg_basebackup refuses otherwise)
$PGBIN/pg_basebackup -h /tmp -p 5432 -U postgres -D $REPLICA -R -S nairavault_replica_1 -X stream -P
chmod 700 $REPLICA
echo "standby.signal present:"; ls $REPLICA/standby.signal
echo "primary_conninfo written by pg_basebackup -R:"; grep primary_conninfo $REPLICA/postgresql.auto.conf | sed 's/password=[^ ]*/password=***/'
cat >> $REPLICA/postgresql.conf <<EOF
port = 5433
hot_standby = on
hot_standby_feedback = on
EOF

echo
echo "=== 3. Start the replica on port 5433"
$PGBIN/pg_ctl -D $REPLICA -l $LOG/replica.log -o "-k /tmp" start
sleep 3

echo
echo "=== 4. Is replication live?  (pg_stat_replication on the PRIMARY)"
P -c "SELECT client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
             write_lag, flush_lag, replay_lag FROM pg_stat_replication;"
echo "--- on the REPLICA:"
R -c "SELECT pg_is_in_recovery() AS is_replica, pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
             now() - pg_last_xact_replay_timestamp() AS replay_delay;"

echo
echo "=== 5. Write on the primary, read on the replica"
P -c "SELECT count(*) AS customers_on_primary FROM vault.customers;"
R -c "SELECT count(*) AS customers_on_replica FROM vault.customers;"
P -c "INSERT INTO vault.customers(full_name, phone, date_of_birth, state_of_residence)
      VALUES ('Replication Test', '08100000001', '1990-01-01', 'Ondo') RETURNING customer_id, full_name;"
sleep 1
R -c "SELECT customer_id, full_name, state_of_residence FROM vault.customers WHERE phone = '08100000001';"

echo
echo "=== 6. The replica refuses writes (hot standby is read-only)"
R -c "INSERT INTO vault.customers(full_name, phone, date_of_birth) VALUES ('Should Fail', '08100000002', '1990-01-01');" 2>&1 || true

echo
echo "=== 7. A transfer through transfer_funds() on the primary is visible on the replica"
P -c "SELECT vault.transfer_funds(100, 200, 500, 'Replication demo') AS reference;"
sleep 1
R -c "SELECT reference, status, amount FROM vault.transfers WHERE narration = 'Replication demo' ORDER BY transfer_id DESC LIMIT 1;"
R -c "SELECT account_id, balance FROM vault.accounts WHERE account_id IN (100,200) ORDER BY 1;"

echo
echo "=== 8. Replication lag under load: 2,000 inserts on the primary, measure lag"
P -q -c "INSERT INTO vault.audit_log(actor_type, action, entity, details)
         SELECT 'system', 'lag_test', 'audit_log', jsonb_build_object('i', g) FROM generate_series(1,2000) g;"
P -c "SELECT sent_lsn, replay_lsn, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_behind, replay_lag FROM pg_stat_replication;"
sleep 1
P -c "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_behind_after_1s FROM pg_stat_replication;"

echo
echo "=== 9. Read-scaling: the heavy reconciliation query from Portfolio 2 runs on the REPLICA"
R -c "EXPLAIN (ANALYZE, SUMMARY) SELECT a.account_id FROM vault.accounts a
      LEFT JOIN (SELECT account_id, sum(CASE WHEN direction='CR' THEN amount ELSE -amount END) net
                 FROM vault.transactions GROUP BY account_id) l ON l.account_id = a.account_id
      WHERE a.balance <> coalesce(l.net,0);" | tail -3

echo
echo "=== 10. FAILOVER: promote the replica to a primary"
$PGBIN/pg_ctl -D $REPLICA promote
sleep 2
R -c "SELECT pg_is_in_recovery() AS still_replica;"
R -c "INSERT INTO vault.customers(full_name, phone, date_of_birth) VALUES ('Written After Promotion', '08100000003', '1990-01-01') RETURNING customer_id, full_name;"
echo "Replica is now a writable primary on port 5433. (The old primary on 5432 would be fenced off / rebuilt as the new replica.)"

echo
echo "=== 11. Clean up: stop the promoted replica so the original primary is the only writer again"
$PGBIN/pg_ctl -D $REPLICA stop -m fast
P -c "SELECT pg_drop_replication_slot('nairavault_replica_1');"
P -c "DELETE FROM vault.customers WHERE phone IN ('08100000001');" >/dev/null
P -c "DELETE FROM vault.audit_log WHERE action = 'lag_test';" >/dev/null
echo "done"
