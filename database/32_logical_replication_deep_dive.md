# Chapter 32 — Logical Replication: CDC, Upgrades & ETL

Logical replication is the most versatile data movement tool in PostgreSQL's arsenal — and the most misunderstood. This chapter covers the internals, production hazards, CDC pipelines, and how to use it for zero-downtime major version upgrades.

---

## 32.1 Logical Decoding Internals

Logical replication is built on **logical decoding** — translating WAL records from physical (byte diffs) into a stream of logical changes (INSERT/UPDATE/DELETE on a table with column values).

```
WAL (physical)  →  Logical Decoding Plugin  →  Change Stream (logical)
                         ↑
              wal2json, pgoutput, decoderbufs
```

**Output plugins** determine the format of the change stream:
- `pgoutput` — built-in, used by PostgreSQL native logical replication
- `wal2json` — JSON format, used by Debezium and many ETL tools
- `decoderbufs` — Protocol Buffers, used by Debezium's older connector

```sql
-- Inspect available output plugins
SELECT name FROM pg_available_extensions WHERE name LIKE '%wal%' OR name LIKE '%decoder%';

-- Check current WAL level (must be logical)
SHOW wal_level;
-- Requires: wal_level = logical in postgresql.conf
-- Restart required to change this
```

### What logical decoding captures

```sql
-- Logical replication tracks these per table:
-- INSERT: full new row
-- UPDATE: old row (if REPLICA IDENTITY set) + new row
-- DELETE: old row (needs REPLICA IDENTITY)

-- REPLICA IDENTITY controls what is logged for UPDATE/DELETE
ALTER TABLE orders REPLICA IDENTITY FULL;    -- log entire old row
ALTER TABLE orders REPLICA IDENTITY DEFAULT; -- log primary key only (default)
ALTER TABLE orders REPLICA IDENTITY NOTHING; -- skip UPDATE/DELETE (dangerous)
ALTER TABLE orders REPLICA IDENTITY USING INDEX idx_name; -- use unique index
```

---

## 32.2 Replication Slots — The Core Hazard

A **replication slot** holds WAL on the primary until the subscriber acknowledges receipt. This is the most dangerous component in a logical replication setup.

```sql
-- View all replication slots and their WAL retention
SELECT slot_name, slot_type, active, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots;
```

**The disk-fill hazard**: if a subscriber falls behind (crash, network partition, slow consumer), the slot retains WAL indefinitely. On a busy primary, this can exhaust disk in hours.

```sql
-- CRITICAL: always set this in postgresql.conf
max_slot_wal_keep_size = 10GB  -- slot is invalidated if it retains more than this

-- Monitor slot lag (add this to your alerting)
SELECT slot_name,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS consumer_lag
FROM pg_replication_slots
WHERE slot_type = 'logical';

-- Alert threshold: > 5GB lag on a production primary is dangerous
```

```sql
-- Drop an orphaned slot (do this when you decommission a subscriber)
SELECT pg_drop_replication_slot('my_slot_name');

-- DO NOT leave unused slots — they silently retain WAL forever
```

---

## 32.3 Native Logical Replication Setup

```sql
-- ON THE PUBLISHER (source database)
-- 1. Set wal_level = logical in postgresql.conf + restart

-- 2. Create a publication (defines what to replicate)
CREATE PUBLICATION pub_orders FOR TABLE orders, order_items;

-- Or replicate everything
CREATE PUBLICATION pub_all FOR ALL TABLES;

-- Or with row filter (PG 15+)
CREATE PUBLICATION pub_active_orders FOR TABLE orders
    WHERE (status != 'archived');

-- 3. Grant replication privilege
CREATE USER replicator WITH REPLICATION PASSWORD 'secret';
GRANT SELECT ON orders, order_items TO replicator;

-- ON THE SUBSCRIBER (destination database)
-- 4. Create the tables (DDL is NOT replicated automatically)
-- CREATE TABLE orders (...); -- must match structure

-- 5. Create the subscription
CREATE SUBSCRIPTION sub_orders
    CONNECTION 'host=primary user=replicator password=secret dbname=mydb'
    PUBLICATION pub_orders;
```

```sql
-- Monitor replication status
-- On publisher:
SELECT * FROM pg_stat_replication;

-- On subscriber:
SELECT * FROM pg_stat_subscription;
SELECT * FROM pg_subscription_rel;  -- per-table status
```

---

## 32.4 DDL Replication — The Blind Spot

**Logical replication does NOT replicate DDL.** This is the most common production surprise.

```
Publisher: ALTER TABLE orders ADD COLUMN notes TEXT;
                ↓
Subscriber: table does not have column 'notes' → replication breaks
```

### Strategies for handling DDL

**Strategy 1: Apply DDL manually on subscriber first**
```sql
-- Step 1: Apply DDL on subscriber
-- (subscriber just ignores the new column until publisher adds it)
ALTER TABLE orders ADD COLUMN notes TEXT;  -- on subscriber

-- Step 2: Apply DDL on publisher
ALTER TABLE orders ADD COLUMN notes TEXT;  -- on publisher
-- Replication continues, new column is replicated
```

**Strategy 2: Pause, migrate, resume**
```sql
-- Pause subscription
ALTER SUBSCRIPTION sub_orders DISABLE;

-- Apply DDL on both sides
-- ...

-- Resume
ALTER SUBSCRIPTION sub_orders ENABLE;
```

**Strategy 3: Use pglogical extension** (replicates DDL, compatible with PG 10+)
```sql
-- pglogical supports DDL replication via DDL triggers
-- SELECT pglogical.replicate_ddl_command('ALTER TABLE ...');
```

---

## 32.5 CDC with Debezium + Kafka

**Change Data Capture (CDC)** uses logical decoding to stream every database change to Kafka as an event. Debezium is the standard connector.

```
PostgreSQL (wal2json plugin)
    ↓ logical replication slot
Debezium PostgreSQL Connector (Kafka Connect)
    ↓ Kafka topics
Consumers (Elasticsearch, data warehouse, microservices)
```

### Debezium connector configuration

```json
{
  "name": "postgres-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "postgres-primary",
    "database.port": "5432",
    "database.user": "replicator",
    "database.password": "secret",
    "database.dbname": "mydb",
    "database.server.name": "mydb",
    "plugin.name": "pgoutput",
    "slot.name": "debezium_slot",
    "publication.name": "dbz_publication",

    "table.include.list": "public.orders,public.customers",

    "heartbeat.interval.ms": "60000",
    "slot.max.retries": "3",

    "transforms": "unwrap",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "false"
  }
}
```

### Kafka message structure

```json
// Topic: mydb.public.orders
// Key: {"order_id": 1001}
// Value (after ExtractNewRecordState):
{
  "order_id": 1001,
  "customer_id": 42,
  "status": "shipped",
  "__op": "u",          // c=create, u=update, d=delete, r=read (snapshot)
  "__source_ts_ms": 1716000000000,
  "__deleted": "false"
}
```

### The snapshot problem

When Debezium first connects, it **snapshots** the entire table before streaming changes. For a 500M-row orders table, this takes hours and creates enormous read load.

```json
// Snapshot mode options:
"snapshot.mode": "initial",          // full snapshot + stream (default)
"snapshot.mode": "never",            // no snapshot, stream from now
"snapshot.mode": "exported",         // consistent snapshot exported at a specific LSN
"snapshot.mode": "initial_only",     // snapshot only, no streaming

// For large tables: skip snapshot and accept a data gap
"snapshot.mode": "never"
```

---

## 32.6 Zero-Downtime Major Version Upgrade

PostgreSQL major versions (e.g. 14 → 16) cannot use streaming replication across versions. Logical replication is the only online upgrade path.

### The procedure

```
Phase 1: Prepare new cluster
  1. Set up PG 16 cluster
  2. Restore schema-only dump to PG 16
  3. Install extensions on PG 16

Phase 2: Initial data sync
  4. Create publication on PG 14: CREATE PUBLICATION upgrade_pub FOR ALL TABLES;
  5. Create subscription on PG 16: CREATE SUBSCRIPTION upgrade_sub ...;
  6. Wait for initial sync to complete (pg_subscription_rel all 'r' = ready)

Phase 3: Catch up and cut over
  7. Monitor replication lag: pg_stat_subscription.received_lsn vs publisher
  8. When lag < 1 second, schedule maintenance window
  9. Stop application writes to PG 14
  10. Wait for PG 16 to fully catch up (lag = 0)
  11. Promote PG 16 / point application at PG 16
  12. Remove subscription and publication
```

```sql
-- Step 4: On PG 14 publisher
CREATE PUBLICATION upgrade_pub FOR ALL TABLES;

-- Step 5: On PG 16 subscriber
CREATE SUBSCRIPTION upgrade_sub
    CONNECTION 'host=pg14 user=replicator password=secret dbname=mydb'
    PUBLICATION upgrade_pub;

-- Step 6: Monitor initial sync
SELECT subrelid::regclass, srsubstate
FROM pg_subscription_rel;
-- srsubstate: i=initialize, d=data sync, s=sync, r=ready

-- Step 7: Monitor lag
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag
FROM pg_stat_subscription;

-- Step 12: Cleanup after cutover
DROP SUBSCRIPTION upgrade_sub;    -- on new server
DROP PUBLICATION upgrade_pub;     -- on old server
SELECT pg_drop_replication_slot('upgrade_slot'); -- if needed
```

### Sequences — the manual step

Logical replication does NOT replicate sequence values. After cutover you must set sequences on the new server:

```sql
-- On PG 14: capture sequence values
SELECT 'SELECT setval(''' || sequence_name || ''', ' || last_value || ');'
FROM information_schema.sequences s
JOIN (SELECT sequence_name, last_value FROM each_sequence) ls USING (sequence_name);

-- Simpler:
SELECT pg_export_snapshot();  -- alternative: use pg_dump --section=post-data
```

---

## 32.7 Monitoring Logical Replication Health

```sql
-- Publication health
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete
FROM pg_publication;

-- Subscription status
SELECT subname, subenabled,
       received_lsn,
       latest_end_lsn,
       last_msg_receipt_time
FROM pg_stat_subscription;

-- Per-table sync state
SELECT subrelid::regclass AS table_name,
       srsubstate AS state,   -- r=ready, d=data copy, s=synchronized
       srsublsn
FROM pg_subscription_rel;

-- Replication slot lag on publisher
SELECT slot_name, active,
       pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes
FROM pg_replication_slots
WHERE slot_type = 'logical'
ORDER BY lag_bytes DESC;
```

```sql
-- Alert query: slots with > 1GB lag
SELECT slot_name,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag
FROM pg_replication_slots
WHERE pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) > 1073741824;
```

---

## 32.8 Bidirectional Replication (BDR)

**BDR (Bi-Directional Replication)** allows writes on multiple nodes simultaneously — each node replicates to all others. Conflict resolution is required.

```
Node A ←→ Node B ←→ Node C
(all accept writes; changes flow in all directions)
```

Native PostgreSQL does not support BDR out of the box. Options:
- **pglogical 3 / BDR** (2ndQuadrant/EDB): enterprise extension with conflict detection
- **Bucardo**: open-source, supports multi-master
- **Citus**: sharding-based, distributes writes differently

```sql
-- Conflict handling in pglogical:
-- Default: last-write-wins based on commit timestamp
-- Requires: track_commit_timestamp = on in postgresql.conf

SHOW track_commit_timestamp;  -- must be on for conflict resolution

-- Custom conflict handlers can be defined to prefer one node's data
```

**When to use BDR**:
- Multi-region active-active writes
- Geographic distribution with local low-latency writes
- Not needed for read scaling (use streaming replicas instead)

**The conflict problem**: two nodes simultaneously update the same row. Without careful application-level design, data loss is possible regardless of conflict resolution strategy.

---

## 32.9 Logical Replication for ETL Pipelines

Logical replication powers modern data pipelines without ETL frameworks:

```sql
-- Pattern: replicate OLTP tables to an analytics schema on a read replica
-- or a separate warehouse database

-- Source: operational database (high write volume)
CREATE PUBLICATION analytics_pub
    FOR TABLE orders, customers, order_items
    WITH (publish = 'insert, update');  -- analytics doesn't need deletes

-- Sink: read-optimized schema
-- (subscriber can have different indexes, partitioning, even column subsets)
CREATE SUBSCRIPTION analytics_sub
    CONNECTION '...'
    PUBLICATION analytics_pub
    WITH (copy_data = true, create_slot = true);
```

### Selective replication for compliance

```sql
-- PG 15+: row filtering — don't replicate PII to analytics
CREATE PUBLICATION analytics_pub_filtered FOR TABLE customers
    WHERE (marketing_consent = true)
WITH (publish_via_partition_root = true);

-- PG 16+: column filtering — omit sensitive columns
CREATE PUBLICATION analytics_pub_cols FOR TABLE customers
    (customer_id, created_at, country, tier);  -- omit email, phone, address
```

---

## 32.10 Common Failure Modes

| Failure | Symptom | Fix |
|---------|---------|-----|
| Slot inactive but not dropped | `pg_replication_slots.active = false`; WAL growing | Drop slot: `pg_drop_replication_slot()` |
| Subscriber table missing column | Replication worker error in logs | Apply DDL on subscriber first |
| Subscriber primary key conflict | `duplicate key value violates unique constraint` | Truncate subscriber table, re-sync |
| `max_slot_wal_keep_size` exceeded | Slot invalidated: `pg_replication_slots.invalid_reason` | Re-create slot, re-sync subscriber |
| Snapshot too large | Debezium OOM or hours-long initial load | Use `snapshot.mode = never` or `exported` |
| Sequence drift after cutover | New IDs conflict with existing rows | Manually advance sequences post-cutover |

---

## Key Terms

| Term | Meaning |
|------|---------|
| Logical decoding | Translating WAL (physical) into a stream of logical row changes |
| Replication slot | Server-side cursor that retains WAL until subscriber acknowledges |
| `max_slot_wal_keep_size` | Limit on WAL retained per slot; prevents disk fill |
| Publication | Set of tables on the publisher whose changes will be replicated |
| Subscription | Subscriber-side connection to a publication |
| `pgoutput` | Built-in output plugin used by native logical replication |
| `wal2json` | Output plugin producing JSON change events (used by Debezium) |
| CDC | Change Data Capture — streaming every DB change to an event bus |
| REPLICA IDENTITY | Controls what columns are logged for UPDATE/DELETE |
| BDR | Bi-Directional Replication — multi-master writes across nodes |

---

## Practice Questions

1. A replication slot hasn't been consumed for 3 days on a busy primary. What is the risk and how do you address it?
2. You add a column `notes TEXT` to the `orders` table on the publisher. The subscriber breaks. What is the correct procedure?
3. You need to upgrade a production PostgreSQL 14 cluster to PostgreSQL 16 with < 5 minutes downtime. Outline the step-by-step procedure.
4. After a zero-downtime upgrade using logical replication, users report duplicate key errors when inserting. What did you forget?
5. Debezium is taking 6 hours to snapshot a 2TB table on first start. How do you fix this without restarting from scratch?
6. You want to replicate the `orders` table to an analytics database but need to exclude the `customer_email` column for GDPR. What PostgreSQL version and syntax enables this?

---

**← Previous:** [31_query_planner_internals.md](31_query_planner_internals.md)  
**Next →** [33_advanced_query_patterns.md](33_advanced_query_patterns.md)
