# learn_sql

A complete, hands-on PostgreSQL learning repository — two tracks in one place.

---

## Repository Structure

```
learn_sql/
├── sql/               ← 25 SQL chapters + cheatsheet (hands-on queries)
├── database/          ← 30-chapter database mastery course (concepts + internals)
└── docker-compose.yml ← PostgreSQL dev environment
```

---

## Track 1 — SQL Practice (`sql/`)

25 chapters of hands-on PostgreSQL queries using the classic EMP/DEPT dataset.  
Start here if you want to **write and run SQL immediately**.

### Quick Start

```bash
# Start PostgreSQL with Docker
docker compose up -d

# Connect and load sample data
psql -h localhost -U admin -d learn_sql
\i sql/ddl-script.sql

# Open any chapter
\i sql/chp1.sql
```

### Chapter Index

| # | File | Topic |
|---|------|-------|
| 1 | [chp1.sql](sql/chp1.sql) | Retrieving Records — WHERE, BETWEEN, IN, LIKE, CASE, COALESCE |
| 2 | [chp2.sql](sql/chp2.sql) | Sorting — ORDER BY, NULLS FIRST/LAST, COLLATE |
| 3 | [chp3.sql](sql/chp3.sql) | Joins & Set Ops — INNER/LEFT/FULL/SELF/CROSS JOIN, UNION, EXISTS |
| 4 | [chp4.sql](sql/chp4.sql) | DML — INSERT, UPDATE, DELETE, UPSERT, RETURNING, MERGE |
| 5 | [chp5.sql](sql/chp5.sql) | Metadata — information_schema, pg_catalog, table sizes |
| 6 | [chp6.sql](sql/chp6.sql) | Strings — TRIM, SUBSTR, REPLACE, REGEXP, STRING_AGG |
| 7 | [chp7.sql](sql/chp7.sql) | Numbers — Aggregates, running totals, PERCENTILE, RANK |
| 8 | [chp8.sql](sql/chp8.sql) | Dates & Times — EXTRACT, DATE_TRUNC, AGE, intervals, timezone |
| 9 | [chp9.sql](sql/chp9.sql) | CTEs — WITH, chained CTEs, recursive org hierarchy |
| 10 | [chp10.sql](sql/chp10.sql) | Window Functions — ROW_NUMBER, LAG/LEAD, moving averages |
| 11 | [chp11.sql](sql/chp11.sql) | Advanced Aggregation — GROUPING SETS, ROLLUP, CUBE, pivot |
| 12 | [chp12.sql](sql/chp12.sql) | Subqueries — correlated, EXISTS vs IN, NOT IN NULL trap |
| 13 | [chp13.sql](sql/chp13.sql) | Indexes & Performance — EXPLAIN ANALYZE, B-tree, GIN, partial |
| 14 | [chp14.sql](sql/chp14.sql) | Transactions & Views — ACID, isolation levels, MATERIALIZED VIEW |
| 15 | [chp15.sql](sql/chp15.sql) | PL/pgSQL — functions, procedures, loops, exception handling |
| 16 | [chp16.sql](sql/chp16.sql) | Triggers & Dynamic SQL — BEFORE/AFTER, audit logging, EXECUTE |
| 17 | [chp17.sql](sql/chp17.sql) | JSONB — operators, jsonb_set, GIN index, JSONPath |
| 18 | [chp18.sql](sql/chp18.sql) | Partitioning — RANGE/LIST/HASH, pruning, attach/detach |
| 19 | [chp19.sql](sql/chp19.sql) | Full-Text Search — tsvector, tsquery, ts_rank, ts_headline |
| 20 | [chp20.sql](sql/chp20.sql) | Security — roles, GRANT/REVOKE, RLS policies |
| 21 | [chp21.sql](sql/chp21.sql) | Performance Tuning — join strategies, work_mem, pg_stat_statements |
| 22 | [chp22.sql](sql/chp22.sql) | Extensions — pg_trgm, pgcrypto, uuid-ossp, tablefunc, PostGIS |
| 23 | [chp23.sql](sql/chp23.sql) | Custom Types — ENUM, Arrays, Composite, Range, Exclusion constraints |
| 24 | [chp24.sql](sql/chp24.sql) | Bulk I/O & Pub/Sub — COPY, LISTEN/NOTIFY, advisory locks |
| 25 | [chp25.sql](sql/chp25.sql) | Interview Patterns — gaps & islands, deduplication, top-N per group |
| — | [cheatsheet.sql](sql/cheatsheet.sql) | Quick syntax reference for all 25 chapters |
| — | [ddl-script.sql](sql/ddl-script.sql) | Sample schema and seed data (run this first) |

### Learning Paths

| Goal | Chapters |
|------|---------|
| New to SQL | 1 → 2 → 3 → 4 → 6 → 7 → 8 |
| Interview prep | 1 → 2 → 3 → 10 → 9 → 12 → 25 |
| Production / DBA | 13 → 14 → 18 → 20 → 21 → 24 |
| Advanced PostgreSQL | 15 → 16 → 17 → 19 → 23 |

---

## Track 2 — Database Mastery (`database/`)

A 30-chapter course covering everything from first principles to production engineering.  
Start here if you want to **understand how databases work deeply**.

### Module 1 — Foundations (Beginner)
| Chapter | Topic |
|---------|-------|
| [01](database/01_what_is_database.md) | What is a Database? — DBMS, RDBMS, types of databases |
| [02](database/02_data_models.md) | Data Models — relational, document, key-value, graph |
| [03](database/03_er_diagrams.md) | ER Diagrams — entities, cardinality, junction tables |
| [04](database/04_relational_model.md) | Relational Model — keys, constraints, NULL, referential integrity |
| [05](database/05_normalization.md) | Normalization — 1NF → BCNF, anomalies, denormalization |
| [06](database/06_schema_design.md) | Schema Design — naming, data types, constraints, audit columns |

### Module 2 — Core Internals (Intermediate)
| Chapter | Topic |
|---------|-------|
| [07](database/07_storage_engine.md) | Storage Engine — pages, heap files, buffer pool, TOAST, bloat |
| [08](database/08_indexes.md) | Indexes — B-tree, Hash, GIN, GiST, BRIN, partial, covering |
| [09](database/09_query_processing.md) | Query Processing — parser → planner → executor, join algorithms |
| [10](database/10_query_optimization.md) | Query Optimization — EXPLAIN ANALYZE, pg_stat_statements, anti-patterns |
| [11](database/11_transactions_acid.md) | Transactions & ACID — isolation levels, dirty reads, SELECT FOR UPDATE |
| [12](database/12_concurrency_control.md) | Concurrency Control — MVCC, locks, deadlocks, XID wraparound |
| [13](database/13_wal_journaling.md) | WAL & Journaling — crash recovery, checkpoints, fsync, archiving |

### Module 3 — Administration & Operations (Intermediate–Advanced)
| Chapter | Topic |
|---------|-------|
| [14](database/14_backup_strategies.md) | Backup Strategies — pg_dump, pg_basebackup, pgBackRest, 3-2-1 rule |
| [15](database/15_pitr.md) | Point-in-Time Recovery — WAL archiving, restore targets, timelines |
| [16](database/16_replication.md) | Replication — streaming, sync vs async, slots, logical replication |
| [17](database/17_high_availability.md) | High Availability — Patroni, HAProxy, split brain, fencing |
| [18](database/18_vacuum_maintenance.md) | VACUUM & Maintenance — autovacuum tuning, bloat, XID wraparound |
| [19](database/19_connection_pooling.md) | Connection Pooling — PgBouncer setup, pool modes, sizing |
| [20](database/20_monitoring.md) | Monitoring — pg_stat_* views, pg_stat_statements, alerts, pgBadger |

### Module 4 — Advanced Topics
| Chapter | Topic |
|---------|-------|
| [21](database/21_partitioning.md) | Partitioning — range, list, hash, pg_partman, partition pruning |
| [22](database/22_sharding.md) | Sharding — strategies, shard keys, Citus, resharding |
| [23](database/23_nosql.md) | NoSQL — MongoDB, Redis, Cassandra, polyglot persistence |
| [24](database/24_cap_distributed.md) | CAP Theorem — CP vs AP, PACELC, Raft, Saga pattern |
| [25](database/25_security.md) | Security — RLS, roles, pgcrypto, SQL injection, auditing |
| [26](database/26_advanced_schema_patterns.md) | Advanced Schema Patterns — soft deletes, temporal tables, ltree |
| [27](database/27_full_text_search.md) | Full-Text Search — tsvector, tsquery, GIN, ranking, pg_trgm |
| [28](database/28_json_semistructured.md) | JSON & Semi-structured Data — JSONB operators, indexing, hybrid schemas |
| [29](database/29_performance_tuning.md) | Performance Tuning — shared_buffers, work_mem, PGTune, checkpoints |
| [30](database/30_production_checklist.md) | Database in Production — zero-downtime migrations, CI/CD, full checklist |

### Module 5 — Senior DBA (Advanced)
| Chapter | Topic |
|---------|-------|
| [31](database/31_query_planner_internals.md) | Query Planner Internals — pg_stats, extended statistics, cost model, JIT, pg_hint_plan |
| [32](database/32_logical_replication_deep_dive.md) | Logical Replication Deep Dive — CDC, Debezium/Kafka, slot hazards, zero-downtime upgrades |
| [33](database/33_advanced_query_patterns.md) | Advanced Query Patterns — window frames, recursive CTEs, LATERAL, MERGE, DISTINCT ON |
| [34](database/34_connection_management_scale.md) | Connection Management at Scale — PgBouncer HA, DISCARD ALL hazards, timeout hierarchy |
| [35](database/35_observability_engineering.md) | Observability Engineering — wait events, pg_wait_sampling, auto_explain, SLOs, OpenTelemetry |
| [36](database/36_compliance_advanced_security.md) | Compliance & Advanced Security — RBAC, dynamic masking, envelope encryption, GDPR, SOC 2 |
| [37](database/37_extension_ecosystem.md) | Extension Ecosystem — TimescaleDB, pgvector (HNSW/IVFFlat), PostGIS, pg_cron, pg_partman |
| [38](database/38_capacity_planning_cloud.md) | Capacity Planning & Cloud — RDS vs Aurora internals, TCO, IOPS sizing, rightsizing |
| [39](database/39_operational_runbooks.md) | Operational Runbooks — crash, replication lag, disk full, XID wraparound, lock storm, corruption |
| [40](database/40_postgres_for_olap.md) | PostgreSQL for OLAP — parallel query, columnar storage (Hydra), DuckDB, FDWs, hybrid workloads |

---

## Prerequisites

- PostgreSQL 15+ recommended (`MERGE` requires 15+)
- `psql` CLI or any SQL client (DBeaver, TablePlus, pgAdmin, DataGrip)
- Docker + Docker Compose (optional — for the included `docker-compose.yml`)
