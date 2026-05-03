# Chapter 1 — What is a Database?

## 1.1 Data vs Information

- **Data**: raw, unprocessed facts — `42`, `"John"`, `2024-01-01`
- **Information**: processed data with meaning — "John's age is 42, joined on Jan 1 2024"

A database turns data into information by organizing it with structure and relationships.

---

## 1.2 What is a Database?

A **database** is an organized collection of structured data stored electronically so it can be easily accessed, managed, and updated.

Real-world examples:
- A hospital storing patient records, diagnoses, medications
- An e-commerce site storing products, orders, customers
- A bank storing accounts, transactions, balances

Without a database you'd store all this in flat files — no relationships, no search, no concurrency, no safety.

---

## 1.3 What is a DBMS?

A **Database Management System (DBMS)** is software that sits between your application and the raw data. You never touch files directly — you talk to the DBMS.

```
Your Application
      ↓  SQL / API
    DBMS          ← manages everything below
      ↓
  Data on Disk
```

### What a DBMS does for you:
| Function | What it means |
|----------|--------------|
| Data definition | Create/modify tables, columns, types (DDL) |
| Data manipulation | INSERT, UPDATE, DELETE, SELECT (DML) |
| Data security | Control who can read/write what |
| Data integrity | Enforce rules — no nulls, no duplicates, valid foreign keys |
| Concurrency | Let 1000 users query at the same time safely |
| Backup & Recovery | Survive crashes and hardware failure |

---

## 1.4 DBMS vs RDBMS

| Feature | DBMS | RDBMS |
|---------|------|-------|
| Data storage | Files / hierarchical | Tables (rows & columns) |
| Relationships | No formal support | Enforced via foreign keys |
| Data integrity | Weak | Strong — constraints, ACID |
| Query language | None standard | SQL |
| Examples | Early file systems, XML stores | PostgreSQL, MySQL, Oracle, SQL Server |

**RDBMS** is the dominant type. PostgreSQL (which you already know) is an RDBMS.

---

## 1.5 Types of Databases

There is no single "best" database — the right choice depends on what you're storing and how you access it.

| Type | How data is stored | Best for | Examples |
|------|--------------------|----------|---------|
| **Relational** | Tables with rows & columns | Structured data, complex queries | PostgreSQL, MySQL, SQLite |
| **Document** | JSON-like documents | Flexible schemas, nested data | MongoDB, CouchDB |
| **Key-Value** | Simple key → value pairs | Caching, sessions, counters | Redis, DynamoDB |
| **Column-Family** | Column groups per row | Wide rows, analytics at scale | Cassandra, HBase |
| **Graph** | Nodes and edges | Social networks, recommendations | Neo4j, Amazon Neptune |
| **Time-Series** | Time-stamped records | Metrics, IoT, logs | InfluxDB, TimescaleDB |
| **Search Engine** | Inverted indexes | Full-text search | Elasticsearch, Solr |

---

## 1.6 Spreadsheet vs Database

| Scenario | Spreadsheet | Database |
|----------|-------------|----------|
| < 10,000 rows, single user | ✅ Fine | Overkill |
| Multiple users editing at once | ❌ Conflict-prone | ✅ |
| Relationships between data | ❌ Manual vlookups | ✅ Foreign keys |
| Enforcing data rules | ❌ Manual | ✅ Constraints |
| Millions of records | ❌ Crashes/slow | ✅ |
| Audit trail / history | ❌ Hard | ✅ WAL, triggers |
| Access control per user | ❌ | ✅ Roles & privileges |

---

## 1.7 The 3-Schema Architecture

Every RDBMS separates concerns into three layers — this is why you can change how data is stored without rewriting your application.

```
┌─────────────────────────────────┐
│   External Schema (Views)       │  ← What each user/app sees
├─────────────────────────────────┤
│   Conceptual Schema (Tables)    │  ← Logical structure: tables, columns, keys
├─────────────────────────────────┤
│   Internal Schema (Storage)     │  ← Physical: files, pages, indexes
└─────────────────────────────────┘
```

- **Data independence**: You can reorganize storage (internal) without changing the application (external).
- This is a core reason RDBMS has dominated for 50 years.

---

## 1.8 How PostgreSQL Fits In

PostgreSQL is:
- An **open-source RDBMS** (relational, SQL-based)
- One of the most feature-rich databases available
- Used in production at companies like Apple, Instagram, Spotify, GitHub
- Supports SQL + JSON + full-text search + extensions (PostGIS, TimescaleDB, etc.)

The concepts in this course apply to all RDBMS, but examples will use PostgreSQL.

---

## Key Terms

| Term | Meaning |
|------|---------|
| Schema | The blueprint/structure of a database |
| Instance | The actual data stored at a point in time |
| Query | A request to read or manipulate data |
| Metadata | Data about data (column names, types, constraints) |
| Data Independence | Changing storage without breaking applications |
| DDL | Data Definition Language — CREATE, ALTER, DROP |
| DML | Data Manipulation Language — SELECT, INSERT, UPDATE, DELETE |

---

## Practice Questions

1. What is the difference between a DBMS and a plain file system?
2. Name 3 advantages an RDBMS gives you over a spreadsheet.
3. You're building a social network. Which database type would you choose for storing "who follows who"? Why?
4. What are the three layers of the 3-schema architecture?
5. Why is data independence important?

---

**Next →** [02_data_models.md](02_data_models.md)
