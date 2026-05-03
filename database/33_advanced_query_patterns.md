# Chapter 33 — Advanced Query Patterns at Scale

Senior DBAs are expected to write and review complex queries that are both correct and efficient. This chapter covers the patterns that separate advanced SQL from intermediate — window function mechanics, recursive CTE internals, LATERAL joins, MERGE, and CTE materialization traps.

---

## 33.1 Window Function Frame Specifications

Most developers know `ROW_NUMBER()` and `LAG()`. Senior DBAs know the full frame specification that controls exactly which rows each window function sees.

```sql
function() OVER (
    PARTITION BY col
    ORDER BY col
    ROWS|RANGE|GROUPS BETWEEN frame_start AND frame_end
)
```

### Frame modes

| Mode | Unit | Use case |
|------|------|---------|
| `ROWS` | Physical rows | Exact N rows before/after |
| `RANGE` | Logical value range | All rows with same ORDER BY value |
| `GROUPS` | Peer groups | Distinct ORDER BY values |

```sql
-- ROWS: exactly 3 preceding rows (ignores ties)
SELECT order_date, amount,
       SUM(amount) OVER (
           ORDER BY order_date
           ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
       ) AS rolling_4day_sum
FROM orders;

-- RANGE: all rows with the same order_date (handles ties correctly)
SELECT order_date, amount,
       SUM(amount) OVER (
           ORDER BY order_date
           RANGE BETWEEN CURRENT ROW AND CURRENT ROW
       ) AS daily_total
FROM orders;

-- Unbounded: running total from start to current row
SELECT order_date, amount,
       SUM(amount) OVER (
           ORDER BY order_date
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS cumulative_total
FROM orders;

-- Full partition: each row sees the entire partition (same as no frame clause)
SELECT customer_id, amount,
       SUM(amount) OVER (PARTITION BY customer_id) AS customer_total
FROM orders;
```

### The default frame trap

```sql
-- When ORDER BY is present but no frame clause, the default is:
-- RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
-- This causes ties to give identical running totals to rows with the same ORDER BY value

-- SUM with ORDER BY and no frame = running total that jumps on ties
-- Use ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW to avoid tie ambiguity
```

---

## 33.2 Advanced Window Patterns

```sql
-- Median per group (no MEDIAN function in PostgreSQL)
SELECT department,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY salary) AS median_salary
FROM employees
GROUP BY department;

-- First and last value in partition
SELECT customer_id, order_date, amount,
       FIRST_VALUE(amount) OVER w AS first_order_amount,
       LAST_VALUE(amount)  OVER w AS last_order_amount,
       NTH_VALUE(amount, 2) OVER w AS second_order_amount
FROM orders
WINDOW w AS (
    PARTITION BY customer_id
    ORDER BY order_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
);

-- Gap between current and previous event
SELECT customer_id, order_date,
       order_date - LAG(order_date) OVER (
           PARTITION BY customer_id ORDER BY order_date
       ) AS days_since_last_order
FROM orders;

-- Percent of total within group
SELECT department, name, salary,
       ROUND(salary * 100.0 / SUM(salary) OVER (PARTITION BY department), 1) AS pct_of_dept
FROM employees;
```

---

## 33.3 Recursive CTE — Execution Model

Most developers use recursive CTEs but don't understand how they execute. This matters for performance and correctness.

```sql
WITH RECURSIVE cte AS (
    -- Anchor: runs once, seeds the working table
    SELECT id, manager_id, name, 0 AS depth
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    -- Recursive: runs repeatedly against the working table
    -- until no new rows are produced
    SELECT e.id, e.manager_id, e.name, r.depth + 1
    FROM employees e
    JOIN cte r ON e.manager_id = r.id
)
SELECT * FROM cte ORDER BY depth, name;
```

**Execution model:**
1. Run anchor query → put results in **working table**
2. Run recursive query joining `employees` with working table → new rows only
3. Append new rows to working table; replace old working table with new rows
4. Repeat from step 2 until working table is empty
5. Return union of all intermediate results

```sql
-- Cycle detection: prevent infinite loops on cyclic graphs
WITH RECURSIVE traversal AS (
    SELECT id, parent_id, name,
           ARRAY[id] AS visited,   -- track visited IDs
           false AS cycle
    FROM nodes WHERE id = 1

    UNION ALL

    SELECT n.id, n.parent_id, n.name,
           visited || n.id,
           n.id = ANY(visited)     -- detect if we've seen this node
    FROM nodes n
    JOIN traversal t ON n.parent_id = t.id
    WHERE NOT t.cycle              -- stop if cycle detected
)
SELECT * FROM traversal WHERE NOT cycle;

-- PostgreSQL 14+: built-in CYCLE clause
WITH RECURSIVE traversal AS (
    SELECT id, parent_id FROM nodes WHERE id = 1
    UNION ALL
    SELECT n.id, n.parent_id FROM nodes n
    JOIN traversal t ON n.parent_id = t.id
) CYCLE id SET is_cycle USING path
SELECT * FROM traversal WHERE NOT is_cycle;
```

---

## 33.4 LATERAL Joins — Top-N Per Group

`LATERAL` allows a subquery to reference columns from preceding FROM items — like a correlated subquery in the FROM clause.

```sql
-- Top 3 orders per customer (classic top-N per group)
SELECT c.customer_id, c.name, o.order_id, o.amount
FROM customers c
CROSS JOIN LATERAL (
    SELECT order_id, amount
    FROM orders
    WHERE customer_id = c.customer_id  -- reference to outer query
    ORDER BY amount DESC
    LIMIT 3
) o;

-- Equivalent using ROW_NUMBER (sometimes slower on large datasets):
SELECT customer_id, name, order_id, amount
FROM (
    SELECT c.customer_id, c.name, o.order_id, o.amount,
           ROW_NUMBER() OVER (PARTITION BY c.customer_id ORDER BY o.amount DESC) AS rn
    FROM customers c
    JOIN orders o USING (customer_id)
) ranked
WHERE rn <= 3;
```

```sql
-- LATERAL with function call (unnest per row)
SELECT p.product_id, tag
FROM products p
CROSS JOIN LATERAL unnest(p.tags) AS tag;

-- LATERAL for calling a set-returning function
SELECT u.user_id, log.*
FROM users u
CROSS JOIN LATERAL get_recent_logs(u.user_id, 5) AS log;
```

---

## 33.5 MERGE (PostgreSQL 15+)

`MERGE` is the SQL standard upsert with full WHEN MATCHED / NOT MATCHED control.

```sql
-- Sync a staging table into production
MERGE INTO products AS target
USING staging_products AS source
ON target.product_id = source.product_id

WHEN MATCHED AND source.price != target.price THEN
    UPDATE SET price = source.price, updated_at = NOW()

WHEN MATCHED AND source.deleted = true THEN
    DELETE

WHEN NOT MATCHED THEN
    INSERT (product_id, name, price, created_at)
    VALUES (source.product_id, source.name, source.price, NOW());
```

```sql
-- MERGE with DO NOTHING for matched (insert-only upsert)
MERGE INTO events AS target
USING new_events AS source ON target.event_id = source.event_id
WHEN NOT MATCHED THEN
    INSERT (event_id, event_type, payload)
    VALUES (source.event_id, source.event_type, source.payload);
-- More explicit than INSERT ... ON CONFLICT DO NOTHING

-- RETURNING clause (PG 17+)
MERGE INTO orders AS t USING updates AS s ON t.order_id = s.order_id
WHEN MATCHED THEN UPDATE SET status = s.status
RETURNING t.order_id, t.status;
```

---

## 33.6 DISTINCT ON vs ROW_NUMBER

Both solve "get the latest row per group" but behave differently:

```sql
-- DISTINCT ON: PostgreSQL-specific, simpler, single pass
SELECT DISTINCT ON (customer_id)
    customer_id, order_id, order_date, amount
FROM orders
ORDER BY customer_id, order_date DESC;
-- Keeps the first row for each customer_id after ordering by order_date DESC

-- ROW_NUMBER: standard SQL, more flexible (can filter on rn)
SELECT customer_id, order_id, order_date, amount
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) AS rn
    FROM orders
) t
WHERE rn = 1;
```

**When to prefer each:**
- `DISTINCT ON`: simpler, often faster for a single "latest" per group
- `ROW_NUMBER`: needed when you want top-N (not just top-1), or when filtering on rank in a CTE
- `DISTINCT ON` requires `ORDER BY` to start with the `DISTINCT ON` columns

---

## 33.7 CTE Materialization — The Hidden Performance Trap

PostgreSQL 12 changed CTE behavior. Before: CTEs were always optimization fences (materialized). After: the planner can inline them unless they are recursive or have side effects.

```sql
-- PG 12+: planner decides (usually inlines simple CTEs)
WITH recent_orders AS (
    SELECT * FROM orders WHERE order_date > NOW() - INTERVAL '30 days'
)
SELECT * FROM recent_orders WHERE customer_id = 42;

-- Force materialization (optimization fence — planner cannot push predicates in)
WITH recent_orders AS MATERIALIZED (
    SELECT * FROM orders WHERE order_date > NOW() - INTERVAL '30 days'
)
SELECT * FROM recent_orders WHERE customer_id = 42;
-- Scans all 30-day orders first, then filters — often slower

-- Force inlining (allow planner to push predicates through)
WITH recent_orders AS NOT MATERIALIZED (
    SELECT * FROM orders WHERE order_date > NOW() - INTERVAL '30 days'
)
SELECT * FROM recent_orders WHERE customer_id = 42;
-- Planner can combine WHERE clauses and use index on (order_date, customer_id)
```

**Rule of thumb:**
- Use `NOT MATERIALIZED` when the CTE is a simple filter/join that benefits from predicate pushdown
- Use `MATERIALIZED` when the CTE is expensive and referenced multiple times (avoid re-execution)
- Use `MATERIALIZED` as an optimization fence only when you understand the plan implications

---

## 33.8 Gaps and Islands at Scale

```sql
-- Classic gaps-and-islands: find consecutive date ranges
-- Input: user active dates; Output: contiguous activity streaks

WITH numbered AS (
    SELECT user_id, active_date,
           active_date - (ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY active_date))::int
           AS grp
    FROM user_activity
),
streaks AS (
    SELECT user_id,
           MIN(active_date) AS streak_start,
           MAX(active_date) AS streak_end,
           COUNT(*) AS streak_days
    FROM numbered
    GROUP BY user_id, grp
)
SELECT * FROM streaks ORDER BY user_id, streak_start;
```

```sql
-- Find gaps (missing dates in a series)
SELECT generate_series::date AS missing_date
FROM generate_series('2024-01-01'::date, '2024-12-31'::date, '1 day'::interval)
WHERE generate_series::date NOT IN (
    SELECT active_date FROM user_activity WHERE user_id = 42
);
```

---

## 33.9 Parallel Query and Aggregation

```sql
-- Check if a query uses parallel workers
EXPLAIN (ANALYZE, VERBOSE)
SELECT customer_id, SUM(amount)
FROM orders
GROUP BY customer_id;
-- Look for: Gather, Parallel Seq Scan, Partial HashAggregate

-- Force parallel for testing
SET max_parallel_workers_per_gather = 4;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;

-- Two-phase aggregation in parallel:
-- Phase 1: Partial HashAggregate in each worker (local partial sums)
-- Phase 2: Gather + Finalize HashAggregate (merge partial results)
-- This is why COUNT(*) in parallel returns exact results
```

---

## 33.10 Anti-Patterns That Scale Poorly

```sql
-- ❌ NOT IN with NULLs: returns no rows if subquery has any NULL
SELECT * FROM orders WHERE customer_id NOT IN (
    SELECT customer_id FROM blacklist  -- if any row is NULL, entire result = empty
);
-- ✅ Use NOT EXISTS instead:
SELECT * FROM orders o
WHERE NOT EXISTS (
    SELECT 1 FROM blacklist b WHERE b.customer_id = o.customer_id
);

-- ❌ COUNT(*) > 0 to check existence: scans entire table
SELECT * FROM customers WHERE (SELECT COUNT(*) FROM orders WHERE customer_id = id) > 0;
-- ✅ EXISTS stops at first match:
SELECT * FROM customers c WHERE EXISTS (
    SELECT 1 FROM orders o WHERE o.customer_id = c.id
);

-- ❌ OFFSET for pagination on large tables: scans and discards N rows
SELECT * FROM orders ORDER BY created_at LIMIT 20 OFFSET 100000;
-- ✅ Keyset pagination:
SELECT * FROM orders WHERE created_at < $last_seen_created_at
ORDER BY created_at DESC LIMIT 20;
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| Window frame | `ROWS/RANGE/GROUPS BETWEEN` clause defining which rows a window function sees |
| Recursive CTE | CTE that references itself; executes iteratively until no new rows |
| LATERAL | Allows a subquery in FROM to reference columns from preceding FROM items |
| MERGE | SQL standard: INSERT/UPDATE/DELETE in one statement based on match condition |
| DISTINCT ON | PostgreSQL extension: keep first row per group after ordering |
| CTE materialization | Whether a CTE result is stored and reused vs inlined into the parent query |
| Gaps and islands | Pattern for identifying contiguous ranges in sequence data |
| Keyset pagination | Pagination using WHERE on the last seen value, avoiding OFFSET scan |

---

## Practice Questions

1. Write a query returning the 3 most recent orders per customer. Use both LATERAL and ROW_NUMBER approaches.
2. Explain the difference between `ROWS BETWEEN 3 PRECEDING AND CURRENT ROW` and `RANGE BETWEEN 3 PRECEDING AND CURRENT ROW` for a date-ordered dataset.
3. A CTE is referenced 5 times in a query and is expensive to compute. Should you use `MATERIALIZED` or `NOT MATERIALIZED`? Why?
4. You have a table of employee login timestamps. Write a query that finds all contiguous login streaks (consecutive days) per employee.
5. What is the difference between `NOT IN` and `NOT EXISTS`? When does `NOT IN` return unexpected results?
6. Write a MERGE statement that upserts a product: update price if exists, insert if not, and delete if the source marks it deleted.

---

**← Previous:** [32_logical_replication_deep_dive.md](32_logical_replication_deep_dive.md)  
**Next →** [34_connection_management_scale.md](34_connection_management_scale.md)
