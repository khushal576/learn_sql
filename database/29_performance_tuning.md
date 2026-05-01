# Chapter 29 — Performance Tuning

Performance tuning is the discipline of systematically finding and removing bottlenecks. This chapter covers PostgreSQL configuration, memory tuning, and the full toolkit for squeezing maximum performance from your database.

---

## 29.1 The Tuning Process

```
1. Measure baseline         → pg_stat_statements, EXPLAIN ANALYZE
2. Identify the bottleneck  → CPU? Memory? I/O? Locks? Network?
3. Make one change at a time
4. Measure again            → did it improve?
5. Repeat
```

Never tune by guessing. Every change must be validated with measurement.

---

## 29.2 Memory Configuration

The most impactful configuration parameters:

### shared_buffers

PostgreSQL's page cache — the most important memory setting.

```ini
# Default: 128MB (too small for production)
shared_buffers = 4GB   # Start with 25% of total RAM

# For a 32GB RAM server:
shared_buffers = 8GB
```

Pages served from `shared_buffers` are ~100× faster than disk reads. Larger = more cache hits.

**Note**: Don't set above 40% of RAM — the OS also needs memory for its own file cache (which PostgreSQL benefits from too).

### effective_cache_size

Hint to the planner about total available memory (shared_buffers + OS cache). Does not allocate memory.

```ini
effective_cache_size = 24GB  # ~75% of total RAM
# Tells the planner "there's ~24GB of cache available"
# Higher value → planner prefers index scans over seq scans
```

### work_mem

Memory for sort and hash operations **per operation per connection**:

```ini
# Default: 4MB (too small — causes spilling to disk)
work_mem = 64MB

# WARNING: This multiplies by concurrent connections × operations per query
# 100 connections × 5 operations × 64MB = 32GB potential usage
# Don't set globally if you have many connections
```

Set globally conservatively, override per-session for analytics:

```sql
-- For a heavy analytical query
SET work_mem = '512MB';
SELECT ... ORDER BY ... GROUP BY ...;
RESET work_mem;
```

Check if queries are spilling to disk (bad):
```sql
-- log_temp_files = 0 in postgresql.conf logs any temp file creation
-- Also visible in EXPLAIN ANALYZE:
-- -> Sort  (cost=... actual ...)
--      Sort Method: external merge  Disk: 1024kB  ← spilling!
--      Sort Method: quicksort  Memory: 512kB      ← good, in memory
```

### maintenance_work_mem

Memory for VACUUM, CREATE INDEX, ALTER TABLE:

```ini
maintenance_work_mem = 1GB  # Default 64MB is too small for large indexes
```

Higher = faster index builds and VACUUM.

---

## 29.3 I/O Configuration

### random_page_cost

Controls how the planner weighs random vs sequential I/O:

```ini
# Default: 4.0 (assumes HDD where random I/O is ~4× slower than sequential)
# For SSD:
random_page_cost = 1.1

# For NVMe in cloud (very fast random I/O):
random_page_cost = 1.0
```

Lowering this makes the planner prefer index scans over sequential scans.

### effective_io_concurrency

How many concurrent I/O operations the OS can handle:

```ini
# HDD: 1-2
effective_io_concurrency = 1

# SSD: 100-200
effective_io_concurrency = 200

# NVMe: 400-1000
effective_io_concurrency = 400
```

Used for bitmap heap scans — higher = more prefetching.

### wal_compression

Compress WAL to reduce I/O:

```ini
wal_compression = on   # ~3× compression, minimal CPU cost
```

---

## 29.4 Connection and Parallelism

### max_connections

```ini
# Default: 100. Each connection = ~5-10MB RAM.
max_connections = 200   # Use PgBouncer instead of increasing this too high
```

### max_parallel_workers_per_gather

Parallel query workers per query:

```ini
max_parallel_workers_per_gather = 4  # Default 2
max_parallel_workers = 8             # Total workers available
max_worker_processes = 16            # Total background workers
```

### min_parallel_table_scan_size

Minimum table size before parallel scan is considered:

```ini
min_parallel_table_scan_size = 8MB  # Default 8MB
min_parallel_index_scan_size = 512kB
```

---

## 29.5 Checkpoint and WAL Tuning

```ini
# More WAL before checkpoint = fewer checkpoints = smoother I/O
max_wal_size = 4GB           # Default 1GB — increase for write-heavy workloads
min_wal_size = 1GB
checkpoint_completion_target = 0.9  # Spread flushes over 90% of interval

# WAL buffers (usually auto is fine, set explicitly for busy servers)
wal_buffers = 64MB           # Default auto (~4MB) — increase for high-write workloads

# For durability vs performance tradeoff
synchronous_commit = on      # Default: safe
# synchronous_commit = off   # ~3× write speedup, up to 3× wal_writer_delay data loss risk
```

---

## 29.6 Autovacuum Tuning for Performance

Aggressive autovacuum prevents bloat and keeps statistics fresh:

```ini
autovacuum_max_workers = 5          # Default 3 — increase for many tables
autovacuum_vacuum_cost_delay = 2ms  # Default 20ms — reduce for faster vacuum
autovacuum_vacuum_cost_limit = 400  # Default 200 — double the work per unit time
autovacuum_vacuum_scale_factor = 0.05  # Default 0.2 — vacuum sooner (5% dead)
autovacuum_analyze_scale_factor = 0.02
```

---

## 29.7 The Production PostgreSQL Configuration Template

A starting point for a dedicated 32 GB RAM, 8-core server with SSD:

```ini
# Memory
shared_buffers = 8GB
effective_cache_size = 24GB
work_mem = 64MB
maintenance_work_mem = 2GB
huge_pages = try

# I/O
random_page_cost = 1.1
effective_io_concurrency = 200
wal_compression = on

# WAL & Checkpoints
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_completion_target = 0.9
wal_buffers = 64MB

# Connections & Parallelism
max_connections = 200
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
max_worker_processes = 16

# Autovacuum
autovacuum_max_workers = 5
autovacuum_vacuum_cost_delay = 2ms
autovacuum_vacuum_cost_limit = 400
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02

# Logging
log_min_duration_statement = 1000
log_checkpoints = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0
shared_preload_libraries = 'pg_stat_statements'

# Statistics
track_io_timing = on
track_counts = on
```

Use **PGTune** (pgtune.leopard.in.ua) to generate a config for your specific hardware.

---

## 29.8 Query-Level Tuning

### The tuning hierarchy

```
1. Fix the query (rewrite, add index)     ← biggest wins
2. Fix statistics (ANALYZE)               ← fixes bad plans
3. Adjust planner costs (random_page_cost)
4. Adjust memory (work_mem)
5. Adjust parallelism
6. Tune configuration
7. Upgrade hardware                        ← last resort
```

### Identifying queries to tune

```sql
-- Top 10 queries by total time (from pg_stat_statements)
SELECT
    left(query, 100) AS query,
    calls,
    round(total_exec_time::numeric / 1000, 2) AS total_sec,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    rows / calls AS avg_rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

### EXPLAIN flags for deep diagnosis

```sql
EXPLAIN (
    ANALYZE,      -- actually run the query
    BUFFERS,      -- show cache hits and reads
    VERBOSE,      -- show output columns and extra info
    SETTINGS,     -- show changed planner settings
    FORMAT TEXT   -- or JSON for programmatic parsing
)
SELECT ...;
```

### Reading EXPLAIN: the key signals

```
Rows removed by filter: 999999   ← index would help here
actual rows=0 (estimated rows=1000) ← stats mismatch → ANALYZE
Sort Method: external merge  Disk: 204800kB  ← increase work_mem
Hash Batches: 8              ← hash join spilling → increase work_mem
shared read=50000            ← lots of disk reads → check cache hit rate
```

---

## 29.9 Connection Pooling Impact on Performance

With 200 direct connections to PostgreSQL, performance degrades from context-switching overhead. Target < 4× CPU cores in active connections.

```
PostgreSQL server (16 CPUs):
  Optimal concurrent queries: ~16
  Max connections: 200
  But only ~16 actually run at once — rest queue in PgBouncer

PgBouncer (transaction mode):
  max_client_conn = 2000    ← app servers
  default_pool_size = 30    ← actual PostgreSQL connections
```

---

## 29.10 OS-Level Tuning

```bash
# Disable transparent huge pages (improves latency consistency)
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# Increase file descriptor limits
echo "postgres soft nofile 65536" >> /etc/security/limits.conf
echo "postgres hard nofile 65536" >> /etc/security/limits.conf

# vm.overcommit_memory — allow PostgreSQL to allocate memory freely
echo "vm.overcommit_memory = 2" >> /etc/sysctl.conf

# Swappiness — reduce kernel's tendency to swap
echo "vm.swappiness = 1" >> /etc/sysctl.conf

# Disk scheduler — use deadline or noop for SSDs
echo "deadline" > /sys/block/sda/queue/scheduler
```

---

## 29.11 Performance Monitoring Queries

```sql
-- Cache hit ratio (target > 99%)
SELECT round(
    sum(heap_blks_hit) * 100.0 /
    nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2
) AS cache_hit_pct
FROM pg_statio_user_tables;

-- Index usage ratio (tables with low index use = missing indexes)
SELECT relname,
       seq_scan, idx_scan,
       round(idx_scan * 100.0 / nullif(seq_scan + idx_scan, 0), 1) AS idx_pct
FROM pg_stat_user_tables
WHERE seq_scan + idx_scan > 100
ORDER BY idx_pct ASC;

-- Temp file usage (queries spilling to disk)
SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_size
FROM pg_stat_database
ORDER BY temp_bytes DESC;

-- Bloat estimate
SELECT schemaname, tablename,
       round(n_dead_tup * 100.0 / nullif(n_live_tup, 0), 1) AS dead_pct,
       last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY dead_pct DESC;
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| `shared_buffers` | PostgreSQL's in-memory page cache (25% of RAM) |
| `work_mem` | Memory per sort/hash operation |
| `effective_cache_size` | Planner hint: total cache available (shared_buffers + OS) |
| `random_page_cost` | Planner cost weight for random I/O (lower for SSD) |
| `maintenance_work_mem` | Memory for VACUUM, CREATE INDEX |
| PGTune | Tool that generates optimized postgresql.conf for your hardware |
| Spill to disk | Query operation that exceeds `work_mem` and writes to temp files |
| Cache hit ratio | % of page reads served from memory vs disk |

---

## Practice Questions

1. A 64 GB RAM server runs PostgreSQL. What would you set `shared_buffers`, `effective_cache_size`, and `work_mem` to?
2. EXPLAIN ANALYZE shows `Sort Method: external merge  Disk: 512MB`. What parameter do you increase and by how much?
3. Your planner keeps choosing seq scans on a table with indexes. The server has SSDs. What parameter should you adjust?
4. You have 500 app servers, each with a pool of 20 connections = 10,000 total. What should `max_connections` be and what else do you need?
5. What does `checkpoint_completion_target = 0.9` do and why is it important for I/O?
6. A query runs fine for the first time (cold cache) but slower on subsequent runs. Is this expected? What would you look for?

---

**← Previous:** [28_json_semistructured.md](28_json_semistructured.md)  
**Next →** [30_production_checklist.md](30_production_checklist.md)
