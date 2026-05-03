# Chapter 30 — Database in Production

This final chapter is your end-to-end production guide: deploying safely, running schema migrations with zero downtime, CI/CD integration, and the complete pre-production checklist.

---

## 30.1 The Production Mindset

Production is different from development:
- **Failures are expensive** — downtime costs money and trust
- **Changes are risky** — every deployment could break something
- **Data is irreplaceable** — no "undo" button
- **Scale is unpredictable** — what works for 1K users breaks at 1M

Every change to production should be:
1. Tested in a staging environment that mirrors production
2. Reversible (have a rollback plan)
3. Monitored during and after deployment
4. Documented (who, when, what, why)

---

## 30.2 Schema Migrations

The most dangerous operation in database operations. Every schema change carries risk.

### Migration Tools

| Tool | Stack | Approach |
|------|-------|---------|
| **Flyway** | Java/JVM | SQL files, versioned |
| **Liquibase** | Java/JVM | XML/YAML/SQL, versioned |
| **Alembic** | Python | Python + SQL |
| **golang-migrate** | Go | SQL files |
| **Prisma Migrate** | Node.js | ORM-integrated |
| **Rails ActiveRecord** | Ruby | ORM-integrated |
| **sqitch** | Any | Dependency-based |

### Migration File Structure (Flyway style)

```
migrations/
├── V1__create_users_table.sql
├── V2__add_email_to_users.sql
├── V3__create_orders_table.sql
├── V4__add_index_orders_customer.sql
└── V5__add_soft_delete_to_orders.sql
```

Each migration is applied once, in version order, and recorded in a `schema_history` table.

### Example Migration

```sql
-- V5__add_soft_delete_to_orders.sql

-- Safe to run: ADD COLUMN with default is instant in PG 11+
ALTER TABLE orders ADD COLUMN deleted_at TIMESTAMPTZ;

-- Create index concurrently (no lock)
CREATE INDEX CONCURRENTLY idx_orders_deleted_at ON orders (deleted_at)
    WHERE deleted_at IS NULL;
```

---

## 30.3 Zero-Downtime Schema Changes

PostgreSQL takes locks for DDL operations. Some operations are safe; others lock the table for minutes or hours.

### Lock Levels for Common DDL

| Operation | Lock | Safe? |
|-----------|------|-------|
| `ADD COLUMN` with no default | Access Exclusive | ✅ Instant |
| `ADD COLUMN` with default (PG 11+) | Access Exclusive | ✅ Instant |
| `ADD COLUMN` with volatile default (PG < 11) | Access Exclusive | ❌ Table rewrite |
| `DROP COLUMN` | Access Exclusive | ✅ Instant (logical only) |
| `ADD CONSTRAINT NOT NULL` | Access Exclusive | ❌ Full table scan |
| `ADD CONSTRAINT FOREIGN KEY` | Share Row Exclusive | ❌ Locks both tables |
| `ADD INDEX` | Share | ❌ Blocks writes |
| `CREATE INDEX CONCURRENTLY` | None (mostly) | ✅ Safe |
| `ALTER COLUMN TYPE` (compatible) | Access Exclusive | ❌ Usually table rewrite |
| `RENAME TABLE` | Access Exclusive | ✅ Instant |
| `DROP TABLE` | Access Exclusive | ✅ Instant (but destructive!) |

### Safe Pattern: Adding a NOT NULL Column

```sql
-- ❌ WRONG: blocks entire table for full scan + backfill
ALTER TABLE orders ADD COLUMN priority INT NOT NULL DEFAULT 1;

-- ✅ RIGHT: three safe steps
-- Step 1: Add nullable column (instant)
ALTER TABLE orders ADD COLUMN priority INT;

-- Step 2: Backfill in batches (no lock held)
DO $$
DECLARE batch_size INT := 10000;
        last_id    BIGINT := 0;
BEGIN
    LOOP
        UPDATE orders SET priority = 1
        WHERE order_id > last_id
          AND order_id <= last_id + batch_size
          AND priority IS NULL;
        EXIT WHEN NOT FOUND;
        last_id := last_id + batch_size;
        PERFORM pg_sleep(0.01);  -- breathe between batches
    END LOOP;
END;
$$;

-- Step 3: Add NOT NULL constraint (validates — fast in PG 12+ with NOT VALID trick)
ALTER TABLE orders ADD CONSTRAINT orders_priority_not_null
    CHECK (priority IS NOT NULL) NOT VALID;           -- doesn't scan existing rows

ALTER TABLE orders VALIDATE CONSTRAINT orders_priority_not_null; -- scans, but no lock
```

### Safe Pattern: Adding a Foreign Key

```sql
-- ❌ Locks both tables
ALTER TABLE orders ADD CONSTRAINT fk_orders_customer
    FOREIGN KEY (customer_id) REFERENCES customers(id);

-- ✅ Safe: validate separately
ALTER TABLE orders ADD CONSTRAINT fk_orders_customer
    FOREIGN KEY (customer_id) REFERENCES customers(id)
    NOT VALID;                    -- constraint exists but not validated yet

ALTER TABLE orders VALIDATE CONSTRAINT fk_orders_customer;  -- ShareUpdateExclusiveLock
```

### Safe Pattern: Adding an Index

```sql
-- ❌ Locks table for writes during index build (minutes on large table)
CREATE INDEX idx_orders_status ON orders (status);

-- ✅ No write locks during build
CREATE INDEX CONCURRENTLY idx_orders_status ON orders (status);
```

`CONCURRENTLY` takes longer (makes two passes) but doesn't block. Only downside: cannot run inside a transaction.

---

## 30.4 The Expand-Contract Pattern for Breaking Changes

When you need to rename a column or change its type:

```
Phase 1 — Expand (backward compatible):
  - Add new column (status_v2 TEXT)
  - Deploy code that writes to BOTH old and new columns
  - Backfill new column from old column

Phase 2 — Migrate:
  - Deploy code that reads from new column
  - Stop writing to old column

Phase 3 — Contract (cleanup):
  - Drop old column
  - Rename new column if needed
```

This allows deployments without downtime — each phase is independently deployable.

---

## 30.5 CI/CD for Database Changes

### Pipeline Structure

```
Developer → PR → Review → Merge to main
                              ↓
                    CI: migrate test DB
                    CI: run integration tests
                              ↓
                    CD: deploy to staging
                    CD: migrate staging DB
                    CD: run smoke tests
                              ↓
                    CD: deploy to production
                    CD: migrate production DB (with backup first)
                    CD: verify key metrics
```

### Automated Migration in CI

```yaml
# .github/workflows/test.yml
- name: Run migrations
  run: |
    flyway -url=jdbc:postgresql://localhost/testdb migrate
    
- name: Run tests
  run: pytest tests/
```

### Pre-migration Backup

Always take a backup before a production migration:

```bash
# Before deploying
pg_dump -U postgres -d mydb -Fc -f /backups/pre_migration_$(date +%Y%m%d_%H%M%S).dump

# Run migration
flyway migrate

# If something goes wrong:
pg_restore -U postgres -d mydb /backups/pre_migration_*.dump
```

---

## 30.6 Blue-Green Deployment for Databases

For major schema changes, use blue-green:

```
Blue environment (current production)
    └── Database v1

Green environment (new version)
    └── Database v2 (migrated schema)

Traffic switch: Load balancer points from blue → green
Rollback: Switch back to blue
```

Requires:
- Both schemas compatible (expand-contract pattern)
- Database can be shared or replicated
- Quick traffic switch mechanism

---

## 30.7 Production Deployment Checklist

### Before Every Deployment

- [ ] Schema migrations reviewed by a second person
- [ ] Migration tested on a production-sized staging database
- [ ] Backup taken immediately before migration
- [ ] Rollback plan documented and tested
- [ ] Long-running migration estimated (time on staging × production size)
- [ ] Deployment scheduled for low-traffic window if risky
- [ ] Monitoring dashboards open during deployment
- [ ] On-call engineer notified

### Schema Change Safety

- [ ] All indexes created with `CONCURRENTLY`
- [ ] All FK constraints added with `NOT VALID` then `VALIDATE`
- [ ] No `ALTER COLUMN TYPE` on large tables without rewrite strategy
- [ ] No `ADD COLUMN ... NOT NULL DEFAULT` on PG < 11 without batching
- [ ] No `VACUUM FULL` or `CLUSTER` during business hours (unless emergency)

### Connection & Access

- [ ] Application uses connection pooling (PgBouncer)
- [ ] Each service has its own role with least privilege
- [ ] Superuser access restricted to localhost only
- [ ] SSL/TLS enforced for all connections (`sslmode=verify-full`)
- [ ] `pg_hba.conf` has no `trust` entries for network connections

### Performance

- [ ] All new tables have appropriate indexes on FK and frequently queried columns
- [ ] EXPLAIN ANALYZE run on all new queries (no seq scans on large tables)
- [ ] `shared_buffers`, `work_mem`, `random_page_cost` tuned for hardware
- [ ] Connection count within limits (PgBouncer pool size set correctly)
- [ ] `autovacuum` enabled and tuned per-table where needed

### Backup & Recovery

- [ ] Automated backups running and verified
- [ ] WAL archiving enabled (`archive_mode = on`)
- [ ] Last backup restore tested (within last 30 days)
- [ ] PITR configured and tested
- [ ] RTO and RPO targets defined and achievable

### High Availability

- [ ] At least one streaming replica running
- [ ] Patroni (or equivalent) managing failover
- [ ] Replication lag monitored and alerted
- [ ] Failover tested (manually, at least quarterly)
- [ ] DR replica in a separate region/AZ

### Monitoring & Alerting

- [ ] `pg_stat_statements` extension enabled
- [ ] Slow query log enabled (`log_min_duration_statement`)
- [ ] Alerts: connection count, cache hit rate, replication lag, XID age, disk space
- [ ] pgBadger or equivalent running on logs
- [ ] Grafana dashboard (or equivalent) set up

### Security

- [ ] `pgaudit` enabled for DDL and write operations
- [ ] No plaintext passwords in application config (use secrets manager)
- [ ] Row-level security enabled on multi-tenant tables
- [ ] Database not exposed to public internet (VPC/private network only)
- [ ] Regular security review of roles and privileges

---

## 30.8 Incident Response for Database Issues

### Slow query emergency

```sql
-- 1. Find what's running
SELECT pid, now() - query_start AS duration, left(query, 100)
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY duration DESC;

-- 2. Kill a specific query (graceful)
SELECT pg_cancel_backend(pid);

-- 3. Kill connection (forceful)
SELECT pg_terminate_backend(pid);
```

### Lock contention emergency

```sql
-- Find what's blocking what
SELECT blocked.pid, left(blocked.query, 80) AS blocked_query,
       blocking.pid AS blocking_pid, left(blocking.query, 80) AS blocking_query
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid));

-- Kill the blocking query
SELECT pg_terminate_backend(blocking_pid);
```

### Disk space emergency

```sql
-- Largest tables
SELECT relname, pg_size_pretty(pg_total_relation_size(oid))
FROM pg_class WHERE relkind='r'
ORDER BY pg_total_relation_size(oid) DESC LIMIT 10;

-- Immediate relief: VACUUM to reclaim bloat (doesn't free to OS)
VACUUM ANALYZE bloated_table;

-- Nuclear option (only if space critical and table lock acceptable)
VACUUM FULL bloated_table;  -- WARNING: full lock
```

---

## 30.9 Your Learning Path Forward

You have now covered the complete database curriculum:

```
Module 1: Foundations          → How databases work conceptually
Module 2: Core Internals       → What PostgreSQL does under the hood
Module 3: Administration       → Running PostgreSQL in production
Module 4: Advanced Topics      → Scaling, security, specialized features
```

### Next steps by goal:

**Become a better developer**:
- Practice writing complex queries: window functions, CTEs, recursive queries
- Study query optimization: EXPLAIN plans for real workloads
- Build a side project with PostgreSQL as the backend

**Become a DBA**:
- Set up a real Patroni HA cluster (use Docker/Vagrant locally)
- Practice backup and PITR restores
- Study `pg_stat_*` views deeply — run a real production load

**Become a data engineer**:
- Learn CDC (Change Data Capture) with Debezium
- Study logical replication for data pipelines
- Explore TimescaleDB for time-series workloads
- Learn dbt for SQL-based data transformation

**Scale to distributed systems**:
- Hands-on with CockroachDB or YugabyteDB
- Study Citus for PostgreSQL sharding
- Learn Kafka + Flink for event streaming pipelines

---

## 30.10 Reference Card — Most Used Commands

```sql
-- Performance investigation
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
SELECT * FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
SELECT * FROM pg_stat_activity WHERE state != 'idle';

-- Maintenance
VACUUM ANALYZE table_name;
REINDEX INDEX CONCURRENTLY index_name;
ANALYZE table_name;

-- Monitoring
SELECT * FROM pg_stat_user_tables ORDER BY n_dead_tup DESC;
SELECT * FROM pg_stat_replication;
SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;

-- Locks
SELECT pid, relation::regclass, mode, granted FROM pg_locks;
SELECT pg_blocking_pids(pid) FROM pg_stat_activity WHERE wait_event_type = 'Lock';

-- Size
SELECT pg_size_pretty(pg_database_size('mydb'));
SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) FROM pg_class WHERE relkind='r' ORDER BY 2 DESC LIMIT 10;

-- Replication
SELECT * FROM pg_stat_replication;
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| Schema migration | A versioned, tracked change to the database schema |
| Expand-contract | Deploy in phases to avoid breaking changes |
| `NOT VALID` | Add a constraint without scanning existing rows |
| `VALIDATE CONSTRAINT` | Scan existing rows to verify a NOT VALID constraint |
| `CREATE INDEX CONCURRENTLY` | Build index without blocking writes |
| Blue-green deployment | Run two environments, switch traffic between them |
| CI/CD pipeline | Automated build, test, and deploy pipeline |
| Rollback plan | Documented steps to undo a migration if it goes wrong |

---

## Congratulations

You have completed the full 30-chapter database mastery course.

```
Chapter 1-6   ✅  Foundations
Chapter 7-13  ✅  Core Internals
Chapter 14-20 ✅  Administration & Operations
Chapter 21-30 ✅  Advanced Topics
```

You now have the conceptual foundation and practical skills to design, build, operate, and scale production PostgreSQL databases. The only thing left is practice — build real systems, hit real problems, and solve them.

---

**← Previous:** [29_performance_tuning.md](29_performance_tuning.md)  
**← Back to start:** [README.md](README.md)
