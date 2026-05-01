# Chapter 2 — Data Models

A **data model** defines how data is structured, stored, and accessed. Choosing the right model is one of the most important architectural decisions you make.

---

## 2.1 What is a Data Model?

A data model answers three questions:
1. **Structure** — how is data organized?
2. **Operations** — how do you read/write it?
3. **Constraints** — what rules must data follow?

Think of it as the "shape" of your database.

---

## 2.2 The Relational Model

The dominant model since the 1970s (Edgar Codd, IBM, 1970).

Data is stored in **tables** (also called relations):
- Each table has named **columns** with fixed types
- Each row is a **record / tuple**
- Relationships between tables are expressed via **keys**

```
employees
┌────┬──────────┬────────┬───────────┐
│ id │ name     │ salary │ dept_id   │
├────┼──────────┼────────┼───────────┤
│  1 │ Alice    │ 90000  │ 10        │
│  2 │ Bob      │ 75000  │ 20        │
└────┴──────────┴────────┴───────────┘

departments
┌────┬─────────────┐
│ id │ name        │
├────┼─────────────┤
│ 10 │ Engineering │
│ 20 │ Marketing   │
└────┴─────────────┘
```

`employees.dept_id` → `departments.id` = the relationship.

**Strengths**: structured, enforces integrity, powerful SQL queries, ACID transactions  
**Weaknesses**: rigid schema, joins can be slow on massive scale, poor fit for deeply nested data

---

## 2.3 The Document Model

Data is stored as **self-contained documents** (usually JSON or BSON).

```json
{
  "id": 1,
  "name": "Alice",
  "salary": 90000,
  "department": {
    "id": 10,
    "name": "Engineering"
  },
  "skills": ["Python", "SQL", "Docker"]
}
```

No joins needed — related data is nested inside the document.

**Strengths**: flexible schema (fields can vary per document), natural for hierarchical data, easy to change structure  
**Weaknesses**: data duplication (department stored in every employee), hard to enforce cross-document integrity, poor for complex queries across many documents

**When to use**: content management, product catalogs, user profiles, anything with varying structure per record

---

## 2.4 The Key-Value Model

The simplest model: a giant dictionary.

```
"session:abc123" → { "user_id": 42, "expires": "2024-12-01" }
"cache:user:42"  → { "name": "Alice", "plan": "pro" }
"counter:views"  → 1048576
```

You can only look up by key — no filtering, no joins.

**Strengths**: extremely fast reads/writes (O(1)), simple to scale  
**Weaknesses**: no queries, no relationships, no structure enforced

**When to use**: session storage, caching, rate limiting, feature flags, real-time counters

---

## 2.5 The Column-Family Model

Data is stored by **column groups**, not rows. Each row can have different columns.

```
Row key: "user:42"
  profile:name    → "Alice"
  profile:email   → "alice@example.com"
  activity:last_login → "2024-11-01"
  activity:pages_viewed → 342
```

Designed for massive scale — petabytes across thousands of nodes.

**Strengths**: horizontal scaling, excellent write throughput, great for sparse data  
**Weaknesses**: limited query patterns, no joins, eventual consistency by default

**When to use**: IoT sensor data, activity logs, messaging at Twitter/Facebook scale

---

## 2.6 The Graph Model

Data is stored as **nodes** (entities) and **edges** (relationships).

```
(Alice) --[FOLLOWS]--> (Bob)
(Alice) --[LIKES]--> (Post:42)
(Bob)   --[WORKS_AT]--> (Company:Acme)
```

Relationships are first-class citizens — traversing them is fast.

**Strengths**: natural for connected data, efficient multi-hop queries ("friends of friends who bought X")  
**Weaknesses**: poor for simple tabular data, niche tooling, harder to learn

**When to use**: social networks, fraud detection, recommendation engines, knowledge graphs

---

## 2.7 The Time-Series Model

Optimized for **timestamped data** arriving in sequence.

```
timestamp           | metric      | value
--------------------|-------------|-------
2024-11-01 00:00:01 | cpu_usage   | 42.3
2024-11-01 00:00:02 | cpu_usage   | 43.1
2024-11-01 00:00:02 | memory_free | 2048
```

Compresses time-series data aggressively, supports fast range queries by time.

**When to use**: server metrics, financial tick data, IoT sensor readings, application logs

---

## 2.8 Comparing All Models

| Model | Data Shape | Query Style | Best For |
|-------|-----------|-------------|----------|
| Relational | Tables | SQL (any) | Structured, transactional |
| Document | JSON trees | Find by field | Hierarchical, flexible schema |
| Key-Value | Dictionary | Lookup by key | Cache, sessions |
| Column-Family | Column groups | Row key + column filter | Wide rows, massive scale |
| Graph | Nodes + edges | Graph traversal | Connected data |
| Time-Series | Timestamped rows | Time range queries | Metrics, logs |

---

## 2.9 Polyglot Persistence

Modern systems often use **multiple database types** together — the right tool for each job.

```
┌────────────────────────────────────────────────────┐
│                    Your Application                  │
└──────────┬──────────────┬────────────┬─────────────┘
           ↓              ↓            ↓
      PostgreSQL        Redis       Elasticsearch
   (orders, users)   (sessions,   (product search,
                      caching)     full-text)
```

This is called **polyglot persistence** — each store does what it's best at.

---

## 2.10 The Hierarchical & Network Models (Historical)

Before the relational model, databases used:
- **Hierarchical model** (IBM IMS, 1960s) — tree structure, parent/child. Fast reads but rigid, no many-to-many.
- **Network model** (CODASYL, 1970s) — graph of records with pointers. More flexible but complex to navigate.

Both were replaced by the relational model because SQL is far easier than manually traversing pointers.

---

## Key Terms

| Term | Meaning |
|------|---------|
| Data Model | How data is structured and accessed |
| Relation / Table | The core unit of the relational model |
| Document | A self-contained JSON record |
| Node / Edge | The units of a graph database |
| Polyglot Persistence | Using multiple database types in one system |
| Schema-on-write | Relational — enforce structure when writing |
| Schema-on-read | Document — interpret structure when reading |

---

## Practice Questions

1. What are the three questions a data model must answer?
2. You're storing a product catalog where each product has a different set of attributes (a shirt has "size" and "color", a laptop has "RAM" and "CPU"). Which model fits best?
3. Explain why the document model leads to data duplication.
4. Your app needs to answer "show me all friends-of-friends who are in the same city." Which model is best suited?
5. What is polyglot persistence and why do companies use it?

---

**← Previous:** [01_what_is_database.md](01_what_is_database.md)  
**Next →** [03_er_diagrams.md](03_er_diagrams.md)
