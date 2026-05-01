# Chapter 22 — Sharding

Sharding is horizontal scaling — splitting data across multiple independent database servers (shards). It is the solution when a single PostgreSQL server cannot handle the write throughput or data volume required.

---

## 22.1 Vertical vs Horizontal Scaling

| | Vertical Scaling | Horizontal Scaling (Sharding) |
|-|-----------------|-------------------------------|
| How | Bigger machine (more CPU, RAM, disk) | More machines (each holds a subset of data) |
| Limit | Physical hardware ceiling | Theoretically unlimited |
| Complexity | Low | High |
| Cost | Expensive at the top end | Commodity hardware |
| When to use | First | When vertical is not enough |

**Always exhaust vertical scaling first.** Sharding adds enormous operational complexity. Most applications never need it.

---

## 22.2 What is a Shard?

A shard is an independent PostgreSQL instance holding a horizontal partition of the data.

```
All Users: 100 million rows
    │
    ├── Shard 1: users where user_id MOD 4 = 0  (25M rows)
    ├── Shard 2: users where user_id MOD 4 = 1  (25M rows)
    ├── Shard 3: users where user_id MOD 4 = 2  (25M rows)
    └── Shard 4: users where user_id MOD 4 = 3  (25M rows)
```

Each shard is a fully independent PostgreSQL server — its own CPU, RAM, disk, and WAL.

---

## 22.3 Sharding Strategies

### Range Sharding
Route rows based on a range of the shard key.

```
Shard 1: user_id 1 – 25,000,000
Shard 2: user_id 25,000,001 – 50,000,000
Shard 3: user_id 50,000,001 – 75,000,000
Shard 4: user_id 75,000,001 – 100,000,000
```

Pro: range queries on the shard key hit one shard only.  
Con: hotspots if recent IDs get all the writes (e.g., new signups all go to Shard 4).

### Hash Sharding
Route rows based on `hash(shard_key) MOD num_shards`.

```
shard_id = hash(user_id) MOD 4
```

Pro: even distribution — no hotspots.  
Con: range queries on the shard key hit all shards.

### Directory / Lookup Sharding
A routing table maps each key to a shard:

```
routing_table:
  tenant_id=1001 → shard_3
  tenant_id=1002 → shard_1
  tenant_id=2500 → shard_2
```

Pro: flexible, can move tenants between shards.  
Con: routing table is a bottleneck and must be highly available.

---

## 22.4 Choosing the Shard Key

The shard key determines data distribution and query efficiency. Choosing badly causes hotspots and cross-shard queries.

### Good shard keys:
- High cardinality (many distinct values)
- Even distribution
- Appears in most queries (queries hit one shard)
- Immutable (never changes for a row)

### Common choices:
| Use Case | Shard Key |
|----------|-----------|
| Multi-tenant SaaS | `tenant_id` |
| Social network | `user_id` |
| E-commerce | `user_id` or `order_id` |
| Geospatial | Geographic region |
| Time-series | Time range (for archiving) |

### Bad shard keys:
- `created_at` — all new writes go to latest shard (hotspot)
- Low-cardinality columns (`status`, `country`) — uneven distribution
- Columns that change (requires moving the row between shards)

---

## 22.5 Cross-Shard Queries — The Main Challenge

When a query needs data from multiple shards, it must be executed on each shard and results merged:

```sql
-- If sharded by user_id, this requires querying all shards:
SELECT COUNT(*) FROM orders WHERE product_id = 42;

-- But this hits one shard:
SELECT COUNT(*) FROM orders WHERE user_id = 1234;
```

Cross-shard JOINs are especially painful — the application or middleware must:
1. Query each shard
2. Fetch all results
3. Join in application memory or a coordinator node

Design your queries and schema so that **most queries are single-shard**.

---

## 22.6 Citus — Sharding Inside PostgreSQL

**Citus** is a PostgreSQL extension (open source, also available as managed cloud service) that turns PostgreSQL into a distributed database.

```
┌─────────────────────────────────────────┐
│  Coordinator Node (PostgreSQL + Citus)  │
│  - Accepts queries                      │
│  - Routes to worker nodes               │
│  - Merges results                       │
└───────┬──────────────┬──────────────────┘
        │              │
   ┌────▼────┐    ┌────▼────┐
   │Worker 1 │    │Worker 2 │  ...
   │(shards) │    │(shards) │
   └─────────┘    └─────────┘
```

The coordinator distributes queries automatically — your application connects to one PostgreSQL endpoint.

### Citus Setup

```sql
-- On coordinator: enable extension
CREATE EXTENSION citus;

-- Register worker nodes
SELECT citus_add_node('worker1', 5432);
SELECT citus_add_node('worker2', 5432);

-- Distribute a table across workers
-- (hash-shard by tenant_id into 32 shards across workers)
SELECT create_distributed_table('orders', 'tenant_id', shard_count => 32);

-- Co-locate related tables (orders and order_items on same shards)
SELECT create_distributed_table('order_items', 'tenant_id',
    colocate_with => 'orders');

-- Reference table: replicated to all workers (small lookup tables)
SELECT create_reference_table('countries');
```

### Citus Query Routing

```sql
-- Single-shard query (routes to one worker)
SELECT * FROM orders WHERE tenant_id = 1001 AND order_id = 5000;

-- Multi-shard aggregation (parallel across workers, merged at coordinator)
SELECT tenant_id, SUM(total) FROM orders GROUP BY tenant_id;

-- Cross-table join (works because orders and order_items are co-located)
SELECT o.order_id, oi.product_id
FROM orders o JOIN order_items oi USING (tenant_id, order_id)
WHERE o.tenant_id = 1001;
```

---

## 22.7 Application-Level Sharding

Without a tool like Citus, the application handles routing:

```python
def get_shard(user_id: int, num_shards: int = 4) -> str:
    shard_id = hash(user_id) % num_shards
    return f"shard_{shard_id}"

def get_connection(user_id: int):
    shard = get_shard(user_id)
    return connection_pool[shard]

# Usage
conn = get_connection(user_id=1234)
conn.execute("SELECT * FROM orders WHERE user_id = $1", [1234])
```

This works but adds routing logic to every query in the application. Citus or similar tools are preferable.

---

## 22.8 Resharding

When you add more shards, existing data must be redistributed. This is **resharding** — one of the most painful operations in a sharded system.

With Citus (online, no downtime):
```sql
-- Add a new worker
SELECT citus_add_node('worker3', 5432);

-- Rebalance shards across all workers
SELECT rebalance_table_shards('orders');
```

Without a tool: requires:
1. Stand up new shards
2. Copy data from old shards to new shards
3. Update routing logic
4. Verify consistency
5. Cut over with minimal downtime window

This is why choosing the right number of shards upfront matters — too few and you reshard soon; Citus's virtual shards (32+) decouple physical nodes from shard count.

---

## 22.9 Sharding Trade-offs

| Feature | Single PostgreSQL | Sharded |
|---------|------------------|---------|
| ACID transactions | ✅ Full | ❌ Cross-shard only with 2PC |
| JOINs | ✅ Any | ❌ Cross-shard is expensive |
| Write throughput | Limited by one server | ✅ Linear scaling |
| Operational complexity | Low | High |
| Schema changes | Simple | Must run on every shard |
| Backup | One backup | N backups |
| Monitoring | One server | N servers |

---

## 22.10 When to Actually Shard

Signs you need sharding:
- Write throughput exceeds what one server can handle (> ~50K writes/sec)
- Data size exceeds what one server can store economically (> few TB)
- Vertical scaling is too expensive or not available
- Specific regulatory requirements (data must stay in certain regions)

Consider these alternatives first:
1. Read replicas (offload reads)
2. Partitioning (manage large tables on one server)
3. Caching (reduce DB load)
4. Bigger hardware (vertical scaling)
5. Archiving old data (reduce working set size)

---

## Key Terms

| Term | Meaning |
|------|---------|
| Shard | An independent database server holding a horizontal slice of data |
| Shard key | Column used to route rows to shards |
| Hotspot | One shard receiving disproportionate load |
| Cross-shard query | A query that must access multiple shards |
| Citus | PostgreSQL extension for transparent horizontal sharding |
| Co-location | Placing related rows on the same shard for efficient JOINs |
| Resharding | Redistributing data when adding or removing shards |
| Reference table | Small table replicated to all shards (for lookups) |

---

## Practice Questions

1. What are the three sharding strategies? What are the pros and cons of each?
2. You shard `orders` by `user_id`. A product manager wants `SELECT COUNT(*) FROM orders WHERE product_id = 42`. What problem does this create?
3. What is co-location in Citus and why does it matter for JOINs?
4. Why is `created_at` a bad shard key for a social media app?
5. List four things you should try before sharding.
6. What makes resharding painful and how does Citus's virtual shard model reduce that pain?

---

**← Previous:** [21_partitioning.md](21_partitioning.md)  
**Next →** [23_nosql.md](23_nosql.md)
