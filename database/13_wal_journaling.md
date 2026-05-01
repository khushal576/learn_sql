# Chapter 13 — WAL & Journaling

The Write-Ahead Log (WAL) is the most important component of PostgreSQL's durability and crash recovery system. It also powers replication, point-in-time recovery, and streaming.

---

## 13.1 The Problem WAL Solves

Without WAL: when PostgreSQL modifies a page, it marks it as "dirty" in `shared_buffers`. The page is flushed to disk eventually — but if the server crashes before the flush, the change is lost.

With WAL: **before** changing a page in the buffer pool, PostgreSQL writes a log record describing the change. The log is flushed to disk first. If the server crashes, the WAL log can replay the change on recovery.

> **Write the log first, then the data** — hence "Write-Ahead Log".

---

## 13.2 How WAL Works

```
Client sends: UPDATE employees SET salary = 90000 WHERE id = 1

1. PostgreSQL constructs WAL record:
   "On page (0,5) of relation 16399, change salary from 80000 to 90000"
   Assigns LSN (Log Sequence Number): 0/3A1B4C0

2. WAL record is written to WAL buffer (in shared memory)

3. On COMMIT:
   WAL buffer is flushed to disk (fsync) → durability guaranteed
   Returns success to client

4. Later (asynchronously):
   Dirty page flushed from shared_buffers to the actual table file
```

The key insight: the table file on disk may be **behind** the WAL log — that's OK. On crash, WAL replay brings it up to date.

---

## 13.3 LSN — Log Sequence Number

Every WAL record gets a unique, monotonically increasing **LSN** (Log Sequence Number):

```sql
-- Current WAL write position
SELECT pg_current_wal_lsn();
-- → 0/5A3B2C0

-- Current insert position
SELECT pg_current_wal_insert_lsn();

-- Distance between two LSNs (bytes of WAL generated)
SELECT pg_wal_lsn_diff('0/5A3B2C0', '0/3A1B4C0');
-- → 33619968  (32 MB of WAL generated between these points)
```

LSNs are used everywhere:
- Replication lag is measured in LSN difference
- PITR recovery restores to a specific LSN
- EXPLAIN BUFFERS shows the LSN of pages

---

## 13.4 WAL Files on Disk

WAL is stored in `$PGDATA/pg_wal/` as 16 MB segment files:

```
$PGDATA/pg_wal/
├── 000000010000000000000001
├── 000000010000000000000002
├── 000000010000000000000003
└── ...
```

File naming: `TTTTTTTTSSSSSSSSSSSSSSSS`
- `T` = timeline ID (increments on recovery, e.g., after failover)
- `S` = WAL segment number

PostgreSQL keeps a circular pool of WAL files. Old segments are recycled or archived.

---

## 13.5 Checkpoints

The WAL keeps growing. Without cleanup, it would be infinite. **Checkpoints** solve this:

A checkpoint:
1. Flushes all dirty pages from `shared_buffers` to disk
2. Writes a checkpoint record to WAL
3. Updates the control file: "WAL before this point is no longer needed for recovery"
4. Old WAL segments before the checkpoint can be recycled

```
WAL: [...segment1...][...segment2...][checkpoint][...segment3...]
                       ^
              WAL before this can be deleted
              (all changes are in the data files)
```

### Checkpoint Configuration

```ini
# postgresql.conf
checkpoint_timeout = 5min       # Max time between checkpoints
max_wal_size = 1GB              # Trigger checkpoint if WAL grows beyond this
min_wal_size = 80MB             # Minimum WAL to keep
checkpoint_completion_target = 0.9  # Spread flush over 90% of checkpoint_timeout
```

`checkpoint_completion_target = 0.9` prevents I/O spikes: instead of flushing all dirty pages at once, PostgreSQL spreads the writes over 90% of the checkpoint interval.

### Check Checkpoint Frequency

```sql
SELECT checkpoints_timed, checkpoints_req,
       checkpoint_write_time, checkpoint_sync_time,
       buffers_checkpoint
FROM pg_stat_bgwriter;
```

`checkpoints_req` >> `checkpoints_timed` means checkpoints are triggered by WAL size, not time — consider increasing `max_wal_size`.

---

## 13.6 Crash Recovery

When PostgreSQL starts after a crash:

```
1. Read the control file → find last checkpoint LSN
2. Open WAL at the checkpoint position
3. Replay every WAL record from checkpoint → end of WAL
4. All transactions that were committed: changes applied
5. All transactions that were not committed: rolled back (undo)
6. Database is consistent → accept connections
```

This is called **REDO recovery**. PostgreSQL only needs to replay from the last checkpoint — not from the beginning.

The further apart checkpoints are, the longer crash recovery takes. Keep `checkpoint_timeout` reasonable (default 5 minutes is usually fine).

---

## 13.7 WAL Archiving — The Foundation of PITR

By default, old WAL segments are recycled (overwritten). For **Point-in-Time Recovery (PITR)** and **streaming replication**, you need to **archive** WAL segments before they're recycled.

```ini
# postgresql.conf
archive_mode = on
archive_command = 'cp %p /mnt/wal_archive/%f'
# %p = full path to WAL segment
# %f = filename of WAL segment
```

With archiving enabled:
- Every completed WAL segment is copied to the archive location
- Archive can be on another disk, NFS, S3, etc.
- `archive_command` must return 0 on success, non-zero on failure (PostgreSQL retries on failure)

For production, use a robust tool instead of `cp`:
```ini
archive_command = 'pgbackrest --stanza=main archive-push %p'
archive_command = 'wal-g wal-push %p'
```

---

## 13.8 WAL Level Settings

WAL verbosity is controlled by `wal_level`:

| Level | Records | Used For |
|-------|---------|----------|
| `minimal` | Only crash recovery | Standalone DB, bulk loads |
| `replica` | + info for streaming replication | Default, replication |
| `logical` | + info for logical decoding | Logical replication, CDC |

```ini
# postgresql.conf
wal_level = replica   # default, recommended
```

Changing `wal_level` requires a restart.

---

## 13.9 fsync and WAL Durability

PostgreSQL calls `fsync()` on WAL at every COMMIT to guarantee durability.

```ini
# postgresql.conf
fsync = on           # NEVER turn this off in production
synchronous_commit = on  # Wait for WAL flush before returning success
```

### synchronous_commit Options

| Setting | Behavior | Risk on Crash |
|---------|----------|--------------|
| `on` | Wait for WAL flushed to local disk | No data loss |
| `remote_write` | Wait for WAL sent to standby, written but not flushed | Tiny window |
| `remote_apply` | Wait for standby to apply the WAL | No data loss on standby |
| `local` | Wait for local flush only (ignore standby) | No local loss |
| `off` | Don't wait — return immediately | Up to `wal_writer_delay` ms of loss |

`synchronous_commit = off` is an application-level setting for non-critical transactions:

```sql
SET synchronous_commit = off;
INSERT INTO analytics_events ...;  -- OK to lose if crash happens
```

**NEVER set `fsync = off`** — this risks database corruption (not just data loss) if the OS crashes.

---

## 13.10 WAL and Performance

WAL writing is a bottleneck in write-heavy workloads. Tuning:

```ini
# Larger WAL buffers = batch more records before flushing
wal_buffers = 64MB          # default: auto (usually 4-16MB)

# For SSDs: multiple WAL writers
# (PostgreSQL 14+, usually just one is needed)

# For bulk loads: reduce WAL overhead
ALTER TABLE new_table SET UNLOGGED;  -- no WAL for this table (lost on crash!)
-- After load:
ALTER TABLE new_table SET LOGGED;
```

For bulk inserts, temporarily disabling WAL (`UNLOGGED` table) can be 5-10x faster — but the table is empty after a crash.

---

## 13.11 Monitoring WAL

```sql
-- WAL generation rate (bytes/sec)
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0') / extract(epoch FROM now() - pg_postmaster_start_time());

-- Current WAL files on disk
SELECT count(*), sum(size) FROM pg_ls_waldir();

-- Replication lag (for replicas)
SELECT client_addr,
       state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

---

## 13.12 WAL Summary: What Depends on WAL

```
WAL enables:
├── Crash Recovery          ← replay WAL after crash
├── PITR                    ← archive WAL segments, restore to any point
├── Streaming Replication   ← ship WAL to replica in real-time (Chapter 16)
├── Logical Replication     ← decode WAL to SQL-like stream (Chapter 16)
└── Change Data Capture     ← tools like Debezium read the WAL stream
```

Everything that makes PostgreSQL reliable and scalable is built on top of WAL.

---

## Key Terms

| Term | Meaning |
|------|---------|
| WAL | Write-Ahead Log — changes written before data files |
| LSN | Log Sequence Number — monotonic position in the WAL stream |
| Checkpoint | Point where all dirty pages are flushed; WAL before it can be recycled |
| WAL Archiving | Saving WAL segments before recycling (needed for PITR) |
| fsync | System call ensuring WAL is durably on disk |
| synchronous_commit | Whether to wait for WAL flush before reporting commit success |
| REDO Recovery | Replay WAL from last checkpoint to restore after crash |
| UNLOGGED table | Table that bypasses WAL — fast writes but lost on crash |

---

## Practice Questions

1. Why must the WAL record be written to disk before the data page?
2. What is a checkpoint and why does it allow old WAL to be deleted?
3. You need to load 500M rows from a CSV as fast as possible. How does WAL configuration help?
4. What is the risk of setting `synchronous_commit = off`? What is the risk of setting `fsync = off`?
5. After a server crash, PostgreSQL replays WAL. Starting from what point? Why not from the beginning?
6. Your replication lag is increasing. Which WAL metrics would you check first?

---

**← Previous:** [12_concurrency_control.md](12_concurrency_control.md)  
**Next →** [14_backup_strategies.md](14_backup_strategies.md) *(Module 3 — Administration & Operations)*
