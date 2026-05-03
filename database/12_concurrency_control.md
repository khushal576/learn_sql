# Chapter 12 — Concurrency Control

A database serves many clients simultaneously. Concurrency control ensures that concurrent transactions produce correct results — as if they ran one at a time.

---

## 12.1 Two Approaches to Concurrency Control

| Approach | Strategy | Used In |
|---------|----------|---------|
| **Lock-Based (Pessimistic)** | Lock data before accessing it; others wait | Traditional RDBMS, MySQL InnoDB |
| **MVCC (Optimistic)** | Keep multiple versions; readers never block writers | PostgreSQL, Oracle, MySQL InnoDB |

PostgreSQL uses **MVCC** as its primary mechanism, supplemented by locks when needed.

---

## 12.2 MVCC — Multi-Version Concurrency Control

MVCC is PostgreSQL's core concurrency mechanism. The key idea:

> **Readers don't block writers. Writers don't block readers.**

Instead of locking rows for reads, PostgreSQL keeps **multiple versions** of each row. Each transaction sees the version that was current when the transaction started.

### How it works

Every row has two hidden fields (from Chapter 7):
- `xmin`: Transaction ID that created this version
- `xmax`: Transaction ID that deleted/replaced this version (0 = still alive)

```
-- Original row (created by transaction 100):
xmin=100, xmax=0, name='Alice', salary=90000

-- After UPDATE by transaction 200:
xmin=100, xmax=200, name='Alice', salary=90000   ← old version (dead to T200+)
xmin=200, xmax=0,   name='Alice', salary=95000   ← new version (alive for T200+)
```

### Visibility Rules

A row version is visible to a transaction if:
- `xmin` is a committed transaction that started before the current transaction's snapshot
- `xmax` is either 0 (not deleted) or an uncommitted transaction, or started after the snapshot

```
T1 starts (snapshot: sees committed transactions ≤ 150)
T2 starts, updates Alice's salary to 95000, commits (xid=200)

T1 reads Alice → still sees salary=90000 (xmin=200 is after T1's snapshot)
T3 starts after T2 → sees salary=95000
```

Each transaction gets a **snapshot** at its start (for `REPEATABLE READ`/`SERIALIZABLE`) or at each statement (for `READ COMMITTED`).

---

## 12.3 Transaction IDs and the Snapshot

```sql
-- Current transaction ID
SELECT txid_current();

-- Current snapshot: xmin, xmax, in-progress xids
SELECT txid_current_snapshot();
-- Returns: 500:503:501  meaning:
--   500 = oldest active transaction
--   503 = next transaction ID to be assigned
--   501 = currently in-progress (not yet committed)
```

---

## 12.4 Lock Types in PostgreSQL

Even with MVCC, some operations require locks.

### Table-Level Locks

```sql
-- Explicit table lock
LOCK TABLE employees IN EXCLUSIVE MODE;
```

| Lock Mode | Acquired By | Conflicts With |
|-----------|------------|----------------|
| `ACCESS SHARE` | SELECT | ACCESS EXCLUSIVE only |
| `ROW SHARE` | SELECT FOR UPDATE | EXCLUSIVE, ACCESS EXCLUSIVE |
| `ROW EXCLUSIVE` | INSERT, UPDATE, DELETE | SHARE, SHARE ROW EXCLUSIVE, EXCLUSIVE, ACCESS EXCLUSIVE |
| `SHARE UPDATE EXCLUSIVE` | VACUUM, CREATE INDEX CONCURRENTLY | SHARE UPDATE EXCLUSIVE and above |
| `SHARE` | CREATE INDEX | ROW EXCLUSIVE and above |
| `SHARE ROW EXCLUSIVE` | Certain triggers | SHARE and above |
| `EXCLUSIVE` | Rare | ROW SHARE and above |
| `ACCESS EXCLUSIVE` | ALTER TABLE, DROP TABLE, VACUUM FULL | Everything |

**The most important conflict**: `ACCESS EXCLUSIVE` (from ALTER TABLE) blocks **all** reads and writes. This is why schema changes during peak traffic cause downtime.

---

### Row-Level Locks

Row locks are taken automatically by DML and can be explicit:

```sql
SELECT * FROM orders WHERE id = 1 FOR UPDATE;           -- exclusive row lock
SELECT * FROM orders WHERE id = 1 FOR SHARE;            -- shared row lock
SELECT * FROM orders WHERE id = 1 FOR NO KEY UPDATE;    -- weaker exclusive
SELECT * FROM orders WHERE id = 1 FOR KEY SHARE;        -- weakest shared
```

Row locks are stored in the row's tuple header — they don't use a lock table for most cases (unlike table locks).

---

### Advisory Locks

Application-defined locks not tied to any database object:

```sql
-- Session-level advisory lock (released when session ends)
SELECT pg_advisory_lock(12345);         -- exclusive
SELECT pg_advisory_lock_shared(12345);  -- shared
SELECT pg_advisory_unlock(12345);

-- Transaction-level (released at COMMIT/ROLLBACK)
SELECT pg_advisory_xact_lock(12345);

-- Non-blocking (returns false if can't acquire)
SELECT pg_try_advisory_lock(12345);
```

Use cases:
- Ensure only one process runs a job at a time
- Application-level mutex for external resources
- Distributed locking across application servers

---

## 12.5 Deadlocks

A deadlock occurs when two transactions each hold a lock the other needs:

```
T1: LOCK row A (waiting for row B)
T2: LOCK row B (waiting for row A)
← both wait forever
```

PostgreSQL detects deadlocks automatically (every `deadlock_timeout` ms, default 1 second) and kills one transaction:

```
ERROR: deadlock detected
DETAIL: Process 1234 waits for ShareLock on transaction 5678;
        blocked by process 5678.
        Process 5678 waits for ShareLock on transaction 1234;
        blocked by process 1234.
HINT: See server log for query details.
```

### Preventing Deadlocks

**Always acquire locks in the same order**:

```sql
-- ❌ Deadlock risk: T1 locks user then order, T2 locks order then user
T1: UPDATE users SET ... WHERE id=1;  UPDATE orders SET ... WHERE id=100;
T2: UPDATE orders SET ... WHERE id=100; UPDATE users SET ... WHERE id=1;

-- ✅ Both acquire locks in same order
T1: UPDATE orders SET ... WHERE id=100; UPDATE users SET ... WHERE id=1;
T2: UPDATE orders SET ... WHERE id=100; UPDATE users SET ... WHERE id=1;
```

**Use `NOWAIT` to fail fast instead of waiting**:
```sql
SELECT * FROM orders WHERE id = 1 FOR UPDATE NOWAIT;
-- Immediately raises error if row is locked, instead of waiting
```

---

## 12.6 Lock Monitoring

```sql
-- View all locks
SELECT pid, relation::regclass, mode, granted
FROM pg_locks
WHERE relation IS NOT NULL;

-- Find blocking and blocked queries
SELECT
    blocked.pid          AS blocked_pid,
    blocked.query        AS blocked_query,
    blocking.pid         AS blocking_pid,
    blocking.query       AS blocking_query
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.wait_event_type = 'Lock';

-- Kill a blocking process
SELECT pg_terminate_backend(blocking_pid);
```

---

## 12.7 MVCC and Table Bloat Revisited

Because MVCC keeps old row versions, dead tuples accumulate. This is why VACUUM exists.

```
After many UPDATEs:
Page: [v1(dead)][v2(dead)][v3(dead)][v4(alive)] ← 3/4 of page is waste
```

When the oldest active transaction ID advances past `xmax`, old versions become truly dead and VACUUM can clean them.

### Transaction ID Wraparound — A Critical Danger

PostgreSQL uses 32-bit transaction IDs. After ~2 billion transactions, XID wraps around.

To prevent all old rows from becoming "in the future" (invisible), PostgreSQL uses `FREEZE`:
- `VACUUM FREEZE` marks old rows as permanently visible (xmin = frozen)
- `autovacuum_freeze_max_age` (default 200 million XIDs) triggers forced freeze

```sql
-- Check how close tables are to wraparound
SELECT relname,
       age(relfrozenxid) AS xid_age,
       pg_size_pretty(pg_total_relation_size(oid)) AS size
FROM pg_class
WHERE relkind = 'r'
ORDER BY age(relfrozenxid) DESC
LIMIT 20;
```

If `xid_age` approaches 2 billion, the database goes into read-only mode. Monitor this.

---

## 12.8 Optimistic Locking (Application-Level)

For cases where conflicts are rare, avoid database locks entirely:

```sql
-- Add a version column
ALTER TABLE products ADD COLUMN version INT NOT NULL DEFAULT 1;

-- Read with version
SELECT id, price, version FROM products WHERE id = 1;
-- → version = 5

-- Update only if version hasn't changed (optimistic check)
UPDATE products
SET price = 99.99, version = version + 1
WHERE id = 1 AND version = 5;
-- rows_affected = 1 → success (nobody else changed it)
-- rows_affected = 0 → conflict! another transaction already updated it → retry
```

This is the basis of optimistic concurrency in ORMs like Hibernate, ActiveRecord, etc.

---

## 12.9 Concurrency Patterns Summary

| Pattern | When to Use | Mechanism |
|---------|------------|-----------|
| Default (READ COMMITTED) | Most OLTP reads | MVCC snapshot per statement |
| Explicit SELECT FOR UPDATE | Must prevent concurrent update | Row-level lock |
| SELECT FOR UPDATE SKIP LOCKED | Job queues, task processing | Skip already-locked rows |
| SERIALIZABLE | Complex read-write transactions | SSI (PostgreSQL) |
| Advisory locks | Application-level mutex | pg_advisory_lock |
| Optimistic locking | Rare conflicts, high concurrency | Version column + conditional UPDATE |

---

## Key Terms

| Term | Meaning |
|------|---------|
| MVCC | Multiple row versions so readers and writers don't block each other |
| xmin / xmax | Hidden row fields tracking when a version was created/deleted |
| Snapshot | A point-in-time view of committed transactions used by a query |
| Deadlock | Two transactions each waiting for a lock the other holds |
| Advisory Lock | Application-defined lock on any integer identifier |
| XID Wraparound | 32-bit transaction counter overflow — requires VACUUM FREEZE |
| Optimistic Locking | Detect conflicts at commit time using version columns |

---

## Practice Questions

1. Why do readers never block writers in PostgreSQL?
2. Two transactions both try to transfer money from the same account simultaneously. How does PostgreSQL handle this?
3. You see a deadlock error. What does it mean and how do you prevent it in your code?
4. What is `SELECT FOR UPDATE SKIP LOCKED` and when would you use it?
5. What is XID wraparound and what happens if you don't prevent it?
6. You have a product catalog updated by one admin and read by millions of users. Which locking strategy minimizes impact on readers?

---

**← Previous:** [11_transactions_acid.md](11_transactions_acid.md)  
**Next →** [13_wal_journaling.md](13_wal_journaling.md)
