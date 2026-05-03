-------------------------------------------------
-- CHAPTER 24
-- Bulk I/O, Pub/Sub, Advisory Locks, and Sampling
-------------------------------------------------
-- Four practical PostgreSQL capabilities that most tutorials skip:
--
--   COPY          — the fastest way to load or export data
--   LISTEN/NOTIFY — lightweight publish-subscribe messaging built into PostgreSQL
--   Advisory locks — application-level distributed locking without a lock table
--   TABLESAMPLE   — efficient random sampling from large tables
--
-- These are production tools that appear in real systems every day.

-------------------------------------------------
-- PART 1: COPY — Bulk Import and Export
-------------------------------------------------
-- INSERT processes one row at a time through the query planner.
-- COPY bypasses the planner and loads data in bulk — typically 10-100x faster.
--
-- Two forms:
--   Server-side COPY  — the file lives on the PostgreSQL SERVER filesystem.
--                       Requires superuser or pg_read_server_files privilege.
--   Client-side \copy — the file lives on your LOCAL machine.
--                       A psql meta-command, no special privileges needed.
--                       Always use \copy when connecting through Docker or a remote server.

-------------------------------------------------
-- Export: COPY table TO file
-------------------------------------------------

-- Server-side export (file created on the server)
copy emp to '/tmp/emp_export.csv'
with (format csv, header true);

-- Export specific columns with a WHERE filter
copy (
    select empno, ename, sal, deptno
    from emp
    where deptno = 10
) to '/tmp/emp_dept10.csv'
with (format csv, header true);

-- Binary format is faster but not human-readable
copy emp to '/tmp/emp_export.bin' with (format binary);

-- Write to STDOUT (useful in shell scripts: psql -c "\copy emp to stdout" > file.csv)
-- copy emp to stdout with (format csv, header true);

-------------------------------------------------
-- Import: COPY table FROM file
-------------------------------------------------

-- Create a staging table to load into
create table if not exists emp_staging (like emp);

-- Server-side import
copy emp_staging from '/tmp/emp_export.csv'
with (format csv, header true);

select count(*) from emp_staging;   -- should match emp row count

-- Truncate-then-load is the standard pattern for full table refreshes
truncate emp_staging;
copy emp_staging from '/tmp/emp_export.csv'
with (format csv, header true);

drop table if exists emp_staging;

-------------------------------------------------
-- psql \copy (client-side) — no superuser required
-------------------------------------------------
-- When connected via psql, use \copy instead of COPY for local files.
-- Syntax is identical except for the leading backslash.
--
-- \copy emp to '/local/path/emp.csv' with (format csv, header true)
-- \copy emp from '/local/path/emp.csv' with (format csv, header true)
--
-- In Docker: your local filesystem is NOT the same as the container filesystem.
-- Always use \copy from a psql session when the file is on your laptop.

-------------------------------------------------
-- COPY options reference
-------------------------------------------------
-- FORMAT          csv | text | binary
-- HEADER          true | false   (include/skip column name row)
-- DELIMITER       ','  (default for CSV, TAB for text)
-- NULL            ''   (string that represents NULL)
-- QUOTE           '"'  (default CSV quote character)
-- ESCAPE          '"'  (default CSV escape character)
-- ENCODING        'UTF8' (file encoding)
-- ON_ERROR        IGNORE (skip bad rows — PostgreSQL 17+)

-- Example: load a tab-separated file where NULLs are written as \N
-- copy emp from '/tmp/emp.tsv' with (format text, null '\N');

-------------------------------------------------
-- COPY performance tips
-------------------------------------------------
-- 1. Drop indexes before a large COPY, recreate them after — much faster overall.
-- 2. Wrap multiple COPYs in a single transaction to reduce WAL overhead.
-- 3. Set synchronous_commit = off for the session if data loss is acceptable.
-- 4. Use UNLOGGED tables for staging — no WAL writes at all.

-- COPY vs INSERT performance comparison
-- INSERT 14 rows: trivially fast for small data
-- COPY 1M rows:   typically 10-50x faster than equivalent multi-row INSERT

-------------------------------------------------
-- PART 2: LISTEN / NOTIFY — Pub/Sub Messaging
-------------------------------------------------
-- NOTIFY sends a message on a named channel. Any session LISTENing to that channel
-- receives the message at the start of the next command or when polling.
-- Delivery is transactional — if the sending transaction rolls back, no message is sent.
-- Messages are NOT persisted — if no one is listening, the message is lost.

-------------------------------------------------
-- Sending a notification
-------------------------------------------------

-- Simple notify (no payload)
notify emp_changes;

-- Notify with a payload string (max 8000 bytes)
notify emp_changes, 'empno=7369 action=update';

-- pg_notify() function — same as NOTIFY but callable from PL/pgSQL
select pg_notify('emp_changes', 'empno=7499 action=insert');

-------------------------------------------------
-- Listening for notifications
-------------------------------------------------
-- In a second psql session, run:
--   LISTEN emp_changes;
-- Then any NOTIFY on that channel delivers to that session.
-- In psql interactive mode, the notification prints after the next command.
--
-- Client libraries handle this differently:
--   psycopg2 (Python):   conn.notifies queue, poll with conn.poll()
--   node-postgres (JS):  client.on('notification', handler)
--   JDBC (Java):         PGConnection.getNotifications()

-- Check which channels this session is listening to
select pg_listening_channels();

-- Stop listening
-- unlisten emp_changes;
-- unlisten *;    -- stop listening to all channels

-------------------------------------------------
-- Trigger-based NOTIFY (most common production pattern)
-------------------------------------------------
-- Fire a notification automatically whenever a row is inserted/updated.
-- This decouples the app from knowing when to send notifications.

create or replace function notify_emp_change()
returns trigger language plpgsql as $$
begin
    perform pg_notify(
        'emp_changes',
        json_build_object(
            'action', TG_OP,
            'empno',  NEW.empno,
            'ename',  NEW.ename
        )::text
    );
    return NEW;
end;
$$;

create trigger emp_change_notify
after insert or update on emp
for each row execute function notify_emp_change();

-- Now any INSERT or UPDATE on emp sends a JSON payload to the 'emp_changes' channel.
-- Application code listening on that channel receives it immediately.

-- Clean up the trigger and function
drop trigger if exists emp_change_notify on emp;
drop function if exists notify_emp_change();

-------------------------------------------------
-- PART 3: Advisory Locks
-------------------------------------------------
-- Advisory locks are application-defined locks stored in PostgreSQL shared memory.
-- They are NOT tied to any table, row, or transaction — your app controls them.
-- Use cases:
--   - Prevent two processes running the same cron job simultaneously
--   - Distributed mutex for a critical section (cache rebuild, file processing)
--   - Queue "at most once" processing

-- Advisory locks use a 64-bit integer key.
-- Use hashtext() to convert a meaningful name to a stable integer key.
select hashtext('daily_report_job')::bigint as lock_key;

-------------------------------------------------
-- Session-level advisory locks
-------------------------------------------------
-- Held until explicitly released or the session disconnects.

-- Acquire a lock (blocks if already held by another session)
select pg_advisory_lock(12345);

-- Non-blocking try — returns false immediately if lock is not available
select pg_advisory_try_lock(12345);    -- true if acquired, false if not

-- Release the lock
select pg_advisory_unlock(12345);

-- Release all session advisory locks at once
select pg_advisory_unlock_all();

-------------------------------------------------
-- Transaction-level advisory locks (usually preferred)
-------------------------------------------------
-- Automatically released at the end of the transaction. Cleaner and safer.

begin;
    -- Acquire a transaction-level advisory lock
    select pg_advisory_xact_lock(42);
    -- ... do critical work here ...
    -- Lock is released automatically at COMMIT or ROLLBACK
commit;

-- Non-blocking transaction-level try
begin;
    select pg_advisory_xact_try_lock(42) as got_lock;
commit;

-------------------------------------------------
-- Two-argument form (32-bit + 32-bit = 64-bit key)
-------------------------------------------------
-- Useful for namespacing: first arg = application/job type, second = specific ID.
-- e.g. (1, order_id) means "processing order order_id in app namespace 1"
select pg_advisory_lock(1, 999);       -- lock for (app=1, resource=999)
select pg_advisory_unlock(1, 999);

-------------------------------------------------
-- Inspecting current advisory locks
-------------------------------------------------
select pid, locktype, objid, granted
from pg_locks
where locktype = 'advisory';

-------------------------------------------------
-- Pattern: distributed cron deduplication
-------------------------------------------------
-- Multiple app servers run the same cron job. Only one should execute it.
do $$
declare
    got_lock boolean;
begin
    got_lock := pg_try_advisory_xact_lock(hashtext('hourly_report')::bigint);
    if got_lock then
        raise notice 'Acquired lock — running job';
        -- perform actual_job_function();
    else
        raise notice 'Another server is running this job — skipping';
    end if;
end;
$$;

-------------------------------------------------
-- PART 4: TABLESAMPLE — Efficient Random Sampling
-------------------------------------------------
-- TABLESAMPLE lets you query a random fraction of a table without scanning all rows.
-- Essential for exploratory analysis on large tables where exact results are not needed.
--
-- Two methods:
--   BERNOULLI(n) — each row is independently included with n% probability.
--                  True statistical random sample. Scans the whole table.
--   SYSTEM(n)    — randomly selects 8KB data blocks (pages) instead of rows.
--                  Much faster on large tables, but less statistically random.

-------------------------------------------------
-- BERNOULLI — statistically correct, row-level sampling
-------------------------------------------------
-- Select approximately 50% of emp rows at random
select *
from emp tablesample bernoulli(50);

-- emp only has 14 rows so results vary a lot at small percentages
-- On a million-row table this would reliably return ~500,000 rows.

-- Use REPEATABLE(seed) for deterministic results (same rows every time)
select empno, ename, sal
from emp tablesample bernoulli(70) repeatable(42);

-------------------------------------------------
-- SYSTEM — block-level sampling (faster, less random)
-------------------------------------------------
-- Randomly selects whole 8KB pages. Very fast on large tables.
-- May return 0 rows on small tables if no pages are selected.
select *
from emp tablesample system(50);

select *
from emp tablesample system(100) repeatable(1);   -- all pages, deterministic

-------------------------------------------------
-- Practical sampling patterns
-------------------------------------------------

-- Approximate count without a full table scan (on large tables)
-- Estimate total rows from a 1% sample:
select count(*) * 100 as estimated_total
from emp tablesample bernoulli(1);

-- Sample for data exploration — check column distributions without loading all rows
select deptno, count(*) as sampled_count
from emp tablesample bernoulli(80)
group by deptno;

-- Combine with CTE for a labelled sample set
with sample as (
    select * from emp tablesample bernoulli(50) repeatable(99)
)
select job, round(avg(sal), 2) as avg_sal
from sample
group by job
order by avg_sal desc;

-- Note: TABLESAMPLE does not support subqueries or CTEs directly —
-- it applies only to a base table reference.

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Use \copy (psql client-side) instead of server-side COPY whenever possible.
--    It works without superuser privileges and handles Docker/remote-server file paths correctly.

-- 2. COPY is transactional — wrap multiple loads in BEGIN/COMMIT for all-or-nothing loads.
--    On failure, the entire COPY rolls back with no partial data.

-- 3. LISTEN/NOTIFY is NOT a reliable message queue — messages are lost if no session is
--    listening when NOTIFY fires. Use it for cache-invalidation signals, not critical events.
--    For reliable messaging, pair it with an outbox table pattern.

-- 4. Always prefer transaction-level advisory locks (pg_advisory_xact_lock) over
--    session-level ones. Transaction-level locks release automatically and cannot be forgotten.

-- 5. Use BERNOULLI for statistical correctness; use SYSTEM for raw speed on large tables.
--    Always test that your sample size is large enough to be representative.

-- 6. COPY with UNLOGGED tables is the fastest possible bulk load — no WAL overhead.
--    Load into an UNLOGGED staging table, validate, then INSERT ... SELECT into the real table.
