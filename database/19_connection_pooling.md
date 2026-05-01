# Chapter 19 — Connection Pooling & PgBouncer

PostgreSQL creates a new OS process for every client connection. At scale, this becomes a bottleneck. Connection pooling is the solution — and PgBouncer is the standard tool for it.

---

## 19.1 The Problem: PostgreSQL Connection Cost

When a client connects to PostgreSQL:
1. A new OS process is forked (`~5-10 MB` of memory each)
2. A connection setup handshake runs (TLS, authentication, catalog loading)
3. The process persists for the entire connection lifetime

At **100 connections**: ~500 MB RAM used just for connections  
At **500 connections**: ~2.5 GB RAM, significant context-switching overhead  
At **1000+ connections**: PostgreSQL becomes slow and unstable

**Real-world problem**: A web application with 50 app servers, each with a connection pool of 20 → 1000 connections to PostgreSQL. Too many.

---

## 19.2 What is Connection Pooling?

A **connection pool** sits between your application and PostgreSQL:

```
App Server 1 ──┐
App Server 2 ──┼──→ PgBouncer ──→ PostgreSQL
App Server 3 ──┘     (pool)        (few real connections)
  1000 app connections   ↕   only 20-50 connections to PostgreSQL
```

PgBouncer maintains a small pool of real PostgreSQL connections and multiplexes thousands of application connections across them.

Applications think they have a direct connection. PostgreSQL sees only a small number of connections.

---

## 19.3 PgBouncer Pool Modes

PgBouncer has three pooling modes, trading flexibility for efficiency:

### Session Mode (safest, least efficient)

```
Client connects → gets a dedicated server connection
Client disconnects → connection returned to pool
```

- Application has one server connection for its entire session
- Supports all PostgreSQL features (prepared statements, session-level settings, `SET`, `LISTEN/NOTIFY`)
- **Not much better than direct connections** — each client still occupies a slot

**Use when**: Application uses session-level features (SET, temp tables, advisory locks)

---

### Transaction Mode (recommended for most apps)

```
Client sends BEGIN → gets a server connection
Client sends COMMIT/ROLLBACK → connection returned to pool immediately
Between transactions: no server connection held
```

- One server connection shared across many idle clients
- **Dramatic efficiency**: 1000 app clients → 20 server connections if most are idle between transactions
- **Limitation**: No session-level features — prepared statements, `SET LOCAL`, `LISTEN/NOTIFY` don't work across transactions

**Use when**: Stateless applications (REST APIs, microservices)

---

### Statement Mode (most aggressive, rarely used)

```
Each individual SQL statement gets a connection
After the statement: connection returned immediately
```

- **Breaks multi-statement transactions** — each statement is a separate transaction
- Only safe for single-statement, auto-commit workloads
- Almost never used in practice

---

## 19.4 Installing and Configuring PgBouncer

### Install

```bash
# Debian/Ubuntu
apt-get install pgbouncer

# RHEL/CentOS
yum install pgbouncer
```

### Configuration File

```ini
# /etc/pgbouncer/pgbouncer.ini

[databases]
# Database aliases: client connects to "mydb", PgBouncer routes to real host
mydb = host=127.0.0.1 port=5432 dbname=mydb

# Connection to a replica (for read routing)
mydb_read = host=10.0.0.2 port=5432 dbname=mydb

# Wildcard: any database name passes through
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432                   # PgBouncer listens here
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

pool_mode = transaction              # RECOMMENDED for most apps

# Pool sizing
max_client_conn = 1000               # max client connections to PgBouncer
default_pool_size = 20               # server connections per database+user combo
min_pool_size = 5                    # keep this many connections open always
reserve_pool_size = 5                # extra connections for spikes
max_db_connections = 50              # hard cap on server connections per database

# Timeouts
server_idle_timeout = 600            # close idle server connections after 10min
client_idle_timeout = 0              # don't close idle clients
query_timeout = 0                    # no per-query timeout (set in app/PostgreSQL)
connect_timeout = 15                 # fail fast if can't connect to PostgreSQL

# Logging
log_connections = 0                  # 0 = quiet, 1 = log connects
log_disconnections = 0
log_pooler_errors = 1

# Admin interface
admin_users = postgres
stats_users = monitor
```

### User List

```ini
# /etc/pgbouncer/userlist.txt
# Format: "username" "md5hash_or_password"
"appuser" "md5abc123def456..."
"readonly" "md5xyz789..."

# Get the md5 hash:
# echo -n "passwordusername" | md5sum → prepend "md5"
```

### Start and Verify

```bash
systemctl start pgbouncer
systemctl enable pgbouncer

# Connect to PgBouncer admin console
psql -h 127.0.0.1 -p 6432 -U postgres pgbouncer

# View pool stats
SHOW POOLS;
SHOW STATS;
SHOW CLIENTS;
SHOW SERVERS;
```

---

## 19.5 PgBouncer Admin Commands

```sql
-- Connect to admin console
psql -h 127.0.0.1 -p 6432 -U postgres pgbouncer

-- Pool status: cl_active, cl_waiting, sv_active, sv_idle, sv_used
SHOW POOLS;
--  database | user    | cl_active | cl_waiting | sv_active | sv_idle | sv_used
-- ----------+---------+-----------+------------+-----------+---------+---------
--  mydb     | appuser |        45 |          0 |        18 |       2 |       0

-- Current statistics
SHOW STATS;

-- Active client connections
SHOW CLIENTS;

-- Active server connections
SHOW SERVERS;

-- Configuration
SHOW CONFIG;

-- Reload config without restart
RELOAD;

-- Pause a database (queues new queries, waits for current to finish)
PAUSE mydb;

-- Resume
RESUME mydb;

-- Kill all connections to a database
KILL mydb;

-- Graceful shutdown
SHUTDOWN;
```

---

## 19.6 Understanding SHOW POOLS Output

```
cl_active   = clients with a server connection assigned
cl_waiting  = clients waiting for a server connection (queue)
sv_active   = server connections in use
sv_idle     = server connections waiting in pool
sv_used     = server connections recently used but now idle (may need cleanup)
```

**Warning signs**:
- `cl_waiting > 0` persistently → pool is undersized, increase `default_pool_size`
- `sv_active` ≈ `default_pool_size` always → pool exhausted
- Many `sv_used` connections → connection churn, reduce `server_idle_timeout`

---

## 19.7 PgBouncer with TLS

```ini
# pgbouncer.ini

# Client → PgBouncer: TLS
client_tls_sslmode = require
client_tls_ca_file = /etc/ssl/certs/ca.crt
client_tls_cert_file = /etc/pgbouncer/server.crt
client_tls_key_file = /etc/pgbouncer/server.key

# PgBouncer → PostgreSQL: TLS
server_tls_sslmode = require
server_tls_ca_file = /etc/ssl/certs/ca.crt
```

---

## 19.8 PgBouncer and Prepared Statements

Prepared statements are a common compatibility issue with transaction mode pooling.

The problem:
```
Client: PREPARE stmt AS SELECT * FROM users WHERE id = $1
          → executed on server connection A
Client: EXECUTE stmt
          → might get server connection B, which doesn't have "stmt"
          → ERROR: prepared statement "stmt" does not exist
```

Solutions:

1. **Use session mode** (if your app uses prepared statements heavily)

2. **Use protocol-level prepared statements** (ORMs often do this transparently):
   PostgreSQL's "unnamed prepared statement" (`PREPARE ""`) is prepared and executed in the same round-trip — works in transaction mode

3. **`server_reset_query`**: PgBouncer sends this after each transaction to reset state:
   ```ini
   server_reset_query = DISCARD ALL
   ```

4. **Application-level**: Disable prepared statements in your ORM/driver:
   ```python
   # SQLAlchemy
   engine = create_engine(url, execution_options={"no_parameters": True})
   ```

---

## 19.9 Sizing the Pool

**Formula for `default_pool_size`**:

```
Optimal server connections = number of CPU cores on PostgreSQL server

A PostgreSQL server with 8 CPU cores handles ~8 queries in parallel.
More connections than CPUs = context switching → worse performance.

default_pool_size = 2 × num_cpus  (accounting for I/O wait)
```

For a server with 16 CPUs:
```ini
default_pool_size = 25      # leave some headroom
max_db_connections = 30     # hard cap
max_client_conn = 2000      # can accept thousands of app connections
```

**Rule**: Having 10,000 app connections to PgBouncer with only 25 PostgreSQL connections is fine — as long as your app is not all querying simultaneously.

---

## 19.10 PgBouncer Architecture in Production

```
Internet
    ↓
Load Balancer (Nginx / HAProxy)
    ↓
App Servers × N
    ↓
PgBouncer (transaction mode, 6432)
    ├──→ PostgreSQL Primary :5432    (reads + writes)
    └── PgBouncer (session mode, 6433)
           └──→ PostgreSQL Replica :5432  (read-only queries)
```

Best practice:
- Run PgBouncer on the **same server** as PostgreSQL (no network hop, Unix socket)
- Or run PgBouncer on each app server (no single point of failure)

```ini
# Use Unix socket for lowest latency
[databases]
mydb = host=/var/run/postgresql port=5432 dbname=mydb
```

---

## 19.11 Alternatives to PgBouncer

| Tool | Model | When to use |
|------|-------|-------------|
| **PgBouncer** | External process | Most production setups |
| **Pgpool-II** | Proxy + load balancer | Query routing + read/write splitting |
| **pg_bouncer (cloud)** | Managed (AWS RDS Proxy, Supabase) | Cloud deployments |
| **Built-in app pool** | Library-level (HikariCP, connection_pool) | Simple cases, single app server |

For most cases, **PgBouncer in transaction mode** is the right answer.

---

## Key Terms

| Term | Meaning |
|------|---------|
| Connection pool | A set of reused database connections shared across many clients |
| Session mode | One server connection per client session |
| Transaction mode | Server connection released after each transaction |
| Statement mode | Server connection released after each statement |
| `max_client_conn` | Max clients that can connect to PgBouncer |
| `default_pool_size` | Server connections per database+user pair |
| `cl_waiting` | Clients queued waiting for a server connection |
| `DISCARD ALL` | Resets all session state; used between pooled connections |

---

## Practice Questions

1. Your PostgreSQL server has 8 CPUs. What is a good `default_pool_size` for PgBouncer?
2. Your app uses `SET search_path = myschema` in each session. Which PgBouncer pool mode should you use?
3. `SHOW POOLS` shows `cl_waiting = 50` constantly. What does this mean and how do you fix it?
4. Explain why prepared statements break in transaction mode and three ways to solve it.
5. What is the advantage of running PgBouncer on the same server as PostgreSQL?
6. Your app has 500 instances each with a pool of 10 connections = 5000 connections total. PostgreSQL is struggling. How does PgBouncer help?

---

**← Previous:** [18_vacuum_maintenance.md](18_vacuum_maintenance.md)  
**Next →** [20_monitoring.md](20_monitoring.md)
