# Chapter 18 — Vacuuming & Maintenance

PostgreSQL requires regular maintenance to stay healthy. Without it, tables bloat, queries slow down, and in the worst case the database stops accepting writes. This chapter covers everything you need to keep PostgreSQL running smoothly.

---

## 18.1 Why VACUUM Exists

As covered in Chapters 7 and 12, PostgreSQL's MVCC model never overwrites rows — it creates new versions and marks old ones as dead. Over time:

```
Before any changes:
Page: [row1(live)] [row2(live)] [row3(live)]

After many UPDATEs/DELETEs:
Page: [row1(dead)] [row1_v2(dead)] [row1_v3(live)] [row2(dead)] [row3(dead)]
       └── 2/3 of the page is wasted space
```

**VACUUM** reclaims dead tuple space and performs other critical housekeeping.

---

## 18.2 What VACUUM Does

```sql
VACUUM employees;
```

VACUUM performs these tasks:
1. **Removes dead tuples** — marks the space as reusable (updates FSM — Free Space Map)
2. **Updates visibility map** — marks pages where all tuples are visible to all transactions (speeds up index-only scans and future VACUUMs)
3. **Advances frozen XID** — prevents transaction ID wraparound
4. **Updates pg_stat_user_tables** — refreshes row count estimates

What regular `VACUUM` does NOT do:
- Does not return space to the OS (pages stay allocated)
- Does not defragment pages
- Does not rebuild indexes

---

## 18.3 VACUUM FULL — Reclaiming Space to OS

```sql
VACUUM FULL employees;
```

`VACUUM FULL`:
- Rewrites the entire table into a new file
- Returns freed space to the OS
- Rebuilds all indexes

**CRITICAL WARNING**: `VACUUM FULL` takes an `ACCESS EXCLUSIVE` lock — **the entire table is locked for the duration**. No reads or writes allowed. On a large table this can take hours.

Use only when:
- You deleted a massive portion of a table (e.g., deleted 90% of rows) and need the disk space back
- Scheduled maintenance window, low traffic

**Alternative**: `pg_repack` — rewrites the table concurrently without locks:
```bash
pg_repack -U postgres -d mydb -t employees
```

---

## 18.4 autovacuum — The Background Maintenance Daemon

PostgreSQL runs **autovacuum** automatically so you don't have to manually VACUUM every table.

Autovacuum triggers VACUUM on a table when:
```
dead_tuples > autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor × n_live_tuples
```

Default thresholds:
```ini
autovacuum_vacuum_threshold = 50       # min dead tuples before triggering
autovacuum_vacuum_scale_factor = 0.2   # 20% of table size
```

Example: table with 10,000 rows → vacuum triggers when dead tuples > 50 + 0.2 × 10,000 = **2,050**

### Autovacuum Configuration

```ini
# postgresql.conf

autovacuum = on                          # NEVER turn off
autovacuum_max_workers = 3               # parallel autovacuum workers
autovacuum_naptime = 1min                # check for tables needing vacuum every minute
autovacuum_vacuum_threshold = 50
autovacuum_vacuum_scale_factor = 0.2     # reduce to 0.01 for large tables
autovacuum_analyze_threshold = 50
autovacuum_analyze_scale_factor = 0.1

# Prevent autovacuum from hammering I/O
autovacuum_vacuum_cost_delay = 2ms       # pause between work units (20ms default = too slow)
autovacuum_vacuum_cost_limit = 200       # work units before pause
```

### Per-Table Autovacuum Settings

For large tables, the default 20% threshold means autovacuum won't run until millions of dead tuples accumulate. Override per-table:

```sql
-- High-churn table: vacuum more aggressively
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.01,   -- 1% threshold
    autovacuum_vacuum_threshold = 100,
    autovacuum_analyze_scale_factor = 0.01
);

-- Critical table: vacuum very frequently
ALTER TABLE accounts SET (
    autovacuum_vacuum_scale_factor = 0.001,
    autovacuum_vacuum_cost_delay = 0         -- no throttling
);
```

---

## 18.5 Monitoring Bloat and Vacuum Status

```sql
-- Vacuum status for all tables
SELECT schemaname,
       tablename,
       n_live_tup,
       n_dead_tup,
       round(n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100, 1) AS dead_pct,
       last_vacuum,
       last_autovacuum,
       last_analyze,
       last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;

-- Tables that need vacuum most urgently (highest dead %)
SELECT tablename, n_dead_tup, n_live_tup,
       round(n_dead_tup::numeric / nullif(n_live_tup, 0) * 100, 1) AS dead_ratio_pct
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY dead_ratio_pct DESC;

-- Check if autovacuum is currently running
SELECT pid, relid::regclass, phase, heap_blks_scanned, heap_blks_vacuumed
FROM pg_stat_progress_vacuum;
```

---

## 18.6 VACUUM FREEZE and Transaction ID Wraparound

PostgreSQL uses 32-bit transaction IDs (XIDs). After ~2.1 billion transactions, XIDs wrap around. If a row's `xmin` becomes "in the future" — the row disappears.

PostgreSQL prevents this via **FREEZE**: mark old rows as permanently visible (set `xmin` to a special frozen XID).

```ini
# postgresql.conf
autovacuum_freeze_max_age = 200000000   # freeze rows older than 200M transactions
vacuum_freeze_min_age = 50000000        # minimum age to freeze a row
```

### Monitoring XID Age — Critical

```sql
-- Check how close tables are to wraparound (MUST MONITOR)
SELECT datname,
       age(datfrozenxid) AS db_xid_age,
       2100000000 - age(datfrozenxid) AS xids_remaining
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- Per-table XID age
SELECT relname,
       age(relfrozenxid) AS table_xid_age,
       pg_size_pretty(pg_total_relation_size(oid))
FROM pg_class
WHERE relkind = 'r'
ORDER BY age(relfrozenxid) DESC
LIMIT 20;
```

**Alert thresholds**:
- `age > 1,500,000,000`: Warning — vacuum should be running
- `age > 1,900,000,000`: Critical — PostgreSQL enters read-only mode soon
- `age = 2,100,000,000`: Emergency — PostgreSQL **refuses all writes**

### Emergency Manual FREEZE

```sql
-- Force freeze on a specific table
VACUUM FREEZE employees;

-- Force freeze on entire database (heavy operation)
VACUUM FREEZE;
```

---

## 18.7 ANALYZE — Keeping Statistics Fresh

`ANALYZE` updates the statistics used by the query planner. Without fresh statistics, the planner makes bad estimates → bad query plans.

```sql
-- Analyze one table
ANALYZE employees;

-- Analyze one column
ANALYZE employees (salary, dept_id);

-- Analyze entire database
ANALYZE;
```

Autovacuum runs `ANALYZE` automatically (controlled by `autovacuum_analyze_*` settings).

Run manual `ANALYZE` after:
- Large bulk inserts or deletes
- Major data changes (> 10% of table)
- Schema changes that add/alter columns

---

## 18.8 REINDEX — Rebuilding Indexes

Indexes can become bloated or corrupt:

```sql
-- Rebuild one index (takes lock in older versions)
REINDEX INDEX idx_employees_email;

-- Rebuild all indexes on a table
REINDEX TABLE employees;

-- Rebuild all indexes in the database
REINDEX DATABASE mydb;

-- Concurrent rebuild (PostgreSQL 12+, no lock)
REINDEX INDEX CONCURRENTLY idx_employees_email;
REINDEX TABLE CONCURRENTLY employees;
```

Run `REINDEX` when:
- Index bloat is high (check with `pg_stat_user_indexes` size)
- Index corruption detected
- After `VACUUM FULL` (happens automatically)

---

## 18.9 CLUSTER — Physically Reorder a Table

`CLUSTER` rewrites a table in physical order matching an index — improving sequential access performance for range queries.

```sql
-- Reorder employees by dept_id (good if you often query by department)
CLUSTER employees USING idx_employees_dept_id;

-- Remember the cluster index for future CLUSTER calls
CLUSTER employees;  -- uses the last-specified index
```

**Warning**: `CLUSTER` takes `ACCESS EXCLUSIVE` lock. Use `pg_repack` for online reordering.

After `CLUSTER`, queries like `WHERE dept_id = 10` benefit from better physical locality — pages are in order → fewer I/Os.

---

## 18.10 Maintenance Schedule Recommendations

### Automatic (autovacuum handles these — verify it's working):
- Regular VACUUM and ANALYZE
- XID freeze for most tables

### Manual / Periodic:
```sql
-- Weekly: check bloat
SELECT tablename,
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
       n_dead_tup, last_autovacuum
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;

-- Weekly: check unused indexes
SELECT indexname, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0 AND indexname NOT LIKE '%pkey%';

-- Monthly: check XID age (ALERT if > 1.5B)
SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;

-- Monthly: check for index bloat and reindex if > 30% bloat
-- Use pgstattuple extension for precise bloat measurement
CREATE EXTENSION pgstattuple;
SELECT * FROM pgstattuple('idx_employees_email');
```

---

## 18.11 Table Maintenance Cheatsheet

```sql
-- Remove dead rows from table (fast, online)
VACUUM table_name;

-- Remove dead rows + return space to OS (locks table)
VACUUM FULL table_name;

-- Freeze old rows (prevent XID wraparound)
VACUUM FREEZE table_name;

-- Update planner statistics
ANALYZE table_name;

-- Vacuum + analyze in one pass
VACUUM ANALYZE table_name;

-- Rebuild index (concurrent, no lock)
REINDEX INDEX CONCURRENTLY index_name;

-- Check bloat without locking
SELECT * FROM pgstattuple('table_name');

-- Online table rewrite (no lock, external tool)
pg_repack -t table_name
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| Dead tuple | Old row version no longer visible to any transaction |
| Table bloat | Wasted space from accumulated dead tuples |
| VACUUM | Reclaims dead tuple space, updates FSM and visibility map |
| VACUUM FULL | Rewrites table file to reclaim space to OS; requires full lock |
| autovacuum | Background daemon that runs VACUUM/ANALYZE automatically |
| ANALYZE | Updates planner statistics from current table data |
| FREEZE | Marks old rows permanently visible to prevent XID wraparound |
| XID wraparound | 32-bit transaction counter overflow — triggers emergency freeze |
| FSM | Free Space Map — tracks pages with available space |
| Visibility Map | Tracks pages where all tuples are visible to all transactions |

---

## Practice Questions

1. Why does VACUUM not return space to the OS by default?
2. You deleted 80% of rows from a 100 GB table. The table still shows 100 GB on disk. What do you do?
3. Your query planner is choosing bad plans on a recently-bulk-loaded table. What is the likely cause and fix?
4. What happens if XID age reaches 2.1 billion and you haven't run VACUUM FREEZE?
5. What is the difference between `autovacuum_vacuum_scale_factor = 0.2` for a 100-row table vs a 100M-row table?
6. You want to reorder a 500 GB production table to match an index, but cannot afford downtime. What tool do you use?

---

**← Previous:** [17_high_availability.md](17_high_availability.md)  
**Next →** [19_connection_pooling.md](19_connection_pooling.md)
