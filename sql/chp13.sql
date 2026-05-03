-------------------------------------------------
-- CHAPTER 13
-- Indexes and Query Performance
-------------------------------------------------
-- An index is a data structure that speeds up data retrieval at the cost
-- of additional storage and write overhead.
-- This chapter covers: index types, creating/dropping indexes,
-- EXPLAIN ANALYZE (reading query plans), when indexes are used or skipped,
-- partial indexes, covering indexes, expression indexes, and
-- statistics-based optimisation tips.
-- Understanding indexes is essential for intermediate SQL roles.

-------------------------------------------------

-- Creating a basic B-tree index (default type)
-- B-tree is the default and works for =, <, >, BETWEEN, LIKE 'prefix%'

create index idx_emp_deptno on emp(deptno);

-- Now queries that filter on deptno can use this index:
select * from emp where deptno = 20;

-- Check if index exists:
select indexname, indexdef
from pg_indexes
where tablename = 'emp';

-------------------------------------------------

-- Creating a unique index
-- Enforces uniqueness AND speeds up lookups on that column.

create unique index idx_emp_empno on emp(empno);

-- Equivalent to declaring a PRIMARY KEY constraint on empno.
-- Duplicate inserts on empno will now raise an error.

-------------------------------------------------

-- Composite (multi-column) index
-- Useful when queries filter or sort on multiple columns together.

create index idx_emp_dept_sal on emp(deptno, sal);

-- This index helps queries like:
select ename, sal from emp where deptno = 10 order by sal desc;

-- Column ORDER matters: idx_emp_dept_sal(deptno, sal) helps WHERE deptno = X.
-- It does NOT help a query that only filters on sal (leading column must be used).

-------------------------------------------------

-- Dropping an index

drop index if exists idx_emp_dept_sal;
drop index if exists idx_emp_deptno;

-------------------------------------------------

-- EXPLAIN — show the query execution plan (no actual execution)
-- Read it bottom-up: innermost node executes first.

explain
select * from emp where deptno = 20;

-- Output nodes you will see:
-- Seq Scan       → full table scan (no index used)
-- Index Scan     → uses index to find rows, then fetches full row
-- Index Only Scan → uses index alone (all needed columns in index)
-- Bitmap Heap Scan → combines index scan with heap access in batches

-------------------------------------------------

-- EXPLAIN ANALYZE — actually runs the query AND shows timing
-- Use this to see real row counts and execution time.

explain analyze
select * from emp where deptno = 20;

-- Key numbers to read:
-- cost=0.00..X.XX  → estimated cost (startup cost .. total cost)
-- rows=X           → estimated row count
-- actual time=X..X → real execution time in milliseconds
-- actual rows=X    → real row count (compare with estimate)
-- loops=X          → how many times this node executed

-- Large difference between "rows" (estimate) and "actual rows" (real)
-- means statistics are stale → run ANALYZE to update them.

-------------------------------------------------

-- EXPLAIN (ANALYZE, BUFFERS) — also shows cache hits vs disk reads

explain (analyze, buffers)
select ename, sal
from emp
where sal > 2000
order by sal desc;

-- "Buffers: shared hit=X" → pages served from memory (fast)
-- "Buffers: shared read=X" → pages read from disk (slow)

-------------------------------------------------

-- When does PostgreSQL SKIP an index?

-- 1. Full table scan is cheaper (table is very small)
explain select * from emp;
-- Seq Scan — 14 rows, faster to just read all of them.

-- 2. Function applied to the indexed column prevents index use
create index idx_emp_ename on emp(ename);

explain select * from emp where lower(ename) = 'smith';
-- Seq Scan — index is on ename, not lower(ename).

-- Fix: create a functional index
create index idx_emp_ename_lower on emp(lower(ename));

explain select * from emp where lower(ename) = 'smith';
-- Now uses the functional index.

-------------------------------------------------

-- Expression (functional) index
-- Index on a computed expression, not a raw column value.

create index idx_emp_annual_sal on emp((sal * 12));

-- Now this query can use the index:
explain select ename from emp where sal * 12 > 30000;

-- Always wrap the expression in extra parentheses in CREATE INDEX.

-------------------------------------------------

-- Partial index
-- Index only a subset of rows — smaller, faster to maintain.

create index idx_emp_high_sal on emp(sal)
where sal > 2000;

-- This index only covers rows where sal > 2000.
-- Smaller index = faster scans for high-salary queries.

explain select ename from emp where sal > 3000;
-- Can use idx_emp_high_sal.

explain select ename from emp where sal > 1000;
-- May NOT use idx_emp_high_sal (predicate doesn't match partial index condition).

-------------------------------------------------

-- Covering index (Index Only Scan)
-- Include all columns the query needs directly in the index.
-- PostgreSQL can satisfy the query entirely from the index — no heap access.

create index idx_emp_dept_cover on emp(deptno) include (ename, sal);

explain analyze
select ename, sal
from emp
where deptno = 20;
-- Should show "Index Only Scan" — no heap fetch needed.

-------------------------------------------------

-- Index types overview

-- B-tree (default): equality, range, BETWEEN, ORDER BY, LIKE 'prefix%'
create index idx_btree on emp using btree (sal);

-- Hash: equality only (=), smaller than B-tree for equality workloads
create index idx_hash on emp using hash (empno);

-- GIN (Generalized Inverted Index): full-text search, arrays, JSONB
-- Example (on a jsonb column, not in this schema):
-- create index idx_gin on documents using gin (content);

-- GiST: geometric data, full-text search (tsvector), range types
-- BRIN: very large tables where column values correlate with physical order
--       (e.g., timestamp columns in append-only tables) — tiny index size

-------------------------------------------------

-- Checking index usage in production
-- pg_stat_user_indexes tracks how often each index is scanned.

select relname          as table_name,
       indexrelname     as index_name,
       idx_scan         as times_used,
       idx_tup_read     as rows_read_via_index,
       idx_tup_fetch    as rows_fetched
from pg_stat_user_indexes
order by idx_scan desc;

-- idx_scan = 0 means the index has never been used → candidate for removal.

-------------------------------------------------

-- Table statistics — ANALYZE updates the planner's row count estimates

analyze emp;

-- Run after bulk inserts/updates so the planner has accurate statistics.
-- VACUUM ANALYZE does both at once (reclaims space + updates stats).

-- Check current statistics:
select tablename,
       n_live_tup,
       n_dead_tup,
       last_analyze,
       last_autoanalyze
from pg_stat_user_tables
where tablename = 'emp';

-------------------------------------------------

-- EXPLAIN output: understanding cost units
-- cost is measured in arbitrary "page read" units (not milliseconds).
-- cost=startup..total
--   startup cost = cost before first row is returned (e.g., sort must finish first)
--   total cost   = cost to return all rows

-- Lower cost = faster (in theory).
-- Always use EXPLAIN ANALYZE for real timings.

-------------------------------------------------

-- Common interview question: why is this query slow?

-- Slow — function on indexed column prevents index use:
explain select * from emp where upper(ename) = 'SMITH';

-- Fix option 1: store data consistently (always uppercase):
explain select * from emp where ename = 'SMITH';

-- Fix option 2: create a functional index:
-- create index idx_upper_ename on emp(upper(ename));

-------------------------------------------------

-- Common interview question: LIKE and indexes

create index idx_ename on emp(ename);

-- Uses index (left-anchored prefix):
explain select * from emp where ename like 'S%';

-- Does NOT use index (leading wildcard):
explain select * from emp where ename like '%MITH';

-- For full-text / arbitrary pattern matching, use GIN + pg_trgm extension:
-- create extension if not exists pg_trgm;
-- create index idx_trgm_ename on emp using gin (ename gin_trgm_ops);
-- Then: WHERE ename like '%MITH' can use the trigram index.

-------------------------------------------------

-- Clean up indexes created in this chapter

drop index if exists idx_btree;
drop index if exists idx_hash;
drop index if exists idx_emp_ename;
drop index if exists idx_emp_ename_lower;
drop index if exists idx_emp_annual_sal;
drop index if exists idx_emp_high_sal;
drop index if exists idx_emp_dept_cover;
drop index if exists idx_emp_empno;
drop index if exists idx_ename;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Index columns used frequently in WHERE, JOIN ON, and ORDER BY.
--    Do not index every column — each index adds write overhead.

-- 2. Always use EXPLAIN ANALYZE (not just EXPLAIN) to see real performance.
--    Estimated rows vs actual rows reveals stale statistics.

-- 3. Run ANALYZE (or VACUUM ANALYZE) after large data loads
--    so the planner has accurate statistics.

-- 4. Avoid applying functions to indexed columns in WHERE clauses.
--    Use a functional index or rewrite the predicate instead.

-- 5. Partial indexes are ideal for highly selective conditions
--    (e.g., WHERE status = 'active' on a mostly-inactive table).

-- 6. Covering indexes (INCLUDE clause) enable Index Only Scans —
--    the fastest possible read path in PostgreSQL.

-- 7. Remove unused indexes (idx_scan = 0 in pg_stat_user_indexes).
--    They waste storage and slow down every INSERT/UPDATE/DELETE.

-- 8. LIKE '%pattern' (leading wildcard) cannot use a B-tree index.
--    Use pg_trgm + GIN index for arbitrary substring matching.
