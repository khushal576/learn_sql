# Chapter 24 — CAP Theorem & Distributed Systems

Understanding the CAP theorem and distributed systems concepts is essential when designing systems that use multiple databases or need to scale beyond a single server.

---

## 24.1 The CAP Theorem

Proposed by Eric Brewer (2000), proved by Gilbert & Lynch (2002):

> In a distributed system, you can only guarantee **two out of three** properties simultaneously: **Consistency**, **Availability**, and **Partition Tolerance**.

```
         Consistency
             /\
            /  \
           /    \
          / CA   \
         /        \
        /____CP____\
       /     |      \
      /   AP |       \
     /       |        \
Availability -- Partition
              Tolerance
```

---

## 24.2 The Three Properties

### C — Consistency
Every read receives the most recent write or an error. All nodes see the same data at the same time.

```
Write "balance=500" to Node 1
Read from Node 2 → must return 500 (not old value)
```

This is NOT the same as ACID consistency. CAP consistency = linearizability (all operations appear atomic and in real-time order).

### A — Availability
Every request receives a response (not necessarily the latest data). The system is always up — no timeouts, no errors.

```
Node 2 is partitioned from Node 1
Read from Node 2 → returns stale data, but returns something
```

### P — Partition Tolerance
The system continues operating even when network messages between nodes are lost or delayed (a network partition).

```
Node 1 ──╳── Node 2    (network partition)
Both nodes keep running
```

---

## 24.3 Why You Always Need Partition Tolerance

Network partitions happen — cables fail, switches reboot, datacenter links degrade. You cannot build a distributed system that opts out of partition tolerance.

**P is non-negotiable in distributed systems.**

Therefore the real choice is:
- **CP**: When a partition occurs, reject requests rather than serve stale data (choose consistency over availability)
- **AP**: When a partition occurs, serve stale data rather than reject requests (choose availability over consistency)

CA (no partition tolerance) only makes sense for a single-node system — i.e., a traditional RDBMS on one server.

---

## 24.4 Database Classification

| Database | CAP | Explanation |
|---------|-----|-------------|
| **PostgreSQL** (single node) | CA | No partition — full ACID |
| **PostgreSQL + sync replication** | CP | Won't return until all nodes confirm |
| **PostgreSQL + async replication** | AP | Returns success, replica may lag |
| **Cassandra** | AP | Tunable consistency, defaults to availability |
| **MongoDB** (default) | CP | Primary required for writes |
| **CockroachDB** | CP | Distributed SQL, consistency priority |
| **DynamoDB** | AP | Eventually consistent by default |
| **Redis** (standalone) | CA | Single node |
| **Redis Cluster** | AP | Availability prioritized |
| **etcd / ZooKeeper** | CP | Consensus protocols |

---

## 24.5 PACELC — Beyond CAP

CAP only describes behavior during a partition. **PACELC** extends it to normal operation:

> **P**artition → **A**vailability vs **C**onsistency  
> **E**lse (no partition) → **L**atency vs **C**onsistency

During normal operation (no partition), you must choose between:
- **Low latency**: Don't wait for all nodes to confirm → might serve stale data
- **Strong consistency**: Wait for all nodes → higher latency

```
Amazon DynamoDB: PA / EL  (available during partition, low latency normally)
Google Spanner:  PC / EC  (consistent during partition, consistent normally — uses atomic clocks)
PostgreSQL:      PC / EC  (single node: consistent always)
Cassandra:       PA / EL  (available + low latency)
```

---

## 24.6 Consistency Models — A Spectrum

CAP consistency (linearizability) is the strongest model. Real systems offer a spectrum:

| Model | Guarantee | Example |
|-------|-----------|---------|
| **Linearizable** | All ops appear atomic in real-time order | PostgreSQL SERIALIZABLE |
| **Sequential** | All nodes see same order, not necessarily real-time | |
| **Causal** | Causally related ops are in order | |
| **Read-your-writes** | You always see your own writes | Most web apps need this |
| **Monotonic reads** | Never read older data than you saw before | |
| **Eventual consistency** | Eventually all nodes converge | DynamoDB default |

**Eventual consistency** means: given no new writes, all replicas eventually agree — but you might read stale data in the interim.

---

## 24.7 Eventual Consistency in Practice

For a user profile update:

```
User writes: name = "Alice Smith" → goes to primary
User reads immediately from replica → might see "Alice" (old value)
After replication lag (milliseconds to seconds):
All replicas show "Alice Smith"
```

This is acceptable for: social media feeds, product views, non-critical counters.  
This is NOT acceptable for: bank balances, inventory (don't oversell), seat booking.

---

## 24.8 Consensus Algorithms — How Distributed Databases Agree

When multiple nodes must agree on a value (who is the leader? did this write succeed?), they use consensus algorithms:

### Raft (used by etcd, CockroachDB, TiDB)
```
1. Nodes elect a leader (majority vote)
2. All writes go through the leader
3. Leader replicates to followers
4. Write confirmed after majority acknowledge
5. If leader fails → election → new leader
```

Guarantees: no data loss as long as a majority of nodes are alive.

### Paxos (used by Google Spanner, Chubby)
Similar to Raft but historically described first. Harder to implement correctly.

### Why this matters for PostgreSQL
- Patroni uses **etcd** (Raft-based) to elect a PostgreSQL primary
- CockroachDB uses **Raft** per data range for distributed transactions
- The "majority" requirement means you need **odd numbers of nodes** (3, 5, 7) for proper quorum

---

## 24.9 Distributed Transactions

Transactions across multiple nodes (different shards, different databases):

### Two-Phase Commit (2PC)
```
Phase 1 (Prepare):
  Coordinator → Node A: "Prepare to commit transaction X"
  Coordinator → Node B: "Prepare to commit transaction X"
  Both reply: "Ready"

Phase 2 (Commit):
  Coordinator → Node A: "Commit"
  Coordinator → Node B: "Commit"
```

Problem: If coordinator crashes between Phase 1 and Phase 2, nodes are stuck in "prepared" state indefinitely — this is the 2PC blocking problem.

PostgreSQL supports `PREPARE TRANSACTION` / `COMMIT PREPARED` for 2PC.

### Saga Pattern
Instead of distributed ACID transactions, use a sequence of local transactions with **compensating transactions** for rollback:

```
Order Saga:
1. Reserve inventory (local transaction on inventory service)
2. Charge payment (local transaction on payment service)
3. Create shipment (local transaction on shipping service)

If step 3 fails:
→ Refund payment (compensating transaction)
→ Release inventory (compensating transaction)
```

Used by Amazon, Uber, Netflix for distributed workflows. More complex but avoids 2PC blocking.

---

## 24.10 Replication Lag and Read-After-Write

A common real-world problem with replicas:

```
1. User updates profile photo
2. Write goes to primary
3. User is redirected to profile page
4. Profile page queries replica
5. Replica hasn't received the update yet → shows old photo
6. User is confused
```

Solutions:

```python
# Option 1: Read from primary for a brief period after a write
# Option 2: Read your own writes — route to primary if user recently wrote
# Option 3: Wait for replica to catch up
#   SELECT pg_wal_replay_wait(lsn_from_last_write)
# Option 4: Use a monotonic session token (client sends the LSN of their last write)
```

This is the "read-your-writes" consistency requirement that even eventually-consistent systems often try to satisfy.

---

## 24.11 PostgreSQL and Distributed Systems

PostgreSQL is fundamentally a single-node database. Distributed capabilities are added through tools:

| Need | Tool | Approach |
|------|------|---------|
| Read scaling | Streaming replication | AP — replicas may lag |
| HA failover | Patroni + etcd | CP — requires quorum |
| Distributed SQL | CockroachDB / YugabyteDB | CP — Raft consensus |
| Sharding | Citus | CP for coordinator queries |
| Geo-distribution | Google Spanner / CockroachDB | PC/EC (PACELC) |

For most applications, PostgreSQL with replication + Patroni is sufficient and far simpler than fully distributed SQL.

---

## Key Terms

| Term | Meaning |
|------|---------|
| CAP theorem | Distributed systems can guarantee only 2 of: Consistency, Availability, Partition Tolerance |
| Linearizability | Strongest consistency — all ops appear atomic in real-time |
| Eventual consistency | Replicas converge eventually; stale reads possible |
| PACELC | Extension of CAP: also considers latency vs consistency when no partition |
| Raft | Consensus algorithm used by etcd, CockroachDB |
| 2PC | Two-Phase Commit — distributed transaction protocol |
| Saga | Compensating transaction pattern for distributed workflows |
| Read-your-writes | Guarantee: you always see your own most recent writes |

---

## Practice Questions

1. Why is partition tolerance non-negotiable in distributed systems?
2. DynamoDB is AP. What does this mean for a banking application?
3. You have async replication. A user updates their email and immediately reads their profile. What might they see?
4. Why do distributed systems like etcd require an odd number of nodes (3, 5)?
5. What is the difference between CAP consistency and ACID consistency?
6. A distributed order system uses 2PC. The coordinator crashes after Phase 1. What happens?

---

**← Previous:** [23_nosql.md](23_nosql.md)  
**Next →** [25_security.md](25_security.md)
