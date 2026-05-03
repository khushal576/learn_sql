# Chapter 38 — Capacity Planning & Cloud Architecture

Capacity planning is the skill of staying ahead of resource exhaustion before it causes incidents. Cloud deployments add a new dimension: managed services have hidden limits, cost structures, and failure modes that differ significantly from self-hosted PostgreSQL.

---

## 38.1 The Capacity Planning Process

```
1. Baseline current utilization
   → CPU, memory, I/O, connections, storage growth rate

2. Project growth
   → Business forecast × resource-per-unit metrics

3. Identify the constraint
   → Which resource runs out first?

4. Determine headroom threshold
   → At what utilization % do you act? (typically 70%)

5. Right-size or scale
   → Vertical scale, read replicas, partitioning, archival
```

```sql
-- Baseline storage growth rate
SELECT
    datname,
    pg_size_pretty(pg_database_size(datname)) AS db_size
FROM pg_database
WHERE datistemplate = false;

-- Table growth tracking (run daily, compare over weeks)
SELECT
    relname,
    pg_size_pretty(pg_total_relation_size(oid)) AS total_size,
    pg_size_pretty(pg_relation_size(oid)) AS table_size,
    pg_size_pretty(pg_total_relation_size(oid) - pg_relation_size(oid)) AS index_size,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(oid) DESC
LIMIT 20;
```

---

## 38.2 CPU and Memory Capacity Signals

```sql
-- Connection saturation (leading indicator for CPU pressure)
SELECT count(*) AS active, max_conn
FROM pg_stat_activity, (SELECT setting::int AS max_conn FROM pg_settings WHERE name = 'max_connections') m
WHERE state = 'active'
GROUP BY max_conn;

-- Long-running queries (CPU consumers)
SELECT pid, now() - query_start AS runtime, left(query, 100)
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY runtime DESC
LIMIT 10;

-- Cache hit rate (low = memory-bound)
SELECT
    sum(heap_blks_hit) AS hits,
    sum(heap_blks_read) AS reads,
    round(sum(heap_blks_hit) * 100.0 / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2) AS hit_pct
FROM pg_statio_user_tables;
-- Target: > 99% for OLTP, > 95% for mixed workloads
```

### Memory sizing rules of thumb

```
shared_buffers      = 25% of RAM
effective_cache_size = 75% of RAM
work_mem            = RAM × 0.25 / max_connections / 4
                    (conservative; tune up for analytics)

Example: 64 GB RAM, 200 max_connections:
  shared_buffers = 16 GB
  effective_cache_size = 48 GB
  work_mem = 64GB × 0.25 / 200 / 4 = ~20 MB per operation
```

---

## 38.3 Storage Capacity Planning

```sql
-- Storage consumption breakdown
SELECT
    schemaname,
    relname,
    pg_size_pretty(pg_total_relation_size(relid)) AS total,
    pg_size_pretty(pg_relation_size(relid)) AS table,
    pg_size_pretty(pg_indexes_size(relid)) AS indexes,
    round(pg_indexes_size(relid) * 100.0 / pg_total_relation_size(relid)) AS idx_pct
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 20;

-- WAL generation rate (for storage and replication planning)
SELECT
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')) AS total_wal_generated;

-- More useful: WAL generation per time window
-- Capture pg_current_wal_lsn() at t1 and t2, compute diff
```

### Storage growth forecasting

```sql
-- Create a daily snapshot table for trend analysis
CREATE TABLE storage_snapshots (
    snapped_at TIMESTAMPTZ DEFAULT NOW(),
    relname    TEXT,
    total_bytes BIGINT
);

INSERT INTO storage_snapshots (relname, total_bytes)
SELECT relname, pg_total_relation_size(relid)
FROM pg_stat_user_tables;

-- 30-day growth rate
SELECT
    a.relname,
    pg_size_pretty(a.total_bytes - b.total_bytes) AS growth_30d,
    pg_size_pretty(a.total_bytes) AS current_size,
    round((a.total_bytes - b.total_bytes) * 12.0 / 1073741824, 1) AS projected_annual_growth_gb
FROM storage_snapshots a
JOIN storage_snapshots b ON a.relname = b.relname
WHERE a.snapped_at >= NOW() - INTERVAL '1 day'
  AND b.snapped_at <= NOW() - INTERVAL '30 days'
ORDER BY (a.total_bytes - b.total_bytes) DESC;
```

---

## 38.4 IOPS Capacity and SSD vs HDD Tradeoffs

```
IOPS (I/O Operations Per Second) budget:

Random read IOPS consumed by:
  - Index scans (each page fetch = 1 random read)
  - Buffer pool cache misses
  - PITR recovery

Sequential read IOPS consumed by:
  - Sequential scans
  - VACUUM, ANALYZE
  - Checkpoint dirty page flushes

Cloud IOPS limits:
  AWS gp3: 3,000 IOPS baseline, 16,000 IOPS provisioned max
  AWS io2: up to 64,000 IOPS
  GCP pd-ssd: up to 100,000 IOPS (size-dependent)
```

```sql
-- Measure I/O operations from pg_statio_*
SELECT
    relname,
    heap_blks_read AS table_reads,    -- random reads (cache miss)
    heap_blks_hit  AS table_hits,     -- served from shared_buffers
    idx_blks_read  AS index_reads,
    idx_blks_hit   AS index_hits
FROM pg_statio_user_tables
ORDER BY heap_blks_read + idx_blks_read DESC
LIMIT 10;

-- track_io_timing = on gives actual I/O time in pg_stat_io (PG 16+)
SELECT backend_type, object, context,
       reads, read_time,
       writes, write_time
FROM pg_stat_io
WHERE reads > 0
ORDER BY read_time DESC;
```

---

## 38.5 RDS vs Aurora PostgreSQL Internals

### Amazon RDS PostgreSQL
- Standard PostgreSQL running on EC2 + EBS
- Multi-AZ: synchronous streaming replica, automatic failover (~30-60s)
- Storage: EBS, grows in 10 GB increments, max 64 TB
- Read replicas: async streaming, up to 15 per cluster (cross-region supported)
- Maintenance window: patch downtime ~30s for minor, potentially minutes for major

### Amazon Aurora PostgreSQL
- Shared distributed storage across 6 AZ copies (3 AZs × 2)
- Storage: automatically grows to 128 TB, no pre-provisioning
- Failover: ~30s (no replay needed — storage is shared)
- Read replicas: up to 15, all share same storage volume (no replica lag for writes)
- Aurora Global Database: < 1 second replication across regions

```
Key Aurora limits that surprise teams:
  - max_connections: CPU-based formula (r5.2xlarge ≈ 1300 connections)
  - No pg_basebackup: use Aurora snapshots instead
  - temp_file_limit applies per session
  - Some extensions unavailable (file_fdw, postgres_fdw to external hosts)
  - Aurora Serverless v2: scales from 0.5 ACU; cold start latency can spike
```

### When to choose which

| Scenario | Recommendation |
|----------|---------------|
| Lift-and-shift, need exact PG compatibility | RDS |
| Variable workload, need auto-scaling | Aurora Serverless v2 |
| Read-heavy with many replicas | Aurora (shared storage = no replica lag) |
| Cross-region DR with < 1s RPO | Aurora Global |
| Budget-sensitive, predictable load | RDS (cheaper for stable workloads) |
| Need pg_basebackup / custom extensions | RDS |

---

## 38.6 TCO Analysis: Self-Managed vs Managed

```
Cost components for self-managed PostgreSQL:
  Infrastructure: EC2/VM costs
  Storage: EBS or local NVMe
  HA: additional instances + load balancer
  Engineering: DBA time (highest cost!)
    - Setup: 40-80 hours
    - Ongoing: 10-20 hours/month per cluster
    - Incidents: unpredictable

Cost components for managed (RDS/Aurora):
  Service premium: typically 2-3× raw infrastructure cost
  Savings: DBA time (80% reduction for routine ops)
  Limitations: less control, version lag, extension restrictions

Break-even analysis:
  DBA hourly cost: $150/hr
  Monthly DBA hours for self-managed: 20 hrs = $3,000/month
  RDS premium over raw EC2: $500-$1,500/month

For most teams: managed service is cheaper when DBA time is included.
Self-managed makes sense for: > 10 TB, heavy customization, cost at massive scale.
```

---

## 38.7 Rightsizing PostgreSQL Instances

```
Symptoms → Resource constraint → Action

High CPU + active connections near max
  → CPU bound → scale up (more cores) or add read replicas

High memory + low cache hit rate (< 95%)
  → Memory bound → increase shared_buffers or scale up RAM

High IOPS + many disk reads in pg_statio
  → I/O bound → provision more IOPS, add SSD, or increase cache

Connections waiting in PgBouncer
  → Connection saturation → not necessarily CPU — check if queries are slow

Replication lag growing
  → Replica can't keep up → scale up replica, reduce write load, or split reads
```

```sql
-- Identify if CPU or I/O is the bottleneck
-- High CPU: many active backends, low wait events
-- High I/O: many backends with wait_event_type = 'IO'

SELECT wait_event_type, count(*)
FROM pg_stat_activity
WHERE state = 'active'
GROUP BY wait_event_type;
-- If IO >> CPU → storage bottleneck
-- If CPU (NULL wait_event) >> IO → compute bottleneck
```

---

## 38.8 Partitioning and Archival for Capacity

```sql
-- The most impactful capacity tool: archive old data

-- Pattern 1: Move old partitions to cold storage
-- Using pg_partman retention (Chapter 37) or manually:
ALTER TABLE orders DETACH PARTITION orders_2022;
-- Now export to S3, Glacier, or cold storage
\COPY orders_2022 TO '/archive/orders_2022.csv' CSV;
DROP TABLE orders_2022;

-- Pattern 2: Tablespaces for tiered storage
-- Move older data to cheaper slower disk
CREATE TABLESPACE cold_storage LOCATION '/mnt/cold_disk';
ALTER TABLE orders_2022 SET TABLESPACE cold_storage;

-- Pattern 3: FDW to query archived data
CREATE EXTENSION file_fdw;
CREATE SERVER csv_server FOREIGN DATA WRAPPER file_fdw;
CREATE FOREIGN TABLE orders_2022_archive (
    order_id INT, customer_id INT, created_at TIMESTAMPTZ, amount NUMERIC
)
SERVER csv_server
OPTIONS (filename '/archive/orders_2022.csv', format 'csv', header 'true');
```

---

## 38.9 Scaling Decision Framework

```
Single-node PostgreSQL limits (rough):
  CPU: up to ~96 cores (diminishing returns above 32 due to lock contention)
  RAM: up to ~6 TB (practical limit ~512 GB for shared_buffers benefit)
  Storage: up to ~100 TB with tablespaces
  Connections: ~2,000 (with PgBouncer)
  Write throughput: ~50,000-200,000 TPS on NVMe

When to scale horizontally (beyond single node):
  → Writes exceed single-node WAL write throughput
  → Storage > 10 TB and growing fast
  → Read replicas can't absorb read load
  → Compliance requires geographic distribution

Horizontal scaling options:
  Read load:   Streaming read replicas
  Write scale: Citus (sharding), CockroachDB, YugabyteDB
  Mixed:       Partitioning + multiple primaries per shard
```

---

## 38.10 Cloud-Specific Operational Gotchas

```
AWS RDS:
  - Reboot required to change static parameters (max_connections, shared_buffers)
  - Enhanced Monitoring: 1-second OS metrics (costs extra)
  - Performance Insights: query-level performance (14 days free, 2yr costs)
  - RDS Proxy adds ~1ms latency; skip for sub-1ms SLA requirements
  - Multi-AZ failover switches DNS; apps need reconnect logic

Aurora:
  - Aurora fast clone: instant copy of cluster for testing
  - Backtrack: rewind cluster to a point-in-time without restore
  - Aurora DSQL (2024): distributed, serverless, Postgres-compatible
  - Writer endpoint vs reader endpoint vs cluster endpoint — use the right one

GCP Cloud SQL:
  - PITR enabled separately; WAL stored in GCS
  - Private IP requires VPC peering; Public IP needs authorized networks
  - Maintenance can cause 2-3 minute downtime; schedule carefully

Azure Database for PostgreSQL:
  - Flexible Server: better than Single Server (don't use Single Server)
  - Zone redundant HA: synchronous standby, ~60-120s failover
  - Read replicas: can be promoted, stops replication permanently
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| IOPS | Input/Output Operations Per Second — storage throughput metric |
| Cache hit ratio | % of page reads served from shared_buffers vs disk |
| Aurora shared storage | Aurora's 6-copy distributed storage layer, shared by all instances |
| TCO | Total Cost of Ownership — includes infrastructure + operational labor |
| Rightsizing | Matching instance size to actual workload requirements |
| Tablespace | Named storage location; enables tiered storage for cold data |
| Aurora Serverless v2 | Aurora that scales capacity automatically in Aurora Capacity Units (ACUs) |
| PITR | Point-in-Time Recovery — restore to any second within retention window |

---

## Practice Questions

1. Your PostgreSQL cache hit rate drops from 99% to 91% over two weeks. What is the likely cause and what are three responses?
2. Compare RDS Multi-AZ vs Aurora for a workload needing < 30 seconds failover and 10 read replicas. Which do you choose?
3. A table is growing at 50 GB/month. You have 6 months before storage is exhausted. What is your action plan?
4. An engineer wants to use file_fdw on RDS PostgreSQL. Will it work? What are the RDS-specific restrictions?
5. Your Aurora PostgreSQL instance is hitting connection limits during peak traffic despite PgBouncer. What is the Aurora-specific reason and fix?
6. At what workload scale does it make sense to move from a single PostgreSQL primary with read replicas to Citus sharding?

---

**← Previous:** [37_extension_ecosystem.md](37_extension_ecosystem.md)  
**Next →** [39_operational_runbooks.md](39_operational_runbooks.md)
