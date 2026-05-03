# Chapter 15 — Point-in-Time Recovery (PITR)

PITR lets you restore your database to any moment in the past — not just the last backup. If someone runs `DROP TABLE orders` at 2:37 PM, you can restore to 2:36 PM. This is the most powerful data recovery capability in PostgreSQL.

---

## 15.1 How PITR Works

PITR requires two things working together:

```
┌──────────────────────────────────────────────────────────┐
│  1. A base backup                                        │
│     (pg_basebackup or pgBackRest full backup)            │
│     → snapshot of all data files at a point in time     │
└──────────────────────┬───────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────┐
│  2. All WAL segments after that backup                   │
│     (archived continuously)                             │
│     → every change since the backup                     │
└──────────────────────────────────────────────────────────┘

Recovery = Base backup + Replay WAL segments up to target time
```

Think of it like version control: the base backup is like a git snapshot, and WAL segments are like individual commits. You can replay commits up to any point.

---

## 15.2 Setting Up PITR (Step by Step)

### Step 1 — Enable WAL Archiving

```ini
# postgresql.conf
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /wal_archive/%f && cp %p /wal_archive/%f'
```

The `archive_command`:
- `%p` = full path of the WAL segment to archive
- `%f` = filename only
- Must return 0 on success, non-zero on failure (PostgreSQL retries on failure)
- `test ! -f` prevents overwriting an already-archived segment

Verify archiving is working:
```sql
SELECT archived_count, last_archived_wal, last_archived_time,
       failed_count, last_failed_wal
FROM pg_stat_archiver;
```

---

### Step 2 — Take a Base Backup

```bash
# Take the base backup
pg_basebackup -U postgres -D /backups/base_20241101 -Ft -Xs -z -P

# Or with pgBackRest (recommended)
pgbackrest --stanza=main --type=full backup
```

Record the timestamp of this backup — you can only recover to times after this point.

---

### Step 3 — Continuous WAL Archiving

With `archive_mode = on`, PostgreSQL automatically copies each completed WAL segment (16 MB) to your archive when it's full or when `archive_timeout` is reached.

```ini
# Flush WAL to archive at least every 60 seconds
# (reduces maximum data loss window for low-traffic DBs)
archive_timeout = 60
```

Your archive grows continuously:
```
/wal_archive/
├── 000000010000000000000001  ← archived immediately after backup
├── 000000010000000000000002
├── 000000010000000000000003  ← 16 MB per segment
└── ...                       ← one per ~16 MB of writes
```

---

## 15.3 Performing a PITR Restore

Scenario: `DROP TABLE orders` executed at 14:37:22 on 2024-11-01. You need to restore to 14:37:00.

### Step 1 — Stop PostgreSQL

```bash
systemctl stop postgresql
```

### Step 2 — Clear the Data Directory

```bash
# Back up current data dir first (just in case)
mv /var/lib/postgresql/14/main /var/lib/postgresql/14/main_broken

# Create empty data dir
mkdir /var/lib/postgresql/14/main
chown postgres:postgres /var/lib/postgresql/14/main
```

### Step 3 — Restore the Base Backup

```bash
# Restore from tar backup
tar -xzf /backups/base_20241101/base.tar.gz -C /var/lib/postgresql/14/main

# Or with pgBackRest
pgbackrest --stanza=main restore
```

### Step 4 — Configure Recovery Target

Create `postgresql.conf` recovery settings (PostgreSQL 12+):

```ini
# postgresql.conf (or recovery.conf in older versions)

# Where to find archived WAL segments
restore_command = 'cp /wal_archive/%f %p'

# Stop recovery at this timestamp (just before the DROP TABLE)
recovery_target_time = '2024-11-01 14:37:00'

# What to do after reaching the target
recovery_target_action = 'promote'   # become primary after recovery
# Options: 'pause' (default), 'promote', 'shutdown'
```

Also create a `recovery.signal` file (PostgreSQL 12+):
```bash
touch /var/lib/postgresql/14/main/recovery.signal
```

In older versions (pre-12), use `recovery.conf` instead of `postgresql.conf`.

### Step 5 — Start PostgreSQL

```bash
systemctl start postgresql
```

PostgreSQL will:
1. Detect `recovery.signal`
2. Restore base backup data files
3. Replay WAL segments one by one until reaching `14:37:00`
4. Stop and promote to primary

Watch the logs:
```
LOG:  starting point-in-time recovery to 2024-11-01 14:37:00+00
LOG:  restored log file "000000010000000000000001" from archive
LOG:  redo starts at 0/1000028
LOG:  consistent recovery state reached at 0/1000100
LOG:  recovery stopping before commit of transaction 501, time 2024-11-01 14:37:01
LOG:  pausing at the end of recovery
```

### Step 6 — Verify and Promote

```sql
-- Connect and verify the table is back
SELECT COUNT(*) FROM orders;

-- Promote the database (if recovery_target_action = 'pause')
SELECT pg_promote();
-- Or: touch /var/lib/postgresql/14/main/promote.signal
```

---

## 15.4 Recovery Target Options

You can target recovery at different points:

```ini
# By timestamp (most common)
recovery_target_time = '2024-11-01 14:37:00 UTC'

# By transaction ID (useful when you know the exact bad transaction)
recovery_target_xid = '500'
# Stops just before transaction 500 commits

# By named restore point (must be created before the incident)
recovery_target_name = 'before_migration'
# Create with: SELECT pg_create_restore_point('before_migration');

# By LSN (exact WAL position)
recovery_target_lsn = '0/5A3B2C0'

# Recover to end of WAL (latest possible state — full recovery)
recovery_target = 'immediate'    -- stop at consistent state
# Or just don't set any target
```

### Inclusive vs Exclusive

```ini
recovery_target_inclusive = true   # include the target transaction (default)
recovery_target_inclusive = false  # stop just before the target
```

For "restore before the DROP TABLE": use `false` with the XID of the DROP, or set time to one second before.

---

## 15.5 Creating Restore Points

Plant named checkpoints in your WAL before risky operations:

```sql
-- Before a big migration or deployment
SELECT pg_create_restore_point('before_v2_migration');

-- This creates a named record in the WAL
-- Later, recover to this exact point:
-- recovery_target_name = 'before_v2_migration'
```

Best practice: always create a restore point before running schema migrations in production.

---

## 15.6 PITR with pgBackRest

pgBackRest handles the full PITR workflow:

```bash
# Restore to specific time
pgbackrest \
  --stanza=main \
  --type=time \
  "--target=2024-11-01 14:37:00" \
  --target-action=promote \
  restore

# Restore to specific LSN
pgbackrest \
  --stanza=main \
  --type=lsn \
  --target=0/5A3B2C0 \
  restore

# Restore to a named restore point
pgbackrest \
  --stanza=main \
  --type=name \
  --target=before_v2_migration \
  restore
```

pgBackRest automatically:
- Selects the correct base backup (most recent before the target)
- Fetches needed WAL segments from archive
- Configures recovery settings

---

## 15.7 PITR Timelines

After a recovery, PostgreSQL starts a new **timeline**. This prevents accidentally replaying WAL from before the recovery point.

```
Timeline 1: ... commit ... commit ... DROP TABLE ... commit ...
                                         ↑
                              Recovery to here
                                         ↓
Timeline 2: ... (starts fresh from recovery point) ... commit ...
```

WAL filenames include the timeline ID:
```
00000001 00000000 00000001   ← timeline 1
00000002 00000000 00000001   ← timeline 2 (after recovery)
```

If you need to recover again to a different point, you can go back to any previous timeline using `recovery_target_timeline`.

---

## 15.8 Monitoring the Archive

```sql
-- Archive statistics
SELECT archived_count,
       last_archived_wal,
       last_archived_time,
       failed_count,
       last_failed_wal,
       last_failed_time
FROM pg_stat_archiver;

-- Alert if archiving is failing
-- failed_count > 0 or last_archived_time > 5 minutes ago = problem
```

If archiving fails, `failed_count` increases but PostgreSQL keeps running — it just can't delete old WAL segments. Eventually disk fills up.

---

## 15.9 PITR vs Simple Restore

| | Simple Restore | PITR |
|-|---------------|------|
| Recovery point | Backup time only | Any second since last backup |
| Data loss (RPO) | Since last backup (hours/days) | Minutes (or seconds with short archive_timeout) |
| Requires | Just the backup file | Backup + continuous WAL archive |
| Complexity | Low | Medium |
| Storage | Backup only | Backup + WAL stream |

For any production database with business data, PITR is non-negotiable.

---

## 15.10 Calculating Your RPO

```
RPO = time since last archived WAL segment

If archive_timeout = 60s → max RPO = 60 seconds
If archive_timeout = 0 (default, archives only when segment is full):
  Low-traffic DB generating 1 WAL segment/hour → RPO = up to 1 hour
  High-traffic DB generating 1 segment/minute → RPO = up to 1 minute
```

For stricter RPO requirements, stream WAL continuously to a replica (Chapter 16) — that gives you near-zero RPO.

---

## Key Terms

| Term | Meaning |
|------|---------|
| PITR | Point-in-Time Recovery — restore to any past moment |
| Base backup | Full data file snapshot; starting point for PITR |
| restore_command | Shell command to fetch archived WAL during recovery |
| Recovery target | The timestamp/XID/LSN/name to stop replay at |
| Timeline | Sequential identifier; increments after each recovery |
| Restore point | Named WAL marker created with `pg_create_restore_point()` |
| RPO | Recovery Point Objective — max data loss in time |
| archive_timeout | Max seconds before forcing a WAL segment archive |

---

## Practice Questions

1. A DBA accidentally runs `DELETE FROM orders` with no WHERE clause at 3:15 PM. You have a base backup from 2:00 AM and continuous WAL archiving. Walk through the recovery steps.
2. What is the difference between `recovery_target_inclusive = true` and `false`?
3. Why does PostgreSQL create a new timeline after recovery?
4. What is `pg_create_restore_point()` and when should you use it?
5. Your low-traffic database has `archive_timeout` not set. What is the worst-case RPO?
6. What is the minimum configuration needed to enable PITR?

---

**← Previous:** [14_backup_strategies.md](14_backup_strategies.md)  
**Next →** [16_replication.md](16_replication.md)
