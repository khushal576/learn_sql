# learn_sql

A hands-on SQL learning repo using the classic EMP/DEPT dataset (PostgreSQL).
Covers the full PostgreSQL journey: from basic querying to senior/DBA-level topics including window functions, CTEs, PL/pgSQL, triggers, JSON, partitioning, full-text search, RLS, and performance tuning.

---

## Setup

1. Start PostgreSQL and connect to your database.
2. Run the DDL script to create all tables and sample data:

```sql
\i ddl-script.sql
```

3. Open any chapter file and run it:

```sql
\i chp1.sql
```

---

## Schema Overview

| Table | Description |
|---|---|
| `emp` | 14 employees — empno, ename, job, mgr, hiredate, sal, comm, deptno |
| `dept` | 4 departments — deptno, dname, loc |
| `dept_east` | Subset of dept (depts 10, 20) |
| `emp_bonus` | 3 bonus records — empno, received, type |
| `emp_commission` | Commission data for dept 10 |
| `new_sal` | Sample updated salaries |
| `dupes` | Duplicate rows for deduplication practice |
| `sales` | 6 rows of daily sales figures with dates |
| `t1`, `t10`, `t100` | Helper tables for iteration examples |
| Views `V`–`V7` | String manipulation practice views |

---

## Chapters

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

---

## How to Use

- Run `ddl-script.sql` once per session (or once per fresh database).
- Each chapter is self-contained — open any file and run it top-to-bottom.
- Each section has a comment explaining the concept before the query.
- Each chapter ends with **Best Practice Notes** summarising key takeaways.
- **Chapters 1–7**: SQL fundamentals — filtering, sorting, joins, DML, strings, numbers.
- **Chapters 8–11**: Intermediate — dates, CTEs, window functions, advanced aggregation.
- **Chapters 12–14**: Interview-ready — subqueries, indexes/performance, transactions/views/constraints.
- **Chapters 15–18**: Advanced — PL/pgSQL, triggers, JSON/JSONB, table partitioning.
- **Chapters 19–22**: Senior/DBA — full-text search, security/RLS, performance tuning, extensions.

---

## Prerequisites

- PostgreSQL 13+ (some features like `MERGE` require PostgreSQL 15+)
- `psql` CLI or any SQL client (DBeaver, TablePlus, pgAdmin, DataGrip)
