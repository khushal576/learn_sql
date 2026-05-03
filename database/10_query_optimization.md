# Chapter 10 — Query Optimization

Query optimization is the art of making slow queries fast. This chapter covers the tools, techniques, and thought process for systematically diagnosing and fixing slow queries.

---

## 10.1 The Optimization Process

Never guess. Always measure.

```
1. Identify the slow query     → pg_stat_statements, slow query log
2. Understand the plan         → EXPLAIN (ANALYZE, BUFFERS)
3. Find the bottleneck         → which node takes the most time?
4. Fix the root cause          → add index, rewrite query, update stats
5. Verify the improvement      → run EXPLAIN ANALYZE again
```

---

## 10.2 EXPLAIN — Your Primary Tool

```sql
-- Estimated plan only (no actual execution)
EXPLAIN SELECT * FROM employees WHERE dept_id = 10;

-- Run the query, show actual timing and row counts
EXPLAIN ANALYZE SELECT * FROM employees WHERE dept_id = 10;

-- Full details: timing, buffers (cache hits vs disk reads), WAL
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM employees WHERE dept_id = 10;
```

### Reading EXPLAIN Output

```
Index Scan using idx_emp_dept on employees
        (cost=0.43..8.45 rows=5 width=60)
        (actual time=0.025..0.032 rows=5 loops=1)
  Index Cond: (dept_id = 10)
  Buffers: shared hit=3
```

| Field | Meaning |
|-------|---------|
| `cost=0.43..8.45` | Startup cost .. total cost (planner estimate, not ms) |
| `rows=5` | Estimated rows |
| `actual time=0.025..0.032` | Real ms: first row .. last row |
| `actual rows=5` | Real row count |
| `loops=1` | How many times this node ran (> 1 in nested loops) |
| `shared hit=3` | Pages served from buffer pool (fast) |
| `shared read=12` | Pages read from disk (slow) |

### The Most Important Signal

**Estimated rows vs actual rows mismatch**:
```
rows=5 (estimated) vs actual rows=50000
```
This means statistics are stale. The planner made a bad plan because it underestimated rows. Fix: `ANALYZE table_name`.

---

## 10.3 pg_stat_statements — Finding the Slow Queries

The best way to find slow queries in production:

```sql
-- Enable (add to postgresql.conf, then reload)
-- shared_preload_libraries = 'pg_stat_statements'

CREATE EXTENSION pg_stat_statements;

-- Top 10 queries by total time
SELECT query,
       calls,
       round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       round(stddev_exec_time::numeric, 2) AS stddev_ms,
       rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- Queries with high variance (sometimes fast, sometimes slow)
SELECT query, mean_exec_time, stddev_exec_time
FROM pg_stat_statements
WHERE stddev_exec_time > mean_exec_time
ORDER BY stddev_exec_time DESC;
```

---

## 10.4 Slow Query Log

Configure PostgreSQL to log queries slower than a threshold:

```ini
# postgresql.conf
log_min_duration_statement = 1000   # log queries > 1 second
log_statement = 'none'              # don't log all statements
```

Then use **pgBadger** to parse and analyze the log:
```bash
pgbadger /var/log/postgresql/postgresql.log -o report.html
```

---

## 10.5 Common Query Problems and Fixes

### Problem 1: Missing Index

```sql
-- Slow: seq scan on 10M row table
SELECT * FROM orders WHERE customer_id = 42;

-- EXPLAIN shows: Seq Scan on orders (cost=0.00..250000)

-- Fix:
CREATE INDEX idx_orders_customer ON orders(customer_id);
-- Now: Index Scan (cost=0.43..8.45)
```

---

### Problem 2: Index Not Used Due to Type Mismatch

```sql
-- idx_users_id exists on users(id) where id is INTEGER
-- But query casts it:
SELECT * FROM users WHERE id = '42';   -- '42' is TEXT
-- Planner can't use the index — types don't match

-- Fix: use the right type
SELECT * FROM users WHERE id = 42;
```

Also applies to function calls:
```sql
-- Index on created_at won't be used:
WHERE DATE(created_at) = '2024-01-01'    -- function wraps the column

-- Fix: range query instead
WHERE created_at >= '2024-01-01' AND created_at < '2024-01-02'
```

---

### Problem 3: LIKE with Leading Wildcard

```sql
-- B-Tree index can't help with leading wildcard
WHERE name LIKE '%smith'   -- ❌ full scan

-- Prefix LIKE works:
WHERE name LIKE 'smith%'   -- ✅ index used

-- For suffix/contains: use full-text search or trigram index
CREATE EXTENSION pg_trgm;
CREATE INDEX idx_name_trgm ON employees USING GIN (name gin_trgm_ops);
WHERE name LIKE '%smith%'   -- ✅ trigram index used
```

---

### Problem 4: N+1 Query Problem

Running one query per row instead of one query total:

```sql
-- ❌ N+1: 1 query to get orders, then 1 query per order for customer
SELECT * FROM orders;
-- for each order: SELECT * FROM customers WHERE id = ?

-- ✅ Fix: one JOIN
SELECT o.*, c.name, c.email
FROM orders o
JOIN customers c ON o.customer_id = c.id;
```

This is a common application-layer bug. Check your ORM settings.

---

### Problem 5: SELECT *

```sql
-- ❌ Fetches all columns, can't use covering index
SELECT * FROM employees WHERE dept_id = 10;

-- ✅ Only fetch what you need
SELECT employee_id, name, salary FROM employees WHERE dept_id = 10;
-- Can use covering index: CREATE INDEX ON employees(dept_id) INCLUDE (name, salary)
```

---

### Problem 6: Stale Statistics

```sql
-- EXPLAIN shows rows=1 but actual rows=500000
-- Planner chose an index scan that's now slower than seq scan

-- Fix: update statistics
ANALYZE employees;

-- Check when statistics were last updated
SELECT schemaname, tablename, last_analyze, last_autoanalyze
FROM pg_stat_user_tables;
```

---

### Problem 7: Inefficient Joins

```sql
-- ❌ Implicit cross join (very common mistake)
SELECT * FROM employees, departments
WHERE employees.dept_id = departments.dept_id;
-- Without WHERE it would be a CROSS JOIN (millions of rows)

-- ✅ Explicit JOIN
SELECT * FROM employees
JOIN departments ON employees.dept_id = departments.dept_id;
```

---

### Problem 8: Large OFFSET

```sql
-- ❌ Slow: must scan and discard 1M rows
SELECT * FROM events ORDER BY created_at LIMIT 10 OFFSET 1000000;

-- ✅ Keyset pagination (cursor-based)
SELECT * FROM events
WHERE created_at < '2024-01-01 10:00:00'   -- last seen value
ORDER BY created_at DESC
LIMIT 10;
```

Keyset pagination is O(log n) — doesn't get slower as you page deeper.

---

## 10.6 Query Rewriting Techniques

### Use EXISTS Instead of IN (for large subqueries)

```sql
-- ❌ IN with subquery — can be slow
SELECT * FROM customers
WHERE id IN (SELECT customer_id FROM orders WHERE total > 1000);

-- ✅ EXISTS — stops at first match
SELECT * FROM customers c
WHERE EXISTS (
    SELECT 1 FROM orders o
    WHERE o.customer_id = c.id AND o.total > 1000
);
```

### Push Filters Down

```sql
-- ❌ Filter happens after join (more rows to join)
SELECT *
FROM (SELECT * FROM orders JOIN order_items USING (order_id)) sub
WHERE sub.customer_id = 42;

-- ✅ Filter first, then join (fewer rows to join)
SELECT * FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.customer_id = 42;
```

Modern planners often do this automatically, but explicit is safer.

### Avoid Functions on Indexed Columns in WHERE

```sql
-- ❌ Function prevents index use
WHERE UPPER(status) = 'ACTIVE'
WHERE EXTRACT(YEAR FROM created_at) = 2024
WHERE LENGTH(name) > 5

-- ✅ Rearrange to keep column bare
WHERE status = 'active'   -- store lowercase consistently
WHERE created_at BETWEEN '2024-01-01' AND '2024-12-31'
```

---

## 10.7 Statistics and the Planner

The planner uses these statistics to estimate row counts:

```sql
-- Column statistics for a table
SELECT attname, n_distinct, correlation
FROM pg_stats
WHERE tablename = 'employees';
```

| Field | Meaning |
|-------|---------|
| `n_distinct` | Estimated distinct values. Negative = fraction of total rows |
| `correlation` | How correlated physical order is to column order (1 = perfect, 0 = random) |
| `most_common_vals` | Most frequent values |
| `most_common_freqs` | Frequencies of those values |
| `histogram_bounds` | Distribution of values |

**Increase statistics target** for columns with complex distributions:
```sql
-- Default is 100. Increase for skewed distributions.
ALTER TABLE orders ALTER COLUMN customer_id SET STATISTICS 500;
ANALYZE orders;
```

---

## 10.8 Planner Configuration Parameters

```sql
-- Disable/enable scan types (for testing)
SET enable_seqscan = OFF;
SET enable_indexscan = OFF;
SET enable_hashjoin = OFF;
SET enable_mergejoin = OFF;
SET enable_nestloop = OFF;

-- Cost parameters (rarely change these in production)
SHOW random_page_cost;   -- default 4.0 (lower for SSD, e.g., 1.1)
SHOW seq_page_cost;      -- default 1.0
SHOW cpu_tuple_cost;     -- default 0.01
```

For SSD storage, lower `random_page_cost`:
```ini
# postgresql.conf
random_page_cost = 1.1   # SSD: random I/O is almost as fast as sequential
```

---

## 10.9 Parallel Query

PostgreSQL can run queries using multiple CPU cores:

```sql
-- Check parallel settings
SHOW max_parallel_workers_per_gather;   -- default 2

-- Force parallel (for testing)
SET max_parallel_workers_per_gather = 4;
SET force_parallel_mode = ON;
```

EXPLAIN shows parallel nodes:
```
Gather  (cost=1000..85000 rows=1000 width=40)
  Workers Planned: 3
  ->  Parallel Seq Scan on large_table
        Filter: (value > 1000)
```

Parallel scans are used automatically for large tables with expensive filters.

---

## 10.10 Optimization Checklist

Before deploying a query to production:

- [ ] Run `EXPLAIN ANALYZE` — no seq scans on large tables without justification
- [ ] Estimated rows ≈ actual rows (no > 10x discrepancy)
- [ ] No type mismatches in WHERE clauses
- [ ] No functions wrapping indexed columns in WHERE
- [ ] No `SELECT *` on wide tables
- [ ] No OFFSET > 1000 — use keyset pagination
- [ ] Joins have indexes on join columns
- [ ] `ANALYZE` run recently on affected tables
- [ ] `shared hit` >> `shared read` in BUFFERS output (data in cache)

---

## Key Terms

| Term | Meaning |
|------|---------|
| `EXPLAIN` | Show the query execution plan |
| `EXPLAIN ANALYZE` | Execute query and show actual vs estimated stats |
| `pg_stat_statements` | Extension tracking all executed queries and their stats |
| Statistics Target | How much detail `ANALYZE` collects per column |
| Keyset Pagination | Cursor-based paging, O(log n) regardless of depth |
| N+1 Problem | One query per row instead of one query total |
| Correlation | How physically ordered a column's values are |

---

## Practice Questions

1. EXPLAIN shows `rows=100` but EXPLAIN ANALYZE shows `actual rows=500000`. What is the problem and the fix?
2. You have an index on `email` but a query `WHERE LOWER(email) = $1` does a seq scan. Why and how do you fix it?
3. What is the difference between `shared hit` and `shared read` in BUFFERS output?
4. Why is `OFFSET 100000` slow and what is the better alternative?
5. Write a query to find the top 5 slowest queries by total execution time using `pg_stat_statements`.
6. When should you lower `random_page_cost` and to what value?

---

**← Previous:** [09_query_processing.md](09_query_processing.md)  
**Next →** [11_transactions_acid.md](11_transactions_acid.md)
