# Chapter 21 — Partitioning

Partitioning splits one logical table into multiple physical pieces. For large tables (100M+ rows), it dramatically improves query performance, maintenance speed, and data lifecycle management.

---

## 21.1 Why Partition?

| Problem | How Partitioning Helps |
|---------|----------------------|
| Queries on huge tables are slow | Partition pruning skips irrelevant partitions entirely |
| VACUUM on 500 GB table takes hours | Vacuum each 10 GB partition independently |
| Deleting old data is slow (DELETE) | Drop a partition instantly — no DELETE, no bloat |
| Index rebuild takes too long | Rebuild one partition's index at a time |
| Hot vs cold data on different storage | Put recent partitions on SSD, old ones on HDD |

---

## 21.2 Partitioning Strategies

| Strategy | Split By | Best For |
|----------|----------|---------|
| **Range** | Value ranges | Dates, timestamps, numeric IDs |
| **List** | Explicit value lists | Region, country, category |
| **Hash** | Hash of column value | Even distribution, no natural range |

---

## 21.3 Range Partitioning

```sql
-- Partitioned parent table
CREATE TABLE orders (
    order_id    BIGSERIAL,
    customer_id BIGINT NOT NULL,
    total       NUMERIC(12,2),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (created_at);

-- Monthly partitions
CREATE TABLE orders_2024_01 PARTITION OF orders
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE orders_2024_02 PARTITION OF orders
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

-- Catch-all for unmatched rows
CREATE TABLE orders_default PARTITION OF orders DEFAULT;
```

---

## 21.4 List Partitioning

```sql
CREATE TABLE sales (
    sale_id BIGSERIAL,
    region  TEXT NOT NULL,
    amount  NUMERIC(12,2)
) PARTITION BY LIST (region);

CREATE TABLE sales_north PARTITION OF sales
    FOR VALUES IN ('north', 'northeast', 'northwest');

CREATE TABLE sales_south PARTITION OF sales
    FOR VALUES IN ('south', 'southeast', 'southwest');

CREATE TABLE sales_other PARTITION OF sales DEFAULT;
```

---

## 21.5 Hash Partitioning

Evenly distribute rows when there is no natural range:

```sql
CREATE TABLE user_events (
    event_id   BIGSERIAL,
    user_id    BIGINT NOT NULL,
    event_type TEXT,
    created_at TIMESTAMPTZ
) PARTITION BY HASH (user_id);

CREATE TABLE user_events_0 PARTITION OF user_events
    FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE user_events_1 PARTITION OF user_events
    FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE user_events_2 PARTITION OF user_events
    FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE user_events_3 PARTITION OF user_events
    FOR VALUES WITH (MODULUS 4, REMAINDER 3);
```

---

## 21.6 Partition Pruning

PostgreSQL automatically skips partitions that cannot contain matching rows.

```sql
-- Scans only orders_2024_03 (skips all other months)
EXPLAIN SELECT * FROM orders
WHERE created_at >= '2024-03-01' AND created_at < '2024-04-01';
-- → Seq Scan on orders_2024_03

-- No pruning — customer_id is not the partition key
SELECT * FROM orders WHERE customer_id = 42;  -- scans all partitions
```

**Pruning only works when the WHERE clause references the partition key.**

---

## 21.7 Indexes on Partitioned Tables

```sql
-- Create on the parent → PostgreSQL creates on all partitions automatically
CREATE INDEX ON orders (customer_id);
CREATE INDEX ON orders (created_at);

-- Unique indexes must include the partition key
CREATE UNIQUE INDEX ON orders (order_id, created_at);
-- Cannot create: UNIQUE INDEX ON orders (order_id) alone
```

---

## 21.8 Partition Maintenance

The biggest win: dropping old data is instant.

```sql
-- Drop partition: milliseconds regardless of size
DROP TABLE orders_2023_01;

-- Detach (keep data as standalone table, remove from parent)
ALTER TABLE orders DETACH PARTITION orders_2023_01;

-- Re-attach later
ALTER TABLE orders ATTACH PARTITION orders_2023_01
    FOR VALUES FROM ('2023-01-01') TO ('2023-02-01');
```

### Automate with pg_partman

```sql
CREATE EXTENSION pg_partman;

SELECT partman.create_parent(
    p_parent_table => 'public.orders',
    p_control      => 'created_at',
    p_type         => 'native',
    p_interval     => 'monthly',
    p_premake      => 3   -- pre-create 3 future partitions
);

-- Run in a cron job to create new and drop expired partitions
SELECT partman.run_maintenance();
```

---

## 21.9 Inspecting Partitions

```sql
-- List partitions with sizes
SELECT inhrelid::regclass AS partition,
       pg_size_pretty(pg_relation_size(inhrelid)) AS size
FROM pg_inherits
WHERE inhparent = 'orders'::regclass
ORDER BY partition;

-- Row counts per partition
SELECT tableoid::regclass AS partition, COUNT(*)
FROM orders
GROUP BY tableoid
ORDER BY 1;
```

---

## 21.10 Partitioning vs Indexing

| Scenario | Solution |
|----------|---------|
| Table < 50M rows | Index only |
| Table > 100M rows, queries always filter by date | Range partitioning + indexes |
| Need to bulk-delete old data regularly | Partitioning (DROP PARTITION) |
| Even write distribution | Hash partitioning |
| Queries on multiple non-partition-key columns | Indexes on those columns |

Partitioning and indexing are complementary — partitioning prunes at the table level, indexes prune within a partition.

---

## Key Terms

| Term | Meaning |
|------|---------|
| Partition | A physical child table storing a subset of parent rows |
| Partition key | Column used to route each row to the right partition |
| Partition pruning | Skipping non-matching partitions at query time |
| Default partition | Catches rows that match no defined partition |
| pg_partman | Extension for automatic partition lifecycle management |

---

## Practice Questions

1. You have a 2 TB `events` table queried almost exclusively by `event_date`. What strategy and interval?
2. Why must a UNIQUE index on a partitioned table include the partition key?
3. You need to delete all data older than 1 year nightly from a 500 GB table. How does partitioning help?
4. EXPLAIN shows all partitions being scanned even with a WHERE clause on the partition key. What might be wrong?
5. Hash-partition `user_events` by `user_id` into 8 partitions. A query filters only on `event_type`. How many partitions are scanned?

---

**← Previous:** [20_monitoring.md](20_monitoring.md)  
**Next →** [22_sharding.md](22_sharding.md)
