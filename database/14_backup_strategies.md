# Chapter 14 — Backup Strategies

Backups are your last line of defense. A database without a tested, working backup is not a database — it's a liability. This chapter covers every backup method in PostgreSQL, when to use each, and how to verify them.

---

## 14.1 Backup Taxonomy

Before picking a tool, understand what you're backing up and how.

### Logical vs Physical

| | Logical | Physical |
|-|---------|----------|
| **What is backed up** | SQL: schema + data as INSERT/COPY statements | Raw data files (pages, WAL) |
| **Tools** | `pg_dump`, `pg_dumpall` | `pg_basebackup`, pgBackRest, WAL-G |
| **Restore to different PG version** | ✅ Yes | ❌ Same major version only |
| **Restore single table** | ✅ Yes | ❌ Harder |
| **Backup speed** | Slower (serializes data) | Fast (file copy) |
| **Restore speed** | Slow (re-inserts all rows) | Fast (copy files back) |
| **Point-in-time recovery** | ❌ No | ✅ Yes (with WAL archiving) |
| **Best for** | Dev/test, migrations, small DBs, table-level restores | Production, large DBs, DR |

### Online vs Offline

- **Online (hot) backup**: taken while the database is running, serving traffic — no downtime
- **Offline (cold) backup**: taken while the database is stopped — guaranteed consistent state

PostgreSQL supports online backups for both logical (`pg_dump`) and physical (`pg_basebackup`).

---

## 14.2 pg_dump — Logical Backup

`pg_dump` exports one database at a time as SQL or binary format.

### Basic Usage

```bash
# Plain SQL format (human-readable, pipe-able)
pg_dump -U postgres -d mydb > mydb_backup.sql

# Compressed SQL
pg_dump -U postgres -d mydb | gzip > mydb_backup.sql.gz

# Custom binary format (recommended for production)
pg_dump -U postgres -d mydb -Fc -f mydb_backup.dump

# Directory format (parallelizable)
pg_dump -U postgres -d mydb -Fd -f /backups/mydb/ -j 4
# -j 4 = use 4 parallel workers
```

### Format Comparison

| Format | Flag | Pros | Cons |
|--------|------|------|------|
| Plain SQL | `-Fp` (default) | Human-readable, portable | Huge files, slow restore |
| Custom | `-Fc` | Compressed, selective restore, reorderable | Binary (not human-readable) |
| Directory | `-Fd` | Parallel dump/restore | Multiple files |
| Tar | `-Ft` | Single file, parallel restore | Not seekable |

**Use custom format (`-Fc`) for production** — it's compressed, supports parallel restore, and lets you restore specific tables/schemas.

### Selective Restore with pg_restore

```bash
# List contents
pg_restore -l mydb_backup.dump

# Restore entire backup
pg_restore -U postgres -d mydb mydb_backup.dump

# Restore only specific table
pg_restore -U postgres -d mydb -t employees mydb_backup.dump

# Restore only schema (no data)
pg_restore -U postgres -d mydb --schema-only mydb_backup.dump

# Restore only data (schema already exists)
pg_restore -U postgres -d mydb --data-only mydb_backup.dump

# Parallel restore
pg_restore -U postgres -d mydb -j 4 mydb_backup.dump
```

---

## 14.3 pg_dumpall — Backup Everything

`pg_dump` only backs up one database. Use `pg_dumpall` for:
- All databases
- Global objects: roles, tablespaces

```bash
# Dump everything (roles + all databases)
pg_dumpall -U postgres > full_cluster.sql

# Dump only globals (roles, tablespaces) — no database data
pg_dumpall -U postgres --globals-only > globals.sql

# Restore
psql -U postgres < full_cluster.sql
```

**Limitation**: `pg_dumpall` output is plain SQL only (no custom format, no parallel restore).

---

## 14.4 pg_basebackup — Physical Backup

`pg_basebackup` takes a binary copy of the entire PostgreSQL data directory while the server is running.

```bash
# Basic base backup
pg_basebackup -U replication -D /backups/base -Fp -Xs -P
# -D = destination directory
# -Fp = plain format (copy of data directory)
# -Xs = include WAL via streaming (ensures consistent backup)
# -P = show progress

# Compressed tar format (better for storage)
pg_basebackup -U replication -D /backups/base -Ft -Xs -z -P
# -Ft = tar format
# -z = gzip compression

# With WAL included in backup
pg_basebackup -U replication -D /backups/base -Ft -Xfetch -z
```

### What pg_basebackup requires

```ini
# postgresql.conf — must be set before running basebackup
wal_level = replica
max_wal_senders = 3     # at least 1 slot for backup

# pg_hba.conf — allow replication connections
host  replication  replication_user  10.0.0.0/8  md5
```

---

## 14.5 Backup Retention and Rotation

Never keep just one backup. Follow the **3-2-1 rule**:
- **3** copies of the data
- **2** different storage media
- **1** offsite (different location/cloud region)

### Example rotation policy

```bash
#!/bin/bash
# Daily backup with 30-day retention
DATE=$(date +%Y%m%d)
BACKUP_DIR="/backups/daily"

pg_dump -U postgres -d mydb -Fc -f "${BACKUP_DIR}/mydb_${DATE}.dump"

# Delete backups older than 30 days
find "${BACKUP_DIR}" -name "*.dump" -mtime +30 -delete
```

---

## 14.6 pgBackRest — Production Backup Tool

`pgBackRest` is the industry-standard backup tool for PostgreSQL in production. It replaces manual `pg_basebackup` + WAL archiving scripts.

### Features
- Full, differential, and incremental backups
- Built-in WAL archiving and management
- Parallel backup and restore
- S3/Azure/GCS support
- Backup verification (checksums)
- PITR (Point-in-Time Recovery)
- Backup from standby (no load on primary)

### Configuration

```ini
# /etc/pgbackrest/pgbackrest.conf

[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2        # keep 2 full backups
repo1-retention-diff=14       # keep 14 differentials
start-fast=y
log-level-console=info

[main]                         # stanza name
pg1-path=/var/lib/postgresql/14/main
```

### Common Commands

```bash
# Initialize stanza
pgbackrest --stanza=main stanza-create

# Full backup
pgbackrest --stanza=main --type=full backup

# Differential backup (since last full)
pgbackrest --stanza=main --type=diff backup

# Incremental backup (since last any backup)
pgbackrest --stanza=main --type=incr backup

# List backups
pgbackrest --stanza=main info

# Restore (stop PostgreSQL first)
pgbackrest --stanza=main restore

# Restore to a specific time
pgbackrest --stanza=main --type=time "--target=2024-11-01 14:30:00" restore

# Verify backup integrity
pgbackrest --stanza=main check
```

---

## 14.7 WAL-G — Cloud-Native Backup

**WAL-G** is a modern backup tool focused on cloud storage (S3, GCS, Azure).

```bash
# Configure (environment variables)
export WALG_S3_PREFIX=s3://my-bucket/backups/postgres
export AWS_REGION=us-east-1

# Full backup
wal-g backup-push $PGDATA

# List backups
wal-g backup-list

# Restore latest
wal-g backup-fetch $PGDATA LATEST

# WAL archiving
archive_command = 'wal-g wal-push %p'
restore_command = 'wal-g wal-fetch %f %p'
```

---

## 14.8 Backup Verification — The Most Important Step

**An untested backup is not a backup.**

Test your restores regularly:

```bash
#!/bin/bash
# Weekly backup verification script

# 1. Restore backup to test instance
pg_restore -U postgres -d mydb_test /backups/mydb_latest.dump

# 2. Run sanity checks
psql -U postgres -d mydb_test -c "SELECT COUNT(*) FROM employees;"
psql -U postgres -d mydb_test -c "SELECT MAX(created_at) FROM orders;"

# 3. Compare row counts with production
# (compare expected vs actual)

# 4. Alert if mismatch
```

Use a dedicated **restore test server** — restore your backup weekly and verify it works.

---

## 14.9 Backup Size and Performance

### Estimating backup size

```sql
-- Database sizes
SELECT datname,
       pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
ORDER BY pg_database_size(datname) DESC;

-- Table sizes
SELECT tablename,
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total,
       pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_only,
       pg_size_pretty(pg_indexes_size(schemaname||'.'||tablename)) AS indexes
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

### Reducing backup time

- Use `--jobs` / `-j` for parallel dump/restore
- Exclude large tables you can reconstruct (logs, events) from daily backups
- Use incremental backups (pgBackRest) instead of full every time
- Backup from a replica to avoid impacting the primary

---

## 14.10 Backup Strategy by Environment

| Environment | Strategy |
|-------------|----------|
| **Development** | `pg_dump` on demand, no retention needed |
| **Staging** | Weekly `pg_dump`, keep 2 weeks |
| **Small production** | Daily `pg_dump -Fc`, 30-day retention, test monthly |
| **Large production** | pgBackRest: daily full + hourly WAL archiving, PITR, offsite, weekly restore test |
| **Critical/financial** | pgBackRest on replica + continuous WAL archiving to S3, RPO = seconds |

---

## Key Terms

| Term | Meaning |
|------|---------|
| Logical backup | SQL-level dump (INSERT/COPY statements) |
| Physical backup | Binary copy of data files |
| pg_dump | Logical backup of one database |
| pg_dumpall | Logical backup of all databases + globals |
| pg_basebackup | Physical backup of the entire data directory |
| pgBackRest | Production backup tool with incremental backups and PITR |
| WAL-G | Cloud-native backup tool |
| 3-2-1 rule | 3 copies, 2 media types, 1 offsite |
| RPO | Recovery Point Objective — max acceptable data loss |
| RTO | Recovery Time Objective — max acceptable downtime |

---

## Practice Questions

1. You need to restore a single table from a backup. Which backup format supports this?
2. What is the difference between `pg_dump` and `pg_basebackup`?
3. Your database is 2 TB. Daily full dumps take 6 hours. What backup strategy do you adopt?
4. What does the 3-2-1 backup rule mean?
5. Why is testing your restore just as important as taking the backup?
6. What RPO and RTO can you achieve with continuous WAL archiving?

---

**← Previous:** [13_wal_journaling.md](13_wal_journaling.md)  
**Next →** [15_pitr.md](15_pitr.md)
