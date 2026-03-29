# Database Concepts for Freshers
### Databases, SQL, MySQL, PostgreSQL — What's the Difference?
### + Backups, Replication, and Best Practices

---

## Part 1: The Confusion — Database vs SQL vs MySQL vs PostgreSQL

Think of it like this analogy:

> **A database is a filing cabinet.**
> **SQL is the language you use to talk to it.**
> **MySQL / PostgreSQL / SQLite are different brands of filing cabinets.**

---

### What is a Database?

A **database** is an organised collection of data stored on a computer so it can be retrieved, updated, and managed efficiently. Without a database, you'd store data in Excel files or plain text files — which breaks down the moment you have millions of rows or multiple people writing at the same time.

A **Database Management System (DBMS)** is the software that manages the database — it handles storage, retrieval, security, and transactions. When people say "the database", they usually mean the DBMS + the data together.

---

### What is SQL?

**SQL (Structured Query Language)** is the language you write to communicate with a relational database. It is NOT a database itself — it's a language, like English.

```sql
-- SQL is a language — you write this to ask the database for data
SELECT ename, sal FROM emp WHERE deptno = 10;
```

SQL is standardised by ISO/ANSI, which means the core syntax works across most databases. The problem is every database adds its own extra features on top of the standard, so a query written for MySQL might not work in PostgreSQL without changes.

---

### What is a Relational Database?

A **relational database** stores data in tables (rows and columns), and tables can be related to each other through keys. The theory behind it was invented by Edgar Codd at IBM in 1970.

```
emp table                    dept table
-----------                  -----------
empno | ename | deptno  ←→  deptno | dname
7369  | SMITH | 20           10     | ACCOUNTING
7499  | ALLEN | 30           20     | RESEARCH
```

The `deptno` column is the link between the two tables — this is a **foreign key relationship**.

All of the following are **Relational Database Management Systems (RDBMS)**:
- PostgreSQL
- MySQL
- MariaDB
- SQLite
- Microsoft SQL Server (often called "MSSQL")
- Oracle Database
- IBM Db2

---

### What is a Non-Relational (NoSQL) Database?

Some problems don't fit neatly into tables. **NoSQL databases** use different data models:

| Type | Examples | Good For |
|---|---|---|
| Document | MongoDB, CouchDB | Flexible JSON-like records (user profiles, product catalogues) |
| Key-Value | Redis, DynamoDB | Caching, sessions, fast lookups by a single key |
| Column-Family | Apache Cassandra, HBase | Time-series data, write-heavy workloads at massive scale |
| Graph | Neo4j, Amazon Neptune | Social networks, fraud detection (data with many relationships) |

**SQL vs NoSQL is not a competition.** Most real systems use both — PostgreSQL for the main data, Redis for caching, perhaps Elasticsearch for search.

---

## Part 2: The Main Databases Compared

### PostgreSQL

- **Type**: Relational (RDBMS) + object features
- **Created**: 1996 (evolved from POSTGRES at UC Berkeley, 1986)
- **Licence**: Open source (PostgreSQL Licence — very permissive, similar to BSD)
- **Owned by**: The PostgreSQL Global Development Group (community, no single company)
- **Strengths**:
  - Most SQL-standard-compliant of all open-source databases
  - Rich type system: JSON/JSONB, arrays, ranges, custom types, enums
  - Extensible: extensions for geospatial (PostGIS), full-text search, time-series (TimescaleDB)
  - Excellent at complex queries, analytics, and write-heavy workloads
  - ACID-compliant with the strongest isolation guarantees
  - Row-Level Security, advanced partitioning, logical replication
- **Used by**: Apple, Instagram, Reddit, Twitch, Shopify, GitHub, Notion
- **When to choose**: When correctness, complex queries, and rich data types matter

---

### MySQL

- **Type**: Relational (RDBMS)
- **Created**: 1995
- **Licence**: Open source (GPL) + commercial licence
- **Owned by**: Oracle Corporation (acquired in 2010 via Sun Microsystems)
- **Strengths**:
  - Extremely widespread — the "M" in the classic LAMP stack (Linux, Apache, MySQL, PHP)
  - Simple to set up and administer
  - Fast for read-heavy workloads (e.g. websites serving mostly SELECT queries)
  - Massive community and documentation
- **Weaknesses compared to PostgreSQL**:
  - Less SQL-standard-compliant (historically more lenient — silently truncates strings, accepts invalid dates)
  - Weaker support for complex queries, CTEs (added in MySQL 8.0), window functions (MySQL 8.0)
  - No native support for arrays, range types, or JSONB
  - Replication historically weaker (improving with MySQL 8.x)
- **Used by**: Facebook, Twitter (historically), Wikipedia, WordPress, YouTube
- **When to choose**: For web applications and CMSs (WordPress, Drupal), or when the team already knows MySQL

---

### MariaDB

- **Type**: Relational (RDBMS) — a fork of MySQL
- **Created**: 2009, by the original MySQL creator (Michael Widenius) after Oracle bought MySQL
- **Licence**: Open source (GPL)
- **Key difference from MySQL**: Fully open source, no Oracle control. Mostly MySQL-compatible but diverging over time with its own features.
- **When to choose**: Drop-in MySQL replacement when Oracle ownership is a concern.

---

### SQLite

- **Type**: Relational (RDBMS) — embedded, serverless
- **Key difference**: There is NO server. The entire database is a single file on disk. Your application reads/writes it directly.
- **Strengths**: Zero configuration, no network, perfect for mobile apps, local tools, testing
- **Weaknesses**: Not designed for concurrent writes from multiple processes. No user management.
- **Used by**: Every Android and iOS app (system databases), browsers (Chrome, Firefox), Xcode, Python's `sqlite3` module
- **When to choose**: Mobile apps, embedded systems, local desktop apps, automated test databases

---

### Microsoft SQL Server (MSSQL)

- **Type**: Relational (RDBMS)
- **Created**: 1989
- **Owned by**: Microsoft
- **Key feature**: Deep integration with the Windows ecosystem and .NET / C# applications. Uses T-SQL (Transact-SQL) dialect.
- **When to choose**: Enterprise environments running on Windows, .NET applications, companies already in the Microsoft ecosystem

---

### Oracle Database

- **Type**: Relational (RDBMS) + object features
- **Created**: 1979 (one of the oldest)
- **Owned by**: Oracle Corporation
- **Key features**: Industry-leading performance for massive enterprise workloads, RAC (Real Application Clusters) for extreme high availability, PL/SQL procedural language
- **When to choose**: Large enterprises, banks, telecoms, government systems. Very expensive licensing.

---

### Quick Comparison Table

| Feature | PostgreSQL | MySQL | SQLite | SQL Server | Oracle |
|---|---|---|---|---|---|
| Open Source | Yes (free) | Partially (GPL, but Oracle-owned) | Yes (public domain) | No | No |
| Serverless | No | No | **Yes** | No | No |
| JSON support | Excellent (JSONB) | Basic | No | Good | Good |
| Window functions | Full | MySQL 8.0+ | 3.25+ | Full | Full |
| Stored procedures | PL/pgSQL | Yes | No | T-SQL | PL/SQL |
| Best for | Complex apps, analytics | Web apps, CMSs | Mobile, local | .NET / Windows | Large enterprise |
| Cost | Free | Free (community) | Free | Paid | Very expensive |

---

## Part 3: Backups — Types and Best Practices

A backup is a copy of your data that you can restore from if something goes wrong — hardware failure, accidental deletion, corruption, ransomware, or a bad migration.

> **The golden rule of backups: a backup you have never tested is not a backup.**

---

### Types of Backup

#### 1. Full Backup
A complete copy of the entire database at a point in time.

- **Pros**: Simple to restore — just one file.
- **Cons**: Slowest and largest. If you run it daily, you store 7 full copies per week.
- **Use when**: Data is small, or as the weekly "anchor" backup.

```
Sunday:   FULL backup   → 10 GB
Monday:   FULL backup   → 10 GB
...
Total per week: 70 GB
```

---

#### 2. Incremental Backup
Only backs up data that has **changed since the last backup** (full or incremental).

- **Pros**: Very fast, very small.
- **Cons**: Restoration is complex — you need the full backup PLUS every incremental in order.
- **Use when**: Data changes frequently and backup windows are short.

```
Sunday:   FULL backup       → 10 GB
Monday:   Incremental       → 0.5 GB (only Monday's changes)
Tuesday:  Incremental       → 0.3 GB (only Tuesday's changes)
...
Restore Tuesday: need Sunday FULL + Monday INC + Tuesday INC
```

---

#### 3. Differential Backup
Backs up data that has **changed since the last FULL backup** (not since the last backup).

- **Pros**: Easier to restore than incremental (only need full + one differential).
- **Cons**: Grows larger each day until the next full backup.

```
Sunday:   FULL backup       → 10 GB
Monday:   Differential      → 0.5 GB (changes since Sunday)
Tuesday:  Differential      → 0.8 GB (all changes since Sunday)
Wednesday:Differential      → 1.2 GB (all changes since Sunday)
...
Restore Wednesday: only need Sunday FULL + Wednesday DIFF
```

---

#### 4. Logical Backup (pg_dump)
Exports the database as **SQL statements** (CREATE TABLE, INSERT, etc.) or a structured format that can be replayed on any compatible PostgreSQL instance.

- **Tool in PostgreSQL**: `pg_dump` and `pg_dumpall`
- **Pros**: Portable across PostgreSQL versions, easy to inspect, can restore a single table
- **Cons**: Slower to restore than physical for large databases; does not include WAL/point-in-time recovery

```bash
# Backup a single database
pg_dump -h localhost -U admin -d learn_sql -F c -f learn_sql.dump
# -F c = custom format (compressed, supports parallel restore)

# Backup all databases + roles + global objects
pg_dumpall -h localhost -U admin -f full_cluster.sql

# Restore a single database
pg_restore -h localhost -U admin -d learn_sql -F c learn_sql.dump

# Restore from plain SQL dump
psql -h localhost -U admin -d learn_sql -f learn_sql.sql
```

---

#### 5. Physical Backup (pg_basebackup)
Copies the **raw data files** on disk — the actual files PostgreSQL writes to. Faster to restore for large databases.

- **Tool in PostgreSQL**: `pg_basebackup`
- **Pros**: Fastest restore for large databases; forms the base for Point-In-Time Recovery (PITR)
- **Cons**: PostgreSQL-version-specific (you cannot restore a PG 15 physical backup onto PG 14), cannot restore a single table

```bash
# Take a physical base backup
pg_basebackup -h localhost -U admin -D /backup/base -Ft -z -P
# -Ft = tar format, -z = gzip compress, -P = show progress

# This is the foundation for PITR (see WAL below)
```

---

#### 6. Point-In-Time Recovery (PITR)
Not a backup type itself, but a capability that lets you restore the database to **any specific moment in time** — not just the last backup.

PostgreSQL writes every change to the **Write-Ahead Log (WAL)**. If you keep your base backup + all WAL files since that backup, you can replay the WAL to any point in time.

```
Base backup (Sunday)  +  WAL files (Mon, Tue, Wed)
                                           ↑
                              Restore to Wednesday 14:37:52
```

This is essential for recovering from "I ran DELETE without WHERE at 2pm" scenarios — you restore to 1:59pm.

---

### PostgreSQL Backup Tools Summary

| Tool | Type | Format | Use Case |
|---|---|---|---|
| `pg_dump` | Logical | SQL, custom, directory, tar | Single database backup, cross-version migration |
| `pg_dumpall` | Logical | SQL | Entire cluster including roles and tablespaces |
| `pg_restore` | Restore | Works with custom/directory/tar from pg_dump | Restore from pg_dump output |
| `pg_basebackup` | Physical | tar or plain files | Physical backup, PITR setup, replica seeding |
| `pgBackRest` | Physical + WAL | Compressed, deduplicated | Production PITR, automated retention policies |
| `Barman` | Physical + WAL | Compressed | Enterprise backup management for PostgreSQL |

---

### Backup Best Practices

**1. Follow the 3-2-1 rule:**
- **3** copies of your data
- **2** different storage media (e.g. local disk + cloud)
- **1** copy offsite (different physical location / different cloud region)

**2. Test your restores regularly.**
Schedule a monthly restore to a test server and verify the data is correct. A backup you have never restored from is a backup you cannot trust.

**3. Automate and monitor.**
Manual backups get forgotten. Use a scheduler (cron, pgBackRest, cloud automated snapshots) and alert if a backup job fails.

**4. Check backup size and duration.**
A backup that suddenly takes 10x longer or produces a 10x larger file is a signal that something changed — investigate before you need it.

**5. Use pg_dump --format=custom (-Fc) not plain SQL for large databases.**
Custom format is compressed, supports parallel restore with `-j`, and lets you restore individual tables.

**6. Keep multiple retention points.**
A common policy:
- Daily backups → keep 7 days
- Weekly backups → keep 4 weeks
- Monthly backups → keep 12 months

**7. Secure your backups.**
Encrypt backups at rest (pgBackRest supports AES-256). An unencrypted backup is as sensitive as the production database.

**8. Store backups separately from the database server.**
If the server's disk fails or is compromised, backups on the same disk are gone too.

---

## Part 4: Replication — What It Is and Why It Matters

**Replication** means keeping two or more copies of the database in sync in real time (or near real time).

The server you write to is called the **Primary** (or Master).
The copy that receives updates is called the **Replica** (or Standby / Secondary / Slave).

### Why Replicate?

| Problem | How Replication Helps |
|---|---|
| **High Availability** | If the primary server crashes, a replica can take over (failover) — minimises downtime |
| **Read Scaling** | Direct heavy read traffic (reports, analytics) to replicas so the primary stays fast |
| **Disaster Recovery** | A replica in a different data centre / cloud region survives a site-level failure |
| **Zero-downtime upgrades** | Upgrade the replica first, then promote it and cut over |

---

### Types of Replication in PostgreSQL

#### 1. Streaming Replication (Physical — built in)
The primary sends **WAL (Write-Ahead Log) bytes** to the replica in real time. The replica replays those bytes to stay in sync.

- **Synchronous**: Primary waits for the replica to confirm it received the WAL before acknowledging the transaction to the client. Zero data loss. Slightly slower writes.
- **Asynchronous**: Primary does not wait. Faster writes, but the replica can lag behind by a few seconds. Small risk of data loss if the primary crashes.

```
Client → [write] → Primary ──WAL stream──→ Replica
                      ↑
              If synchronous: waits for replica ACK
              If asynchronous: does not wait
```

This is the most common setup. The replica is a byte-for-byte copy of the primary — same PostgreSQL version, same file layout. The replica is **read-only** while replicating.

---

#### 2. Logical Replication (built in, PostgreSQL 10+)
Instead of WAL bytes, the primary sends **logical changes** (INSERT, UPDATE, DELETE with actual row data). The replica applies those changes using SQL-level logic.

- **Pros**:
  - Replica can be a different PostgreSQL major version
  - Can replicate only specific tables (not the whole database)
  - Replica can have extra indexes or columns
  - Used for zero-downtime major version upgrades
- **Cons**:
  - Does not replicate DDL changes (ALTER TABLE, CREATE INDEX) automatically
  - Slightly higher overhead than streaming replication

```
Primary publishes: CREATE PUBLICATION my_pub FOR TABLE emp, dept;
Replica subscribes: CREATE SUBSCRIPTION my_sub CONNECTION '...' PUBLICATION my_pub;
```

---

#### 3. Replication Slots
A replication slot makes the primary remember how far a replica has read the WAL — it won't delete WAL files the replica still needs. Prevents replica falling too far behind from causing data loss. Must be monitored — a disconnected replica with a slot can cause the primary's disk to fill up.

---

### Replication vs Backup — They Are NOT the Same

This is a very common misunderstanding:

| | Replication | Backup |
|---|---|---|
| **Purpose** | High availability + read scaling | Disaster recovery + point-in-time restore |
| **Protects against server crash?** | Yes | Yes |
| **Protects against accidental DELETE?** | **No** — the delete replicates immediately | **Yes** — restore from before the delete |
| **Protects against corruption?** | **No** — corruption replicates | **Yes** — restore from clean backup |
| **Protects against ransomware?** | **No** — encryption replicates | **Yes** — if backups are stored offsite |

> **You need BOTH replication AND backups.** Replication is not a substitute for backups.

---

### Replication Terminology Glossary

| Term | Meaning |
|---|---|
| **Primary / Master** | The server that accepts writes |
| **Replica / Standby / Secondary / Slave** | A server that receives and replays changes from the primary |
| **Hot Standby** | A replica that accepts read queries while replicating |
| **Warm Standby** | A replica that replicates but does NOT accept queries |
| **Failover** | Promoting a replica to primary after the primary fails |
| **Switchover** | A planned, graceful failover (e.g. for maintenance) |
| **Lag** | How far behind the replica is (measured in bytes or seconds) |
| **WAL** | Write-Ahead Log — the journal of every change PostgreSQL makes |
| **PITR** | Point-In-Time Recovery — restoring to a specific moment using WAL |
| **Replication Slot** | A bookmark that tells the primary how far a replica has read |
| **Publication** | Defines which tables to replicate (logical replication) |
| **Subscription** | The replica's connection to a publication |

---

### Popular High-Availability Tools (built on top of replication)

| Tool | What It Does |
|---|---|
| **Patroni** | Automates failover for PostgreSQL clusters using etcd/Consul/ZooKeeper for consensus |
| **Repmgr** | Simpler failover management and monitoring for streaming replication |
| **pgBackRest** | Backup + WAL archiving tool that integrates with PITR and replication |
| **pgBouncer** | Connection pooler — sits in front of PostgreSQL to manage connection limits |
| **HAProxy** | Load balancer — routes reads to replicas and writes to primary |

---

## Summary

```
DATABASE    — the organised collection of data
DBMS        — the software managing it (PostgreSQL, MySQL, SQLite, etc.)
SQL         — the language you write to talk to a relational DBMS
PostgreSQL  — open-source RDBMS, best for complex data and correctness
MySQL       — open-source RDBMS (Oracle-owned), best for web apps
SQLite      — embedded, serverless RDBMS, best for local/mobile apps
MSSQL       — Microsoft's RDBMS, best for Windows/.NET environments
Oracle      — enterprise RDBMS, powerful and expensive

BACKUP TYPES:
  Full          — complete copy, slowest/largest, simplest restore
  Incremental   — only changes since last backup, fastest/smallest, complex restore
  Differential  — changes since last FULL, medium speed/size, moderate restore
  Logical       — SQL statements via pg_dump, portable, single-table restore
  Physical      — raw files via pg_basebackup, fastest restore, enables PITR

REPLICATION:
  Streaming     — WAL bytes sent in real time, exact copy, read scaling + HA
  Logical       — row-level changes, cross-version, selective tables

KEY RULE: Replication ≠ Backup. You need both.
KEY RULE: Test your restores. An untested backup is not a backup.
```
