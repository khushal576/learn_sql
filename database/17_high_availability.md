# Chapter 17 — High Availability

High Availability (HA) means the database remains accessible even when individual components fail. The goal is minimizing **downtime** (RTO) and **data loss** (RPO) during failures.

---

## 17.1 Failure Modes and What HA Solves

| Failure | Without HA | With HA |
|---------|-----------|---------|
| Primary server crash | Hours of downtime (manual recovery) | Seconds (automatic failover) |
| Primary disk failure | Data loss + rebuild from backup | Replica promoted, WAL has latest data |
| Network partition | Unavailable | Replica takes over |
| Planned maintenance | Downtime for upgrades | Rolling restarts, switchover |
| Data center outage | Total loss | DR replica in other region |

---

## 17.2 HA Architecture Concepts

### Failover vs Switchover

- **Failover**: Emergency — primary died unexpectedly. Replica promoted automatically or manually. Risk of data loss if async replication.
- **Switchover**: Planned — gracefully move primary role to a replica. Zero data loss (old primary confirms all WAL sent before stepping down).

### Split Brain

The most dangerous HA problem: **two nodes both think they're the primary**.

```
Primary ←──── network partition ────→ Replica
  writes                                 promoted by HA tool
  still going                            also accepting writes
```

Both are accepting writes → data diverges → impossible to merge correctly.

HA tools prevent split brain using **fencing** and **quorum**.

### Fencing

When a node is demoted (or suspected dead), **fence** it — forcibly prevent it from writing:
- STONITH (Shoot The Other Node In The Head) — power off via IPMI/iLO
- Revoke network access via firewall
- Revoke disk access via SCSI reservations

Without fencing, split brain is not truly prevented.

---

## 17.3 Patroni — Industry Standard HA for PostgreSQL

**Patroni** is the most widely used HA solution for PostgreSQL (used at Zalando, GitLab, Heroku).

### How Patroni Works

```
┌──────────────────────────────────────────────────────────────┐
│                    DCS (Distributed Config Store)             │
│               etcd / Consul / ZooKeeper                       │
│  Holds: who is primary, leader lock, cluster config          │
└──────┬──────────────────┬────────────────────────────────────┘
       │                  │
       ▼                  ▼
┌─────────────┐    ┌─────────────┐
│  Node 1     │    │  Node 2     │
│  Patroni    │    │  Patroni    │
│  +          │    │  +          │
│  PostgreSQL │    │  PostgreSQL │
│  (primary)  │    │  (replica)  │
└─────────────┘    └─────────────┘
```

**Patroni** runs as a daemon on each PostgreSQL node and:
1. Competes for a **leader lock** in the DCS (etcd/Consul)
2. Whoever holds the lock is primary; others are replicas
3. Leader renews lock every TTL seconds (default 10s)
4. If leader fails to renew → lock expires → another node wins election → failover

### Installing Patroni

```bash
pip install patroni[etcd]
```

### Patroni Configuration

```yaml
# /etc/patroni/patroni.yml
scope: postgres-cluster
name: node1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.1:8008

etcd:
  hosts: 10.0.0.10:2379,10.0.0.11:2379,10.0.0.12:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576  # 1MB — don't failover if replica is this far behind
  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.1:5432
  data_dir: /var/lib/postgresql/14/main
  authentication:
    replication:
      username: replicator
      password: secret
    superuser:
      username: postgres
      password: secret
  parameters:
    wal_level: replica
    max_wal_senders: 10
    max_replication_slots: 10
    hot_standby: on
```

### Patroni Commands (patronictl)

```bash
# View cluster status
patronictl -c /etc/patroni/patroni.yml list

# Output:
# + Cluster: postgres-cluster -------+----+-----------+
# | Member | Host       | Role    | State   | TL | Lag in MB |
# +--------+------------+---------+---------+----+-----------+
# | node1  | 10.0.0.1:5432 | Leader  | running |  1 |           |
# | node2  | 10.0.0.2:5432 | Replica | running |  1 |         0 |
# | node3  | 10.0.0.3:5432 | Replica | running |  1 |         0 |

# Manual switchover (planned)
patronictl -c /etc/patroni/patroni.yml switchover --master node1 --candidate node2

# Manual failover (emergency)
patronictl -c /etc/patroni/patroni.yml failover --master node1

# Restart PostgreSQL on a node (rolling restart)
patronictl -c /etc/patroni/patroni.yml restart postgres-cluster node1

# Reload config (no restart)
patronictl -c /etc/patroni/patroni.yml reload postgres-cluster

# Edit cluster-wide DCS config
patronictl -c /etc/patroni/patroni.yml edit-config
```

---

## 17.4 Patroni + HAProxy for Connection Routing

Applications need to always connect to the current primary. HAProxy checks Patroni's REST API to route connections:

```ini
# haproxy.cfg

frontend postgres_write
    bind *:5432
    default_backend postgres_primary

frontend postgres_read
    bind *:5433
    default_backend postgres_replicas

backend postgres_primary
    option httpchk GET /primary
    server node1 10.0.0.1:5432 check port 8008
    server node2 10.0.0.2:5432 check port 8008
    server node3 10.0.0.3:5432 check port 8008

backend postgres_replicas
    option httpchk GET /replica
    balance roundrobin
    server node1 10.0.0.1:5432 check port 8008
    server node2 10.0.0.2:5432 check port 8008
    server node3 10.0.0.3:5432 check port 8008
```

Patroni exposes:
- `GET /primary` → HTTP 200 if this node is primary, 503 otherwise
- `GET /replica` → HTTP 200 if this node is replica, 503 otherwise

HAProxy checks these and only routes to healthy nodes. Application connects to `haproxy:5432` — never to individual PostgreSQL nodes directly.

---

## 17.5 pg_auto_failover — Simpler Alternative

For simpler two-node setups, **pg_auto_failover** is easier to configure than Patroni:

```
Monitor Node (coordinates failover)
    ├── Primary Node
    └── Secondary Node
```

```bash
# Initialize monitor
pg_autoctl create monitor --pgdata /data/monitor --pgport 5555

# Initialize primary
pg_autoctl create postgres \
  --pgdata /data/primary \
  --monitor postgres://autoctl@monitor:5555/pg_auto_failover

# Initialize secondary
pg_autoctl create postgres \
  --pgdata /data/secondary \
  --monitor postgres://autoctl@monitor:5555/pg_auto_failover

# Start
pg_autoctl run
```

pg_auto_failover is simpler but less flexible than Patroni. Good for two-node setups; use Patroni for larger clusters.

---

## 17.6 Connection String for HA

Applications should not hardcode the primary IP. Use:

### Multi-host connection string (libpq)

```
postgresql://user:pass@node1:5432,node2:5432,node3:5432/mydb?target_session_attrs=read-write
```

libpq tries each host in order and uses the first one that satisfies `target_session_attrs`:
- `read-write`: must be primary
- `standby`: must be replica
- `any`: any node

### Via HAProxy (recommended)

```
postgresql://user:pass@haproxy:5432/mydb
```

One endpoint, HAProxy handles routing. Simplest for applications.

---

## 17.7 Failover Checklist

When primary fails and you need to failover:

```
1. Detect failure          (monitoring alert, Patroni auto-detects)
2. Confirm failure         (not just a network blip)
3. Fence the old primary   (STONITH or remove from load balancer)
4. Choose new primary      (highest LSN replica = least data loss)
5. Promote replica         (patronictl failover / pg_ctl promote)
6. Update connection routing (HAProxy detects via health check)
7. Other replicas re-attach (follow new primary)
8. Investigate cause       (don't skip this)
9. Restore old primary     (rejoin as replica once fixed)
```

With Patroni: steps 1-7 happen automatically in ~30 seconds.

---

## 17.8 Recovery Time and Data Loss Expectations

| Configuration | RTO | RPO |
|--------------|-----|-----|
| No HA (manual recovery from backup) | Hours | Hours (since last backup) |
| Async streaming + manual failover | 5-15 min | Seconds (WAL lag) |
| Async streaming + Patroni | 30-60 sec | Seconds (WAL lag) |
| Sync streaming + Patroni | 30-60 sec | Zero (no data loss) |
| Multi-region sync replication | 1-2 min | Zero |

---

## 17.9 Monitoring Patroni

```bash
# REST API health checks
curl http://node1:8008/health      # 200 = healthy
curl http://node1:8008/primary     # 200 = is primary
curl http://node1:8008/replica     # 200 = is replica
curl http://node1:8008/patroni     # full cluster state JSON

# Cluster state
patronictl -c /etc/patroni/patroni.yml list

# History of leadership changes
patronictl -c /etc/patroni/patroni.yml history
```

Alert on:
- Any node unreachable
- Replica lag > threshold
- Unexpected leader change
- Failed DCS (etcd) connection

---

## 17.10 HA Architecture Patterns

### Two-Node (minimum viable)

```
Primary ──streaming──→ Replica
```
Risk: if both nodes in same DC, DC failure kills everything.

### Three-Node (recommended minimum)

```
Primary ──→ Replica 1 (same DC, sync if needed)
        ──→ Replica 2 (different DC, async DR)
```

### Active-Active (requires application-level handling)

PostgreSQL doesn't natively support multi-primary writes. Options:
- **Citus** (sharding) — writes go to different shards on different nodes
- **BDR (Bi-Directional Replication)** — EDB commercial product
- Application-level sharding

For most cases: active-passive (one primary, N replicas) is the right architecture.

---

## Key Terms

| Term | Meaning |
|------|---------|
| RTO | Recovery Time Objective — max acceptable downtime |
| RPO | Recovery Point Objective — max acceptable data loss |
| Failover | Promoting a replica to primary after primary failure |
| Switchover | Planned, graceful demotion of primary to replica |
| Split Brain | Two nodes both believe they are primary — dangerous |
| Fencing | Forcibly preventing a demoted node from writing |
| Quorum | Majority of nodes must agree on who is primary |
| Patroni | Python-based HA daemon for PostgreSQL using a DCS |
| DCS | Distributed Configuration Store (etcd, Consul, ZooKeeper) |
| STONITH | "Shoot The Other Node In The Head" — hardware fencing |

---

## Practice Questions

1. What is split brain and why is it dangerous?
2. What does Patroni use a DCS (etcd/Consul) for?
3. How does HAProxy know which PostgreSQL node is the current primary?
4. What is the difference between a failover and a switchover?
5. You have async replication with a 500ms lag. The primary crashes. How much data do you lose?
6. A replica is 100 MB behind the primary. Patroni is configured with `maximum_lag_on_failover: 1048576` (1 MB). What happens if the primary crashes?

---

**← Previous:** [16_replication.md](16_replication.md)  
**Next →** [18_vacuum_maintenance.md](18_vacuum_maintenance.md)
