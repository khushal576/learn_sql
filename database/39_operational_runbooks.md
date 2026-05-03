# Chapter 39 — Operational Runbooks & Incident Playbooks

A runbook is a documented, step-by-step procedure for handling a known failure mode. Senior DBAs have these internalized. This chapter is the complete reference for every major PostgreSQL emergency — what you do when production is on fire at 3am.

---

## General Incident Principles

```
1. STOP — don't act before you understand the situation
2. Observe — what exactly is failing? What changed recently?
3. Contain — prevent the failure from spreading
4. Diagnose — identify root cause
5. Remediate — fix the immediate problem
6. Restore — bring the system to full health
7. Document — write up what happened and why
```

---

## Runbook 1: Primary Database Crash

**Symptoms**: application cannot connect, `pg_isready` returns error, primary process absent.

```bash
# Step 1: Verify the primary is down
pg_isready -h primary-host -p 5432
# Output: primary-host:5432 - no response

# Step 2: Check if PostgreSQL process exists
ps aux | grep postgres
# or: systemctl status postgresql

# Step 3: Check PostgreSQL logs for crash reason
tail -100 /var/log/postgresql/postgresql-*.log
# Look for: PANIC, FATAL, OOM kill, hardware error

# Step 4: Attempt recovery (if data directory intact)
pg_ctl start -D /var/lib/postgresql/data
# If it starts → crash was clean, WAL replay will recover uncommitted data

# Step 5: If restart fails → check for corruption
pg_filedump /var/lib/postgresql/data/global/pg_control | head -20
# Examine the last checkpoint LSN

# Step 6: If Patroni is managing HA → it handles failover automatically
# Check cluster state:
patronictl -c /etc/patroni/config.yml list
# Should show a replica promoted to primary

# Step 7: If manual failover needed (no Patroni):
# On the best replica (lowest replication lag):
pg_ctl promote -D /var/lib/postgresql/data
# Then repoint application to new primary
```

**Post-recovery**:
```bash
# After primary recovers, rejoin as replica
# In recovery.conf or postgresql.conf:
# primary_conninfo = 'host=new-primary port=5432 user=replicator'
# Add standby.signal file
touch /var/lib/postgresql/data/standby.signal
pg_ctl start -D /var/lib/postgresql/data
```

---

## Runbook 2: Replication Lag Spike

**Symptoms**: replica lag growing, reads from replica returning stale data.

```sql
-- Step 1: Measure current lag
-- On primary:
SELECT
    client_addr,
    application_name,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_size,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;

-- On replica:
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
```

```bash
# Step 2: Identify the cause
# Cause A: Network bandwidth — compare sent_lsn vs write_lsn
# Cause B: Replica I/O — compare write_lsn vs flush_lsn
# Cause C: Replica CPU — compare flush_lsn vs replay_lsn

# Step 3A: If network-bound
# Check: iperf3 between primary and replica nodes
# Fix: enable WAL compression on primary
# postgresql.conf: wal_compression = on

# Step 3B: If replica I/O-bound
# Check: iostat -x 1 on replica
# Fix: increase replica's effective_io_concurrency or upgrade storage

# Step 3C: If replica CPU-bound (large transactions to replay)
# Check: pg_stat_activity on replica for VACUUM, large bulk inserts
# Fix: reduce autovacuum cost delay on replica, increase max_parallel_workers
```

```sql
-- Step 4: Temporary mitigation — route reads back to primary
-- Update application load balancer to send all traffic to primary
-- Set in HAProxy: disable replica backend

-- Step 5: If lag is permanent and > max_standby_streaming_delay
-- Replica may be canceling conflicts
SHOW max_standby_streaming_delay;  -- default 30s
-- Increase temporarily:
ALTER SYSTEM SET max_standby_streaming_delay = '120s';
SELECT pg_reload_conf();
```

---

## Runbook 3: Disk Space Exhaustion

**Symptoms**: PostgreSQL errors "no space left on device", disk usage at 100%.

```bash
# Step 1: Immediate — find what is consuming space
df -h
du -sh /var/lib/postgresql/data/*  | sort -rh | head -20

# Most common disk space consumers:
# pg_wal/ — WAL accumulation (slot lag, archiving lag)
# base/   — table and index bloat
# pg_log/ — verbose logging
```

```bash
# Step 2A: WAL accumulation from replication slot
# On primary:
psql -c "SELECT slot_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) FROM pg_replication_slots;"
# If a slot is retaining GB of WAL and subscriber is down:
psql -c "SELECT pg_drop_replication_slot('slot_name');"
# WARNING: this breaks the subscriber — they must re-sync
```

```sql
-- Step 2B: Bloat — find the worst offenders
SELECT schemaname, relname,
       pg_size_pretty(pg_total_relation_size(relid)) AS size,
       n_dead_tup,
       round(n_dead_tup * 100.0 / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC LIMIT 10;

-- Reclaim bloat without full lock:
VACUUM ANALYZE bloated_table;

-- If desperate and can accept full lock:
VACUUM FULL bloated_table;  -- WARNING: exclusive lock, table rewrite
```

```bash
# Step 2C: Log files
ls -lh /var/log/postgresql/
# Truncate old logs (never truncate the current one)
find /var/log/postgresql/ -name "*.log" -mtime +7 -delete

# Step 3: Free up temp space
psql -c "SELECT datname, temp_files, pg_size_pretty(temp_bytes) FROM pg_stat_database ORDER BY temp_bytes DESC;"
# Temp files live in pg_temp_* directories, cleared automatically when session ends
# Kill sessions with large temp files:
psql -c "SELECT pid FROM pg_stat_activity WHERE state = 'idle in transaction';" 
psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle in transaction';"
```

---

## Runbook 4: XID Wraparound Emergency

**Symptoms**: autovacuum constantly running, age(datfrozenxid) > 1.5 billion, error "database is not accepting commands to avoid wraparound data loss".

```sql
-- Step 1: Assess urgency
SELECT datname, age(datfrozenxid) AS xid_age,
       2147483648 - age(datfrozenxid) AS xids_remaining
FROM pg_database
ORDER BY xid_age DESC;
-- CRITICAL threshold: age > 2,000,000,000 (2 billion) → imminent shutdown
-- WARNING threshold: age > 1,500,000,000

-- Per-table age
SELECT relname, age(relfrozenxid) AS table_age
FROM pg_class
WHERE relkind = 'r'
ORDER BY table_age DESC LIMIT 20;
```

```sql
-- Step 2: Find what is preventing autovacuum
-- Long-running transactions hold back the global XID horizon
SELECT pid, xact_start, now() - xact_start AS duration,
       left(query, 100) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start ASC;

-- Kill the oldest transaction if safe to do so
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE xact_start = (SELECT MIN(xact_start) FROM pg_stat_activity WHERE xact_start IS NOT NULL);
```

```bash
# Step 3: Emergency VACUUM FREEZE
# Set autovacuum to maximum aggression temporarily
psql -c "ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 0;"
psql -c "ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 10000;"
psql -c "SELECT pg_reload_conf();"

# Manual VACUUM FREEZE on oldest tables (connect directly, bypass any limits)
psql -c "VACUUM FREEZE ANALYZE oldest_table;"

# Step 4: If in emergency shutdown state (accepts no commands except superuser)
# Connect as superuser and run VACUUM FREEZE on entire database
psql -U postgres mydb -c "VACUUM FREEZE;"
# This will take a long time on large databases — this is unavoidable
```

---

## Runbook 5: Lock Storm / Lock Pile-Up

**Symptoms**: application requests timing out, connection count spiking, `pg_stat_activity` shows many `waiting` sessions.

```sql
-- Step 1: Identify the blocking chain
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.query AS blocking_query,
    now() - blocked.query_start AS wait_duration
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
ORDER BY wait_duration DESC;
```

```sql
-- Step 2: Find the root blocker (may be several levels deep)
WITH RECURSIVE lock_tree AS (
    SELECT pid, pg_blocking_pids(pid) AS blocking_pids, query, query_start
    FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0

    UNION ALL

    SELECT sa.pid, pg_blocking_pids(sa.pid), sa.query, sa.query_start
    FROM pg_stat_activity sa
    JOIN lock_tree lt ON sa.pid = ANY(lt.blocking_pids)
)
SELECT DISTINCT pid, query, query_start FROM lock_tree
WHERE NOT (pid = ANY(SELECT unnest(blocking_pids) FROM lock_tree));
-- These are the root blockers
```

```sql
-- Step 3: Decide whether to kill the blocker
-- Check: is this a legitimate long transaction or a runaway query?
-- Check: is it an application transaction or a migration/DBA script?

-- Cancel query (graceful — lets transaction rollback cleanly):
SELECT pg_cancel_backend(blocking_pid);

-- Terminate connection (forceful — use if cancel doesn't work):
SELECT pg_terminate_backend(blocking_pid);
```

```sql
-- Step 4: Prevent recurrence
-- Set lock_timeout to prevent indefinite waiting:
ALTER ROLE app_user SET lock_timeout = '5s';

-- Set statement_timeout to kill runaway queries:
ALTER ROLE app_user SET statement_timeout = '30s';

-- Set idle_in_transaction_session_timeout to kill abandoned transactions:
ALTER SYSTEM SET idle_in_transaction_session_timeout = '60s';
SELECT pg_reload_conf();
```

---

## Runbook 6: Corrupt Data Page

**Symptoms**: `ERROR: invalid page in block N of relation base/NNNN/NNNN`, application returning errors for specific records.

```bash
# Step 1: Verify the corruption
pg_filedump -i /var/lib/postgresql/data/base/NNNN/NNNN | head -50
# Look for: PageHeaderData, checksum errors

# Check PostgreSQL logs for the exact relation OID
grep "invalid page" /var/log/postgresql/postgresql.log
# Output: invalid page in block 42 of relation base/16384/24601
```

```sql
-- Step 2: Identify the corrupted table/index
SELECT relname, relkind
FROM pg_class WHERE relfilenode = 24601;
-- relkind: r=table, i=index, t=toast
```

```sql
-- Step 3a: If corrupted index → rebuild it
REINDEX INDEX CONCURRENTLY idx_name;
-- No data loss; index is rebuilt from table data

-- Step 3b: If corrupted table block → recover what you can
-- Enable zero_damaged_pages to skip the bad block (data loss in that block)
SET zero_damaged_pages = on;  -- superuser only
-- This allows queries to skip corrupted blocks (returns NULL for those rows)

-- Export all recoverable data
CREATE TABLE recovered_orders AS SELECT * FROM orders;
-- Missing rows from the corrupt block are simply absent

-- Then restore the missing rows from backup:
-- 1. Restore to a temp database from the last backup before corruption
-- 2. SELECT the affected rows by primary key
-- 3. INSERT them into production
```

```bash
# Step 4: Root cause analysis
# Hardware: check dmesg for disk errors
dmesg | grep -i error | tail -50

# Storage layer: run fsck (offline only)
# Check SMART data:
smartctl -a /dev/sda

# If checksums were enabled, the corruption timestamp is known
# SHOW data_checksums; -- should be on in production
```

---

## Runbook 7: Bloat Emergency

**Symptoms**: table is 10x its expected size, VACUUM not keeping up, disk filling despite stable data volume.

```sql
-- Step 1: Confirm bloat
SELECT
    relname,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup * 100.0 / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 100000
ORDER BY dead_pct DESC;
```

```sql
-- Step 2: Why isn't autovacuum keeping up?
-- Check if autovacuum is being blocked
SELECT pid, wait_event_type, wait_event, left(query, 100)
FROM pg_stat_activity
WHERE query LIKE '%autovacuum%' OR backend_type = 'autovacuum worker';

-- Check for long transactions preventing vacuum
SELECT pid, xact_start, now() - xact_start AS duration
FROM pg_stat_activity
WHERE xact_start < NOW() - INTERVAL '5 minutes'
ORDER BY xact_start;
```

```sql
-- Step 3: Immediate VACUUM with increased resources
-- In another session, set higher cost limits for manual vacuum:
SET vacuum_cost_delay = 0;
SET vacuum_cost_limit = 10000;
VACUUM ANALYZE bloated_table;

-- Step 4: If VACUUM isn't recovering space (table size unchanged after vacuum)
-- Dead tuples are removed from visibility map but not returned to OS
-- VACUUM FULL rewrites the table (exclusive lock!) but returns space to OS
-- Alternative without lock: pg_repack extension
-- pg_repack builds a copy of the table online, then swaps it in

-- Install:
CREATE EXTENSION pg_repack;
-- Run:
-- pg_repack -t bloated_table -d mydb
```

```sql
-- Step 5: Prevent recurrence
-- Tune autovacuum for this specific table:
ALTER TABLE bloated_table SET (
    autovacuum_vacuum_scale_factor = 0.01,  -- vacuum at 1% dead tuples
    autovacuum_vacuum_cost_delay = 2,       -- faster vacuum
    autovacuum_vacuum_threshold = 100
);
```

---

## Runbook 8: Out of Connections

**Symptoms**: `FATAL: remaining connection slots are reserved for non-replication superuser connections`, new connections failing.

```sql
-- Step 1: See who is connected
SELECT usename, application_name, state, count(*)
FROM pg_stat_activity
GROUP BY usename, application_name, state
ORDER BY count(*) DESC;

-- Step 2: Find idle connections that can be terminated
SELECT pid, usename, state, now() - state_change AS idle_duration
FROM pg_stat_activity
WHERE state = 'idle'
ORDER BY idle_duration DESC;

-- Step 3: Kill oldest idle connections to free slots
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND now() - state_change > interval '10 minutes'
  AND usename != 'postgres';
```

```sql
-- Step 4: Emergency — increase max_connections temporarily
-- (requires restart but buys time)
ALTER SYSTEM SET max_connections = 300;
-- Then schedule a restart at next opportunity

-- Step 5: Long-term fix — deploy PgBouncer
-- (see Chapter 34 for full setup)
-- Immediate PgBouncer config:
-- max_client_conn = 10000
-- default_pool_size = 30  (actual connections to PostgreSQL)
```

---

## Quick Reference Card

```sql
-- EMERGENCY QUERIES (copy-paste ready)

-- Who is blocking whom
SELECT blocked.pid, left(blocked.query,60) AS blocked_q,
       blocking.pid AS blocker, left(blocking.query,60) AS blocking_q
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking ON blocking.pid = ANY(pg_blocking_pids(blocked.pid));

-- Long-running queries
SELECT pid, now()-query_start AS age, state, left(query,80)
FROM pg_stat_activity WHERE state != 'idle' ORDER BY age DESC LIMIT 10;

-- Disk space by table
SELECT relname, pg_size_pretty(pg_total_relation_size(oid))
FROM pg_class WHERE relkind='r' ORDER BY pg_total_relation_size(oid) DESC LIMIT 10;

-- XID wraparound risk
SELECT datname, age(datfrozenxid), 2147483648-age(datfrozenxid) AS remaining
FROM pg_database ORDER BY age(datfrozenxid) DESC;

-- Replication lag
SELECT application_name, replay_lag, pg_size_pretty(pg_wal_lsn_diff(sent_lsn,replay_lsn))
FROM pg_stat_replication;

-- Replication slot WAL retention
SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn))
FROM pg_replication_slots;

-- Connection count by state
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;

-- Kill idle connections
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE state='idle' AND now()-state_change > interval '10 min' AND usename!='postgres';
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| Runbook | Documented step-by-step procedure for a known operational failure |
| Lock storm | Cascading blocked sessions caused by one long-running transaction |
| XID wraparound | Transaction ID exhaustion; triggers emergency database shutdown |
| zero_damaged_pages | GUC that skips corrupted blocks instead of crashing |
| pg_repack | Extension that rewrites bloated tables online without exclusive lock |
| `pg_blocking_pids()` | Returns array of PIDs blocking a given session |
| Bloat | Space occupied by dead tuples not yet reclaimed by VACUUM |

---

## Practice Questions

1. At 2am you get paged: application cannot connect to the database. List the first 5 commands you run.
2. A table's dead tuple count is 80% despite autovacuum running. What are three reasons autovacuum might not be working?
3. `age(datfrozenxid)` is at 1.8 billion. How urgent is this? What do you do in the next hour?
4. A lock storm is cascading through the system. You find the root blocker is an idle-in-transaction session from 2 hours ago. What do you do immediately and what do you change to prevent it?
5. A data file is corrupt at block 42. The table has 50M rows and only a few hundred are in the corrupt block. Walk through the recovery procedure.
6. Disk is at 98% on the PostgreSQL data directory. WAL directory is 40 GB. What do you check first, and why might WAL be accumulating?

---

**← Previous:** [38_capacity_planning_cloud.md](38_capacity_planning_cloud.md)  
**Next →** [40_postgres_for_olap.md](40_postgres_for_olap.md)
