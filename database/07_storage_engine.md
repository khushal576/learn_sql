# Chapter 7 — Storage Engine

Understanding how PostgreSQL physically stores data helps you write faster queries, choose the right indexes, and understand why certain operations are expensive.

---

## 7.1 The Big Picture

```
SQL Query
    ↓
Query Planner      ← decides the best execution strategy
    ↓
Executor           ← runs the plan
    ↓
Buffer Manager     ← serves pages from memory (shared_buffers)
    ↓
Storage Manager    ← reads/writes pages to disk
    ↓
OS / Disk          ← actual files
```

Everything in PostgreSQL — tables, indexes, sequences — is stored as **files on disk**, organized into fixed-size **pages**.

---

## 7.2 The Page — The Fundamental Unit

PostgreSQL reads and writes data in chunks called **pages** (also called **blocks**).

- Default page size: **8 KB**
- All I/O happens in whole pages — even reading one row loads the entire 8 KB page
- This is why "read one row" and "read ten rows from the same page" cost almost the same

### Page Structure

```
┌─────────────────────────────────────────────┐
│  Page Header (24 bytes)                     │
│  LSN, flags, free space pointers            │
├─────────────────────────────────────────────┤
│  Item Pointers (4 bytes each)               │
│  [ptr1][ptr2][ptr3]...                      │  ← grow downward
├─────────────────────────────────────────────┤
│                                             │
│           FREE SPACE                        │
│                                             │
├─────────────────────────────────────────────┤
│  ...Tuple N ... Tuple 2 ... Tuple 1         │  ← grow upward
├─────────────────────────────────────────────┤
│  Special Space (indexes only)               │
└─────────────────────────────────────────────┘
```

- **Item pointers** (also called line pointers): small offset+length entries pointing to where each tuple lives
- **Tuples**: the actual row data, packed from the end of the page backward
- When free space is exhausted, the row goes to a new page

---

## 7.3 How Tables Are Stored — Heap Files

A table is stored as a **heap file** — an unordered collection of pages.

```
Table: employees
┌──────────┬──────────┬──────────┬──────────┐
│  Page 0  │  Page 1  │  Page 2  │  Page 3  │  ...
│ 8KB      │ 8KB      │ 8KB      │ 8KB      │
└──────────┴──────────┴──────────┴──────────┘
```

"Heap" means rows are inserted wherever there's free space — **no inherent order**. That's why `SELECT * FROM employees` returns rows in no guaranteed order unless you add `ORDER BY`.

### Physical Location of a Row: ctid

Every row has a hidden column `ctid` (current tuple ID):

```sql
SELECT ctid, * FROM employees LIMIT 5;
--  ctid  | employee_id | name
-- -------+-------------+------
-- (0,1)  |           1 | Alice
-- (0,2)  |           2 | Bob
-- (1,1)  |           3 | Carol
```

`(0,1)` = page 0, item slot 1. This is how indexes point to rows.

---

## 7.4 How PostgreSQL Stores Files on Disk

```
$PGDATA/base/<database_oid>/<table_oid>
```

Each table is one or more files (split at 1 GB by default):
- `12345`        — main table data
- `12345_vm`     — visibility map (for VACUUM optimization)
- `12345_fsm`    — free space map (tracks pages with free space)

You can find the file:
```sql
SELECT pg_relation_filepath('employees');
-- base/16384/16399
```

---

## 7.5 Tuple Layout and MVCC Storage

Each tuple (row) in PostgreSQL has a **header** containing:

| Field | Size | Meaning |
|-------|------|---------|
| `xmin` | 4 bytes | Transaction ID that inserted this row |
| `xmax` | 4 bytes | Transaction ID that deleted/updated this row (0 = alive) |
| `ctid` | 6 bytes | Physical location (page, slot) |
| `infomask` | 2 bytes | Status flags (committed, locked, etc.) |
| Null bitmap | variable | Which columns are NULL |

This is the foundation of **MVCC** (Multi-Version Concurrency Control — covered in Chapter 12). Old versions of rows aren't immediately deleted; they're kept with `xmax` set so concurrent transactions can still read the old version.

---

## 7.6 The Buffer Pool (shared_buffers)

Disk I/O is slow. PostgreSQL caches pages in memory:

```
Disk (slow)                  RAM (fast)
┌─────────────┐              ┌─────────────────────────┐
│ Data Files  │ ←──load───→  │  shared_buffers (cache) │
└─────────────┘              └─────────────────────────┘
                                        ↑
                              All queries read here
```

- `shared_buffers`: the in-memory page cache (default: 128 MB, set to 25% of RAM in production)
- When a page is needed: check buffer pool first → if miss, load from disk
- When a page is modified: written to buffer pool first (dirty page) → flushed to disk later

### Buffer Pool Replacement

When the buffer pool is full and a new page is needed, PostgreSQL evicts the **least recently used (LRU)** page (simplified — actual algorithm is clock sweep).

If your working set fits in `shared_buffers`, queries are served entirely from RAM → very fast.  
If it doesn't, you get frequent disk reads → much slower.

---

## 7.7 TOAST — Storing Large Values

PostgreSQL pages are 8 KB. What happens when a column value is larger than ~2 KB?

**TOAST**: The Oversized-Attribute Storage Technique.

- Values larger than ~2 KB are automatically compressed and/or moved to a separate TOAST table
- The main table stores a pointer to the TOAST table
- Completely transparent — you never see it in queries

```
employees (main heap)
┌──────────────────────────────┐
│ emp_id | name | resume_ptr──────→ pg_toast_16399 (TOAST table)
└──────────────────────────────┘                   │
                                              ┌────┴──────────────┐
                                              │ large resume text │
                                              └───────────────────┘
```

TOAST storage strategies per column:
- `PLAIN`: never compress/toast (use for small fixed types)
- `EXTENDED`: compress first, then toast if still big (default for TEXT, JSONB)
- `EXTERNAL`: toast but don't compress (for data already compressed)
- `MAIN`: compress but don't toast if possible

---

## 7.8 Table Bloat and Dead Tuples

When you `UPDATE` a row, PostgreSQL doesn't overwrite it. It:
1. Marks the old version as deleted (`xmax` = current transaction ID)
2. Inserts a new version in free space

```
Before UPDATE:
Page: [tuple_v1(alive)]

After UPDATE:
Page: [tuple_v1(dead, xmax=500)][tuple_v2(alive, xmin=500)]
```

When you `DELETE`, the row is just marked dead — the space isn't reclaimed immediately.

Over time, pages fill with **dead tuples** → **table bloat**.

**VACUUM** cleans dead tuples and reclaims space (covered in Chapter 18).

```sql
-- Manual vacuum
VACUUM employees;

-- Vacuum + reclaim space back to OS
VACUUM FULL employees;  -- WARNING: full table lock

-- Check bloat
SELECT schemaname, tablename,
       n_dead_tup, n_live_tup,
       round(n_dead_tup::numeric / nullif(n_live_tup,0) * 100, 1) AS dead_pct
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

---

## 7.9 Sequential Scan vs Random Access

**Sequential scan**: reads every page of the table in order.
- Good for: large portions of the table (> ~10-20% of rows)
- Predictable, benefits from OS read-ahead (prefetching)

**Random access** (index scan): jumps to specific pages via index.
- Good for: small, selective queries (< ~5-10% of rows)
- Each jump may hit a different page → many small I/Os

This is why indexes don't always help — for large scans, sequential is faster.

```sql
-- Force a sequential scan (for testing)
SET enable_indexscan = OFF;

-- Check if a query uses seq scan or index scan
EXPLAIN SELECT * FROM employees WHERE dept_id = 10;
```

---

## 7.10 Tablespaces — Controlling Where Data Lives

By default all data goes to the main data directory. You can put specific tables/indexes on different disks:

```sql
CREATE TABLESPACE fast_ssd LOCATION '/mnt/nvme/pgdata';

-- Put a table on fast storage
CREATE TABLE hot_data (...) TABLESPACE fast_ssd;

-- Move an existing index
ALTER INDEX employees_email_idx SET TABLESPACE fast_ssd;
```

Use cases:
- Put hot, frequently-accessed tables on NVMe SSDs
- Put large archive tables on slower, cheaper HDDs
- Separate indexes from table data for better parallelism

---

## Key Terms

| Term | Meaning |
|------|---------|
| Page / Block | 8 KB unit of I/O in PostgreSQL |
| Heap File | Unordered file of pages storing table rows |
| ctid | Physical address of a row: (page, slot) |
| Buffer Pool | In-memory page cache (`shared_buffers`) |
| TOAST | Storage for values too large for a single page |
| Dead Tuple | An old row version no longer visible to any transaction |
| Table Bloat | Wasted space from accumulated dead tuples |
| Tablespace | A storage location for database objects |

---

## Practice Questions

1. Why does reading one row from a page cost the same as reading ten rows on the same page?
2. What does `ctid = (3, 5)` mean?
3. Why doesn't PostgreSQL immediately reclaim space when you DELETE a row?
4. Your table has 10M rows but queries are slow. You check and `shared_buffers` is 128 MB. What's likely happening?
5. When would a sequential scan be faster than an index scan?
6. What is TOAST and when does it activate?

---

**← Previous:** [06_schema_design.md](06_schema_design.md)  
**Next →** [08_indexes.md](08_indexes.md)
