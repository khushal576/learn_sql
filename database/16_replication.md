# Chapter 16 — Replication

Replication copies data from one PostgreSQL server (primary) to one or more others (replicas/standbys). It enables high availability, read scaling, and disaster recovery.

---

## 16.1 Why Replication?

| Goal | How Replication Helps |
|------|----------------------|
| **High availability** | If primary fails, promote a replica → minimal downtime |
| **Read scaling** | Route read queries to replicas → primary handles only writes |
| **Disaster recovery** | Replica in another datacenter/region → survive site failure |
| **Zero-downtime backups** | Take backups from replica → no load on primary |
| **Reporting** | Long-running analytics queries on replica → don't block OLTP |

---

## 16.2 Replication Types Overview

```
Primary (writes here)
    │
    ├── Streaming Replication ──→ Physical Replica
    │   (WAL stream, binary)      (identical copy, read-only)
    │
    └── Logical Replication ───→ Logical Subscriber
        (decoded SQL changes)     (selective tables, different version OK)
```

| | Streaming Replication | Logical Replication |
|-|-----------------------|---------------------|
| What is replicated | Entire cluster (all DBs) | Selected tables/databases |
| Format | Binary (WAL bytes) | Logical (decoded row changes) |
| Replica must be same PG version | Same major version | Can differ |
| Replica can have extra tables | ❌ No | ✅ Yes |
| Replica can be written to | ❌ No (read-only) | ✅ Yes |
| Cascading | ✅ Replica → Replica | ✅ |
| Use for | HA, DR, read scaling | Selective sync, migrations, CDC |

---

## 16.3 Streaming Replication — Setup

### Step 1 — Configure Primary

```ini
# postgresql.conf (primary)
wal_level = replica
max_wal_senders = 5        # max simultaneous replication connections
wal_keep_size = 1GB        # keep this much WAL for slow replicas
listen_addresses = '*'
```

```
# pg_hba.conf (primary) — allow replica to connect
host  replication  replicator  10.0.0.2/32  md5
```

```sql
-- Create replication user
CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'secret';
```

### Step 2 — Take Base Backup on Replica

```bash
# On the replica server
pg_basebackup \
  -h 10.0.0.1 \           # primary IP
  -U replicator \
  -D /var/lib/postgresql/14/main \
  -Fp -Xs -P -R
# -R = write recovery configuration automatically
```

`-R` creates a `standby.signal` file and adds connection info to `postgresql.auto.conf`.

### Step 3 — Start Replica

```bash
systemctl start postgresql
```

PostgreSQL detects `standby.signal`, connects to primary, and streams WAL continuously.

### Verify Replication

```sql
-- On primary: check connected standbys
SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;

-- On replica: check recovery status
SELECT pg_is_in_recovery();  -- TRUE = still a replica
SELECT pg_last_wal_receive_lsn();
SELECT pg_last_wal_replay_lsn();
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
```

---

## 16.4 Synchronous vs Asynchronous Replication

### Asynchronous (default)

```
Primary: COMMIT → returns success immediately
         WAL → sent to replica "soon" (milliseconds typically)
Replica: applies WAL with small delay
```

- Risk: If primary crashes before replica receives WAL → small data loss
- Performance: No wait — fastest possible writes on primary

### Synchronous

```
Primary: COMMIT → waits for replica to confirm WAL received → returns success
```

```ini
# postgresql.conf (primary)
synchronous_standby_names = 'replica1'
# Or for any one of multiple:
synchronous_standby_names = 'ANY 1 (replica1, replica2)'
# Or all must confirm:
synchronous_standby_names = 'ALL (replica1, replica2)'
```

- Risk: Zero data loss — primary never returns success until replica has the WAL
- Performance: Every write waits for replica round-trip (adds latency)
- Danger: If the synchronous replica goes down, **writes block** until it comes back

**Recommendation**: Use async replication + WAL archiving for most cases. Use sync only for financial/critical data, and always have `ANY 1 (replica1, replica2)` so one replica going down doesn't block writes.

---

## 16.5 Replication Slots

A **replication slot** ensures the primary keeps WAL until the replica has consumed it — even if the replica disconnects.

```sql
-- Create a slot
SELECT pg_create_physical_replication_slot('replica1_slot');

-- Use it on replica (in postgresql.auto.conf or recovery config)
primary_slot_name = 'replica1_slot'

-- View all slots and their lag
SELECT slot_name, active, restart_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes
FROM pg_replication_slots;

-- Drop a slot (when replica is decommissioned)
SELECT pg_drop_replication_slot('replica1_slot');
```

### Danger: Unused Slots

If a replica with a slot goes down for a long time, the primary **cannot delete WAL** — disk fills up → primary crashes.

```sql
-- Alert if any slot has > 10 GB of lag
SELECT slot_name,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots
WHERE pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 10 * 1024^3;
```

If a replica won't catch up, drop its slot. Monitor slot lag in production.

---

## 16.6 Logical Replication

Logical replication decodes WAL into row-level changes and sends them as SQL-like messages. The subscriber can apply them to a different PostgreSQL version, different schema, or partially.

### Setup

```sql
-- On publisher (source)
-- postgresql.conf: wal_level = logical

-- Create a publication (what to publish)
CREATE PUBLICATION my_pub FOR TABLE orders, customers;
-- Or all tables:
CREATE PUBLICATION my_pub FOR ALL TABLES;

-- On subscriber (destination)
CREATE SUBSCRIPTION my_sub
  CONNECTION 'host=10.0.0.1 user=replicator password=secret dbname=mydb'
  PUBLICATION my_pub;
```

### What Logical Replication Supports

- Replicate to a different PostgreSQL major version (great for zero-downtime upgrades)
- Replicate only specific tables
- Subscriber can have additional tables and write to them
- Multiple publishers → one subscriber (fan-in)
- One publisher → multiple subscribers (fan-out)

### What It Doesn't Replicate

- DDL (CREATE TABLE, ALTER TABLE) — schema changes must be applied manually
- Sequences — values aren't synchronized
- Large objects

---

## 16.7 Cascading Replication

A replica can itself be a replication source for further replicas:

```
Primary
  └── Replica 1 (hot standby, same DC)
        └── Replica 2 (analytics, same DC)
        └── Replica 3 (DR, different DC)
```

```ini
# Replica 1 configuration
hot_standby = on
wal_level = replica          # must be replica to cascade
max_wal_senders = 3          # allow downstream replicas
```

Downstream replicas connect to Replica 1, not the primary. This reduces load on the primary.

---

## 16.8 Hot Standby — Querying Replicas

By default, streaming replicas are read-only:

```ini
# postgresql.conf (replica)
hot_standby = on   # allow read queries while in recovery (default: on)
```

```sql
-- On replica: these work
SELECT * FROM employees WHERE dept_id = 10;

-- On replica: these fail
INSERT INTO employees ...;  -- ERROR: cannot execute INSERT in a read-only transaction
```

### Handling Read-Your-Writes

If a user writes on primary and immediately reads on replica, they might see stale data:

```sql
-- On replica: wait for it to catch up to at least this LSN
SELECT pg_wal_replay_wait('0/5A3B2C0');

-- Or: check how far behind the replica is
SELECT now() - pg_last_xact_replay_timestamp() AS lag;
```

---

## 16.9 Read Scaling Architecture

```
Application
    │
    ├── Write queries → Primary (10.0.0.1)
    │
    └── Read queries  → Load balancer (HAProxy / PgBouncer)
                              ├── Replica 1 (10.0.0.2)
                              ├── Replica 2 (10.0.0.3)
                              └── Replica 3 (10.0.0.4)
```

Tools for routing:
- **PgBouncer** (Chapter 19) — connection pooling + can route reads to replicas
- **HAProxy** — TCP load balancer, routes port 5432 to replicas
- **Patroni** (Chapter 17) — manages primary/replica topology + exposes endpoints

---

## 16.10 Zero-Downtime PostgreSQL Major Version Upgrade

Using logical replication for major version upgrades (e.g., PG 14 → PG 16):

```
1. Set up PG 16 instance
2. Create logical subscription on PG 16 from PG 14
3. Let replication catch up (near-zero lag)
4. Switch application connection string to PG 16
5. Stop writes on PG 14 briefly → PG 16 catches up fully → promote PG 16
6. Total downtime: seconds
```

This avoids `pg_upgrade` downtime (which requires stopping the database).

---

## Key Terms

| Term | Meaning |
|------|---------|
| Primary | The read-write master database |
| Replica / Standby | A copy of the primary |
| Streaming Replication | Ship WAL bytes from primary to replica in real-time |
| Logical Replication | Ship decoded row changes (more flexible, version-independent) |
| Synchronous Replication | Primary waits for replica to confirm before returning success |
| Replication Slot | Ensures primary keeps WAL until replica consumes it |
| Hot Standby | Replica that accepts read queries while in recovery |
| Publication | Source side of logical replication — defines what to send |
| Subscription | Destination side — applies incoming changes |
| WAL Sender | Backend process on primary that streams WAL |

---

## Practice Questions

1. What is the difference between streaming replication and logical replication?
2. You have one replica with a replication slot. The replica goes offline for 3 days. What happens to the primary?
3. When would you choose synchronous replication? What is the risk?
4. You want to route SELECT queries to replicas without changing application code. What tool do you use?
5. How does logical replication enable zero-downtime PostgreSQL major version upgrades?
6. A replica is 5 minutes behind the primary. What queries would you run to diagnose why?

---

**← Previous:** [15_pitr.md](15_pitr.md)  
**Next →** [17_high_availability.md](17_high_availability.md)
