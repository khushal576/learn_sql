# Chapter 25 — Database Security

Database security is not optional. A single misconfigured permission or unencrypted connection can expose millions of records. This chapter covers everything from roles and privileges to row-level security and encryption.

---

## 25.1 The Security Layers

```
┌────────────────────────────────────────────┐
│  Network Security       (who can connect?) │
├────────────────────────────────────────────┤
│  Authentication         (prove identity)   │
├────────────────────────────────────────────┤
│  Roles & Privileges     (what can they do?)│
├────────────────────────────────────────────┤
│  Row-Level Security     (which rows?)      │
├────────────────────────────────────────────┤
│  Column-Level Security  (which columns?)   │
├────────────────────────────────────────────┤
│  Encryption             (data at rest/transit)│
├────────────────────────────────────────────┤
│  Auditing               (who did what?)    │
└────────────────────────────────────────────┘
```

---

## 25.2 Network Security

Restrict which hosts can connect using `pg_hba.conf` (Host-Based Authentication):

```
# pg_hba.conf format:
# TYPE   DATABASE  USER       ADDRESS         METHOD

# Only localhost can connect as postgres (superuser)
local   all       postgres                   peer

# App servers can connect to mydb as appuser with password
host    mydb      appuser    10.0.0.0/24    scram-sha-256

# Replication from specific IP
host    replication replicator 10.0.0.2/32  scram-sha-256

# Deny everything else (implicit at end of file)
```

### Authentication Methods

| Method | Security | Notes |
|--------|----------|-------|
| `trust` | None | Anyone can connect — NEVER use in production |
| `password` | Weak | Password sent in plaintext |
| `md5` | Weak | MD5 hash — use only if scram not available |
| `scram-sha-256` | Strong | Use this in production |
| `peer` | OS-level | Maps OS user to PG user — good for local connections |
| `cert` | Very strong | Client TLS certificate authentication |
| `ldap` | Enterprise | Integrate with Active Directory |

**Always use `scram-sha-256` over the network.**

### Encrypt all connections with TLS

```ini
# postgresql.conf
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file  = 'server.key'
ssl_ca_file   = 'root.crt'     # for client cert verification
ssl_min_protocol_version = 'TLSv1.2'
```

```
# pg_hba.conf — require SSL
hostssl  mydb  appuser  10.0.0.0/24  scram-sha-256
```

---

## 25.3 Roles and Privileges

PostgreSQL uses a unified role model — roles can be users (with login) or groups (without login).

### Creating Roles

```sql
-- Application user (can login, no superuser)
CREATE ROLE appuser WITH LOGIN PASSWORD 'secret' CONNECTION LIMIT 50;

-- Read-only user
CREATE ROLE readonly WITH LOGIN PASSWORD 'readpass';

-- Group role (no login)
CREATE ROLE developers;

-- Grant group membership
GRANT developers TO alice;
GRANT developers TO bob;
```

### Object Privileges

```sql
-- Grant on tables
GRANT SELECT, INSERT, UPDATE ON orders TO appuser;
GRANT SELECT ON orders TO readonly;

-- Grant on all current tables in a schema
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;

-- Grant on future tables (ALTER DEFAULT PRIVILEGES)
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO readonly;

-- Revoke
REVOKE DELETE ON orders FROM appuser;

-- Grant on sequences (needed for serial inserts)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO appuser;

-- Grant schema usage
GRANT USAGE ON SCHEMA public TO appuser;
```

### Privilege Types

| Privilege | Applies To | Meaning |
|-----------|-----------|---------|
| `SELECT` | Table/view | Read rows |
| `INSERT` | Table | Add rows |
| `UPDATE` | Table/column | Modify rows/columns |
| `DELETE` | Table | Remove rows |
| `TRUNCATE` | Table | Empty table |
| `REFERENCES` | Table | Create FK referencing table |
| `TRIGGER` | Table | Create triggers |
| `EXECUTE` | Function | Call function |
| `USAGE` | Schema/sequence | Use the object |
| `CREATE` | Schema/database | Create objects within |

---

## 25.4 Principle of Least Privilege

Grant only what is needed. Nothing more.

```sql
-- ❌ Bad: everything runs as superuser
-- ❌ Bad: app user has SUPERUSER or all privileges

-- ✅ Good: separate roles per service
CREATE ROLE api_write WITH LOGIN PASSWORD '...';
GRANT SELECT, INSERT, UPDATE ON orders TO api_write;
GRANT SELECT, INSERT ON customers TO api_write;
-- api_write cannot DELETE, DROP, or access other tables

CREATE ROLE reports_reader WITH LOGIN PASSWORD '...';
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO reports_reader;

CREATE ROLE data_pipeline WITH LOGIN PASSWORD '...';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO data_pipeline;
GRANT INSERT ON ALL TABLES IN SCHEMA warehouse TO data_pipeline;
```

---

## 25.5 Row-Level Security (RLS)

RLS restricts which rows a user can see or modify — enforced by the database, not the application.

### Classic use case: multi-tenant SaaS

```sql
-- Enable RLS on the table
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

-- Policy: each user sees only their own orders
CREATE POLICY orders_isolation ON orders
    USING (tenant_id = current_setting('app.tenant_id')::int);

-- Application sets the tenant context per connection
SET app.tenant_id = '1001';

-- Now: SELECT * FROM orders → returns only tenant 1001's orders
-- Even if the SQL has no WHERE clause
```

### Multiple policies

```sql
-- Different policies for different operations
CREATE POLICY orders_select ON orders
    FOR SELECT
    USING (tenant_id = current_setting('app.tenant_id')::int);

CREATE POLICY orders_insert ON orders
    FOR INSERT
    WITH CHECK (tenant_id = current_setting('app.tenant_id')::int);

-- Admin role bypasses RLS
ALTER TABLE orders FORCE ROW LEVEL SECURITY;
-- Superusers bypass RLS by default — use FORCE to apply to table owner too

-- Grant bypass to specific role
ALTER ROLE admin BYPASSRLS;
```

### RLS for column-level access

```sql
-- Only HR can see salary column
CREATE POLICY salary_visibility ON employees
    FOR SELECT
    USING (
        pg_has_role(current_user, 'hr_team', 'member')
        OR employee_id = current_user_id()
    );
```

---

## 25.6 Column-Level Privileges

Restrict access to specific columns:

```sql
-- Analysts can see all columns except salary and ssn
GRANT SELECT (id, name, department, hire_date) ON employees TO analysts;
-- analysts cannot: SELECT salary FROM employees  → ERROR

-- Create a view as an alternative
CREATE VIEW employees_public AS
    SELECT id, name, department, hire_date FROM employees;
GRANT SELECT ON employees_public TO analysts;
REVOKE SELECT ON employees FROM analysts;
```

---

## 25.7 Encryption

### Passwords in the database

Never store plaintext passwords. Use `pgcrypto`:

```sql
CREATE EXTENSION pgcrypto;

-- Store hashed password
INSERT INTO users (email, password_hash)
VALUES ('alice@example.com', crypt('userpassword', gen_salt('bf', 12)));
-- bf = bcrypt, 12 = cost factor

-- Verify password
SELECT * FROM users
WHERE email = 'alice@example.com'
AND password_hash = crypt('inputpassword', password_hash);
```

### Encrypting sensitive columns

```sql
-- Symmetric encryption of PII
CREATE EXTENSION pgcrypto;

-- Store encrypted credit card number
INSERT INTO payment_methods (user_id, card_encrypted)
VALUES (42, pgp_sym_encrypt('4111111111111111', 'encryption_key'));

-- Decrypt for display (only in application layer)
SELECT pgp_sym_decrypt(card_encrypted, 'encryption_key') AS card
FROM payment_methods WHERE user_id = 42;
```

For production PII encryption: use application-layer encryption (encrypt before sending to DB) or a dedicated KMS (AWS KMS, HashiCorp Vault) — don't store the encryption key in the same database.

### Encryption at rest

- **Filesystem-level**: LUKS (Linux), dm-crypt — entire disk encrypted
- **Tablespace-level**: Put tablespace on encrypted volume
- **PostgreSQL TDE** (Transparent Data Encryption): Available in enterprise distributions (EDB)
- **Cloud-managed**: RDS, Cloud SQL, etc. provide encrypted storage by default

### Encryption in transit

Always use SSL/TLS for client connections (see Section 25.2). Verify certificate:

```bash
psql "host=db.example.com dbname=mydb sslmode=verify-full sslrootcert=ca.crt"
```

`sslmode=verify-full` prevents man-in-the-middle attacks.

---

## 25.8 SQL Injection Prevention

SQL injection is the most common database attack. Never concatenate user input into SQL:

```python
# ❌ NEVER do this
query = f"SELECT * FROM users WHERE email = '{user_input}'"
# user_input = "' OR '1'='1" → returns all users

# ✅ Always use parameterized queries
query = "SELECT * FROM users WHERE email = $1"
cursor.execute(query, [user_input])
```

In PostgreSQL functions:

```sql
-- ❌ Dynamic SQL injection risk
CREATE FUNCTION bad_search(search_term TEXT) RETURNS TABLE(...) AS $$
BEGIN
    RETURN QUERY EXECUTE 'SELECT * FROM products WHERE name = ' || search_term;
END;
$$ LANGUAGE plpgsql;

-- ✅ Parameterized
CREATE FUNCTION safe_search(search_term TEXT) RETURNS TABLE(...) AS $$
BEGIN
    RETURN QUERY EXECUTE 'SELECT * FROM products WHERE name = $1'
        USING search_term;
END;
$$ LANGUAGE plpgsql;
```

---

## 25.9 Auditing

Track who did what and when:

```sql
-- Add audit columns to every table
ALTER TABLE orders ADD COLUMN created_by BIGINT REFERENCES users(id);
ALTER TABLE orders ADD COLUMN updated_by BIGINT REFERENCES users(id);
ALTER TABLE orders ADD COLUMN created_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE orders ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();

-- Audit log table
CREATE TABLE audit_log (
    id          BIGSERIAL PRIMARY KEY,
    table_name  TEXT NOT NULL,
    row_id      BIGINT,
    operation   TEXT NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    old_values  JSONB,
    new_values  JSONB,
    changed_by  TEXT NOT NULL DEFAULT current_user,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Audit trigger
CREATE OR REPLACE FUNCTION audit_trigger_fn() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_log (table_name, row_id, operation, old_values, new_values)
    VALUES (
        TG_TABLE_NAME,
        COALESCE(NEW.id, OLD.id),
        TG_OP,
        CASE WHEN TG_OP != 'INSERT' THEN row_to_json(OLD) END,
        CASE WHEN TG_OP != 'DELETE' THEN row_to_json(NEW) END
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER orders_audit
    AFTER INSERT OR UPDATE OR DELETE ON orders
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();
```

For production auditing, use the `pgaudit` extension:
```ini
# postgresql.conf
shared_preload_libraries = 'pgaudit'
pgaudit.log = 'write, ddl'   # log all writes and schema changes
```

---

## 25.10 Security Checklist

- [ ] No `trust` authentication in `pg_hba.conf` for network connections
- [ ] All connections use `scram-sha-256` or certificate auth
- [ ] SSL/TLS enabled, `sslmode=verify-full` from clients
- [ ] No role with `SUPERUSER` used by the application
- [ ] Principle of least privilege applied — each service has its own role
- [ ] `ALTER DEFAULT PRIVILEGES` set for future tables
- [ ] RLS enabled on multi-tenant tables
- [ ] Sensitive columns (passwords) hashed with bcrypt
- [ ] PII encrypted at rest (application-layer or filesystem)
- [ ] All SQL uses parameterized queries
- [ ] Audit logging enabled for write operations
- [ ] `max_connections` and `CONNECTION LIMIT` configured
- [ ] Superuser remote access disabled in `pg_hba.conf`

---

## Key Terms

| Term | Meaning |
|------|---------|
| `pg_hba.conf` | Host-Based Authentication config — who can connect |
| `scram-sha-256` | Secure password authentication method |
| Role | A named identity in PostgreSQL (user or group) |
| Privilege | Permission to perform an operation on an object |
| RLS | Row-Level Security — restrict rows visible to each user |
| Least Privilege | Grant only the minimum permissions required |
| pgcrypto | Extension for cryptographic functions (hashing, encryption) |
| SQL Injection | Attack that inserts malicious SQL via user input |
| pgaudit | Extension for detailed SQL audit logging |

---

## Practice Questions

1. What is the difference between `md5` and `scram-sha-256` authentication?
2. Design roles for: an API server (reads + writes), a reporting tool (reads only), a DBA (everything).
3. You're building a multi-tenant SaaS. How does RLS enforce tenant isolation at the database layer?
4. Why is `ALTER DEFAULT PRIVILEGES` important when adding new tables?
5. A developer stored user passwords as plain MD5 hashes. What's the problem and how do you fix it?
6. What is SQL injection and how do parameterized queries prevent it?

---

**← Previous:** [24_cap_distributed.md](24_cap_distributed.md)  
**Next →** [26_advanced_schema_patterns.md](26_advanced_schema_patterns.md)
