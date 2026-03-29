# learn_sql

A hands-on PostgreSQL learning repo using the classic EMP/DEPT dataset.
Covers the full journey from basic querying to senior/DBA-level topics — 25 chapters plus a quick-reference cheatsheet.

---

## Quick Start

```bash
# Start PostgreSQL with Docker
docker compose up -d

# Connect and load sample data
psql -h localhost -U admin -d learn_sql
\i ddl-script.sql

# Open any chapter
\i chp1.sql
```

Or connect with any SQL client (DBeaver, TablePlus, pgAdmin, DataGrip) and run the files directly.

---

## Learning Paths

Not sure where to start? Pick the track that matches your goal.

| Track | Chapters | Goal |
|---|---|---|
| **SQL Fundamentals** | 1 → 2 → 3 → 4 → 6 → 7 → 8 | New to SQL or switching from another database |
| **Interview Prep** | 1 → 2 → 3 → 10 → 9 → 12 → 25 | Preparing for a technical SQL interview |
| **Production / DBA** | 13 → 14 → 18 → 20 → 21 → 22 → 24 | Deploying and operating PostgreSQL in production |
| **Advanced PostgreSQL** | 15 → 16 → 17 → 19 → 23 | Deep PostgreSQL-specific features |

---

## Schema Overview

| Table | Description | Used In |
|---|---|---|
| `emp` | 14 employees — empno, ename, job, mgr, hiredate, sal, comm, deptno | All chapters |
| `dept` | 4 departments — deptno, dname, loc | Ch1–Ch3, Ch5, Ch7, Ch11 |
| `dept_east` | Subset of dept (depts 10, 20) | Ch3–Ch4 |
| `emp_bonus` | 3 bonus records — empno, received, type | Ch3, Ch7, Ch11 |
| `emp_commission` | Commission data for dept 10 | Ch7 |
| `new_sal` | Sample updated salaries | Ch4 |
| `dupes` | Duplicate rows for deduplication practice | Ch25 |
| `sales` | 6 rows of daily sales figures with dates | Ch7–Ch8 |
| `t1`, `t10`, `t100` | Helper tables for iteration examples | Ch8–Ch9 |
| Views `V`–`V7` | String manipulation practice views | Ch6 |

---

## Chapter Index

| # | File | Topic | Key Concepts |
|---|---|---|---|
| 1 | [chp1.sql](chp1.sql) | Retrieving Records | WHERE, BETWEEN, IN, LIKE, ILIKE, DISTINCT, CASE, COALESCE, FETCH FIRST, GREATEST/LEAST |
| 2 | [chp2.sql](chp2.sql) | Sorting Query Results | ORDER BY, multi-column sort, CASE sort, NULLS FIRST/LAST, COLLATE, LIMIT/OFFSET |
| 3 | [chp3.sql](chp3.sql) | Working with Multiple Tables | INNER/LEFT/RIGHT/FULL/SELF/CROSS JOIN, UNION/INTERSECT/EXCEPT, EXISTS, LATERAL, NATURAL JOIN |
| 4 | [chp4.sql](chp4.sql) | Inserting, Updating, and Deleting | INSERT, UPDATE, DELETE, TRUNCATE, ON CONFLICT (upsert), RETURNING, MERGE (PG 15+) |
| 5 | [chp5.sql](chp5.sql) | Metadata Queries | information_schema, pg_catalog, pg_indexes, pg_stat_*, table sizes, DDL generation |
| 6 | [chp6.sql](chp6.sql) | Working with Strings | UPPER/LOWER, TRIM, SUBSTR, REPLACE, SPLIT_PART, REGEXP_REPLACE, STRING_AGG, LPAD/RPAD, FORMAT |
| 7 | [chp7.sql](chp7.sql) | Working with Numbers | AVG/MIN/MAX/SUM/COUNT, running totals, median, PERCENTILE_CONT, RANK, GENERATE_SERIES, WIDTH_BUCKET |
| 8 | [chp8.sql](chp8.sql) | Date & Time | CURRENT_DATE, EXTRACT, DATE_PART, TO_CHAR, AGE, DATE_TRUNC, intervals, timezone, gap-finding |
| 9 | [chp9.sql](chp9.sql) | Common Table Expressions | Basic CTE, chained CTEs, CTE in UPDATE/DELETE, recursive org hierarchy, MATERIALIZED hint |
| 10 | [chp10.sql](chp10.sql) | Window Functions | ROW_NUMBER, RANK, DENSE_RANK, LAG/LEAD, FIRST_VALUE/LAST_VALUE, moving averages, NTILE, PERCENT_RANK |
| 11 | [chp11.sql](chp11.sql) | Advanced Aggregation & Pivoting | FILTER, GROUPING SETS, ROLLUP, CUBE, GROUPING(), ARRAY_AGG, JSON_AGG, pivot with CASE |
| 12 | [chp12.sql](chp12.sql) | Subqueries Deep Dive | Correlated vs non-correlated, scalar subqueries, derived tables, EXISTS vs IN, NOT IN NULL trap, Nth highest salary |
| 13 | [chp13.sql](chp13.sql) | Indexes & Query Performance | EXPLAIN ANALYZE, B-tree/Hash/GIN, partial indexes, covering indexes, functional indexes, pg_stat_user_indexes |
| 14 | [chp14.sql](chp14.sql) | Transactions, Views & Constraints | BEGIN/COMMIT/ROLLBACK, SAVEPOINT, isolation levels, ACID, CREATE VIEW, MATERIALIZED VIEW, PK/FK/CHECK/UNIQUE |
| 15 | [chp15.sql](chp15.sql) | PL/pgSQL — Functions & Procedures | CREATE FUNCTION, RETURNS TABLE, DECLARE/IF/LOOP, exception handling, OUT params, IMMUTABLE/STABLE, CREATE PROCEDURE |
| 16 | [chp16.sql](chp16.sql) | Triggers & Dynamic SQL | BEFORE/AFTER/INSTEAD OF triggers, NEW/OLD, WHEN clause, audit logging, EXECUTE, FORMAT %I/%L, parameterised dynamic SQL |
| 17 | [chp17.sql](chp17.sql) | JSON & JSONB Deep Dive | ->/->>, #>/->>, @>, ?, jsonb_set, jsonb_insert, GIN index, JSONPath, jsonb_array_elements, row_to_json |
| 18 | [chp18.sql](chp18.sql) | Table Partitioning | RANGE/LIST/HASH partitioning, partition pruning, EXPLAIN on partitions, attach/detach, archival pattern, subpartitioning |
| 19 | [chp19.sql](chp19.sql) | Full-Text Search | tsvector/tsquery, @@, to_tsvector, plainto_tsquery, ts_rank, ts_headline, GIN index, weights, generated column |
| 20 | [chp20.sql](chp20.sql) | Security — Roles, Grants & RLS | CREATE ROLE, GRANT/REVOKE, schema permissions, column grants, RLS policies, SECURITY DEFINER, privilege auditing |
| 21 | [chp21.sql](chp21.sql) | Advanced Performance Tuning | Join strategies, EXPLAIN ANALYZE deep dive, pg_stats, work_mem, VACUUM/autovacuum, parallel query, pg_stat_statements |
| 22 | [chp22.sql](chp22.sql) | Extensions & Ecosystem | pg_trgm, uuid-ossp, hstore, pgcrypto, tablefunc/crosstab, PostGIS overview, pg_available_extensions |
| 23 | [chp23.sql](chp23.sql) | Custom Data Types & Advanced Constraints | ENUM, Arrays, Composite types, Range types, Exclusion constraints, Generated columns, IDENTITY columns, Deferrable constraints |
| 24 | [chp24.sql](chp24.sql) | Bulk I/O, Pub/Sub, Locks & Sampling | COPY import/export, LISTEN/NOTIFY, Advisory locks, TABLESAMPLE BERNOULLI/SYSTEM |
| 25 | [chp25.sql](chp25.sql) | Classic SQL Interview Patterns | Gaps & Islands, Deduplication, Nth record, Running totals, Consecutive streaks, Missing values, Top-N per group |
| — | [cheatsheet.sql](cheatsheet.sql) | Quick Syntax Reference | One-stop syntax recall for all 25 chapters — open in any SQL client |
| — | [database_concepts.md](database_concepts.md) | Concepts for Freshers | Database vs SQL vs MySQL vs PostgreSQL, backup types, replication, best practices |

---

## Topic Quick-Lookup

Can't remember which chapter covers something? Search this table.

| Topic / Keyword | Chapter |
|---|---|
| What is a database, DBMS, SQL | [database_concepts.md](database_concepts.md) |
| PostgreSQL vs MySQL vs SQLite | [database_concepts.md](database_concepts.md) |
| Backup types (full, incremental, differential) | [database_concepts.md](database_concepts.md) |
| pg_dump, pg_restore, pg_basebackup | [database_concepts.md](database_concepts.md) |
| Replication, streaming, logical | [database_concepts.md](database_concepts.md) |
| PITR, WAL, failover, Patroni | [database_concepts.md](database_concepts.md) |
| WHERE, BETWEEN, LIKE, ILIKE | Ch1 |
| CASE expression | Ch1 |
| COALESCE, NULLIF | Ch1, Ch7 |
| ORDER BY, NULLS LAST | Ch2 |
| LIMIT, OFFSET, FETCH FIRST | Ch1, Ch2 |
| INNER JOIN, LEFT JOIN, FULL JOIN | Ch3 |
| SELF JOIN | Ch3 |
| LATERAL join | Ch3 |
| UNION, INTERSECT, EXCEPT | Ch3 |
| EXISTS, NOT EXISTS | Ch3, Ch12 |
| Upsert, ON CONFLICT | Ch4 |
| RETURNING clause | Ch4 |
| MERGE (PG 15+) | Ch4 |
| information_schema, pg_catalog | Ch5 |
| String functions (SUBSTR, REPLACE, REGEXP) | Ch6 |
| STRING_AGG | Ch6 |
| Median, Percentile | Ch7 |
| GENERATE_SERIES | Ch7 |
| WIDTH_BUCKET (histogram) | Ch7 |
| EXTRACT, DATE_TRUNC, AGE | Ch8 |
| Timezone, AT TIME ZONE | Ch8 |
| Interval arithmetic | Ch8 |
| CTE, WITH clause | Ch9 |
| Recursive CTE | Ch9 |
| ROW_NUMBER, RANK, DENSE_RANK | Ch10 |
| LAG, LEAD | Ch10 |
| Running total, Moving average | Ch10 |
| NTILE, PERCENT_RANK, CUME_DIST | Ch10 |
| GROUPING SETS, ROLLUP, CUBE | Ch11 |
| FILTER in aggregate | Ch11 |
| ARRAY_AGG, JSON_AGG | Ch11 |
| Pivot (CASE-based) | Ch11 |
| NOT IN NULL trap | Ch12 |
| Correlated subquery | Ch12 |
| Nth highest salary | Ch12, Ch25 |
| EXPLAIN, EXPLAIN ANALYZE | Ch13, Ch21 |
| B-tree, Hash, GIN index | Ch13 |
| Partial index, Covering index | Ch13 |
| Transactions, BEGIN/COMMIT | Ch14 |
| SAVEPOINT | Ch14 |
| Isolation levels (SERIALIZABLE, REPEATABLE READ) | Ch14 |
| MATERIALIZED VIEW, REFRESH | Ch14 |
| PL/pgSQL function, procedure | Ch15 |
| Exception handling in PL/pgSQL | Ch15 |
| Triggers (BEFORE/AFTER/INSTEAD OF) | Ch16 |
| Dynamic SQL, EXECUTE | Ch16 |
| JSONB operators (->, ->>, @>, ?) | Ch17 |
| jsonb_set, JSONPath | Ch17 |
| RANGE / LIST / HASH partitioning | Ch18 |
| Attach / Detach partition | Ch18 |
| Full-text search, tsvector, tsquery | Ch19 |
| ts_rank, ts_headline | Ch19 |
| GRANT, REVOKE, roles | Ch20 |
| Row-Level Security (RLS) | Ch20 |
| VACUUM, ANALYZE, autovacuum | Ch21 |
| pg_stat_statements | Ch21 |
| pg_trgm, fuzzy search | Ch22 |
| Crosstab, tablefunc pivot | Ch22 |
| pgcrypto, password hashing | Ch22 |
| ENUM type | Ch23 |
| Array type, unnest | Ch23 |
| Composite type | Ch23 |
| Range type, daterange, int4range | Ch23 |
| Exclusion constraint | Ch23 |
| Deferrable constraint | Ch23 |
| Generated column | Ch23 |
| IDENTITY column, SERIAL vs IDENTITY | Ch23 |
| Table inheritance | Ch23 |
| COPY import / export | Ch24 |
| LISTEN / NOTIFY (pub-sub) | Ch24 |
| Advisory locks | Ch24 |
| TABLESAMPLE BERNOULLI / SYSTEM | Ch24 |
| Gaps and Islands | Ch25 |
| Deduplication, DISTINCT ON | Ch25 |
| Consecutive streaks | Ch25 |
| Missing values in a sequence | Ch25 |
| Top-N per group | Ch25 |

---

## How to Use

- Run `ddl-script.sql` once when you start a fresh database session.
- Each chapter file is self-contained — run any file top-to-bottom in psql or a SQL client.
- Every section has a comment explaining the concept before the query.
- Every chapter ends with **Best Practice Notes** summarising key takeaways.
- Use **cheatsheet.sql** when you just need to recall syntax quickly — no explanations, just the code.

---

## Prerequisites

- PostgreSQL 13+ (some features require PostgreSQL 15+: `MERGE`; PostgreSQL 16 recommended)
- `psql` CLI or any SQL client (DBeaver, TablePlus, pgAdmin, DataGrip)
- Docker + Docker Compose (optional, for the included `docker-compose.yml` setup)
