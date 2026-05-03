# Chapter 9 — Query Processing

Every SQL query you write goes through a multi-stage pipeline before any data is touched. Understanding this pipeline helps you write better queries and interpret EXPLAIN output.

---

## 9.1 The Query Processing Pipeline

```
SQL String (text)
      │
      ▼
┌─────────────┐
│   Parser    │  Syntax check, build parse tree
└──────┬──────┘
       │ parse tree
       ▼
┌─────────────┐
│  Analyzer   │  Semantic check, resolve names → query tree
└──────┬──────┘
       │ query tree
       ▼
┌─────────────┐
│  Rewriter   │  Apply rules, expand views
└──────┬──────┘
       │ rewritten query tree
       ▼
┌─────────────┐
│   Planner   │  Generate candidate plans, pick lowest cost → plan tree
└──────┬──────┘
       │ plan tree
       ▼
┌─────────────┐
│  Executor   │  Execute plan, return rows
└─────────────┘
```

---

## 9.2 Stage 1 — Parser

Converts the raw SQL string into a **parse tree** (an AST — Abstract Syntax Tree).

```sql
SELECT name, salary FROM employees WHERE dept_id = 10;
```

Becomes roughly:
```
SelectStmt
├── targetList: [name, salary]
├── fromClause: [employees]
└── whereClause: dept_id = 10
```

**What the parser does**:
- Checks SQL grammar — catches syntax errors here
- Does NOT check if table/column names exist (that's the analyzer)
- Does NOT know anything about data

**Errors caught here**: `SLECT name FROM ...` → syntax error

---

## 9.3 Stage 2 — Analyzer (Semantic Analysis)

Resolves names against the system catalog:
- Does `employees` table exist?
- Does `dept_id` column exist in `employees`?
- What data type is `dept_id`? Can we compare it to integer `10`?
- Are there any aggregates? GROUP BY required?

Produces a **query tree** — the parse tree enriched with type information and resolved references.

**Errors caught here**: `SELECT foo FROM employees` when `foo` column doesn't exist.

---

## 9.4 Stage 3 — Rewriter (Rule System)

Applies PostgreSQL's **rule system** to transform the query tree:

1. **View expansion**: Replace a view reference with the underlying query
   ```sql
   -- Query on a view:
   SELECT * FROM active_employees WHERE dept_id = 10;
   
   -- Rewriter replaces it with:
   SELECT * FROM employees WHERE deleted_at IS NULL AND dept_id = 10;
   ```

2. **Rule-based rewrites**: Custom rules defined with `CREATE RULE` (rarely used today — triggers are preferred)

3. **Row Security**: Inject row-level security policies into the query

The rewriter is transparent — you don't usually interact with it directly.

---

## 9.5 Stage 4 — Planner (Query Optimizer)

The most complex and important stage. Given the query tree, the planner:

1. **Generates candidate plans**: Different ways to execute the query (which indexes to use, join order, join algorithms)
2. **Estimates cost** for each plan using statistics
3. **Picks the lowest-cost plan**

This is the **cost-based optimizer** (CBO). It uses statistics stored in `pg_statistic` (updated by `ANALYZE`) to estimate:
- How many rows each table has
- How selective each filter is
- What the data distribution looks like

### Example — Simple Query Plans

```sql
SELECT * FROM employees WHERE dept_id = 10;
```

Candidate plans:
1. Sequential scan → filter by dept_id
2. Index scan on `idx_emp_dept_id` → fetch matching rows

Planner estimates costs, picks the cheaper one.

### Join Order and Combinatorial Explosion

For a query joining 5 tables, there are `5! = 120` possible join orders. For 10 tables: over 3.6 million.

PostgreSQL uses **dynamic programming** for ≤ `join_collapse_limit` tables (default 8), and **genetic algorithm** (GEQO) for more.

---

## 9.6 Stage 5 — Executor

Takes the plan tree and actually executes it, one **node** at a time.

Each plan node is an operator that:
- Pulls rows from its child node(s)
- Processes them
- Passes results up to its parent

This is the **Volcano / iterator model** — each node has a `GetNextTuple()` method.

### Common Plan Nodes

| Node | What it does |
|------|-------------|
| `Seq Scan` | Reads table pages sequentially |
| `Index Scan` | Follows index → fetches heap rows |
| `Index Only Scan` | Reads from index only, no heap |
| `Bitmap Heap Scan` | Fetches pages identified by bitmap |
| `Nested Loop` | For each outer row, scan inner (good for small sets) |
| `Hash Join` | Build hash table from inner, probe with outer (good for larger sets) |
| `Merge Join` | Merge two sorted inputs (good when both are sorted) |
| `Sort` | Sort rows (used before merge join, or for ORDER BY) |
| `Hash` | Build hash table (inner side of hash join) |
| `Aggregate` | Compute COUNT, SUM, AVG, etc. |
| `Limit` | Stop after N rows |
| `Append` | Union of multiple child nodes |

---

## 9.7 Join Algorithms in Detail

### Nested Loop Join

```
FOR each row in outer_table:
    FOR each row in inner_table:
        IF join_condition matches:
            output row
```

- Cost: O(outer × inner)
- Best when: outer is small, inner has an index on the join key
- PostgreSQL often uses this for joins where one side is very small

### Hash Join

```
Phase 1 (Build):   Hash all rows of inner table → hash table in memory
Phase 2 (Probe):   For each outer row, look up in hash table
```

- Cost: O(outer + inner)
- Best when: both sides are large, no sort order available
- Falls back to on-disk hash if hash table doesn't fit in `work_mem`

### Merge Join

```
Both inputs must be sorted on the join key.
Walk both sorted lists simultaneously, output matches.
```

- Cost: O(outer log outer + inner log inner) for sorting + O(outer + inner) for merge
- Best when: both sides are already sorted (e.g., both have indexes on the join key)

---

## 9.8 Scan Strategies

### Bitmap Index Scan

Used when an index returns many matching rows spread across many pages:

```
Step 1: Bitmap Index Scan
  Build an in-memory bitmap of matching page numbers
  [page 0: YES, page 1: NO, page 2: YES, page 3: YES, ...]

Step 2: Bitmap Heap Scan
  Visit only the YES pages, in physical order (sequential-ish)
```

More efficient than a plain index scan when many rows match — avoids random I/O by batching page fetches.

---

## 9.9 Reading a Plan Tree

```sql
EXPLAIN SELECT e.name, d.name
FROM employees e
JOIN departments d ON e.dept_id = d.dept_id
WHERE e.salary > 80000;
```

```
Hash Join  (cost=1.09..18.45 rows=8 width=64)
  Hash Cond: (e.dept_id = d.dept_id)
  ->  Seq Scan on employees e  (cost=0.00..16.75 rows=8 width=40)
        Filter: (salary > 80000)
  ->  Hash  (cost=1.04..1.04 rows=4 width=36)
        ->  Seq Scan on departments d  (cost=0.00..1.04 rows=4 width=36)
```

Reading the plan:
- **Indentation** = tree structure. Read from inside out (leaves first)
- **cost=X..Y**: X = startup cost (first row), Y = total cost (all rows)
- **rows=N**: estimated number of rows output by this node
- **width=N**: estimated average row size in bytes

Actual execution with timing:
```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
```

This shows actual vs estimated rows — mismatches reveal stale statistics.

---

## 9.10 The System Catalog

The planner relies on metadata stored in system tables:

```sql
-- Table statistics (row counts, column distributions)
SELECT * FROM pg_statistic WHERE starelid = 'employees'::regclass;

-- Human-readable version
SELECT * FROM pg_stats WHERE tablename = 'employees';

-- All tables and their row counts
SELECT relname, reltuples FROM pg_class WHERE relkind = 'r';
```

`ANALYZE` updates these statistics. Without up-to-date statistics, the planner makes bad estimates → bad plans.

```sql
-- Update statistics for one table
ANALYZE employees;

-- Update all tables
ANALYZE;
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| Parse Tree | AST representation of SQL syntax |
| Query Tree | Parse tree with resolved names and types |
| Plan Tree | Execution plan chosen by the optimizer |
| Cost | Planner's estimate of work (in abstract units, not ms) |
| Cardinality | Number of rows estimated to come out of a node |
| Volcano Model | Pull-based execution: each node requests rows from children |
| Nested Loop | Join by iterating outer × inner |
| Hash Join | Join by building hash table on inner side |
| Merge Join | Join two sorted inputs |
| ANALYZE | Command that updates table statistics |

---

## Practice Questions

1. In which stage does PostgreSQL check if a column name exists?
2. What is view expansion and which stage performs it?
3. You join two tables. One has 1000 rows, the other has 1M rows. Which join algorithm would you expect PostgreSQL to choose?
4. What does `cost=0.00..16.75 rows=8` mean in an EXPLAIN output?
5. Your query is slow and EXPLAIN shows rows=1 but EXPLAIN ANALYZE shows actual rows=50000. What does this tell you and what should you do?
6. Why does join order matter and what technique does the planner use to choose it?

---

**← Previous:** [08_indexes.md](08_indexes.md)  
**Next →** [10_query_optimization.md](10_query_optimization.md)
