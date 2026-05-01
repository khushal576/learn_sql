# Chapter 8 — Indexes

An index is a separate data structure that lets PostgreSQL find rows without scanning every page of a table. Understanding indexes is the single most impactful skill for query performance.

---

## 8.1 What is an Index?

Without an index, finding `WHERE email = 'alice@example.com'` means:
- Read every page of the table
- Check every row
- Return matches

With an index on `email`:
- Look up the value in the index tree (a few page reads)
- Jump directly to the matching rows

An index trades **write overhead and storage** for **faster reads**.

---

## 8.2 B-Tree Index — The Default

**B-Tree** (Balanced Tree) is the default and most versatile index type in PostgreSQL.

### Structure

```
                    [50]
                   /    \
            [25]            [75]
           /    \           /   \
        [10][30]        [60]    [90]
       /  \   \         /  \    /  \
     [5] [15] [35]   [55][65][80][95]
```

- Every leaf node stores: `(key_value → ctid)`
- Balanced: every leaf is at the same depth → consistent lookup time
- Self-balancing: tree rebalances automatically as you insert/delete
- Leaf nodes are linked: range scans (`BETWEEN`, `>`, `<`) traverse the linked list

### Supports

| Operation | Supported |
|-----------|-----------|
| `=` | ✅ |
| `<`, `>`, `<=`, `>=` | ✅ |
| `BETWEEN` | ✅ |
| `LIKE 'abc%'` (prefix) | ✅ |
| `LIKE '%abc'` (suffix) | ❌ |
| `IS NULL` | ✅ (PostgreSQL includes NULLs) |
| Full-text search | ❌ (use GIN) |
| Array contains | ❌ (use GIN) |

```sql
-- B-tree index (default)
CREATE INDEX idx_employees_email ON employees(email);
CREATE INDEX idx_orders_created  ON orders(created_at);
```

---

## 8.3 Composite (Multi-Column) Index

An index on multiple columns:

```sql
CREATE INDEX idx_orders_customer_date ON orders(customer_id, created_at);
```

**Column order matters** — this index supports:
- `WHERE customer_id = 5`  ✅
- `WHERE customer_id = 5 AND created_at > '2024-01-01'`  ✅
- `WHERE created_at > '2024-01-01'`  ❌ (leftmost column not used)

Rule: The index is useful for queries that filter on a **prefix** of the index columns.

**When to use composite index vs two separate indexes?**
- If you always query both columns together → composite
- If you query each column independently → separate indexes
- Composite index is more efficient for the combined query

---

## 8.4 Hash Index

Stores a hash of the indexed value. Only useful for exact equality.

```sql
CREATE INDEX idx_sessions_token ON sessions USING HASH (token);
```

| | B-Tree | Hash |
|-|--------|------|
| Equality (`=`) | ✅ | ✅ |
| Range (`<`, `>`) | ✅ | ❌ |
| Size | Larger | Smaller |
| Speed (equality) | Fast | Slightly faster |

In practice: B-Tree is almost always the right choice. Hash gives marginal gains for pure equality lookups (e.g., UUID or token lookups).

---

## 8.5 GIN Index — Generalized Inverted Index

Designed for columns that contain **multiple values** per row — arrays, JSONB, and full-text search vectors.

```
Column value: ["python", "sql", "docker"]
GIN index:
  "python" → [row 1, row 5, row 12]
  "sql"    → [row 1, row 3, row 7]
  "docker" → [row 1, row 8]
```

Each element points back to the rows containing it — like a book's index.

```sql
-- For JSONB
CREATE INDEX idx_products_attrs ON products USING GIN (attributes);
SELECT * FROM products WHERE attributes @> '{"color": "red"}';

-- For arrays
CREATE INDEX idx_articles_tags ON articles USING GIN (tags);
SELECT * FROM articles WHERE tags @> ARRAY['postgresql'];

-- For full-text search
CREATE INDEX idx_articles_search ON articles USING GIN (to_tsvector('english', body));
SELECT * FROM articles WHERE to_tsvector('english', body) @@ to_tsquery('database');
```

GIN indexes are **large and slow to update** but excellent for read-heavy search workloads.

---

## 8.6 GiST Index — Generalized Search Tree

A framework for indexing complex data types: geometric shapes, ranges, full-text.

```sql
-- Range overlap queries
CREATE INDEX idx_reservations_period ON reservations USING GIST (during);
SELECT * FROM reservations WHERE during && '[2024-12-01, 2024-12-05]'::tsrange;

-- Geometric queries (PostGIS)
CREATE INDEX idx_locations_geo ON locations USING GIST (coordinates);
SELECT * FROM locations WHERE ST_DWithin(coordinates, ST_Point(-73.9, 40.7), 1000);

-- Full-text (alternative to GIN, less common)
CREATE INDEX idx_docs_fts ON documents USING GIST (to_tsvector('english', content));
```

GiST is slower than GIN for full-text but supports `ORDER BY ... <->` (nearest neighbor).

---

## 8.7 BRIN Index — Block Range Index

Stores min/max values **per range of pages** instead of indexing every row.

```
Pages 0-127:    min_date=2020-01-01, max_date=2020-12-31
Pages 128-255:  min_date=2021-01-01, max_date=2021-12-31
Pages 256-383:  min_date=2022-01-01, max_date=2022-12-31
```

To find rows in 2021, skip pages 0-127 and 256+. Read only pages 128-255.

**Requirements**: The data must be **naturally ordered** on disk (e.g., `created_at` on an append-only table).

```sql
CREATE INDEX idx_logs_created ON logs USING BRIN (created_at);
```

| | B-Tree | BRIN |
|-|--------|------|
| Size | Large | Tiny (few KB) |
| Selectivity | Precise | Approximate |
| Requires natural order | No | Yes |
| Best for | Any query | Append-only, time-series |

Use BRIN on huge append-only tables (logs, events) where data is naturally ordered by time.

---

## 8.8 Partial Index — Index Only a Subset of Rows

Index only rows matching a `WHERE` clause:

```sql
-- Only index active users (not the millions of inactive ones)
CREATE INDEX idx_users_active_email ON users(email) WHERE is_active = TRUE;

-- Only index unfulfilled orders
CREATE INDEX idx_orders_pending ON orders(created_at) WHERE status = 'pending';
```

**Advantages**:
- Much smaller index → faster lookups, less memory
- Fewer index updates (inserts/updates to inactive rows skip the index)

**Requirement**: The query's `WHERE` clause must match the index's `WHERE` condition.

```sql
-- This WILL use the partial index
SELECT * FROM users WHERE email = 'alice@x.com' AND is_active = TRUE;

-- This WON'T use it (missing the is_active = TRUE filter)
SELECT * FROM users WHERE email = 'alice@x.com';
```

---

## 8.9 Expression / Functional Index

Index the result of a function or expression:

```sql
-- Case-insensitive email search
CREATE INDEX idx_users_lower_email ON users(LOWER(email));
SELECT * FROM users WHERE LOWER(email) = 'alice@example.com';

-- Index year extracted from a date
CREATE INDEX idx_orders_year ON orders(EXTRACT(YEAR FROM created_at));
SELECT * FROM orders WHERE EXTRACT(YEAR FROM created_at) = 2024;
```

Without this, `WHERE LOWER(email) = ...` would do a full table scan even if there's an index on `email` (the index stores the original case, not the lowercased version).

---

## 8.10 Covering Index (INCLUDE)

An index that contains all columns a query needs — no heap access required.

```sql
-- Query: SELECT name, salary FROM employees WHERE dept_id = 10
-- Without covering index: index lookup → heap fetch for name and salary
-- With covering index:
CREATE INDEX idx_emp_dept_covering ON employees(dept_id) INCLUDE (name, salary);
-- Query satisfied entirely from index (index-only scan)
```

`INCLUDE` columns are stored in leaf nodes but not sorted — they can't be used for filtering, only for covering.

---

## 8.11 Unique Index

Enforces uniqueness and creates an index simultaneously:

```sql
CREATE UNIQUE INDEX idx_users_email ON users(email);
-- equivalent to adding: UNIQUE constraint on email
```

Primary key and UNIQUE constraints automatically create unique indexes.

---

## 8.12 When Indexes Help vs Hurt

### Indexes HELP when:
- Query is highly selective (< ~10% of rows)
- Column is frequently used in `WHERE`, `JOIN`, `ORDER BY`
- Table is large (> a few thousand rows)

### Indexes HURT when:
- Table is small — seq scan is faster than index overhead
- Query returns most of the table — sequential scan wins
- Very high write volume — every insert/update/delete must update all indexes
- Column has very low cardinality (e.g., `is_deleted BOOLEAN` with 99% FALSE — not selective enough)

### How to check if your indexes are being used:

```sql
SELECT schemaname, tablename, indexname,
       idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC;  -- zero scans = unused index
```

Drop indexes that have `idx_scan = 0` — they're just slowing down writes.

---

## 8.13 Index Scan Types

PostgreSQL has several strategies for using an index:

| Scan Type | When Used | Description |
|-----------|-----------|-------------|
| **Index Scan** | Standard | Follow index, fetch each row from heap |
| **Index Only Scan** | Covering index available | All needed data in the index, no heap access |
| **Bitmap Index Scan** | Multiple indexes or many rows | Build a bitmap of matching pages, then fetch in bulk |
| **Sequential Scan** | No useful index, or low selectivity | Read all pages in order |

```sql
EXPLAIN SELECT * FROM employees WHERE dept_id = 10;
-- Index Scan using idx_emp_dept on employees  (cost=0.43..8.45 rows=5 width=60)
--   Index Cond: (dept_id = 10)
```

---

## 8.14 Index Maintenance

Indexes grow and become bloated over time (just like tables):

```sql
-- Rebuild an index (no lock in PostgreSQL 12+)
REINDEX INDEX CONCURRENTLY idx_employees_email;

-- Check index bloat
SELECT indexname, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC;
```

`autovacuum` handles most index maintenance automatically.

---

## Index Type Quick Reference

| Type | Use For | Operators |
|------|---------|-----------|
| B-Tree | Everything (default) | `=`, `<`, `>`, `BETWEEN`, `LIKE 'x%'` |
| Hash | Pure equality, UUID/token | `=` only |
| GIN | Arrays, JSONB, full-text | `@>`, `@@`, `&&` |
| GiST | Ranges, geometry, full-text | `&&`, `<->`, `@>` |
| BRIN | Huge append-only tables | Range scans on ordered data |
| Partial | Subset of rows | Any, with WHERE condition |
| Expression | Function results | Exact match on expression |
| Covering | All columns in SELECT | Index-only scan |

---

## Practice Questions

1. You have a table with 50M rows. `SELECT * FROM logs WHERE created_at > NOW() - INTERVAL '1 day'` is slow. `created_at` is append-only and rows are inserted chronologically. Which index type is best and why?
2. What is the difference between `GIN` and `GiST`?
3. You run `EXPLAIN` and see "Seq Scan" even though an index exists on the column. Name three reasons this might happen.
4. Design indexes for: `SELECT id, name FROM users WHERE is_active = TRUE AND email = $1`
5. What is an index-only scan and what do you need for it to happen?
6. Why might adding more indexes slow down your application?

---

**← Previous:** [07_storage_engine.md](07_storage_engine.md)  
**Next →** [09_query_processing.md](09_query_processing.md)
