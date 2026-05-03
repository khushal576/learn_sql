# Chapter 36 — Compliance & Advanced Security

Security at the Senior DBA level goes beyond GRANT/REVOKE. This chapter covers RBAC role hierarchies, dynamic data masking, envelope encryption with key rotation, Transparent Data Encryption, GDPR right-to-erasure patterns, and SOC 2 / PCI DSS controls.

---

## 36.1 RBAC Role Hierarchy Design

PostgreSQL roles are hierarchical — roles can inherit other roles. A well-designed hierarchy reduces security surface and simplifies auditing.

```sql
-- Pattern: functional roles (no login) + persona roles (login)

-- Tier 1: privilege sets (no login)
CREATE ROLE priv_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO priv_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO priv_readonly;

CREATE ROLE priv_readwrite;
GRANT priv_readonly TO priv_readwrite;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO priv_readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT INSERT, UPDATE, DELETE ON TABLES TO priv_readwrite;

CREATE ROLE priv_admin;
GRANT priv_readwrite TO priv_admin;
GRANT TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public TO priv_admin;

-- Tier 2: service accounts (login, inherit privileges)
CREATE ROLE svc_api WITH LOGIN INHERIT PASSWORD 'secret';
GRANT priv_readwrite TO svc_api;

CREATE ROLE svc_reporting WITH LOGIN INHERIT PASSWORD 'secret';
GRANT priv_readonly TO svc_reporting;

-- Tier 3: human accounts (login, NOINHERIT — must SET ROLE explicitly)
CREATE ROLE dba_alice WITH LOGIN NOINHERIT PASSWORD 'secret';
GRANT priv_admin TO dba_alice;

-- Alice must explicitly activate her admin role:
SET ROLE priv_admin;
-- Provides audit trail: login as alice, then privilege escalation is explicit
```

```sql
-- Audit who has which privileges
SELECT grantee, privilege_type, table_name
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
ORDER BY grantee, table_name;

-- Role membership tree
WITH RECURSIVE role_tree AS (
    SELECT rolname, oid FROM pg_roles WHERE rolname = 'svc_api'
    UNION ALL
    SELECT r.rolname, r.oid
    FROM pg_roles r
    JOIN pg_auth_members m ON r.oid = m.roleid
    JOIN role_tree rt ON m.member = rt.oid
)
SELECT rolname FROM role_tree;
```

---

## 36.2 Dynamic Data Masking

Dynamic masking returns redacted data to unprivileged roles without storing masked copies.

### Approach 1: Views as masking layer

```sql
-- Sensitive base table (DBA access only)
CREATE TABLE customers_raw (
    id         BIGSERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    email      TEXT NOT NULL,
    ssn        TEXT,
    dob        DATE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

REVOKE ALL ON customers_raw FROM PUBLIC;
GRANT SELECT ON customers_raw TO priv_admin;

-- Masked view for application use
CREATE VIEW customers AS
SELECT
    id,
    name,
    -- Mask middle of email: j***@example.com
    LEFT(email, 1) || '***@' || SPLIT_PART(email, '@', 2) AS email,
    -- Mask SSN: show last 4 only
    '***-**-' || RIGHT(ssn, 4) AS ssn,
    -- Mask DOB: show year only
    DATE_TRUNC('year', dob)::date AS dob,
    created_at
FROM customers_raw;

GRANT SELECT ON customers TO priv_readonly;
-- Applications see the view; only DBAs see the raw table
```

### Approach 2: Row-level masking with current_user

```sql
-- Return full data to admin, masked data to others
CREATE VIEW customers_masked AS
SELECT
    id,
    name,
    CASE
        WHEN current_user IN (SELECT rolname FROM pg_roles WHERE rolname = 'priv_admin'
                              AND pg_has_role(current_user, rolname, 'member'))
        THEN email
        ELSE LEFT(email, 1) || '***@' || SPLIT_PART(email, '@', 2)
    END AS email,
    ssn
FROM customers_raw;
```

### Approach 3: anon extension

```sql
-- PostgreSQL Anonymizer extension
CREATE EXTENSION anon;
SELECT anon.init();

-- Declare masking rules as column comments
SECURITY LABEL FOR anon ON COLUMN customers_raw.email
    IS 'MASKED WITH FUNCTION anon.partial_email(email)';

SECURITY LABEL FOR anon ON COLUMN customers_raw.ssn
    IS 'MASKED WITH VALUE ''***-**-0000''';

-- Create a masked role
CREATE ROLE masked_user LOGIN;
SECURITY LABEL FOR anon ON ROLE masked_user IS 'MASKED';
-- masked_user automatically sees masked values
```

---

## 36.3 Envelope Encryption & Key Rotation

PostgreSQL `pgcrypto` handles column-level encryption. Envelope encryption adds a key hierarchy so rotating the master key doesn't re-encrypt all data.

```
Data Encryption Key (DEK) — unique per record, encrypts the actual data
Key Encryption Key (KEK) — master key, stored in Vault/KMS, encrypts DEKs
```

```sql
-- Schema: store encrypted data + encrypted DEK per row
CREATE TABLE sensitive_records (
    id           BIGSERIAL PRIMARY KEY,
    encrypted_dek BYTEA NOT NULL,   -- DEK encrypted with KEK
    encrypted_data BYTEA NOT NULL,  -- actual data encrypted with DEK
    kek_version  INT NOT NULL DEFAULT 1,  -- which KEK version was used
    created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- Write path (application logic pseudocode):
-- 1. Generate random DEK: dek = random_bytes(32)
-- 2. Encrypt data: encrypted_data = AES256_encrypt(plaintext, dek)
-- 3. Encrypt DEK with KEK from Vault: encrypted_dek = vault.encrypt(dek, kek_id)
-- 4. Store (encrypted_dek, encrypted_data, kek_version)

-- Read path:
-- 1. Fetch row from DB
-- 2. Decrypt DEK: dek = vault.decrypt(encrypted_dek, kek_version)
-- 3. Decrypt data: plaintext = AES256_decrypt(encrypted_data, dek)
```

```sql
-- Column encryption with pgcrypto (simpler, single key)
-- Store PGP-encrypted credit card numbers
INSERT INTO payment_methods (user_id, encrypted_card)
VALUES (42, pgp_sym_encrypt('4111111111111111', current_setting('app.encryption_key')));

-- Decrypt (application must provide the key)
SELECT pgp_sym_decrypt(encrypted_card, current_setting('app.encryption_key'))
FROM payment_methods WHERE user_id = 42;
```

### Key rotation procedure

```sql
-- When rotating KEK:
-- 1. Generate new KEK in Vault (kek_version = 2)
-- 2. Re-encrypt DEKs in batches (no data re-encryption needed)

WITH batch AS (
    SELECT id, encrypted_dek FROM sensitive_records
    WHERE kek_version = 1
    LIMIT 1000
)
-- Application re-encrypts each DEK with new KEK, then updates:
UPDATE sensitive_records
SET encrypted_dek = $new_encrypted_dek,
    kek_version = 2
WHERE id = $id;
```

---

## 36.4 Transparent Data Encryption (TDE)

TDE encrypts data at rest — files on disk are encrypted even if someone steals the storage.

PostgreSQL does **not** have native TDE (as of PG 16). Options:

| Option | Level | Notes |
|--------|-------|-------|
| OS-level encryption (LUKS/dm-crypt) | Disk | Transparent, no PostgreSQL config |
| AWS EBS encryption / GCP disk encryption | Cloud disk | Managed, key in KMS |
| pgcrypto | Column | Application must encrypt/decrypt |
| **EDB TDE** (enterprise) | Cluster | Full TDE, key management integration |
| **pg_tde** extension (community, PG 17+) | Cluster | Emerging OSS alternative |

```bash
# LUKS disk encryption (Linux) — encrypt the data directory partition
cryptsetup luksFormat /dev/sdb
cryptsetup luksOpen /dev/sdb pg_data_encrypted
mkfs.ext4 /dev/mapper/pg_data_encrypted
mount /dev/mapper/pg_data_encrypted /var/lib/postgresql/data

# PostgreSQL runs normally; encryption is at the block device layer
# Files unreadable without the LUKS key
```

---

## 36.5 GDPR Right to Erasure

GDPR "right to be forgotten" — a user requests deletion of all their personal data. In a database with FK constraints, audit logs, and replicas, this is complex.

### Strategy 1: Hard delete

```sql
-- Delete from all related tables in dependency order
BEGIN;

DELETE FROM order_items   WHERE order_id IN (SELECT id FROM orders WHERE customer_id = $1);
DELETE FROM orders        WHERE customer_id = $1;
DELETE FROM addresses     WHERE customer_id = $1;
DELETE FROM customers     WHERE id = $1;

-- Audit log of the erasure (log the act, not the data)
INSERT INTO erasure_log (customer_id, requested_at, completed_at)
VALUES ($1, NOW(), NOW());

COMMIT;

-- Problem: audit_log table may contain PII in JSON payloads
-- Solution: scrub PII from audit logs, not delete the record
UPDATE audit_log
SET payload = jsonb_set(payload, '{customer_email}', '"[ERASED]"')
WHERE payload->>'customer_id' = $1::text;
```

### Strategy 2: Pseudonymization (preserve analytics, erase PII)

```sql
-- Replace PII with a pseudonym; keep the record for analytics
UPDATE customers
SET
    name  = 'DELETED_USER_' || id,
    email = 'deleted_' || id || '@example.invalid',
    phone = NULL,
    dob   = NULL,
    deleted_at = NOW()
WHERE id = $1;

-- Benefits: FK references still work, order history preserved for tax/legal
-- Downside: not full erasure — identity could theoretically be re-linked
```

### Strategy 3: Encryption-based erasure

```sql
-- Encrypt all PII per-user with a user-specific DEK stored in Vault
-- To "erase": delete the DEK from Vault
-- Result: data still exists in DB but is cryptographically inaccessible

-- Practical for systems where data has legal retention requirements
-- (you can't delete the row but you can make it unreadable)
```

---

## 36.6 Audit Logging with pgaudit

`pgaudit` provides detailed audit logging that satisfies SOC 2 and PCI DSS requirements.

```ini
# postgresql.conf
shared_preload_libraries = 'pgaudit'

# Audit all DDL and DML on all objects
pgaudit.log = 'ddl, write'

# Audit all reads on specific tables (via role)
pgaudit.log = 'read'
pgaudit.log_catalog = off         # Don't audit pg_catalog queries
pgaudit.log_parameter = on        # Include bind parameters in log
pgaudit.log_relation = on         # Log each relation separately
```

```sql
-- Object-level auditing: audit reads on the customers table only
CREATE ROLE audit_read_customers;
GRANT SELECT ON customers TO audit_read_customers;

-- In postgresql.conf:
-- pgaudit.role = 'audit_read_customers'
-- Any SELECT on customers is logged, regardless of which role does it

-- Sample audit log output:
-- AUDIT: OBJECT,1,1,READ,SELECT,TABLE,public.customers,
--        SELECT * FROM customers WHERE id = 42,[not logged]
```

---

## 36.7 SOC 2 / PCI DSS Database Controls

### SOC 2 Type II database requirements

| Control | Implementation |
|---------|---------------|
| Access control | Role-based, least privilege, NOINHERIT for admins |
| Authentication | scram-sha-256, password rotation, MFA for console |
| Audit logging | pgaudit DDL + write + read for sensitive tables |
| Encryption in transit | SSL/TLS required (`sslmode=verify-full`) |
| Encryption at rest | LUKS/cloud disk encryption |
| Change management | All DDL through CI/CD pipeline, peer-reviewed |
| Monitoring | Alerting on auth failures, privilege escalation |
| Backup & recovery | Automated backups, PITR tested quarterly |

### PCI DSS (cardholder data environment)

```sql
-- PCI requirement: no PANs (card numbers) in plaintext
-- Audit: find any column that might contain card numbers
SELECT table_schema, table_name, column_name
FROM information_schema.columns
WHERE column_name ILIKE ANY (ARRAY['%card%', '%pan%', '%cc_%', '%credit%'])
  AND table_schema NOT IN ('pg_catalog', 'information_schema');

-- PCI requirement: log all access to cardholder data
-- Use pgaudit object-level auditing on payment_methods table

-- PCI requirement: quarterly access review
SELECT grantee, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE table_name IN ('payment_methods', 'card_tokens')
ORDER BY grantee;
```

---

## 36.8 mTLS for Database Connections

Mutual TLS ensures both client and server authenticate via certificates.

```ini
# postgresql.conf
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file  = 'server.key'
ssl_ca_file   = 'root.crt'    # CA that signed client certs

# pg_hba.conf: require client certificate
hostssl mydb svc_api 10.0.0.0/8 cert clientcert=verify-full
```

```bash
# Generate client certificate
openssl genrsa -out client.key 4096
openssl req -new -key client.key -out client.csr -subj "/CN=svc_api"
openssl x509 -req -in client.csr -CA root.crt -CAkey root.key -out client.crt

# Connection string with client cert
psql "host=db.example.com dbname=mydb user=svc_api \
      sslcert=client.crt sslkey=client.key \
      sslrootcert=root.crt sslmode=verify-full"
```

---

## 36.9 Secrets Management

Never store database passwords in application config files.

```bash
# AWS Secrets Manager rotation
aws secretsmanager create-secret \
    --name prod/mydb/svc_api \
    --secret-string '{"username":"svc_api","password":"...","host":"db.example.com"}'

# Application retrieves secret at startup:
aws secretsmanager get-secret-value --secret-id prod/mydb/svc_api

# HashiCorp Vault dynamic credentials (most secure)
vault write database/roles/svc_api \
    db_name=mydb \
    creation_statements="CREATE ROLE {{name}} WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT priv_readwrite TO {{name}};" \
    default_ttl=1h \
    max_ttl=24h

# Each app request gets a unique, time-limited database credential
vault read database/creds/svc_api
# Key     Value
# lease_id      database/creds/svc_api/xyz
# username      v-svc_api-abc123
# password      A1b2C3d4...
```

---

## Key Terms

| Term | Meaning |
|------|---------|
| NOINHERIT | Role attribute requiring explicit SET ROLE to activate inherited privileges |
| Data Encryption Key (DEK) | Per-record key that encrypts actual data |
| Key Encryption Key (KEK) | Master key stored in Vault/KMS that encrypts DEKs |
| Envelope encryption | Two-tier key hierarchy: DEK encrypts data, KEK encrypts DEK |
| TDE | Transparent Data Encryption — encryption at the storage/file level |
| Pseudonymization | Replace PII with reversible pseudonyms (weaker than erasure) |
| pgaudit | Extension providing object-level SQL audit logging |
| mTLS | Mutual TLS — both client and server authenticate via certificates |
| Dynamic credentials | Short-lived, auto-rotating DB credentials via Vault |

---

## Practice Questions

1. Design a 3-tier RBAC hierarchy for a SaaS application with read-only analytics users, read-write API service accounts, and DBAs who should explicitly activate their privileges.
2. A GDPR erasure request arrives for customer ID 42. The customer has orders, addresses, and entries in an audit log. Walk through the erasure strategy.
3. What is envelope encryption and why is it preferred over encrypting data directly with the master key?
4. You need to satisfy PCI DSS for a payments table. List five specific controls you would implement in PostgreSQL.
5. What is the difference between column-level encryption with pgcrypto and TDE at the OS level? When is each appropriate?
6. A developer wants to store the database password in a `.env` file on the production server. What is the correct alternative and how does it work?

---

**← Previous:** [35_observability_engineering.md](35_observability_engineering.md)  
**Next →** [37_extension_ecosystem.md](37_extension_ecosystem.md)
