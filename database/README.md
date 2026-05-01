# Database Mastery — Complete Course

A structured course from absolute basics to production-grade database engineering.

---

## Module 1: Foundations (Beginner)
| Chapter | Topic |
|---------|-------|
| [01_what_is_database.md](01_what_is_database.md) | What is a Database? DBMS vs RDBMS, types of databases |
| [02_data_models.md](02_data_models.md) | Data Models — relational, document, key-value, graph, columnar |
| [03_er_diagrams.md](03_er_diagrams.md) | Entity-Relationship Diagrams — entities, attributes, relationships |
| [04_relational_model.md](04_relational_model.md) | Relational Model — tables, rows, columns, keys (PK, FK, composite, candidate) |
| [05_normalization.md](05_normalization.md) | Normalization — 1NF, 2NF, 3NF, BCNF, denormalization tradeoffs |
| [06_schema_design.md](06_schema_design.md) | Schema Design — naming conventions, data types, constraints |

## Module 2: Core Internals (Intermediate)
| Chapter | Topic |
|---------|-------|
| [07_storage_engine.md](07_storage_engine.md) | Storage Engine — pages, blocks, heap files, how data lives on disk |
| [08_indexes.md](08_indexes.md) | Indexes — B-tree, Hash, GIN, GiST, BRIN; when to use / avoid |
| [09_query_processing.md](09_query_processing.md) | Query Processing — parsing → planning → execution pipeline |
| [10_query_optimization.md](10_query_optimization.md) | Query Optimization — EXPLAIN/ANALYZE, statistics, cost-based optimizer |
| [11_transactions_acid.md](11_transactions_acid.md) | Transactions & ACID — atomicity, consistency, isolation, durability |
| [12_concurrency_control.md](12_concurrency_control.md) | Concurrency Control — locks, MVCC, deadlocks, isolation levels |
| [13_wal_journaling.md](13_wal_journaling.md) | WAL & Journaling — Write-Ahead Log, crash recovery, checkpoints |

## Module 3: Administration & Operations (Intermediate–Advanced)
| Chapter | Topic |
|---------|-------|
| [14_backup_strategies.md](14_backup_strategies.md) | Backup Strategies — pg_dump, pg_basebackup, logical vs physical |
| [15_pitr.md](15_pitr.md) | Point-in-Time Recovery (PITR) — WAL archiving, restoring to any timestamp |
| [16_replication.md](16_replication.md) | Replication — streaming, logical, primary/replica setup |
| [17_high_availability.md](17_high_availability.md) | High Availability — failover, Patroni, pg_auto_failover |
| [18_vacuum_maintenance.md](18_vacuum_maintenance.md) | Vacuuming & Maintenance — autovacuum, bloat, ANALYZE |
| [19_connection_pooling.md](19_connection_pooling.md) | Connection Pooling — why it matters, PgBouncer setup and tuning |
| [20_monitoring.md](20_monitoring.md) | Monitoring & Observability — pg_stat_* views, slow query log, alerts |

## Module 4: Advanced Topics
| Chapter | Topic |
|---------|-------|
| [21_partitioning.md](21_partitioning.md) | Partitioning — range, list, hash; partition pruning |
| [22_sharding.md](22_sharding.md) | Sharding — horizontal scaling, sharding strategies, Citus |
| [23_nosql.md](23_nosql.md) | NoSQL Databases — MongoDB, Redis, Cassandra; when to use each |
| [24_cap_distributed.md](24_cap_distributed.md) | CAP Theorem & Distributed Systems — consistency vs availability |
| [25_security.md](25_security.md) | Database Security — roles, privileges, RLS, encryption |
| [26_advanced_schema_patterns.md](26_advanced_schema_patterns.md) | Advanced Schema Patterns — polymorphism, EAV, audit tables, soft deletes |
| [27_full_text_search.md](27_full_text_search.md) | Full-Text Search — tsvector, tsquery, search indexes |
| [28_json_semistructured.md](28_json_semistructured.md) | JSON & Semi-structured Data — JSONB, indexing JSON, hybrid schemas |
| [29_performance_tuning.md](29_performance_tuning.md) | Performance Tuning — shared_buffers, work_mem, pgBadger, config |
| [30_production_checklist.md](30_production_checklist.md) | Database in Production — deployment checklist, schema migrations, CI/CD |

---

> Start with Chapter 1 and follow in order. Each chapter builds on the previous one.
