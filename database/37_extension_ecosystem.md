# Chapter 37 — PostgreSQL Extension Ecosystem

PostgreSQL's true power is its extension model — functionality that would require a separate database in other systems is a `CREATE EXTENSION` away. This chapter covers the extensions every Senior DBA must know: TimescaleDB, pgvector, PostGIS, pg_cron, pg_partman, and how to evaluate and vet extensions safely.

---

## 37.1 How Extensions Work

```sql
-- Extensions bundle SQL objects + shared libraries
-- They are installed per-database, not per-cluster

CREATE EXTENSION pgcrypto;           -- installs functions from pgcrypto.so
CREATE EXTENSION postgis;            -- installs types, functions, operators

-- View installed extensions
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE installed_version IS NOT NULL;

-- Extension objects live in pg_extension
SELECT extname, extversion, extrelocatable
FROM pg_extension;
```

### Trusted vs untrusted extensions

```sql
-- Trusted extensions: can be installed by any superuser-granted user
-- Listed as "trusted" in extension control file
CREATE EXTENSION pgcrypto;  -- trusted, non-superuser with GRANT can install

-- Untrusted extensions: require superuser (execute C code)
CREATE EXTENSION plpgsql;   -- trusted
CREATE EXTENSION file_fdw;  -- untrusted (reads OS files)

-- Create extension in a specific schema
CREATE EXTENSION postgis SCHEMA gis;
```

---

## 37.2 TimescaleDB — Time-Series at Scale

TimescaleDB extends PostgreSQL for time-series data with automatic partitioning (hypertables), compression, and continuous aggregates.

```sql
CREATE EXTENSION timescaledb;

-- Convert a regular table to a hypertable (partitioned by time automatically)
CREATE TABLE metrics (
    time        TIMESTAMPTZ NOT NULL,
    device_id   INT NOT NULL,
    temperature FLOAT,
    humidity    FLOAT
);

SELECT create_hypertable('metrics', 'time', chunk_time_interval => INTERVAL '1 day');
-- TimescaleDB automatically creates time-based partitions (chunks)
-- Each chunk is a separate table internally
```

```sql
-- Compression: compress old chunks automatically
ALTER TABLE metrics SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'device_id',
    timescaledb.compress_orderby = 'time DESC'
);

SELECT add_compression_policy('metrics', INTERVAL '7 days');
-- Chunks older than 7 days are automatically compressed
-- 90-95% storage reduction typical for time-series data

-- Retention: drop old data automatically
SELECT add_retention_policy('metrics', INTERVAL '90 days');
```

```sql
-- Continuous Aggregates: pre-computed materialized rollups
CREATE MATERIALIZED VIEW metrics_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    device_id,
    AVG(temperature) AS avg_temp,
    MAX(temperature) AS max_temp
FROM metrics
GROUP BY bucket, device_id;

-- Refresh policy: keep aggregates up to date
SELECT add_continuous_aggregate_policy('metrics_hourly',
    start_offset => INTERVAL '3 hours',
    end_offset   => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour');
```

```sql
-- Time-series specific functions
SELECT time_bucket('5 minutes', time) AS bucket,
       AVG(temperature)
FROM metrics
WHERE time > NOW() - INTERVAL '1 day'
GROUP BY bucket
ORDER BY bucket;

-- Interpolate gaps
SELECT time_bucket_gapfill('1 hour', time) AS bucket,
       locf(AVG(temperature))   -- last observation carried forward
FROM metrics
WHERE time BETWEEN NOW() - INTERVAL '24h' AND NOW()
GROUP BY bucket;
```

---

## 37.3 pgvector — AI Embeddings & Similarity Search

pgvector stores and searches vector embeddings — the foundation for semantic search, RAG systems, and recommendations.

```sql
CREATE EXTENSION vector;

-- Store embeddings (e.g. from OpenAI text-embedding-3-small = 1536 dimensions)
CREATE TABLE documents (
    id        BIGSERIAL PRIMARY KEY,
    content   TEXT,
    embedding vector(1536)
);

-- Insert with embedding (application generates the embedding)
INSERT INTO documents (content, embedding)
VALUES ('PostgreSQL is an open-source database', '[0.023, -0.142, ...]'::vector);
```

```sql
-- Nearest neighbor search (find most similar documents)
SELECT id, content,
       embedding <-> '[0.023, ...]'::vector AS distance   -- L2 distance
FROM documents
ORDER BY distance
LIMIT 5;

-- Distance operators:
-- <->  L2 distance (Euclidean)
-- <#>  negative inner product (for dot product similarity)
-- <=>  cosine distance (for normalized vectors, most common for embeddings)

-- Cosine similarity search:
SELECT id, content,
       1 - (embedding <=> query_embedding) AS similarity
FROM documents
ORDER BY similarity DESC
LIMIT 10;
```

### Indexes for vector search

```sql
-- IVFFlat: approximate nearest neighbor, fast build, moderate accuracy
-- lists = sqrt(row_count) is a good starting point
CREATE INDEX idx_docs_embedding_ivfflat
    ON documents USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

-- At query time: probes controls accuracy vs speed tradeoff
SET ivfflat.probes = 10;  -- higher = more accurate, slower

-- HNSW: better accuracy than IVFFlat, slower build, faster queries (PG 0.5+)
CREATE INDEX idx_docs_embedding_hnsw
    ON documents USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
-- m: connections per node (higher = better recall, more memory)
-- ef_construction: build-time search depth (higher = better quality index)

-- At query time:
SET hnsw.ef_search = 40;  -- higher = better recall, slower
```

```sql
-- Hybrid search: combine vector similarity + SQL filters
SELECT id, content,
       embedding <=> query_vec AS distance
FROM documents
WHERE category = 'technical'       -- SQL filter first (fast)
  AND created_at > '2024-01-01'
ORDER BY distance
LIMIT 10;
-- HNSW index handles vector part; btree handles SQL filters
```

---

## 37.4 PostGIS — Spatial Data

PostGIS adds geographic types, functions, and indexes — making PostgreSQL a full GIS database.

```sql
CREATE EXTENSION postgis;

-- Spatial types
CREATE TABLE locations (
    id       BIGSERIAL PRIMARY KEY,
    name     TEXT,
    geom     GEOMETRY(POINT, 4326),  -- SRID 4326 = WGS84 (lat/lon)
    boundary GEOMETRY(POLYGON, 4326)
);

-- Insert with WGS84 coordinates (longitude, latitude)
INSERT INTO locations (name, geom)
VALUES ('Eiffel Tower', ST_SetSRID(ST_MakePoint(2.2945, 48.8584), 4326));

-- Or from WKT:
INSERT INTO locations (name, geom)
VALUES ('Big Ben', ST_GeomFromText('POINT(-0.1246 51.5007)', 4326));
```

```sql
-- Spatial queries
-- Find all locations within 5km of a point
SELECT name, ST_Distance(geom::geography, 'SRID=4326;POINT(2.3 48.8)'::geography) AS dist_m
FROM locations
WHERE ST_DWithin(geom::geography, 'SRID=4326;POINT(2.3 48.8)'::geography, 5000)
ORDER BY dist_m;

-- ::geography cast handles curvature of Earth (meters)
-- ::geometry is flat-earth (degrees, faster)

-- Spatial join: find points within a polygon
SELECT l.name
FROM locations l
JOIN regions r ON ST_Within(l.geom, r.boundary)
WHERE r.name = 'Paris';
```

```sql
-- Spatial index (GiST — essential for performance)
CREATE INDEX idx_locations_geom ON locations USING GIST (geom);

-- Check if index is used:
EXPLAIN SELECT * FROM locations
WHERE ST_DWithin(geom::geography, 'SRID=4326;POINT(2.3 48.8)'::geography, 5000);
-- Should show: Index Scan using idx_locations_geom
```

---

## 37.5 pg_cron — Scheduled Jobs Inside PostgreSQL

```sql
-- Install (requires postgresql.conf: shared_preload_libraries = 'pg_cron')
CREATE EXTENSION pg_cron;

-- Schedule a job (cron syntax: minute hour day month weekday)
SELECT cron.schedule('nightly-vacuum', '0 2 * * *', 'VACUUM ANALYZE orders');
SELECT cron.schedule('hourly-stats',   '0 * * * *', 'ANALYZE customers');

-- Parameterized schedule
SELECT cron.schedule(
    'refresh-materialized-view',
    '*/15 * * * *',    -- every 15 minutes
    'REFRESH MATERIALIZED VIEW CONCURRENTLY summary_stats'
);

-- List scheduled jobs
SELECT * FROM cron.job;

-- View recent execution history
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- Remove a job
SELECT cron.unschedule('nightly-vacuum');
```

```sql
-- pg_cron runs in a specific database — set it in postgresql.conf:
-- cron.database_name = 'mydb'

-- For cross-database jobs: use dblink or foreign data wrappers
-- pg_cron can connect to other databases via connection string
SELECT cron.schedule_in_database(
    'other-db-job', '0 3 * * *',
    'VACUUM ANALYZE big_table',
    'analytics'   -- target database
);
```

---

## 37.6 pg_partman — Automated Partition Management

`pg_partman` automates creating, maintaining, and dropping time-based and serial partitions.

```sql
CREATE EXTENSION pg_partman;

-- Create a partitioned table managed by pg_partman
CREATE TABLE orders (
    order_id    BIGSERIAL,
    customer_id BIGINT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    amount      NUMERIC(12,2)
) PARTITION BY RANGE (created_at);

-- Hand management to pg_partman
SELECT partman.create_parent(
    p_parent_table  => 'public.orders',
    p_control       => 'created_at',
    p_type          => 'native',
    p_interval      => 'monthly',        -- one partition per month
    p_premake       => 3,                -- pre-create 3 future partitions
    p_start_partition => '2024-01-01'
);
```

```sql
-- Maintenance: run periodically (via pg_cron)
SELECT partman.run_maintenance();
-- Creates new partitions, drops old ones per retention config

-- Configure retention
UPDATE partman.part_config
SET retention = '12 months',      -- keep 12 months of data
    retention_keep_table = false   -- actually drop old partitions
WHERE parent_table = 'public.orders';

-- Check partition status
SELECT * FROM partman.part_config WHERE parent_table = 'public.orders';
SELECT * FROM partman.show_partitions('public.orders');
```

---

## 37.7 Useful Extensions Reference

| Extension | Purpose | Install |
|-----------|---------|---------|
| `pgcrypto` | Encryption functions (AES, PGP, bcrypt) | Built-in |
| `uuid-ossp` | UUID generation (v1, v3, v4, v5) | Built-in |
| `pg_trgm` | Trigram similarity search, fuzzy matching | Built-in |
| `hstore` | Key-value storage (JSONB is usually better) | Built-in |
| `ltree` | Hierarchical tree-path data | Built-in |
| `tablefunc` | crosstab/pivot functions | Built-in |
| `postgres_fdw` | Query remote PostgreSQL databases | Built-in |
| `file_fdw` | Query CSV/log files as tables | Built-in |
| `pg_stat_statements` | Query performance statistics | Built-in (preload) |
| `auto_explain` | Auto-log slow query plans | Built-in (preload) |
| `pg_partman` | Automated partition management | Third-party |
| `pg_cron` | Cron-style scheduled jobs | Third-party |
| `pgvector` | Vector similarity search (AI/ML) | Third-party |
| `TimescaleDB` | Time-series hypertables + compression | Third-party |
| `PostGIS` | Geospatial types, functions, indexes | Third-party |
| `pgaudit` | Detailed SQL audit logging | Third-party |
| `pg_repack` | VACUUM FULL without lock | Third-party |
| `pg_wait_sampling` | Wait event profiling | Third-party |
| `pg_stat_monitor` | Enhanced query stats with percentiles | Third-party |
| `anon` | Dynamic data masking / anonymization | Third-party |

---

## 37.8 Vetting Third-Party Extensions

Before installing an extension in production:

```bash
# 1. Check if it's in pgxn.org or well-maintained GitHub repo
# 2. Check PostgreSQL version compatibility
# 3. Check if it requires superuser or just GRANT

# 4. Inspect the control file (is it trusted?)
cat /usr/share/postgresql/15/extension/pg_partman.control
# superuser = false  ← can be installed by non-superuser (safer)
# trusted = true     ← can be installed by users with CREATE privilege

# 5. Review the C source for any dangerous operations
# Look for: system(), popen(), unlink(), setuid()

# 6. Test in staging under load before production install
# Extensions that preload (shared_preload_libraries) affect all connections

# 7. Check upgrade path: can you remove it if needed?
DROP EXTENSION pg_partman CASCADE;  -- does this leave orphaned objects?
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| Hypertable | TimescaleDB table with automatic time-based partitioning |
| Continuous aggregate | Pre-computed TimescaleDB materialized view refreshed incrementally |
| Embedding | Dense vector representation of data (text, image) for similarity search |
| HNSW | Hierarchical Navigable Small World — ANN index for vectors (high recall) |
| IVFFlat | Inverted file flat — ANN index for vectors (faster build, lower recall) |
| `ST_DWithin` | PostGIS function: true if two geometries are within a given distance |
| `vector_cosine_ops` | pgvector operator class for cosine similarity distance |
| Trusted extension | Can be installed by non-superuser; does not require C shared library load |

---

## Practice Questions

1. You need to store 100M sensor readings per day and query 5-minute averages efficiently. Which extension do you use and what specific features enable this?
2. Build a semantic search system: users type a query, you find the 10 most relevant documents. What PostgreSQL setup is required?
3. Your PostGIS query `SELECT * FROM stores WHERE ST_DWithin(geom, $point, 1000)` is doing a sequential scan despite having a GiST index. What is the likely cause?
4. What is the difference between HNSW and IVFFlat indexes in pgvector? When would you choose each?
5. You want to automatically drop partitions older than 6 months from an orders table. How do you configure this with pg_partman?
6. Before installing a third-party extension in production, what five checks do you perform?

---

**← Previous:** [36_compliance_advanced_security.md](36_compliance_advanced_security.md)  
**Next →** [38_capacity_planning_cloud.md](38_capacity_planning_cloud.md)
