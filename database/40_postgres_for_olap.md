# Chapter 40 — PostgreSQL for OLAP & Hybrid Workloads

PostgreSQL started as an OLTP database, but modern deployments use it for analytical queries too. This chapter covers the architecture for hybrid OLTP/OLAP, parallel query internals, columnar storage, foreign data wrappers, DuckDB integration, and where the boundaries of PostgreSQL's analytical capabilities lie.

---

## 40.1 OLTP vs OLAP Workload Characteristics

| Dimension | OLTP | OLAP |
|-----------|------|------|
| Query pattern | Point lookups, short transactions | Full/partial scans, aggregations |
| Data access | Few rows per query | Millions of rows per query |
| Concurrency | Thousands of concurrent users | Tens of concurrent analytical queries |
| Latency target | < 10ms | Seconds to minutes acceptable |
| Index strategy | Many targeted indexes | Few or no indexes; seq scan preferred |
| Bottleneck | Lock contention, connection overhead | CPU, memory, I/O bandwidth |
| Normalization | Normalized (3NF+) | Denormalized (star/snowflake schema) |

The challenge: running both workloads on the same PostgreSQL instance. OLAP queries cause:
- Large sequential scans that evict OLTP data from shared_buffers
- Long-running transactions that hold back VACUUM
- High work_mem consumption per query

---

## 40.2 Parallel Query Architecture

PostgreSQL's parallel query infrastructure splits a single query across multiple worker processes.

```
Leader process (Gather node)
    ├── Parallel Worker 1
    ├── Parallel Worker 2
    └── Parallel Worker 3
        → Each scans a subset of the table
        → Local aggregation (Partial HashAggregate)
        → Results sent to leader via shared memory IPC
        → Leader finalizes (Finalize HashAggregate)
```

```sql
-- Check if a query uses parallelism
EXPLAIN SELECT customer_id, SUM(amount)
FROM orders
GROUP BY customer_id;
/*
Finalize HashAggregate
  ->  Gather
        Workers Planned: 4
        ->  Partial HashAggregate
              ->  Parallel Seq Scan on orders
*/

-- Control parallelism
SET max_parallel_workers_per_gather = 4;
SET parallel_setup_cost = 1000;    -- lower = more eager to parallelize
SET parallel_tuple_cost = 0.1;

-- Disable for OLTP (avoid parallel overhead on small queries)
SET max_parallel_workers_per_gather = 0;
```

### What can and cannot parallelize

```sql
-- ✅ Can parallelize:
-- Sequential scans, aggregations, joins (hash join, merge join)
-- CREATE INDEX, CREATE TABLE AS SELECT
-- VACUUM (from PG 13, parallel vacuum on indexes)

-- ❌ Cannot parallelize:
-- Queries using VOLATILE functions (Chapter 31)
-- Queries writing data (INSERT, UPDATE, DELETE)
-- Queries on temporary tables (they are process-local)
-- Cursor-based queries
-- Queries with subplans that contain non-parallelizable nodes
```

---

## 40.3 Partition-Wise Aggregation and Join

When tables are partitioned, PostgreSQL can push aggregation and joins down into each partition — each partition aggregated independently, then results merged.

```sql
-- Enable partition-wise features
SET enable_partitionwise_aggregate = on;
SET enable_partitionwise_join = on;

-- Example: orders partitioned by month
EXPLAIN SELECT DATE_TRUNC('month', created_at), SUM(amount)
FROM orders  -- partitioned table
GROUP BY 1;
/*
With partition-wise aggregate ON:
  Append
    -> HashAggregate (partial, on orders_2024_01)
    -> HashAggregate (partial, on orders_2024_02)
    ...
  -> Gather + Finalize HashAggregate

Benefits:
- Each partition processed independently → better cache locality
- Enables pruning: only relevant partitions are scanned
- Combines with parallelism: each partition can use parallel workers
*/
```

---

## 40.4 JIT Compilation Deep Dive

JIT (Just-In-Time compilation) translates query expressions into native machine code using LLVM. The benefit is significant for queries that evaluate the same expression millions of times.

```sql
-- JIT cost threshold
SHOW jit_above_cost;         -- default 100000 (plan cost units)
SHOW jit_optimize_above_cost; -- default 500000 (enables LLVM optimization passes)

-- See JIT impact in EXPLAIN ANALYZE
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(amount * 0.9 + tax * 1.1 - discount)
FROM orders
WHERE created_at > '2024-01-01';
/*
JIT:
  Functions: 4
  Options: Inlining true, Optimization true, Expressions true, Deforming true
  Timing: Generation 8.2ms, Inlining 22.1ms, Optimization 45.3ms,
          Emission 18.4ms, Total 94.0ms
Execution Time: 340.2ms
*/
-- Total 94ms of JIT overhead amortized over ~10 million expression evaluations
-- Without JIT: ~2000ms (interpreter overhead per row)
-- With JIT: 340ms — 6× faster
```

```sql
-- JIT expressions: what gets compiled
-- Expressions: WHERE clause predicates, projection expressions
-- Inlining: SQL functions inlined into the query
-- Deforming: tuple deforming (column extraction) compiled

-- When JIT hurts (OLTP queries, few rows):
SET jit = off;  -- per session for OLTP connections
-- Or set per role: ALTER ROLE app_user SET jit = off;
-- Or increase threshold: SET jit_above_cost = 1000000;
```

---

## 40.5 Columnar Storage — Hydra and pg_mooncake

Row storage (PostgreSQL's default) is efficient for OLTP: fetch all columns of one row. Columnar storage is efficient for OLAP: fetch one column of all rows.

```
Row storage (heap):
  Row 1: [id=1, name="Alice", amount=100, status="shipped", created_at=...]
  Row 2: [id=2, name="Bob",   amount=200, status="pending", created_at=...]

Columnar storage:
  amount column: [100, 200, 350, 99, ...]   ← contiguous, compresses 10:1
  status column: [shipped, pending, ...]    ← dictionary encoded
```

### Hydra Columnar (open source)

```sql
-- Install Hydra columnar extension
CREATE EXTENSION columnar;

-- Create a columnar table
CREATE TABLE orders_columnar (
    order_id    BIGINT,
    customer_id BIGINT,
    created_at  TIMESTAMPTZ,
    amount      NUMERIC,
    status      TEXT
) USING columnar;

-- Convert existing heap table to columnar
SELECT alter_table_set_access_method('orders_large', 'columnar');

-- Columnar settings
SELECT alter_columnar_table_set('orders_columnar',
    chunk_group_row_limit => 10000,
    stripe_row_limit => 150000,
    compression => 'zstd',
    compression_level => 3
);
```

```sql
-- Analytical query comparison
-- Heap: seq scan, reads entire row width × row count
-- Columnar: only reads the queried columns → much less I/O

EXPLAIN ANALYZE
SELECT AVG(amount), status
FROM orders_columnar  -- only reads amount + status columns
WHERE created_at > '2024-01-01'
GROUP BY status;
-- Typical: 10-30× less I/O than heap for column-selective queries
```

---

## 40.6 Foreign Data Wrappers for OLAP

FDWs let PostgreSQL query external data sources as if they were local tables.

```sql
-- postgres_fdw: query another PostgreSQL database
CREATE EXTENSION postgres_fdw;
CREATE SERVER analytics_db FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'analytics.internal', port '5432', dbname 'analytics');
CREATE USER MAPPING FOR current_user SERVER analytics_db
    OPTIONS (user 'reader', password 'secret');
CREATE FOREIGN TABLE remote_events (
    event_id BIGINT,
    event_type TEXT,
    occurred_at TIMESTAMPTZ
) SERVER analytics_db OPTIONS (schema_name 'public', table_name 'events');

-- Query as if local — predicates pushed down to remote server
SELECT event_type, count(*) FROM remote_events
WHERE occurred_at > NOW() - INTERVAL '7 days'
GROUP BY event_type;
```

```sql
-- file_fdw: query CSV/log files as tables
CREATE EXTENSION file_fdw;
CREATE SERVER csv_files FOREIGN DATA WRAPPER file_fdw;
CREATE FOREIGN TABLE nginx_logs (
    timestamp TEXT, method TEXT, path TEXT, status INT, bytes BIGINT
)
SERVER csv_files
OPTIONS (filename '/var/log/nginx/access.log', format 'csv', delimiter ' ');

-- parquet_s3_fdw: query Parquet files directly from S3 (third-party)
-- Allows SQL over your data lake without ETL
```

---

## 40.7 DuckDB as a PostgreSQL Sidecar

DuckDB is an in-process analytical database optimized for OLAP. It can be integrated alongside PostgreSQL for hybrid architectures.

### Pattern 1: Application-level routing

```python
# Route OLTP queries to PostgreSQL, OLAP to DuckDB
import psycopg2
import duckdb

pg_conn = psycopg2.connect(DSN)
duck_conn = duckdb.connect()

def query(sql, olap=False):
    if olap:
        return duck_conn.execute(sql).fetchdf()
    else:
        cur = pg_conn.cursor()
        cur.execute(sql)
        return cur.fetchall()

# OLAP: DuckDB reads Parquet files from S3 or local
duck_conn.execute("CREATE VIEW orders AS SELECT * FROM parquet_scan('s3://bucket/orders/*.parquet')")
result = query("SELECT status, SUM(amount) FROM orders GROUP BY status", olap=True)
```

### Pattern 2: DuckDB reads from PostgreSQL via postgres scanner

```python
import duckdb

conn = duckdb.connect()

# DuckDB can directly query PostgreSQL tables
conn.execute("INSTALL postgres; LOAD postgres;")
conn.execute("""
    ATTACH 'dbname=mydb host=localhost user=reader password=secret'
    AS pg_db (TYPE POSTGRES, READ_ONLY);
""")

# DuckDB pulls data from PostgreSQL and applies columnar OLAP engine
result = conn.execute("""
    SELECT customer_id, SUM(amount), COUNT(*)
    FROM pg_db.public.orders
    WHERE created_at > '2024-01-01'
    GROUP BY customer_id
    ORDER BY SUM(amount) DESC
    LIMIT 100
""").fetchdf()
```

### When to use DuckDB sidecar

- Ad-hoc analytical queries on existing PostgreSQL data
- Avoid impact of OLAP queries on production PostgreSQL
- Need columnar performance without migrating tables
- ETL transformations using SQL (DuckDB handles large datasets in memory)

---

## 40.8 OLTP/OLAP Routing Architecture

```
                         Application Tier
                               ↓
                    Query Router / ORM Layer
                    (identifies query type)
                        /          \
                   OLTP            OLAP
                     ↓               ↓
              PostgreSQL       Read Replica +
               Primary         DuckDB/Hydra
               (writes)        (analytics)
                     ↓               ↓
              Streaming      Logical Replication
              Replica         or ETL Pipeline
                                    ↓
                              Data Warehouse
                           (Redshift, BigQuery,
                            Snowflake, ClickHouse)
```

```sql
-- On PostgreSQL read replica: set resource limits for OLAP queries
-- postgresql.conf on replica:
-- max_parallel_workers_per_gather = 8
-- work_mem = 512MB
-- jit = on
-- enable_partitionwise_aggregate = on

-- Separate the OLAP replica via PgBouncer routing:
[databases]
mydb_oltp = host=primary port=5432 dbname=mydb
mydb_olap = host=replica port=5432 dbname=mydb pool_size=10
```

---

## 40.9 When PostgreSQL Is Not Enough for OLAP

PostgreSQL is excellent for analytical queries up to ~1 TB and moderate concurrency. Beyond these limits, consider purpose-built systems:

| Scenario | Recommendation |
|----------|---------------|
| > 1 TB analytical data | ClickHouse, Redshift, BigQuery |
| Sub-second queries on billions of rows | ClickHouse, Apache Pinot |
| Real-time stream analytics | Apache Flink + ClickHouse |
| PostgreSQL-compatible distributed OLAP | Citus, YugabyteDB |
| Time-series at petabyte scale | TimescaleDB + tiered storage, InfluxDB |
| Notebook/exploratory analytics | DuckDB (in-process) |

PostgreSQL with Citus, Hydra columnar, or TimescaleDB can extend the range significantly before requiring a separate OLAP system.

---

## 40.10 Analytical Query Optimization Checklist

```sql
-- 1. Use EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) — understand every node
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT ...;

-- 2. Check for sequential scans that should use indexes
-- For OLAP: seq scan on large tables is often correct (don't fight it)
-- For selective OLAP queries: consider partial indexes or partition pruning

-- 3. Verify partition pruning is working
EXPLAIN SELECT * FROM orders WHERE created_at BETWEEN '2024-01-01' AND '2024-03-31';
-- Should show: Append with only relevant partitions, not all of them

-- 4. Ensure parallel query is engaged
-- Look for: Gather, Parallel Seq Scan, Partial HashAggregate in plan

-- 5. Check work_mem for hash joins and sort operations
SET work_mem = '1GB';  -- for single analytical session
EXPLAIN ANALYZE SELECT ...;
-- Look for: "Hash Batches: 1" (in-memory) vs "Hash Batches: 8" (spilling)

-- 6. For aggregation on many columns: consider GROUPING SETS vs separate queries

-- 7. Materialized views for pre-computed aggregates
CREATE MATERIALIZED VIEW daily_revenue AS
SELECT DATE_TRUNC('day', created_at) AS day,
       SUM(amount) AS revenue,
       COUNT(*) AS orders
FROM orders
GROUP BY 1;

CREATE UNIQUE INDEX ON daily_revenue (day);
REFRESH MATERIALIZED VIEW CONCURRENTLY daily_revenue;

-- 8. pg_stat_statements to find the top analytical queries by total time
SELECT query, calls, round(mean_exec_time) AS mean_ms,
       round(total_exec_time / 1000) AS total_sec
FROM pg_stat_statements
ORDER BY total_exec_time DESC LIMIT 10;
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| Parallel Seq Scan | A table scan split across multiple worker processes |
| Partial aggregate | Per-worker aggregation result, merged by the Gather node |
| Partition-wise aggregate | Aggregation pushed into each partition independently |
| JIT | LLVM compilation of query expressions to native code |
| Columnar storage | Stores data by column rather than by row; better for OLAP scans |
| Hydra | Open-source columnar access method extension for PostgreSQL |
| DuckDB | In-process analytical database; can read PostgreSQL data directly |
| FDW | Foreign Data Wrapper — PostgreSQL's mechanism for querying external data |
| Query routing | Directing OLTP queries to primary, OLAP queries to replica/DuckDB |

---

## Practice Questions

1. An analytical query scans 500M rows and takes 120 seconds. `EXPLAIN ANALYZE` shows no parallel workers. What are three reasons parallelism might not be engaged?
2. What is partition-wise aggregation and how does it improve performance for monthly reports on a range-partitioned table?
3. You need to run SQL queries against 2 years of Parquet files in S3 from within PostgreSQL. What technology enables this?
4. A team runs complex reporting queries on the OLTP primary, causing cache eviction and read latency spikes for application users. Design an architecture that separates these workloads.
5. When would you choose DuckDB over a PostgreSQL read replica for analytics? What are the tradeoffs?
6. JIT compilation adds 200ms overhead to a query that normally takes 50ms. What should you change and why?

---

**← Previous:** [39_operational_runbooks.md](39_operational_runbooks.md)  
**Next →** You have completed the Senior DBA module. See [README.md](README.md) for the full course index.
