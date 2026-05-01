# Chapter 23 — NoSQL Databases

NoSQL databases trade the relational model's structure and guarantees for flexibility, scale, or specialization. Knowing when to use them — and when not to — is a critical engineering skill.

---

## 23.1 Why NoSQL Exists

The relational model excels at structured data with complex queries. NoSQL databases emerged to solve problems it handles poorly:

- **Schema flexibility**: Product catalog where each item has different attributes
- **Massive write throughput**: IoT sensors writing millions of events per second
- **Horizontal scaling by default**: Document stores that shard automatically
- **Specialized access patterns**: Graph traversal, geospatial queries, full-text search

NoSQL does not mean "no SQL" — it means "Not Only SQL." Many NoSQL databases now support SQL-like query languages.

---

## 23.2 MongoDB — Document Store

### What it is
Stores data as **BSON documents** (binary JSON). Collections = tables, documents = rows.

### Data Model
```json
{
  "_id": ObjectId("64f3a1b2c9d4e5f6a7b8c9d0"),
  "name": "Alice",
  "email": "alice@example.com",
  "address": {
    "street": "123 Main St",
    "city": "New York",
    "zip": "10001"
  },
  "orders": [
    { "order_id": 1001, "total": 59.99, "date": "2024-01-15" },
    { "order_id": 1002, "total": 129.00, "date": "2024-02-20" }
  ],
  "tags": ["premium", "nyc"]
}
```

### Key Features
- Schema-less: each document can have different fields
- Nested documents and arrays — no joins needed for related data
- Horizontal sharding built-in (mongos router)
- Secondary indexes including compound, geospatial, text
- Aggregation pipeline for complex analytics
- Transactions (since MongoDB 4.0, multi-document)

### MongoDB vs PostgreSQL

| | PostgreSQL | MongoDB |
|-|-----------|---------|
| Schema | Rigid (enforced) | Flexible (per-document) |
| Joins | ✅ Native, efficient | ❌ `$lookup` is expensive |
| Transactions | ✅ Full ACID | ✅ (limited, added later) |
| Horizontal scale | Manual/Citus | ✅ Built-in sharding |
| Complex queries | ✅ SQL | Aggregation pipeline |

### When to use MongoDB
- Product catalogs with varying attributes per product
- Content management systems (articles, media metadata)
- User profiles with flexible, evolving structure
- Rapid prototyping when schema is unknown

### When NOT to use MongoDB
- Data with complex relationships (many JOINs) → use PostgreSQL
- Financial data requiring strict ACID → use PostgreSQL
- When you already know the schema → use PostgreSQL

---

## 23.3 Redis — Key-Value / Data Structures Store

### What it is
An in-memory data structure store. Blazing fast (< 1ms) because everything lives in RAM.

### Data Structures
```
Strings:   "session:abc123" → "user_id:42"
Lists:     "queue:emails" → ["job1", "job2", "job3"]   (FIFO/LIFO)
Sets:      "online_users" → {42, 103, 789}
Sorted Sets: "leaderboard" → {alice:9850, bob:9200, carol:8100}
Hashes:    "user:42" → {name: Alice, plan: pro, credits: 100}
Streams:   append-only log of events (like Kafka-lite)
```

### Key Features
- Sub-millisecond reads and writes
- Pub/Sub messaging
- TTL (time-to-live) per key — automatic expiry
- Lua scripting for atomic operations
- Persistence options: RDB snapshots, AOF log
- Redis Cluster for horizontal scaling
- Redis Sentinel for HA

### Common Use Cases

```
┌─────────────────┬─────────────────────────────────────────┐
│ Use Case        │ Redis Pattern                           │
├─────────────────┼─────────────────────────────────────────┤
│ Session storage │ SET session:abc123 "{...}" EX 3600      │
│ Rate limiting   │ INCR rate:user:42:minute → check > 100  │
│ Caching         │ GET/SET with TTL                         │
│ Job queue       │ LPUSH / BRPOP                            │
│ Leaderboard     │ Sorted Set: ZADD + ZRANK                 │
│ Pub/Sub         │ PUBLISH channel message                  │
│ Distributed lock│ SET key value NX EX 30                  │
│ Real-time counts│ INCR, HINCRBY                            │
└─────────────────┴─────────────────────────────────────────┘
```

### Redis as a Cache for PostgreSQL

```python
def get_user(user_id: int):
    # Try cache first
    cached = redis.get(f"user:{user_id}")
    if cached:
        return json.loads(cached)

    # Cache miss → query PostgreSQL
    user = db.query("SELECT * FROM users WHERE id = $1", user_id)

    # Store in Redis with 1-hour TTL
    redis.set(f"user:{user_id}", json.dumps(user), ex=3600)
    return user
```

### When to use Redis
- Caching database query results
- Session/token storage
- Real-time features (live counters, leaderboards, chat)
- Job queues and task scheduling
- Rate limiting
- Pub/Sub messaging between services

---

## 23.4 Apache Cassandra — Wide-Column Store

### What it is
A distributed, highly available column-family database designed for massive write throughput across many nodes. Originally built at Facebook for Inbox search.

### Data Model
```
Table: user_activity
Partition key: user_id
Clustering key: activity_time (DESC)

user_id | activity_time       | action     | details
--------+---------------------+------------+---------
   42   | 2024-11-01 14:00:00 | page_view  | /home
   42   | 2024-11-01 13:58:00 | click      | button#signup
   42   | 2024-11-01 13:55:00 | page_view  | /pricing
```

All rows with the same partition key are stored together. Reads by partition key are fast; anything else is a full scan.

### Key Features
- Masterless — every node is equal (no single point of failure)
- Automatically shards data across nodes
- Tunable consistency (ONE, QUORUM, ALL per query)
- Excellent write throughput (append-only writes)
- CQL (Cassandra Query Language) — SQL-like
- Built-in multi-datacenter replication

### Cassandra vs PostgreSQL

| | PostgreSQL | Cassandra |
|-|-----------|-----------|
| Write throughput | High | Extreme (millions/sec) |
| Read patterns | Any SQL query | Must design for access pattern |
| JOINs | ✅ | ❌ Not supported |
| Flexibility | High | Low (query-driven design) |
| ACID | ✅ Full | Limited (lightweight transactions only) |
| Horizontal scale | With Citus | ✅ Native |

### When to use Cassandra
- Time-series data at extreme scale (IoT, metrics, logs)
- User activity feeds (what did user X do in the last 30 days)
- Messages/notifications at Twitter/WhatsApp scale
- When you need multi-datacenter active-active writes

### Cassandra design rule
Design your tables around your queries, not your data. Each query pattern needs its own table (denormalized). There are no JOINs.

---

## 23.5 Other Notable NoSQL Types

### Neo4j — Graph Database
- Stores nodes and edges with properties
- Query language: Cypher
- Best for: social graphs, fraud detection, recommendation engines, knowledge graphs
```cypher
MATCH (alice:Person)-[:FOLLOWS]->(bob:Person)-[:LIKES]->(post:Post)
WHERE alice.name = 'Alice'
RETURN post.title
```

### Elasticsearch — Search Engine
- Distributed full-text search built on Lucene
- JSON documents, inverted index
- Best for: product search, log analytics (ELK stack), autocomplete
- Not a primary store — sync from PostgreSQL via CDC

### InfluxDB / TimescaleDB — Time-Series
- Optimized for high-frequency time-stamped data
- TimescaleDB is a PostgreSQL extension — full SQL + time-series optimizations
- Best for: metrics, monitoring, IoT, financial tick data

### DynamoDB — Managed Key-Value/Document
- AWS-native, serverless, auto-scaling
- Pay per request model
- Best for: AWS-native apps, variable/unpredictable traffic
- Limited query flexibility (must design access patterns upfront)

---

## 23.6 Polyglot Persistence in Practice

A real production system often uses multiple databases:

```
┌─────────────────────────────────────────────────────────────┐
│                    E-Commerce Platform                       │
├──────────────┬──────────────┬────────────────┬─────────────┤
│  PostgreSQL  │    Redis     │  Elasticsearch │  MongoDB    │
│  Orders,     │  Sessions,   │  Product       │  Product    │
│  Users,      │  Cart cache, │  search,       │  catalog    │
│  Payments    │  Rate limits │  autocomplete  │  (flexible) │
└──────────────┴──────────────┴────────────────┴─────────────┘
```

Each database handles what it does best. PostgreSQL remains the system of record for transactional data.

---

## 23.7 Choosing the Right Database

```
Is your data structured with relationships?
  YES → Start with PostgreSQL
  NO  → Does it vary a lot per record? → MongoDB

Do you need sub-millisecond performance?
  YES → Redis (if it fits in RAM)

Do you need extreme write throughput (millions/sec)?
  YES → Cassandra

Do you need full-text search?
  YES → Elasticsearch (or PostgreSQL full-text for simpler cases)

Do you need complex graph traversal?
  YES → Neo4j

Do you need time-series with SQL?
  YES → TimescaleDB (PostgreSQL extension)
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| Document store | Database storing JSON-like self-contained documents |
| Key-value store | Dictionary: key maps to an opaque value |
| Wide-column store | Rows with dynamic column sets; optimized by partition key |
| Graph database | Nodes and edges as first-class citizens |
| Polyglot persistence | Using multiple database types in one system |
| Tunable consistency | Cassandra: choose consistency level per query |
| CDC | Change Data Capture — stream changes from one DB to another |

---

## Practice Questions

1. You're building a product catalog where each product type has different attributes. PostgreSQL or MongoDB? Why?
2. What is Redis used for that PostgreSQL cannot replace?
3. Cassandra requires you to design tables around your queries. What does this mean and why?
4. Your app needs to search products by name, description, and tags with autocomplete. Which database handles this best?
5. Design a polyglot architecture for a ride-sharing app (users, rides, real-time location, surge pricing, trip history).
6. MongoDB added multi-document transactions in v4.0. Does this make it equivalent to PostgreSQL for financial data? Why or why not?

---

**← Previous:** [22_sharding.md](22_sharding.md)  
**Next →** [24_cap_distributed.md](24_cap_distributed.md)
