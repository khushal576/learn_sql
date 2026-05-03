# Chapter 11 — Transactions & ACID

A **transaction** is a unit of work that must succeed or fail as a whole. Transactions are the foundation of data reliability in every serious database system.

---

## 11.1 What is a Transaction?

A transaction groups multiple SQL statements into a single all-or-nothing operation.

```sql
-- Transfer $500 from Alice to Bob
BEGIN;
    UPDATE accounts SET balance = balance - 500 WHERE user_id = 1;  -- deduct Alice
    UPDATE accounts SET balance = balance + 500 WHERE user_id = 2;  -- credit Bob
COMMIT;
```

If the system crashes between the two UPDATEs, neither change survives — the money doesn't disappear into thin air. This is what transactions guarantee.

Without transactions, partial failures leave the database in an inconsistent state.

---

## 11.2 Transaction Control Statements

```sql
BEGIN;          -- start a transaction (also: START TRANSACTION)
COMMIT;         -- save all changes permanently
ROLLBACK;       -- undo all changes since BEGIN

SAVEPOINT sp1;  -- create a checkpoint within the transaction
ROLLBACK TO sp1;-- undo back to the savepoint, keep the transaction open
RELEASE SAVEPOINT sp1;  -- discard the savepoint
```

### Auto-commit

By default in PostgreSQL, every statement is its own transaction:
```sql
-- This is automatically wrapped in BEGIN...COMMIT
UPDATE accounts SET balance = 100 WHERE id = 1;
```

To group multiple statements, explicitly use `BEGIN`.

---

## 11.3 ACID Properties

ACID defines exactly what a database must guarantee for transactions.

### A — Atomicity

> All statements in a transaction succeed, or none of them do.

```sql
BEGIN;
  UPDATE accounts SET balance = balance - 500 WHERE id = 1;
  -- Power failure here ↑
  UPDATE accounts SET balance = balance + 500 WHERE id = 2;
COMMIT;
```

With atomicity: both changes are rolled back on crash. Money is never lost.
Without atomicity: Alice loses $500, Bob gets nothing.

**How PostgreSQL implements it**: WAL (Write-Ahead Log) records all changes. On crash, uncommitted transactions are rolled back during recovery.

---

### C — Consistency

> A transaction brings the database from one valid state to another valid state. All constraints must hold after the transaction completes.

```sql
BEGIN;
  INSERT INTO orders (customer_id, total) VALUES (999, 100.00);
  -- If customer_id 999 doesn't exist → FK constraint fails
  -- PostgreSQL rejects the transaction → database stays consistent
COMMIT;
```

**What enforces consistency**: constraints (NOT NULL, UNIQUE, CHECK, FK), triggers, and application logic.

Note: Consistency is partly the database's job (constraints) and partly the application's job (valid business logic).

---

### I — Isolation

> Concurrent transactions behave as if they ran sequentially. One transaction's intermediate states are invisible to others.

```sql
-- Session 1 (not yet committed)
BEGIN;
UPDATE accounts SET balance = 0 WHERE id = 1;

-- Session 2 (concurrent)
SELECT balance FROM accounts WHERE id = 1;
-- Should NOT see the uncommitted 0 — sees the original value
```

Isolation prevents concurrent transactions from interfering with each other.

**How PostgreSQL implements it**: MVCC (Multi-Version Concurrency Control — Chapter 12).

Isolation has multiple levels — a spectrum from weakest to strongest:

| Level | What it prevents |
|-------|-----------------|
| Read Uncommitted | (not actually used in PostgreSQL — treated as Read Committed) |
| Read Committed | Dirty reads |
| Repeatable Read | Dirty reads + non-repeatable reads |
| Serializable | Dirty reads + non-repeatable reads + phantom reads |

---

### D — Durability

> Once a transaction is committed, the changes survive even a system crash.

```sql
COMMIT;
-- One millisecond later: power failure
-- After restart: the committed data is still there
```

**How PostgreSQL implements it**: On COMMIT, the WAL record is flushed to disk (`fsync`) before returning success to the client. Even if the main data file hasn't been updated yet, the WAL log on disk is enough to replay the change.

---

## 11.4 Read Phenomena — What Isolation Levels Prevent

### Dirty Read
Reading data that another transaction has modified but **not yet committed**.

```
T1: UPDATE accounts SET balance = 0  (not committed)
T2: SELECT balance  → sees 0  (dirty read — T1 might rollback)
T1: ROLLBACK
-- T2 acted on data that never actually existed
```

### Non-Repeatable Read
Reading the same row twice in a transaction and getting different values because another transaction committed between the reads.

```
T1: SELECT balance → 1000
T2: UPDATE accounts SET balance = 500; COMMIT;
T1: SELECT balance → 500  (different from first read — non-repeatable)
```

### Phantom Read
A query returns different rows the second time because another transaction inserted or deleted rows.

```
T1: SELECT COUNT(*) FROM orders WHERE customer_id = 5  → 3
T2: INSERT INTO orders (customer_id, ...) VALUES (5, ...); COMMIT;
T1: SELECT COUNT(*) FROM orders WHERE customer_id = 5  → 4  (phantom row appeared)
```

### Serialization Anomaly
The result of concurrent transactions differs from any possible serial execution.

---

## 11.5 Isolation Levels in PostgreSQL

```sql
-- Set isolation level for a transaction
BEGIN ISOLATION LEVEL READ COMMITTED;
BEGIN ISOLATION LEVEL REPEATABLE READ;
BEGIN ISOLATION LEVEL SERIALIZABLE;

-- Or set the default for the session
SET default_transaction_isolation = 'repeatable read';
```

| Isolation Level | Dirty Read | Non-Repeatable Read | Phantom Read | Serialization Anomaly |
|----------------|-----------|--------------------|--------------|-----------------------|
| Read Committed (default) | ❌ Prevented | ✅ Possible | ✅ Possible | ✅ Possible |
| Repeatable Read | ❌ Prevented | ❌ Prevented | ❌ Prevented* | ✅ Possible |
| Serializable | ❌ Prevented | ❌ Prevented | ❌ Prevented | ❌ Prevented |

*PostgreSQL's MVCC also prevents phantom reads at Repeatable Read level (unlike the SQL standard).

### When to use which level:

- **Read Committed** (default): Fine for most OLTP workloads. Fast, minimal locking.
- **Repeatable Read**: When a transaction needs a consistent snapshot — e.g., generating a report while other transactions are running.
- **Serializable**: When transactions have dependencies that could cause business logic errors — e.g., "book a seat only if available" checked and acted on in the same transaction.

---

## 11.6 Serializable Snapshot Isolation (SSI)

PostgreSQL implements `SERIALIZABLE` using **SSI** — not traditional locking.

SSI tracks read/write dependencies between transactions. If it detects that two transactions have a cycle of dependencies (meaning they can't have run in any serial order), it aborts one of them with:

```
ERROR:  could not serialize access due to read/write dependencies among transactions
```

Your application must handle this by retrying the transaction.

```python
# Application-level retry for serialization failures
while True:
    try:
        with conn.transaction():
            # business logic here
        break
    except SerializationFailure:
        continue  # retry
```

---

## 11.7 Transaction Patterns

### Read-Modify-Write (Optimistic)

```sql
BEGIN;
  -- Read current state
  SELECT balance FROM accounts WHERE id = 1;
  -- Application checks if balance >= 500
  -- Deduct (if another transaction hasn't changed it at SERIALIZABLE level)
  UPDATE accounts SET balance = balance - 500 WHERE id = 1;
COMMIT;
```

### SELECT FOR UPDATE (Pessimistic Locking)

Lock the row for the duration of the transaction:

```sql
BEGIN;
  SELECT balance FROM accounts WHERE id = 1 FOR UPDATE;
  -- Row is now locked — other transactions must wait
  UPDATE accounts SET balance = balance - 500 WHERE id = 1;
COMMIT;
```

Use when you need to prevent concurrent modifications — e.g., flight seat booking.

### SELECT FOR UPDATE SKIP LOCKED

Process items from a queue without blocking:

```sql
BEGIN;
  SELECT * FROM job_queue
  WHERE status = 'pending'
  ORDER BY created_at
  LIMIT 1
  FOR UPDATE SKIP LOCKED;   -- skip rows locked by other workers
  
  -- Process the job...
  UPDATE job_queue SET status = 'done' WHERE id = $1;
COMMIT;
```

Multiple workers can process jobs simultaneously without deadlocks.

---

## 11.8 Long-Running Transactions

Long transactions are dangerous in PostgreSQL:

1. **They block VACUUM** — autovacuum can't clean dead tuples while they're still visible to the old transaction
2. **They cause bloat** — dead tuples accumulate
3. **They hold locks** — blocking other transactions

```sql
-- Find long-running transactions
SELECT pid, now() - xact_start AS duration, query, state
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY duration DESC;

-- Kill a stuck transaction
SELECT pg_terminate_backend(pid);
```

**Best practice**: Keep transactions as short as possible. Don't put user interaction or external API calls inside a transaction.

---

## 11.9 Nested Transactions and Savepoints

PostgreSQL doesn't have true nested transactions, but **savepoints** give partial rollback:

```sql
BEGIN;
  INSERT INTO orders (customer_id) VALUES (1);
  SAVEPOINT sp1;
  
  INSERT INTO order_items (order_id, product_id) VALUES (1, 999);
  -- Error! product_id 999 doesn't exist → FK violation
  
  ROLLBACK TO sp1;  -- undo only the failed insert, keep the order
  -- Retry with correct product_id
  INSERT INTO order_items (order_id, product_id) VALUES (1, 5);
COMMIT;
```

---

## 11.10 Two-Phase Commit (2PC)

For distributed transactions across multiple databases or services:

```sql
-- Phase 1: Prepare (write to WAL, don't commit yet)
PREPARE TRANSACTION 'order-12345';

-- Phase 2: Commit (after all participants are ready)
COMMIT PREPARED 'order-12345';

-- Or rollback
ROLLBACK PREPARED 'order-12345';

-- View prepared transactions
SELECT * FROM pg_prepared_xacts;
```

2PC is rarely used directly — distributed systems usually use application-level sagas or compensating transactions instead.

---

## Key Terms

| Term | Meaning |
|------|---------|
| Transaction | A unit of work: all succeed or all fail |
| ACID | Atomicity, Consistency, Isolation, Durability |
| Dirty Read | Reading uncommitted data from another transaction |
| Non-Repeatable Read | Same row returns different values within one transaction |
| Phantom Read | Different set of rows returned by same query within one transaction |
| Isolation Level | How much one transaction can see of another's work |
| Savepoint | Partial rollback point within a transaction |
| SSI | Serializable Snapshot Isolation — PostgreSQL's serializable implementation |
| SELECT FOR UPDATE | Lock rows for the duration of a transaction |

---

## Practice Questions

1. Transfer $1000 from account A to account B. Write the SQL with proper transaction handling.
2. What happens if you forget `COMMIT` and your application disconnects?
3. Explain the difference between non-repeatable read and phantom read.
4. When would you choose `REPEATABLE READ` over `READ COMMITTED`?
5. What is `SELECT FOR UPDATE SKIP LOCKED` useful for?
6. Why are long-running transactions dangerous in PostgreSQL specifically?

---

**← Previous:** [10_query_optimization.md](10_query_optimization.md)  
**Next →** [12_concurrency_control.md](12_concurrency_control.md)
