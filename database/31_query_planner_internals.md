# Chapter 31 — Query Planner Internals & Statistics

A mid-level DBA reads EXPLAIN output and adds an index. A Senior DBA understands *why* the planner chose a bad plan and knows how to fix it without touching the query. This is the most tested skill gap in Senior DBA interviews.

---

## 31.1 How the Planner Estimates Row Counts

Every plan node shows `rows=N`. That number comes from statistics — not from counting rows at query time. Wrong estimates → wrong plans.

```sql
-- The planner's data source for a table's columns
SELECT attname, n_distinct, correlation,
       most_common_vals, most_common_freqs,
       histogram_bounds
FROM pg_stats
WHERE tablename = 'orders' AND attname = 'status';
```

| Field | What it means |
|-------|--------------|
| `n_distinct` | Estimated distinct values. Negative = fraction of total rows (e.g. -0.05 = 5% of rows are distinct) |
| `correlation` | Physical vs logical order correlation. 1.0 = perfectly sequential on disk (great for range scans). 0 = random |
| `most_common_vals` | Array of the most frequent values |
| `most_common_freqs` | Corresponding frequency of each MCV |
| `histogram_bounds` | Bucket boundaries for the rest of the distribution |

### How cardinality is estimated

For `WHERE status = 'shipped'`:
1. Is `'shipped'` in `most_common_vals`? Use the corresponding frequency → row estimate = frequency × total rows
2. Not in MCV? Use `1 / n_distinct` as the selectivity → row estimate = (1 / n_distinct) × total rows
3. For ranges: count histogram buckets that overlap the range → estimate fraction of rows

---

## 31.2 Statistics Target — When 100 Buckets Is Not Enough

The default statistics target is 100 — meaning 100 MCV entries and 100 histogram buckets per column. For highly skewed or high-cardinality columns, this is insufficient.

```sql
-- Check current target
SELECT attname, attstattarget
FROM pg_attribute
WHERE attrelid = 'orders'::regclass AND attstattarget != 0;
-- -1 = use default (100)

-- Symptom: EXPLAIN shows rows=1, actual rows=500000
-- Cause: the value wasn't in the 100-entry MCV list → fell back to 1/n_distinct
-- Fix: increase statistics target for that column
ALTER TABLE orders ALTER COLUMN customer_id SET STATISTICS 500;
ANALYZE orders;

-- Verify the improvement
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 42;
```

Increase when:
- Column has > 100 distinct common values
- Estimated vs actual row count diverges by > 10×
- Column drives a major join

---

## 31.3 Extended Statistics — Fixing Correlated Column Estimates

PostgreSQL assumes columns are statistically independent. For correlated columns (e.g. `city` and `country`) this causes massive mis-estimates.

```sql
-- Classic problem: planner assumes independence
-- WHERE country = 'US' AND city = 'New York'
-- Estimate: P(US) × P(New York) = 0.3 × 0.001 = 0.0003 → rows = 30
-- Actual: all New York rows ARE in US → rows = 50000

-- Fix: create extended statistics for the correlated pair
CREATE STATISTICS stats_city_country
    ON country, city
    FROM customers;

-- Options: dependencies | ndistinct | mcv
CREATE STATISTICS stats_city_country (dependencies, mcv)
    ON country, city
    FROM customers;

ANALYZE customers;

-- Verify: pg_statistic_ext and pg_statistic_ext_data
SELECT stxname, stxkind FROM pg_statistic_ext;
```

`dependencies`: teaches the planner that knowing `city = 'New York'` already implies `country = 'US'`.  
`ndistinct`: corrects the estimate of distinct value combinations.  
`mcv`: stores most common combinations of column values.

---

## 31.4 The Cost Model in Detail

Every plan node gets a cost calculated from these GUCs:

```sql
SHOW seq_page_cost;        -- 1.0   (baseline: one sequential page read)
SHOW random_page_cost;     -- 4.0   (random page read, relative to seq)
SHOW cpu_tuple_cost;       -- 0.01  (processing one row)
SHOW cpu_index_tuple_cost; -- 0.005 (processing one index entry)
SHOW cpu_operator_cost;    -- 0.0025 (evaluating one operator/function)
SHOW parallel_tuple_cost;  -- 0.1   (passing a tuple to a parallel worker)
SHOW parallel_setup_cost;  -- 1000  (starting a parallel worker)
```

Cost of a sequential scan:
```
cost = (pages × seq_page_cost) + (rows × cpu_tuple_cost)
```

Cost of an index scan:
```
cost = (index_pages × random_page_cost)      -- index lookup
     + (heap_pages × random_page_cost)       -- heap fetch per matching row
     + (rows × cpu_index_tuple_cost)
```

**Why seq scan beats index scan on low-selectivity queries**: if 30% of a table matches, `random_page_cost × 0.3 × total_pages` > `seq_page_cost × total_pages` at default settings. Lower `random_page_cost` (e.g. 1.1 for SSD) shifts this threshold.

---

## 31.5 Plan Cache and Prepared Statements

When you `PREPARE` a statement, PostgreSQL plans it. For parameterized statements, the first 5 executions use a **custom plan** (re-planned each time with actual parameter values). After 5 executions, it evaluates whether a **generic plan** (planned without knowing parameter values) is cheaper overall.

```sql
PREPARE get_orders(int) AS
    SELECT * FROM orders WHERE customer_id = $1;

-- Force custom plan always (useful for highly skewed data)
SET plan_cache_mode = force_custom_plan;

-- Force generic plan always (useful to diagnose cached plan issues)
SET plan_cache_mode = force_generic_plan;

-- Default (PostgreSQL chooses)
SET plan_cache_mode = auto;
```

**The production problem**: if `customer_id = 1` (a mega-customer with 5M orders) and `customer_id = 99999` (a regular customer with 3 orders), the generic plan that works for the average customer is catastrophically slow for the mega-customer. `force_custom_plan` fixes this at the cost of planning overhead per execution.

```sql
-- See cached plans for a prepared statement
SELECT name, statement, generic_plans, custom_plans
FROM pg_prepared_statements;
```

---

## 31.6 JIT Compilation

PostgreSQL 11+ can compile query expressions to native code using LLVM when the query is expensive enough.

```sql
-- JIT settings
SHOW jit;                     -- on/off
SHOW jit_above_cost;          -- 100000 (default) — enable JIT if plan cost > this
SHOW jit_optimize_above_cost; -- 500000 — enable expensive optimizations above this

-- See JIT in EXPLAIN ANALYZE
EXPLAIN (ANALYZE, BUFFERS) SELECT sum(amount) FROM orders WHERE created_at > '2024-01-01';
-- JIT:
--   Functions: 5
--   Options: Inlining true, Optimization true, Expressions true, Deforming true
--   Timing: Generation 3.2ms, Inlining 12.1ms, Optimization 28.3ms, Emission 15.4ms, Total 59.0ms
```

**When JIT helps**: large analytical queries with many expression evaluations (aggregations, complex WHERE clauses). The compilation overhead is amortized over many rows.

**When JIT hurts**: OLTP queries processing hundreds of rows — compilation cost (50–200ms) dominates execution. Disable per-session for OLTP:
```sql
SET jit = off;
```

**The hidden trap**: JIT compilation happens in the background and adds latency to the *first* execution of a query. Under load, this can spike P99.

---

## 31.7 pg_hint_plan — Forcing Plans in Production

When the planner persistently chooses a wrong plan and you cannot fix it via statistics, `pg_hint_plan` lets you inject hints into SQL comments:

```sql
CREATE EXTENSION pg_hint_plan;

-- Force an index scan on a specific index
/*+ IndexScan(orders idx_orders_customer_id) */
SELECT * FROM orders WHERE customer_id = 42;

-- Force a hash join between two tables
/*+ HashJoin(o c) */
SELECT * FROM orders o JOIN customers c ON o.customer_id = c.id;

-- Force nested loop with specific inner table
/*+ NestLoop(o oi) Leading(o oi) */
SELECT * FROM orders o JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.customer_id = 42;

-- Disable seq scan on one specific table
/*+ SeqScan(large_table) */  -- override: forces seq scan
/*+ NoSeqScan(large_table) */ -- forces index
```

Available hints:
- `SeqScan(t)`, `IndexScan(t idx)`, `BitmapScan(t)`, `NoSeqScan(t)`
- `NestLoop(t1 t2)`, `HashJoin(t1 t2)`, `MergeJoin(t1 t2)`
- `Leading(t1 t2 t3)` — force join order
- `Rows(t #100)` — override row estimate

**Warning**: hints are a last resort. They bypass the optimizer and can become wrong after data changes. Document every hint with a comment explaining why.

---

## 31.8 Detecting Plan Regression in Production

A query that ran in 10ms for a year suddenly takes 10 seconds after a statistics update or data growth:

```sql
-- Capture query fingerprints and their mean execution time over time
-- Compare periods using pg_stat_statements reset between samples

-- Approach 1: snapshot pg_stat_statements daily
CREATE TABLE query_stats_snapshots AS
    SELECT current_timestamp AS captured_at, queryid, query,
           calls, mean_exec_time, rows
    FROM pg_stat_statements;

-- Compare this week vs last week
SELECT a.query,
       a.mean_exec_time AS this_week_ms,
       b.mean_exec_time AS last_week_ms,
       round((a.mean_exec_time - b.mean_exec_time) / b.mean_exec_time * 100, 1) AS pct_change
FROM query_stats_snapshots a
JOIN query_stats_snapshots b USING (queryid)
WHERE a.captured_at > now() - interval '7 days'
  AND b.captured_at BETWEEN now() - interval '14 days' AND now() - interval '7 days'
  AND a.mean_exec_time > b.mean_exec_time * 1.5  -- 50% slower
ORDER BY pct_change DESC;
```

```sql
-- Approach 2: use auto_explain to log plans of slow queries automatically
-- postgresql.conf:
-- shared_preload_libraries = 'auto_explain'
-- auto_explain.log_min_duration = 1000
-- auto_explain.log_analyze = on
-- auto_explain.log_buffers = on
-- auto_explain.log_format = json
```

Then grep PostgreSQL logs for `EXPLAIN` output on the regressed query — compare the plan before/after.

---

## 31.9 Join Ordering and GEQO

For queries joining ≤ `join_collapse_limit` tables (default 8), the planner uses **dynamic programming** to evaluate all join orders. For more tables, it switches to **GEQO** (Genetic Query Optimizer) — a randomized heuristic that does not guarantee the optimal order.

```sql
SHOW join_collapse_limit;    -- 8
SHOW geqo_threshold;         -- 12 (GEQO kicks in at 12+ tables)
SHOW geqo_effort;            -- 5  (1=fastest/worst to 10=slowest/best)

-- For a complex 15-table report query that generates a bad GEQO plan:
SET geqo = off;              -- force full DP (expensive but finds better plan)
SET join_collapse_limit = 20;

-- Or lock the join order by using explicit JOIN syntax with no subqueries
-- Explicit JOIN order in SQL constrains planner's options
```

**In practice**: if a 10-table report query is slow, disable GEQO in a transaction, capture the EXPLAIN plan, then hint it with `pg_hint_plan` in production.

---

## 31.10 The `parallel_safe` Function Attribute

Custom functions and parallel queries interact dangerously. A function marked `VOLATILE` (default) prevents parallelism on the query that calls it — even if the function is actually safe.

```sql
-- Check parallelism-blocking functions in a query plan
-- Look for: "Gather" node absent where expected

-- Fix: mark functions correctly
CREATE FUNCTION calculate_discount(price numeric) RETURNS numeric
LANGUAGE sql
IMMUTABLE    -- always returns same output for same input (best for indexes)
PARALLEL SAFE  -- safe to call from parallel workers
AS $$ SELECT price * 0.9 $$;

-- STABLE: same result within a transaction (e.g. NOW())
-- VOLATILE: may return different results — blocks parallelism
-- PARALLEL RESTRICTED: can run in parallel worker but not lead node
-- PARALLEL UNSAFE: blocks all parallelism (default for new functions)
```

Always mark custom functions with the correct volatility and parallel safety. A mis-marked function silently disables parallel query for every query that uses it.

---

## Key Terms

| Term | Meaning |
|------|---------|
| `pg_stats` | Per-column statistics view used by the planner for row estimates |
| Statistics target | Number of MCV entries and histogram buckets collected per column |
| Extended statistics | Multi-column statistics to fix correlated column mis-estimates |
| Generic plan | A plan compiled without actual parameter values (reused for prepared statements) |
| Custom plan | A plan compiled with actual parameter values (re-planned each execution) |
| GEQO | Genetic Query Optimizer — randomized join ordering for many-table queries |
| JIT | Just-In-Time compilation of query expressions via LLVM |
| pg_hint_plan | Extension allowing SQL comment-based plan hints |
| Plan regression | A query that was fast becomes slow due to changed statistics or data |
| `PARALLEL SAFE` | Function attribute indicating it is safe to call from parallel workers |

---

## Practice Questions

1. EXPLAIN shows `rows=1` but EXPLAIN ANALYZE shows `actual rows=800000`. What is the root cause and what are two ways to fix it?
2. You have a query `WHERE country = 'US' AND city = 'Seattle'` that the planner severely underestimates. What do you create and why?
3. A prepared statement runs well for most users but catastrophically slowly for one high-volume customer. What is the likely cause and how do you fix it?
4. `EXPLAIN ANALYZE` shows `JIT: Generation 180ms` on a query that processes 500 rows. What should you do?
5. A 12-table reporting query has a poor plan. You suspect GEQO is choosing a bad join order. What is your diagnostic and remediation process?
6. You write a custom aggregate function. It doesn't break anything but all queries using it are suddenly single-threaded. Why, and how do you fix it?

---

**← Previous:** [30_production_checklist.md](30_production_checklist.md)  
**Next →** [32_logical_replication_deep_dive.md](32_logical_replication_deep_dive.md)
