-------------------------------------------------
-- CHAPTER 21
-- Advanced Performance Tuning
-------------------------------------------------
-- Understanding WHY a query is slow is the difference between
-- a mid-level and senior SQL engineer.
-- This chapter covers: reading EXPLAIN ANALYZE deeply,
-- join strategies (Nested Loop / Hash Join / Merge Join),
-- statistics and their impact on plan quality,
-- work_mem and sort/hash operations,
-- parallel query, VACUUM/ANALYZE internals,
-- and finding the slowest queries with pg_stat_statements.

-------------------------------------------------
-- PART 1: READING EXPLAIN ANALYZE DEEPLY
-------------------------------------------------

-- Always use EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) for full detail.

explain (analyze, buffers, verbose)
select e.ename, d.dname, e.sal
from emp e
join dept d on e.deptno = d.deptno
where e.sal > 1500;

-- Key terms to understand:
--
-- cost=0.00..12.50         startup cost .. total cost (in page-read units)
-- rows=5                   planner's estimated row count
-- width=25                 estimated avg bytes per row
-- actual time=0.020..0.045 real execution time in ms (startup..total)
-- actual rows=8            real row count
-- loops=1                  how many times this node ran
-- Buffers: shared hit=3    pages served from shared_buffers (RAM)
-- Buffers: shared read=1   pages read from disk
--
-- Large gap between rows (estimated) and actual rows = stale statistics.
-- Run ANALYZE to fix.

-------------------------------------------------

-- Node types and what they mean:

-- Seq Scan        — full table scan, reads every row
-- Index Scan      — uses index, fetches rows from heap for each match
-- Index Only Scan — satisfies query entirely from index (no heap access)
-- Bitmap Index Scan + Bitmap Heap Scan — batches index results, then fetches heap
-- Nested Loop     — for each outer row, scan inner (good for small inner sets)
-- Hash Join       — build hash table from inner, probe with outer (good for large sets)
-- Merge Join      — both sides sorted, merge them (good when both are pre-sorted)
-- Sort            — sort rows (can spill to disk if > work_mem)
-- Hash            — build a hash table (can spill to disk if > work_mem)
-- Aggregate       — GROUP BY / aggregate computation
-- Gather          — collects results from parallel workers

-------------------------------------------------
-- PART 2: JOIN STRATEGIES
-------------------------------------------------

-- Nested Loop Join
-- For each row in the outer table, scan (or index-scan) the inner table.
-- Best when: outer table is small, inner has an index on the join key.
-- Worst when: both tables are large (O(n*m) complexity).

explain analyze
select e.ename, d.dname
from emp e
join dept d on e.deptno = d.deptno;
-- On 14-row emp → likely Nested Loop (tiny tables)

-------------------------------------------------

-- Hash Join
-- Build a hash table from the smaller table, probe it with the larger.
-- Best when: no useful index, medium-to-large tables.
-- Memory controlled by work_mem — if hash table > work_mem, it batches to disk.

-- Force hash join (for testing plan differences):
set enable_nestloop = off;
explain analyze
select e.ename, d.dname
from emp e
join dept d on e.deptno = d.deptno;
reset enable_nestloop;

-------------------------------------------------

-- Merge Join
-- Both inputs must be sorted on the join key — merges them in one pass.
-- Best when: both sides are already sorted (e.g., have matching index).
-- Often chosen for range joins or when data is already ordered.

set enable_nestloop = off;
set enable_hashjoin = off;
explain analyze
select e.ename, d.dname
from emp e
join dept d on e.deptno = d.deptno
order by e.deptno;
reset enable_nestloop;
reset enable_hashjoin;

-- Disabling join types is useful ONLY for understanding plan choices.
-- In production, trust the planner unless statistics are provably wrong.

-------------------------------------------------
-- PART 3: STATISTICS AND THE QUERY PLANNER
-------------------------------------------------

-- The planner uses statistics to estimate row counts.
-- Wrong estimates → wrong plan → slow query.

-- View statistics for a column:
select attname,
       n_distinct,          -- estimated number of distinct values (-1 = all unique)
       correlation,         -- how well physical order matches logical order (1.0 = perfect)
       most_common_vals,    -- top N most common values
       most_common_freqs,   -- their frequencies
       histogram_bounds     -- bucket boundaries for range estimates
from pg_stats
where tablename = 'emp'
order by attname;

-- n_distinct = -1 means every value is unique (like empno).
-- correlation near 1.0 → index scan is cheap (rows are physically ordered).
-- correlation near 0.0 → index scan may not help (random heap access).

-------------------------------------------------

-- Statistics target — how much data PostgreSQL samples per column
-- Default: 100 (samples ~30,000 rows)
-- Increase for skewed columns to get better estimates.

alter table emp alter column job set statistics 200;

-- Reset to default:
alter table emp alter column job set statistics -1;

-- After changing statistics target, run ANALYZE to rebuild stats:
analyze emp;

-------------------------------------------------

-- ANALYZE — update statistics (no writes needed)
-- Run after large data loads or when plans become wrong.

analyze emp;
analyze;          -- analyze all tables in current database
vacuum analyze emp; -- reclaim dead rows AND update stats in one pass

-- Check when a table was last analyzed:
select relname,
       last_analyze,
       last_autoanalyze,
       n_live_tup,
       n_dead_tup
from pg_stat_user_tables
where relname = 'emp';

-------------------------------------------------

-- VACUUM — reclaim storage from dead rows
-- Dead rows are created by UPDATE and DELETE (MVCC leaves old versions).
-- VACUUM marks them as reusable. VACUUM FULL rewrites the table (locks it).

vacuum emp;           -- quick vacuum, no lock
vacuum full emp;      -- rewrites entire table, reclaims disk — LOCKS the table!
vacuum analyze emp;   -- vacuum + update stats in one command

-- Autovacuum runs automatically based on these settings (show them):
show autovacuum_vacuum_scale_factor;   -- default 0.2 (20% dead rows triggers vacuum)
show autovacuum_analyze_scale_factor;  -- default 0.1 (10% changes triggers analyze)

-- For high-traffic tables, lower the scale factor:
alter table emp set (autovacuum_vacuum_scale_factor = 0.05);

-------------------------------------------------
-- PART 4: MEMORY — work_mem
-------------------------------------------------

-- work_mem controls memory per sort/hash operation.
-- If a sort or hash table exceeds work_mem → spills to disk (huge slowdown).

show work_mem;   -- default: 4MB

-- Increase for a single query (session-level, not global):
set work_mem = '64MB';

explain analyze
select ename, sal
from emp
order by sal desc;
-- "Sort Method: quicksort" means it fit in memory.
-- "Sort Method: external merge Disk: NNkB" means it spilled to disk.

reset work_mem;

-- Rule: set work_mem globally to a safe level (e.g., 16-64MB),
-- then increase per-session for specific heavy queries.
-- Each sort/hash per query can use work_mem independently.
-- 100 connections × 10 sorts × 64MB = 64GB RAM needed in worst case!

-------------------------------------------------
-- PART 5: PARALLEL QUERY
-------------------------------------------------

-- PostgreSQL can use multiple workers to scan/join/aggregate in parallel.

show max_parallel_workers_per_gather;   -- default: 2
show max_parallel_workers;             -- max total parallel workers

-- Force a parallel plan (lower the threshold for testing):
set min_parallel_table_scan_size = '0';
set min_parallel_index_scan_size = '0';
set parallel_setup_cost = 0;
set parallel_tuple_cost = 0;

explain analyze
select avg(sal), deptno
from emp
group by deptno;
-- On a tiny table: probably not parallel. On millions of rows it would be.

reset min_parallel_table_scan_size;
reset min_parallel_index_scan_size;
reset parallel_setup_cost;
reset parallel_tuple_cost;

-- Disable parallel for a query (useful when parallel causes issues):
set max_parallel_workers_per_gather = 0;
-- ... run query ...
reset max_parallel_workers_per_gather;

-------------------------------------------------
-- PART 6: pg_stat_statements
-------------------------------------------------

-- pg_stat_statements tracks execution statistics for all queries.
-- It is the single best tool for finding slow queries in production.

-- Enable it (requires superuser, restart or pg_reload_conf):
-- In postgresql.conf: shared_preload_libraries = 'pg_stat_statements'
create extension if not exists pg_stat_statements;

-- Top 10 slowest queries by total execution time:
select round(total_exec_time::numeric, 2)  as total_ms,
       calls,
       round(mean_exec_time::numeric, 2)   as avg_ms,
       round(stddev_exec_time::numeric, 2) as stddev_ms,
       rows,
       left(query, 80)                     as query_snippet
from pg_stat_statements
order by total_exec_time desc
limit 10;

-- Top 10 by average execution time (consistently slow):
select round(mean_exec_time::numeric, 2) as avg_ms,
       calls,
       left(query, 80) as query_snippet
from pg_stat_statements
order by mean_exec_time desc
limit 10;

-- Queries with highest I/O (shared_blks_read = disk reads):
select shared_blks_read,
       shared_blks_hit,
       calls,
       left(query, 80) as query_snippet
from pg_stat_statements
order by shared_blks_read desc
limit 10;

-- Reset stats (start fresh):
select pg_stat_statements_reset();

-------------------------------------------------
-- PART 7: COMMON PERFORMANCE ANTI-PATTERNS
-------------------------------------------------

-- Anti-pattern 1: Function on indexed column in WHERE
create index idx_emp_ename_perf on emp(ename);

explain select * from emp where upper(ename) = 'SMITH';
-- Seq Scan — index ignored because upper() is applied.

-- Fix: create a functional index
create index idx_emp_upper_ename on emp(upper(ename));
explain select * from emp where upper(ename) = 'SMITH';
-- Index Scan — uses the functional index.

drop index if exists idx_emp_ename_perf;
drop index if exists idx_emp_upper_ename;

-------------------------------------------------

-- Anti-pattern 2: Implicit type cast breaks index
create index idx_emp_deptno on emp(deptno);  -- deptno is integer

explain select * from emp where deptno = '20';
-- May work — PostgreSQL casts '20' to integer.
-- But: WHERE deptno::text = '20' would break the index.

-- Always match the data type of your filter to the column type.

drop index if exists idx_emp_deptno;

-------------------------------------------------

-- Anti-pattern 3: OR conditions preventing index use

create index idx_emp_job on emp(job);

explain select * from emp where job = 'CLERK' or job = 'MANAGER';
-- Often a Seq Scan. Rewrite as IN:
explain select * from emp where job in ('CLERK', 'MANAGER');
-- More likely to use the index.

drop index if exists idx_emp_job;

-------------------------------------------------

-- Anti-pattern 4: SELECT * in large joins
-- Fetches all columns even if only 2 are needed.
-- Increases row width → more memory → slower sorts.

-- Bad:
explain select * from emp e join dept d on e.deptno = d.deptno;

-- Better:
explain select e.ename, d.dname from emp e join dept d on e.deptno = d.deptno;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Use EXPLAIN (ANALYZE, BUFFERS) — never just EXPLAIN alone.
--    Estimated vs actual rows reveals stale statistics immediately.

-- 2. Run ANALYZE after large data loads. Autovacuum handles steady-state
--    but won't catch a bulk insert before your next query.

-- 3. Understand the three join types: Nested Loop (small tables + index),
--    Hash Join (large unsorted tables), Merge Join (pre-sorted data).
--    Disable them one at a time (enable_nestloop=off) to compare plans.

-- 4. Increase statistics target for skewed columns (status, category, region).
--    The default of 100 often underestimates row counts for common values.

-- 5. Set work_mem per-session for heavy sort/aggregation queries.
--    Never set it globally very high — memory usage multiplies per connection.

-- 6. Install pg_stat_statements immediately on any production database.
--    It is the fastest way to find which queries are consuming the most time.

-- 7. VACUUM FULL rewrites the table — use it sparingly (it locks the table).
--    Regular VACUUM is non-blocking and is safe to run at any time.

-- 8. Parallel query helps large aggregations and seq scans.
--    It does NOT help small OLTP queries — parallel setup overhead dominates.
