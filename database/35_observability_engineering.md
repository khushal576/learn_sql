# Chapter 35 — Observability Engineering & SLOs

Monitoring tells you something is wrong. Observability tells you *why*. This chapter covers PostgreSQL's wait event system, SLO design for databases, auto_explain, OpenTelemetry integration, and multi-tenant observability patterns.

---

## 35.1 The Three Pillars for Databases

| Pillar | PostgreSQL Source | What it answers |
|--------|------------------|-----------------|
| **Metrics** | pg_stat_* views, Prometheus | Is the system healthy right now? |
| **Logs** | postgresql.log, pgBadger | What slow/failed queries happened? |
| **Traces** | auto_explain, OpenTelemetry | Why did this specific request take 800ms? |

Most teams have metrics. Few have proper traces. The difference is whether you can answer "what was the exact query plan for the request that caused the P99 spike?"

---

## 35.2 Wait Event Taxonomy

When a backend is not actively executing CPU instructions, it is *waiting*. The wait event tells you exactly why.

```sql
-- Current wait events across all backends
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE state != 'idle'
GROUP BY wait_event_type, wait_event
ORDER BY count(*) DESC;
```

| Wait Event Type | Meaning | Common Causes |
|----------------|---------|---------------|
| `Lock` | Waiting for a table/row/object lock | Long transactions, lock contention |
| `LWLock` | Lightweight lock (internal) | Buffer pool contention, WAL write |
| `IO` | Waiting for disk I/O | Cache miss, slow storage |
| `IPC` | Inter-process communication | Parallel query worker sync |
| `Client` | Waiting for client to read results | Slow network, client backpressure |
| `Timeout` | Waiting for a timer | pg_sleep, statement_timeout |
| `Activity` | Background process idle sleep | Normal for bgwriter, autovacuum |
| `CPU` | Actually running (no wait) | Normal active execution |

```sql
-- Deep dive: which queries are waiting on locks right now
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.query AS blocking_query,
    now() - blocked.query_start AS blocked_duration
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
ORDER BY blocked_duration DESC;

-- IO wait breakdown
SELECT wait_event, count(*)
FROM pg_stat_activity
WHERE wait_event_type = 'IO'
GROUP BY wait_event;
-- BufferRead: reading a page not in shared_buffers (cache miss)
-- WALWrite: writing WAL records
-- DataFileRead: reading actual table/index data
```

---

## 35.3 pg_wait_sampling — Wait Event History

`pg_stat_activity` shows *current* state — a point-in-time snapshot. `pg_wait_sampling` continuously samples wait events and accumulates history.

```sql
-- Install (requires postgresql.conf preload)
-- shared_preload_libraries = 'pg_wait_sampling'

-- After restart:
CREATE EXTENSION pg_wait_sampling;

-- View accumulated wait profile
SELECT event_type, event, count
FROM pg_wait_sampling_profile
ORDER BY count DESC
LIMIT 20;

-- Reset to start fresh measurement window
SELECT pg_wait_sampling_reset_profile();

-- Useful for: run for 5 minutes during peak load, then inspect
-- Answers: what is the database actually spending time on?
```

---

## 35.4 auto_explain — Capturing Query Plans in Production

`auto_explain` logs the execution plan (with actual timing) for any query exceeding a threshold. The only way to see what plan ran for a past slow query.

```ini
# postgresql.conf
shared_preload_libraries = 'auto_explain'

auto_explain.log_min_duration = 1000    # Log plans for queries > 1 second
auto_explain.log_analyze = on           # Include actual timings (EXPLAIN ANALYZE)
auto_explain.log_buffers = on           # Include buffer statistics
auto_explain.log_format = json          # JSON is easier to parse programmatically
auto_explain.log_nested_statements = on # Also log queries inside functions
auto_explain.log_timing = on            # Per-node timing (expensive but useful)
auto_explain.sample_rate = 0.1          # Only log 10% of slow queries (reduce I/O)
```

```sql
-- Enable for a single session (no config change needed)
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 100;
SET auto_explain.log_analyze = on;

-- Now run your query — the plan appears in PostgreSQL logs
SELECT * FROM orders o JOIN customers c ON o.customer_id = c.id
WHERE o.created_at > '2024-01-01';
```

```bash
# Parse JSON plans from logs
grep -A 200 'EXPLAIN' /var/log/postgresql/postgresql.log | \
    python3 -c "import sys,json; [print(json.dumps(json.loads(l),indent=2)) for l in sys.stdin if l.strip().startswith('{')]"

# pgBadger auto_explain integration
pgbadger --format json --json-plan /var/log/postgresql/postgresql.log
```

---

## 35.5 Defining Database SLOs

An SLO (Service Level Objective) defines the target reliability level. Without it, "slow" and "fast" are meaningless.

### SLO design for PostgreSQL

```
SLO 1: Query latency
  - P50 < 5ms, P99 < 50ms, P999 < 500ms
  - Window: rolling 30 days
  - Error budget: 0.1% of requests can exceed P99 threshold

SLO 2: Availability
  - Database accepting connections: 99.9% of time
  - Measure: connection success rate from app servers

SLO 3: Replication lag
  - Streaming replica lag < 10 seconds at all times
  - Logical replication slot lag < 1 GB

SLO 4: Data durability
  - RPO < 5 minutes (WAL archiving + PITR)
  - RTO < 30 minutes (failover time)
```

```sql
-- Measure P50/P99 from pg_stat_statements
SELECT
    left(query, 80) AS query,
    calls,
    round(mean_exec_time, 2) AS mean_ms,
    round(stddev_exec_time, 2) AS stddev_ms,
    round(min_exec_time, 2) AS min_ms,
    round(max_exec_time, 2) AS max_ms
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 20;

-- Note: pg_stat_statements doesn't store per-request latency
-- For true P99, use application-level tracing or pg_stat_monitor
```

### pg_stat_monitor (better than pg_stat_statements)

```sql
-- Provides histograms, P50/P95/P99, per-user/db breakdown
CREATE EXTENSION pg_stat_monitor;

SELECT bucket_start_time, query, calls,
       mean_time, p50, p95, p99
FROM pg_stat_monitor
ORDER BY p99 DESC LIMIT 10;
```

---

## 35.6 Error Budget Tracking

```sql
-- Snapshot pg_stat_statements hourly (via cron or pg_cron)
CREATE TABLE perf_snapshots (
    snapped_at      TIMESTAMPTZ DEFAULT NOW(),
    queryid         BIGINT,
    query           TEXT,
    calls           BIGINT,
    total_exec_time DOUBLE PRECISION,
    mean_exec_time  DOUBLE PRECISION
);

INSERT INTO perf_snapshots (queryid, query, calls, total_exec_time, mean_exec_time)
SELECT queryid, query, calls, total_exec_time, mean_exec_time
FROM pg_stat_statements;

-- Error budget consumption: queries exceeding SLO threshold
WITH hourly_delta AS (
    SELECT
        a.queryid,
        a.query,
        a.calls - b.calls AS calls_delta,
        a.total_exec_time - b.total_exec_time AS time_delta
    FROM perf_snapshots a
    JOIN perf_snapshots b ON a.queryid = b.queryid
    WHERE a.snapped_at = (SELECT MAX(snapped_at) FROM perf_snapshots)
      AND b.snapped_at = (SELECT MAX(snapped_at) FROM perf_snapshots
                          WHERE snapped_at < (SELECT MAX(snapped_at) FROM perf_snapshots))
)
SELECT queryid,
       left(query, 80),
       calls_delta AS calls_this_hour,
       round((time_delta / calls_delta)::numeric, 2) AS avg_ms_this_hour
FROM hourly_delta
WHERE calls_delta > 0
ORDER BY avg_ms_this_hour DESC;
```

---

## 35.7 OpenTelemetry Integration

OpenTelemetry traces propagate a trace context from the application through to the database query, enabling end-to-end request tracing.

```python
# Python: propagating trace context to PostgreSQL queries
from opentelemetry import trace
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor

# Auto-instrument psycopg2 — every query becomes a span
Psycopg2Instrumentor().instrument()

tracer = trace.get_tracer(__name__)

with tracer.start_as_current_span("handle_order"):
    conn = psycopg2.connect(DSN)
    cur = conn.cursor()
    # This query automatically appears as a child span with:
    # - SQL text
    # - DB name, host, port
    # - Duration
    cur.execute("SELECT * FROM orders WHERE customer_id = %s", (42,))
```

```sql
-- PostgreSQL side: add trace context as a comment (sqlcommenter pattern)
-- Application adds: /* traceparent='00-abc-def-01' */ before every query
-- Then pg_stat_statements groups by queryid ignoring the comment

-- Useful log format that includes trace context:
-- log_line_prefix = '%t [%p]: [%l-1] app=%a,db=%d,user=%u,client=%h '
```

---

## 35.8 Multi-Tenant Observability

In multi-tenant systems, you need per-tenant metrics without exposing one tenant's data to another.

```sql
-- Tag queries with tenant context using application_name
-- Application sets this per request:
SET application_name = 'tenant:acme:order-service';

-- Now pg_stat_activity shows tenant per connection
SELECT application_name, count(*), avg(now() - query_start) AS avg_query_age
FROM pg_stat_activity
WHERE state = 'active'
GROUP BY application_name;

-- Per-tenant query performance from pg_stat_statements
-- (requires application to embed tenant in query comments for grouping)
SELECT
    substring(query FROM '/\* tenant: ([^ ]+)') AS tenant,
    count(*) AS distinct_queries,
    SUM(calls) AS total_calls,
    round(SUM(total_exec_time) / 1000, 2) AS total_sec
FROM pg_stat_statements
WHERE query LIKE '%/* tenant:%'
GROUP BY 1
ORDER BY total_sec DESC;
```

---

## 35.9 Alerting Rules Reference

```yaml
# Prometheus alerting rules for PostgreSQL
groups:
  - name: postgresql
    rules:
      - alert: PGHighConnectionCount
        expr: pg_stat_activity_count > pg_settings_max_connections * 0.8
        for: 5m
        annotations:
          summary: "Connection count above 80% of max_connections"

      - alert: PGReplicationLagHigh
        expr: pg_replication_lag > 30
        for: 2m
        annotations:
          summary: "Streaming replica lag > 30 seconds"

      - alert: PGLongRunningQuery
        expr: pg_stat_activity_max_tx_duration > 300
        for: 1m
        annotations:
          summary: "Query/transaction running > 5 minutes"

      - alert: PGCacheHitRateLow
        expr: |
          sum(pg_stat_database_blks_hit) /
          (sum(pg_stat_database_blks_hit) + sum(pg_stat_database_blks_read)) < 0.95
        for: 5m
        annotations:
          summary: "Cache hit rate below 95%"

      - alert: PGXIDWraparoundRisk
        expr: pg_database_xid_age > 1500000000
        for: 1h
        annotations:
          summary: "XID age > 1.5 billion — wraparound risk"

      - alert: PGLogicalSlotLag
        expr: pg_replication_slot_wal_status_lag_bytes > 5368709120  # 5GB
        for: 5m
        annotations:
          summary: "Logical replication slot lag > 5 GB — disk fill risk"
```

---

## 35.10 Observability Stack Reference

```
Data collection:
  postgres_exporter     → scrapes pg_stat_* views → Prometheus
  pg_activity           → real-time htop-style query monitor
  pgBadger              → parses PostgreSQL logs → HTML reports

Storage & querying:
  Prometheus            → metrics storage, alerting
  Loki                  → log aggregation (pairs with Grafana)

Visualization:
  Grafana               → dashboards (PostgreSQL exporter has pre-built dashboards)
  pgAdmin 4             → query plan visualization

Tracing:
  Jaeger / Tempo        → distributed trace storage
  OpenTelemetry         → instrumentation SDK

Plan analysis:
  explain.dalibo.com    → paste EXPLAIN JSON → visual plan tree
  pev2                  → self-hosted plan visualizer
  auto_explain          → automatic plan capture in logs
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| Wait event | What a backend is waiting on when not executing CPU work |
| `pg_wait_sampling` | Extension that samples wait events continuously to build a profile |
| `auto_explain` | Module that logs query plans for slow queries automatically |
| SLO | Service Level Objective — the target reliability/performance level |
| Error budget | Allowed percentage of SLO violations before action is required |
| OpenTelemetry | Vendor-neutral tracing/metrics standard |
| `pg_stat_monitor` | Enhanced version of pg_stat_statements with latency histograms |
| sqlcommenter | Convention of embedding trace context in SQL comments |

---

## Practice Questions

1. `pg_stat_activity` shows many backends with `wait_event_type = 'Lock'`. What is happening and how do you identify the blocking query?
2. You want to capture the EXPLAIN plan of every query over 500ms in production without restarting PostgreSQL. What do you do?
3. Define three SLOs for a PostgreSQL-backed e-commerce system. What metrics would you use to measure each?
4. A query runs in 5ms most of the time but shows P999 = 2000ms in pg_stat_monitor. What are the likely causes?
5. How do you attribute database load to specific tenants in a shared-schema multi-tenant system?
6. After enabling `auto_explain.log_analyze = on`, your PostgreSQL server's CPU usage increases by 15%. Why, and how do you reduce this impact?

---

**← Previous:** [34_connection_management_scale.md](34_connection_management_scale.md)  
**Next →** [36_compliance_advanced_security.md](36_compliance_advanced_security.md)
