# Chapter 34 — Connection Management at Scale

PostgreSQL connections are expensive: each one is a separate OS process consuming 5–10 MB of RAM. At scale, connection management is as important as query optimization. This chapter covers PgBouncer in depth, cloud proxies, timeout hierarchies, and common failure modes.

---

## 34.1 Why Connections Are Expensive

```
Each PostgreSQL connection = one OS process (not a thread)
  - ~5–10 MB RAM per idle connection
  - fork() overhead on new connection
  - shared memory access through lock contention
  - context switching across many connections hurts CPU cache
```

```sql
-- Current connection state
SELECT count(*), state, wait_event_type, wait_event
FROM pg_stat_activity
GROUP BY state, wait_event_type, wait_event
ORDER BY count(*) DESC;

-- Total connections by application
SELECT application_name, count(*)
FROM pg_stat_activity
GROUP BY application_name
ORDER BY count(*) DESC;

-- Check connection limit
SHOW max_connections;
SELECT count(*) FROM pg_stat_activity;  -- current connections used
```

**Rule**: target active connections ≤ 2–4× CPU cores. Everything else should wait in PgBouncer, not PostgreSQL.

---

## 34.2 PgBouncer Architecture

```
App servers (thousands of connections)
        ↓
    PgBouncer            ← lightweight connection pool (single process)
        ↓
  PostgreSQL             ← small pool of real connections (e.g. 30)
```

PgBouncer multiplexes many client connections onto few server connections.

### Pool modes

| Mode | Server connection released when | Transaction support | Session features |
|------|--------------------------------|--------------------|--------------------|
| `session` | Client disconnects | ✅ Full | ✅ Full (SET, temp tables, prepared statements) |
| `transaction` | Transaction ends | ✅ Full | ❌ No session-level features |
| `statement` | Statement ends | ❌ No multi-statement transactions | ❌ Minimal |

```ini
; pgbouncer.ini
[databases]
mydb = host=127.0.0.1 port=5432 dbname=mydb

[pgbouncer]
pool_mode = transaction           ; most efficient for OLTP
max_client_conn = 10000           ; clients connecting to PgBouncer
default_pool_size = 25            ; server connections to PostgreSQL
min_pool_size = 5                 ; always keep 5 connections warm
reserve_pool_size = 5             ; extra connections for bursts
reserve_pool_timeout = 5          ; wait this long before using reserve

server_idle_timeout = 600         ; close idle server connections after 10 min
client_idle_timeout = 0           ; never close idle clients
server_lifetime = 3600            ; recycle server connections hourly

; Authentication
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
```

---

## 34.3 Transaction Mode Hazards — DISCARD ALL

The most dangerous PgBouncer misconfiguration: using session-level features in transaction mode.

```sql
-- ❌ These break silently in transaction pool mode:

-- Prepared statements: connection may be different on next execution
PREPARE my_stmt AS SELECT * FROM orders WHERE id = $1;
-- The next EXECUTE may go to a different server connection → error

-- Temporary tables: created on one connection, gone on next query
CREATE TEMP TABLE staging (id INT);
-- Next query may not see this table → error

-- SET variables: reset when connection is returned to pool
SET work_mem = '512MB';
SELECT ... ORDER BY ...;  -- work_mem may not apply!

-- Advisory locks: tied to server connection, not client session
SELECT pg_advisory_lock(42);  -- may never be released if connection recycled
```

```sql
-- ✅ Workarounds for transaction mode:

-- Instead of prepared statements: use protocol-level prepared statements
-- (application driver handles this transparently for pg drivers)

-- Instead of SET: set within the transaction
BEGIN;
SET LOCAL work_mem = '512MB';  -- LOCAL: only valid for this transaction
SELECT ... ORDER BY ...;
COMMIT;

-- Instead of temp tables: use regular tables with session ID column, or CTEs

-- Check if running via PgBouncer (to detect environment):
SELECT application_name FROM pg_stat_activity WHERE pid = pg_backend_pid();
```

---

## 34.4 PgBouncer High Availability

A single PgBouncer is a single point of failure. Production deployments need HA.

### Pattern 1: HAProxy in front of multiple PgBouncers

```
App servers
    ↓
HAProxy (health checks, load balancing)
    ├── PgBouncer instance 1
    ├── PgBouncer instance 2
    └── PgBouncer instance 3
          ↓
      PostgreSQL primary
```

```
# HAProxy config for PgBouncer
frontend pgbouncer_frontend
    bind *:5432
    mode tcp
    default_backend pgbouncer_backend

backend pgbouncer_backend
    mode tcp
    balance roundrobin
    option tcp-check
    server pgb1 10.0.1.1:5432 check
    server pgb2 10.0.1.2:5432 check
    server pgb3 10.0.1.3:5432 check
```

### Pattern 2: PgBouncer on every app server (sidecar)

```
App server 1: App + PgBouncer → PostgreSQL
App server 2: App + PgBouncer → PostgreSQL
App server 3: App + PgBouncer → PostgreSQL
```

Eliminates network hop to PgBouncer; each app server manages its own pool. Works well with Kubernetes (PgBouncer as sidecar container).

---

## 34.5 Cloud Proxies

### AWS RDS Proxy

```
App → RDS Proxy → RDS PostgreSQL
```

- Built on AWS infrastructure, managed HA
- Supports IAM authentication
- Multiplexes connections (transaction pinning for session features)
- **Pinning**: session-level features force RDS Proxy to pin a client to one server connection — defeats pooling. Check `DatabaseConnectionsCurrentlySessionPinned` metric.

```python
# RDS Proxy with IAM auth (Python example)
import boto3
import psycopg2

token = boto3.client('rds').generate_db_auth_token(
    DBHostname='mydb.proxy-xxx.us-east-1.rds.amazonaws.com',
    Port=5432,
    DBUsername='myapp'
)
conn = psycopg2.connect(
    host='mydb.proxy-xxx.us-east-1.rds.amazonaws.com',
    database='mydb',
    user='myapp',
    password=token,
    sslmode='verify-full'
)
```

### Cloud SQL Auth Proxy (GCP)

```bash
# Run as sidecar; app connects to localhost
./cloud-sql-proxy --port=5432 project:region:instance

# Connection string
postgresql://user:pass@localhost:5432/dbname
```

---

## 34.6 Timeout Hierarchy

PostgreSQL has many timeout settings that interact. Understanding the hierarchy prevents confusing failures.

```sql
-- Client connection timeout (how long to wait for connection establishment)
-- Set in connection string: connect_timeout=10

-- Statement timeout: kill a query after N ms
SET statement_timeout = '30s';
-- Raises error 57014 if exceeded — does NOT cancel transaction, just statement

-- Lock timeout: give up waiting for a lock after N ms
SET lock_timeout = '5s';
-- Raises error 55P03 — prevents long lock waits from cascading

-- Idle in transaction timeout: rollback abandoned transactions
SET idle_in_transaction_session_timeout = '60s';
-- Kills sessions that opened a transaction but stopped sending queries
-- Critical for preventing long-held locks from abandoned connections

-- Idle session timeout (PG 14+): disconnect idle sessions
SET idle_session_timeout = '300s';
-- Disconnects sessions doing nothing (reduces connection overhead)

-- TCP keepalive (OS level): detect dead connections
-- tcp_keepalives_idle = 60      (seconds before first keepalive)
-- tcp_keepalives_interval = 10  (seconds between keepalives)
-- tcp_keepalives_count = 6      (probes before declaring dead)
```

### Recommended timeout stack for production

```ini
; postgresql.conf
statement_timeout = 0                          ; set per-role or per-query
lock_timeout = '10s'                           ; never wait more than 10s for a lock
idle_in_transaction_session_timeout = '60s'    ; kill abandoned transactions
idle_session_timeout = '600s'                  ; disconnect truly idle sessions

; For OLTP API connections (via role):
ALTER ROLE app_user SET statement_timeout = '5s';
ALTER ROLE reporting_user SET statement_timeout = '300s';
```

---

## 34.7 Connection Pooling for Multi-Tenant SaaS

```sql
-- Pattern: one database per tenant (strong isolation)
-- PgBouncer config: separate pool per database
[databases]
tenant_a = host=127.0.0.1 dbname=tenant_a pool_size=10
tenant_b = host=127.0.0.1 dbname=tenant_b pool_size=10

-- Pattern: shared database, schema-per-tenant
-- PgBouncer: connect_query sets the search_path
[databases]
shared = host=127.0.0.1 dbname=shared connect_query="SET search_path TO tenant_a"

-- Pattern: shared schema with tenant_id column (most common)
-- Use RLS to enforce tenant isolation (Chapter 25/36)
-- PgBouncer: set role per tenant using auth_query
```

---

## 34.8 Detecting Connection Leaks

```sql
-- Sessions open for a long time (potential leaks)
SELECT pid, usename, application_name,
       now() - backend_start AS age,
       state, left(query, 80) AS query
FROM pg_stat_activity
WHERE now() - backend_start > interval '1 hour'
ORDER BY age DESC;

-- Long idle-in-transaction sessions (worst offenders — holding locks)
SELECT pid, usename,
       now() - state_change AS idle_in_txn_duration,
       left(query, 80)
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND now() - state_change > interval '5 minutes'
ORDER BY idle_in_txn_duration DESC;

-- Kill a leaking connection
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND now() - state_change > interval '10 minutes';
```

---

## 34.9 Sizing the Connection Pool

```
Formula for pool sizing:
  PostgreSQL server connections = (CPU cores × 2) + effective_spindle_count
  For a 16-core SSD server: (16 × 2) + 1 ≈ 33 connections

  PgBouncer pool_size ≈ that number
  PgBouncer max_client_conn = pool_size × 10 to 50 (clients wait in PgBouncer)
```

```sql
-- Measure actual active connections at peak (not just total connected)
SELECT count(*)
FROM pg_stat_activity
WHERE state = 'active'
  AND wait_event IS NULL;  -- actually running, not waiting

-- This number should not exceed CPU cores significantly
-- If it does: queries are too slow, not connection count is the problem
```

---

## 34.10 PgBouncer Monitoring

```bash
# Connect to PgBouncer admin console
psql -h 127.0.0.1 -p 6432 -U pgbouncer pgbouncer

# Pool status
SHOW POOLS;
-- cl_active: clients using a server connection
-- cl_waiting: clients waiting for a free server connection  ← alert on this
-- sv_active: server connections in use
-- sv_idle: server connections ready
-- sv_used: server connections recently returned (being recycled)

# Database stats
SHOW DATABASES;
SHOW STATS;   -- requests/sec, avg query time per database

# Reload config without restart
RELOAD;

# Pause a database (for maintenance)
PAUSE mydb;
RESUME mydb;
```

```sql
-- Prometheus metrics via pgbouncer_exporter or pgbouncer's built-in stats
-- Key metrics to alert on:
-- pgbouncer_pools_cl_waiting > 0 for > 5 seconds → pool exhausted
-- pgbouncer_stats_avg_query_time > SLA threshold → backend slow
-- pgbouncer_pools_sv_idle = 0 → all connections busy
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| PgBouncer | Lightweight connection pooler that sits between app and PostgreSQL |
| Pool mode | When server connections are released: session / transaction / statement |
| Connection pinning | RDS Proxy forcing a client to one server connection (defeats pooling) |
| `DISCARD ALL` | Resets session state — run by PgBouncer between clients in session mode |
| `idle_in_transaction_session_timeout` | Kills sessions that opened a transaction but stopped querying |
| `lock_timeout` | Raises error instead of waiting indefinitely for a lock |
| `statement_timeout` | Kills a query after N milliseconds |
| cl_waiting | PgBouncer metric: clients waiting for a free server connection |

---

## Practice Questions

1. Your application uses `SET work_mem = '256MB'` before every large query. PgBouncer is in transaction mode. Will this work? Why or why not?
2. You see `cl_waiting > 0` in PgBouncer's `SHOW POOLS` during peak hours. What does this mean and what are three ways to address it?
3. After enabling `idle_in_transaction_session_timeout = '30s'`, some jobs start failing with `ERROR: canceling statement due to conflict`. What is likely happening?
4. An app server creates a temporary table, inserts data, then queries it 3 seconds later — and gets "table not found." PgBouncer is in transaction mode. Explain the cause.
5. Design a PgBouncer HA setup for a system that cannot afford any connection downtime. What are the components?
6. A PostgreSQL server has 16 cores. What should `default_pool_size` be in PgBouncer and why?

---

**← Previous:** [33_advanced_query_patterns.md](33_advanced_query_patterns.md)  
**Next →** [35_observability_engineering.md](35_observability_engineering.md)
