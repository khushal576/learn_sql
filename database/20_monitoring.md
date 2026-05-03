# Chapter 20 — Monitoring & Observability

You cannot manage what you cannot measure. This chapter covers every built-in PostgreSQL view, metric collection, alerting, and tooling you need to run a healthy production database.

---

## 20.1 The Three Pillars of Database Observability

```
Metrics    → numbers over time (query latency, cache hit rate, connections)
Logs       → timestamped events (slow queries, errors, connections)
Traces     → distributed request traces across services
```

For PostgreSQL, metrics and logs are most important. This chapter focuses on both.

---

## 20.2 pg_stat_* — Built-in Statistics Views

PostgreSQL ships with a rich set of statistics views. These are your first stop for any investigation.

### pg_stat_activity — What's Running Right Now

```sql
-- All active connections and what they're doing
SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       wait_event_type,
       wait_event,
       now() - query_start AS query_duration,
       left(query, 100) AS query_snippet
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY query_duration DESC NULLS LAST;
```

| Column | Meaning |
|--------|---------|
| `state` | `active`, `idle`, `idle in transaction`, `idle in transaction (aborted)` |
| `wait_event_type` | What the query is waiting for: `Lock`, `IO`, `Client`, etc. |
| `wait_event` | Specific event: `relation`, `tuple`, `WALWrite`, etc. |
| `query_start` | When current query started |

**`idle in transaction`** — client started a transaction and went quiet. Dangerous: holds locks, blocks VACUUM. Alert if duration > 30 seconds.

---

### pg_stat_user_tables — Table-Level Stats

```sql
SELECT schemaname,
       tablename,
       seq_scan,                          -- sequential scans (high = missing index)
       idx_scan,                          -- index scans
       n_tup_ins, n_tup_upd, n_tup_del,  -- writes
       n_live_tup, n_dead_tup,            -- bloat indicator
       last_vacuum, last_autovacuum,
       last_analyze, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY seq_scan DESC;
```

High `seq_scan` on large tables = missing indexes or full-table scans.

---

### pg_stat_user_indexes — Index Usage

```sql
SELECT schemaname,
       tablename,
       indexname,
       idx_scan,           -- times this index was used
       idx_tup_read,       -- tuples read via index
       idx_tup_fetch       -- tuples fetched from heap
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC;     -- lowest = least used
```

Indexes with `idx_scan = 0` for weeks are unused — drop them (they slow writes).

---

### pg_statio_user_tables — Buffer Hit Rate

```sql
SELECT schemaname,
       tablename,
       heap_blks_read,    -- pages read from disk
       heap_blks_hit,     -- pages served from shared_buffers
       round(heap_blks_hit::numeric /
             nullif(heap_blks_hit + heap_blks_read, 0) * 100, 2) AS cache_hit_pct
FROM pg_statio_user_tables
ORDER BY heap_blks_read DESC;
```

**Target**: cache hit rate > 99%. If below 95%, `shared_buffers` may be too small.

---

### pg_stat_bgwriter — Background Writer and Checkpoint Stats

```sql
SELECT checkpoints_timed,
       checkpoints_req,           -- checkpoints triggered by WAL size (should be low)
       checkpoint_write_time,
       checkpoint_sync_time,
       buffers_checkpoint,        -- buffers written during checkpoints
       buffers_clean,             -- buffers written by bgwriter
       maxwritten_clean,          -- bgwriter stopped due to max writes (= I/O pressure)
       buffers_backend,           -- buffers written by backends (bad = bgwriter not keeping up)
       buffers_alloc
FROM pg_stat_bgwriter;
```

`checkpoints_req` >> `checkpoints_timed` → increase `max_wal_size`.  
`buffers_backend` > 0 → bgwriter is not keeping up → tune `bgwriter_lru_maxpages`.

---

### pg_stat_replication — Replica Lag

```sql
SELECT client_addr,
       state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS total_lag_bytes,
       write_lag,
       flush_lag,
       replay_lag
FROM pg_stat_replication;
```

Alert if `total_lag_bytes > 50 MB` or `replay_lag > 30 seconds`.

---

### pg_locks — Lock Monitoring

```sql
-- Find blocking queries
SELECT
    blocked.pid          AS blocked_pid,
    blocked.usename      AS blocked_user,
    left(blocked.query, 80) AS blocked_query,
    blocking.pid         AS blocking_pid,
    blocking.usename     AS blocking_user,
    left(blocking.query, 80) AS blocking_query,
    now() - blocked.query_start AS blocked_for
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
ORDER BY blocked_for DESC;
```

---

## 20.3 pg_stat_statements — Query Performance Tracking

The most valuable extension for query analysis:

```sql
-- Enable
shared_preload_libraries = 'pg_stat_statements'  -- requires restart
CREATE EXTENSION pg_stat_statements;

-- Top 10 slowest queries by total time
SELECT
    left(query, 120) AS query,
    calls,
    round(total_exec_time::numeric / 1000, 2) AS total_sec,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    rows,
    round(shared_blks_hit::numeric /
          nullif(shared_blks_hit + shared_blks_read, 0) * 100, 2) AS cache_hit_pct
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- Top 10 by average execution time (consistently slow)
SELECT left(query, 120), calls, round(mean_exec_time::numeric, 2) AS mean_ms
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;

-- Queries with high I/O (many disk reads)
SELECT left(query, 120), shared_blks_read, calls
FROM pg_stat_statements
ORDER BY shared_blks_read DESC
LIMIT 10;

-- Reset stats
SELECT pg_stat_statements_reset();
```

---

## 20.4 Slow Query Log

Log queries that exceed a time threshold:

```ini
# postgresql.conf
log_min_duration_statement = 1000    # log queries > 1 second (ms)
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on                   # log if waiting for a lock > deadlock_timeout
log_temp_files = 0                    # log temp file creation (join/sort spilling to disk)
log_autovacuum_min_duration = 0       # log all autovacuum runs
```

### Analyzing Logs with pgBadger

```bash
# Install
apt-get install pgbadger

# Parse logs and generate HTML report
pgbadger /var/log/postgresql/postgresql*.log -o report.html

# For multiple log files
pgbadger /var/log/postgresql/ --outfile report.html --jobs 4
```

pgBadger produces:
- Top slow queries
- Most frequent queries
- Queries with most lock waits
- Autovacuum activity
- Connection statistics

---

## 20.5 Key Metrics to Monitor

### Connection Metrics

```sql
-- Current connection count vs max
SELECT count(*) AS current,
       max_conn,
       max_conn - count(*) AS available
FROM pg_stat_activity, (SELECT setting::int AS max_conn FROM pg_settings WHERE name='max_connections') mc
GROUP BY max_conn;

-- Connections by state
SELECT state, count(*)
FROM pg_stat_activity
GROUP BY state;
```

Alert: `current / max_connections > 80%`

---

### Cache Hit Rate

```sql
SELECT round(
    sum(heap_blks_hit) * 100.0 /
    nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0),
2) AS cache_hit_pct
FROM pg_statio_user_tables;
```

Alert: `cache_hit_pct < 95%` → consider increasing `shared_buffers`

---

### Transaction Rate and Long-Running Transactions

```sql
-- Transactions per second (check over time)
SELECT xact_commit + xact_rollback AS total_txns
FROM pg_stat_database
WHERE datname = 'mydb';

-- Long idle-in-transaction
SELECT pid, usename, now() - xact_start AS idle_duration
FROM pg_stat_activity
WHERE state = 'idle in transaction'
AND xact_start < now() - INTERVAL '30 seconds';
```

Alert: any `idle in transaction` for > 60 seconds.

---

### Table and Index Bloat

```sql
-- Quick bloat estimate
SELECT relname,
       n_dead_tup,
       n_live_tup,
       round(n_dead_tup * 100.0 / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY dead_pct DESC;
```

Alert: `dead_pct > 20%` on large tables.

---

### XID Age (Wraparound Risk)

```sql
SELECT datname, age(datfrozenxid) AS xid_age
FROM pg_database
ORDER BY xid_age DESC;
```

Alert: `xid_age > 1,500,000,000` (Warning) / `> 1,900,000,000` (Critical)

---

## 20.6 Prometheus + postgres_exporter

For production monitoring with dashboards and alerting:

### Setup postgres_exporter

```bash
# Install
wget https://github.com/prometheus-community/postgres_exporter/releases/latest/download/postgres_exporter-linux-amd64.tar.gz
tar xzf postgres_exporter-linux-amd64.tar.gz

# Configure
export DATA_SOURCE_NAME="postgresql://monitor:secret@localhost:5432/postgres?sslmode=disable"
./postgres_exporter
```

### Key Exported Metrics

```
pg_up                                     # Is PostgreSQL reachable?
pg_stat_activity_count{state="active"}    # Active connections
pg_stat_database_blks_hit                 # Buffer cache hits
pg_stat_database_blks_read               # Disk reads
pg_stat_replication_pg_wal_lsn_diff      # Replica lag (bytes)
pg_stat_user_tables_n_dead_tup           # Dead tuples per table
pg_database_size_bytes                    # Database size
pg_locks_count                            # Lock counts by type
```

### Grafana Dashboard

Import the official PostgreSQL dashboard (ID: **9628** on grafana.com):
- Buffer cache hit rate
- Active connections
- Transactions per second
- Replication lag
- Vacuum activity
- Query performance

---

## 20.7 Essential Alerts Checklist

| Alert | Threshold | Severity |
|-------|-----------|----------|
| PostgreSQL unreachable | Any | Critical |
| Connection count | > 80% of max_connections | Warning |
| Cache hit rate | < 95% | Warning |
| Replication lag | > 30 seconds | Warning / > 5 min = Critical |
| Long idle-in-transaction | > 60 seconds | Warning |
| XID age | > 1.5B (Warning) / > 1.9B (Critical) | Warning/Critical |
| Table bloat | > 20% dead tuples on large tables | Warning |
| Checkpoint frequency | checkpoints_req > checkpoints_timed | Warning |
| Disk space | > 80% full | Warning |
| Slow queries | p99 > SLA threshold | Warning |
| Lock wait | Any query waiting > 30s | Warning |
| Autovacuum disabled | autovacuum = off | Critical |

---

## 20.8 Useful Diagnostic Queries Reference

```sql
-- Database sizes
SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database;

-- Largest tables
SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) AS total
FROM pg_class WHERE relkind='r' ORDER BY pg_total_relation_size(oid) DESC LIMIT 10;

-- Unused indexes (candidates for removal)
SELECT indexname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes WHERE idx_scan = 0 AND NOT indisprimary
ORDER BY pg_relation_size(indexrelid) DESC;

-- Tables missing indexes (high sequential scans)
SELECT relname, seq_scan, idx_scan,
       round(idx_scan * 100.0 / nullif(seq_scan + idx_scan, 0), 1) AS idx_pct
FROM pg_stat_user_tables
WHERE seq_scan > 1000
ORDER BY seq_scan DESC;

-- Running queries with duration
SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state
FROM pg_stat_activity
WHERE state = 'active' AND query_start < now() - INTERVAL '1 second'
ORDER BY duration DESC;

-- Kill all idle connections older than 10 minutes
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
AND query_start < now() - INTERVAL '10 minutes'
AND pid <> pg_backend_pid();
```

---

## 20.9 Maintenance Monitoring Dashboard

Run these queries weekly to stay ahead of problems:

```sql
-- Weekly health check
DO $$
BEGIN
  -- 1. Check for tables not vacuumed in 3 days
  RAISE NOTICE 'Tables needing vacuum:';
END;
$$;

SELECT tablename, last_autovacuum, n_dead_tup
FROM pg_stat_user_tables
WHERE (last_autovacuum IS NULL OR last_autovacuum < now() - INTERVAL '3 days')
  AND n_dead_tup > 10000
ORDER BY n_dead_tup DESC;

-- 2. Check XID age
SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;

-- 3. Check replication lag
SELECT * FROM pg_stat_replication;

-- 4. Check for long-running transactions
SELECT pid, usename, xact_start, now() - xact_start AS age
FROM pg_stat_activity
WHERE xact_start < now() - INTERVAL '1 hour'
ORDER BY age DESC;
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| `pg_stat_activity` | Real-time view of all connections and their current queries |
| `pg_stat_statements` | Aggregated statistics for all executed query patterns |
| `pg_statio_user_tables` | Buffer cache hit/miss counts per table |
| `pg_stat_replication` | Replication status and lag for each replica |
| Cache hit rate | % of page reads served from shared_buffers vs disk |
| Slow query log | `log_min_duration_statement` — logs queries exceeding threshold |
| pgBadger | PostgreSQL log analyzer — produces HTML performance reports |
| postgres_exporter | Prometheus exporter for PostgreSQL metrics |
| RTO / RPO | Recovery Time / Point Objective — downtime/data loss targets |

---

## Practice Questions

1. Write a query to find the top 5 queries by total execution time using `pg_stat_statements`.
2. Your cache hit rate is 85%. What does this indicate and what should you check?
3. `pg_stat_activity` shows 10 connections in state `idle in transaction` for 15 minutes. What is the risk and how do you address it?
4. How do you find tables that are missing indexes (lots of sequential scans on large tables)?
5. Set up alerting: what are the three most critical alerts to have for a production PostgreSQL database?
6. What does `log_temp_files = 0` log and why is it useful for query tuning?

---

**← Previous:** [19_connection_pooling.md](19_connection_pooling.md)  
**Next →** [21_partitioning.md](21_partitioning.md) *(Module 4 — Advanced Topics)*
