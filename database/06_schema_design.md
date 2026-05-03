# Chapter 6 — Schema Design

Schema design is where theory meets practice. A well-designed schema is easy to query, maintains data integrity, and survives real-world growth. A bad one becomes a maintenance nightmare within months.

---

## 6.1 Naming Conventions

Consistency is more important than which convention you choose. Pick one and stick to it.

### Tables
```sql
-- ✅ snake_case, plural nouns (most common in PostgreSQL)
CREATE TABLE employees (...);
CREATE TABLE order_items (...);

-- ❌ Mixed, inconsistent
CREATE TABLE Employee (...);
CREATE TABLE tblOrders (...);
```

### Columns
```sql
-- ✅ snake_case, descriptive
employee_id, first_name, created_at, is_active

-- ❌ Ambiguous or cryptic
emp, fname, ts, flag
```

### Primary Keys
Two common schools of thought:
```sql
-- Option A: id (simple, most common in Rails/Django style)
id SERIAL PRIMARY KEY

-- Option B: table_name_id (explicit, self-documenting)
employee_id SERIAL PRIMARY KEY
```

Option B is better for large systems — when you write `SELECT e.employee_id, e.name` you always know which table `employee_id` belongs to.

### Foreign Keys
Always match the column name of the referenced PK:
```sql
-- If PK is employee_id in employees table:
manager_id  INT REFERENCES employees(employee_id)
-- or if it's a direct reference:
employee_id INT REFERENCES employees(employee_id)
```

### Booleans
Prefix with `is_` or `has_`:
```sql
is_active, is_verified, has_subscription, is_deleted
```

### Timestamps
```sql
created_at   TIMESTAMPTZ   -- when the row was inserted
updated_at   TIMESTAMPTZ   -- when the row was last modified
deleted_at   TIMESTAMPTZ   -- NULL if not deleted (soft delete)
```

---

## 6.2 Choosing the Right Data Types

Using the right data type:
- Saves storage
- Prevents invalid data
- Improves query performance (indexes work better on correct types)

### Numeric Types

| Type | Storage | Range | Use when |
|------|---------|-------|----------|
| `SMALLINT` | 2 bytes | -32768 to 32767 | Status codes, small counts |
| `INT` / `INTEGER` | 4 bytes | ~±2 billion | IDs (small tables), counts |
| `BIGINT` | 8 bytes | ~±9 quintillion | IDs (large tables), timestamps as int |
| `NUMERIC(p,s)` | Variable | Exact | Money, financial data — never use FLOAT |
| `REAL` | 4 bytes | ~6 sig digits | Scientific, approximations OK |
| `DOUBLE PRECISION` | 8 bytes | ~15 sig digits | Scientific, approximations OK |

```sql
-- ✅ Correct for money
price NUMERIC(12, 2)  -- 12 total digits, 2 decimal places

-- ❌ Never use for money — floating point imprecision
price FLOAT
```

### Text Types

| Type | Use when |
|------|----------|
| `VARCHAR(n)` | Known max length (name, code, status) |
| `TEXT` | Unlimited text (descriptions, content) |
| `CHAR(n)` | Fixed-length codes (country codes, status codes) |

In PostgreSQL, `TEXT` and `VARCHAR` have identical performance. Use `TEXT` for variable content, `VARCHAR(n)` when you want to enforce a max length.

### Date/Time Types

| Type | Storage | Use when |
|------|---------|----------|
| `DATE` | 4 bytes | Date only (birthdate, event date) |
| `TIME` | 8 bytes | Time only (no date) |
| `TIMESTAMP` | 8 bytes | Date+time, no timezone |
| `TIMESTAMPTZ` | 8 bytes | Date+time with timezone (recommended) |
| `INTERVAL` | 16 bytes | Durations (2 hours, 3 days) |

**Always use `TIMESTAMPTZ`** for `created_at`/`updated_at` — it stores UTC and converts on display.

### Other Important Types

```sql
UUID          -- universally unique ID, great for distributed systems
BOOLEAN       -- TRUE/FALSE/NULL
JSONB         -- binary JSON, indexable (use over JSON)
ARRAY         -- array of any type (use sparingly)
ENUM          -- fixed set of values
INET / CIDR   -- IP addresses
```

---

## 6.3 Standard Columns Every Table Should Have

```sql
CREATE TABLE any_table (
    -- identity
    id          BIGSERIAL PRIMARY KEY,

    -- audit trail
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- soft delete (optional but useful)
    deleted_at  TIMESTAMPTZ
);
```

This gives you:
- A stable, system-generated PK
- An automatic audit trail
- The ability to recover "deleted" rows

---

## 6.4 Constraints — Your First Line of Defense

Don't trust the application to enforce data rules. Put rules in the database.

```sql
CREATE TABLE products (
    product_id  BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL CHECK (length(name) > 0),
    price       NUMERIC(12,2) NOT NULL CHECK (price >= 0),
    stock       INT NOT NULL DEFAULT 0 CHECK (stock >= 0),
    status      TEXT NOT NULL CHECK (status IN ('active', 'inactive', 'discontinued')),
    sku         TEXT NOT NULL UNIQUE,
    category_id INT NOT NULL REFERENCES categories(category_id)
);
```

Every column should have:
- The right data type
- `NOT NULL` unless NULL is genuinely meaningful
- A `CHECK` constraint for business rules
- A `UNIQUE` constraint if the value must be unique across all rows

---

## 6.5 Using ENUMs for Status Fields

```sql
-- Option A: ENUM type
CREATE TYPE order_status AS ENUM ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled');

CREATE TABLE orders (
    ...
    status order_status NOT NULL DEFAULT 'pending'
);
```

```sql
-- Option B: CHECK constraint on TEXT (more flexible)
CREATE TABLE orders (
    ...
    status TEXT NOT NULL DEFAULT 'pending'
           CHECK (status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled'))
);
```

**ENUM**: Faster, less storage, but hard to alter (adding a value requires `ALTER TYPE`).  
**CHECK on TEXT**: Easier to change, slightly more storage.

For stable, rarely-changing statuses → ENUM. For evolving lists → CHECK on TEXT or a lookup table.

---

## 6.6 Lookup / Reference Tables

For values that change over time, use a lookup table instead of CHECK constraints or ENUMs.

```sql
-- Instead of CHECK (country IN ('US', 'UK', 'DE', ...))
CREATE TABLE countries (
    code  CHAR(2)  PRIMARY KEY,  -- 'US', 'UK', 'DE'
    name  TEXT     NOT NULL
);

CREATE TABLE customers (
    ...
    country_code CHAR(2) REFERENCES countries(code)
);
```

Adding a new country = INSERT one row. No schema change needed.

---

## 6.7 Soft Deletes

Instead of `DELETE`, mark a row as deleted:

```sql
-- Soft delete
UPDATE employees SET deleted_at = NOW() WHERE employee_id = 42;

-- Query only active records
SELECT * FROM employees WHERE deleted_at IS NULL;
```

**Advantages**:
- Recover accidentally deleted records
- Maintain referential integrity
- Audit trail of when something was "deleted"

**Disadvantage**: All queries must filter `WHERE deleted_at IS NULL`. Easy to forget.

**Solution**: Use a view or row-level security to hide deleted rows automatically.

```sql
CREATE VIEW active_employees AS
    SELECT * FROM employees WHERE deleted_at IS NULL;
```

---

## 6.8 Schema Namespacing

PostgreSQL supports **schemas** (namespaces within a database):

```sql
CREATE SCHEMA billing;
CREATE SCHEMA inventory;
CREATE SCHEMA auth;

CREATE TABLE billing.invoices (...);
CREATE TABLE inventory.products (...);
CREATE TABLE auth.users (...);
```

Benefits:
- Organize tables by domain/module
- Apply different permissions per schema
- Avoid table name collisions across teams

Default schema is `public`. For production, use named schemas per domain.

---

## 6.9 Common Schema Patterns

### Audit Table
```sql
CREATE TABLE employee_audit (
    audit_id     BIGSERIAL PRIMARY KEY,
    employee_id  BIGINT NOT NULL,
    changed_by   BIGINT REFERENCES users(id),
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    operation    TEXT NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    old_values   JSONB,
    new_values   JSONB
);
```

### Translation Table (i18n)
```sql
CREATE TABLE products (product_id BIGSERIAL PRIMARY KEY, price NUMERIC);
CREATE TABLE product_translations (
    product_id  BIGINT REFERENCES products(product_id),
    language    CHAR(2),
    name        TEXT NOT NULL,
    description TEXT,
    PRIMARY KEY (product_id, language)
);
```

### Hierarchical Data (Adjacency List)
```sql
CREATE TABLE categories (
    category_id  BIGSERIAL PRIMARY KEY,
    name         TEXT NOT NULL,
    parent_id    BIGINT REFERENCES categories(category_id)  -- NULL = root
);
```

---

## 6.10 Schema Design Checklist

Before finalizing any table, ask:

- [ ] Does every column have the right data type?
- [ ] Is every column `NOT NULL` unless NULL is genuinely meaningful?
- [ ] Does every table have a surrogate PK?
- [ ] Are all natural keys covered by `UNIQUE` constraints?
- [ ] Are all foreign keys declared?
- [ ] Are business rules enforced with `CHECK` constraints?
- [ ] Do you have `created_at` and `updated_at` on every table?
- [ ] Are status fields using ENUM, CHECK, or a lookup table?
- [ ] Is the schema in at least 3NF?
- [ ] Are table and column names consistent and descriptive?

---

## Key Terms

| Term | Meaning |
|------|---------|
| Schema | Namespace + set of tables in a database |
| Constraint | A rule enforced by the database engine |
| Soft Delete | Marking rows inactive instead of removing them |
| Lookup Table | A reference table for valid values |
| Audit Trail | A record of all changes to data |
| ENUM | A column type restricted to a fixed set of values |
| TIMESTAMPTZ | Timestamp with timezone — stores UTC internally |

---

## Practice Questions

1. Why should you use `NUMERIC` instead of `FLOAT` for financial data?
2. Design a schema for a hotel booking system: rooms, guests, bookings, room types.
3. What is the difference between `TIMESTAMP` and `TIMESTAMPTZ`?
4. A column `status` can be 'draft', 'published', or 'archived'. What are the three ways to enforce this, and what are the tradeoffs?
5. Why is `deleted_at TIMESTAMPTZ` better than a `is_deleted BOOLEAN` for soft deletes?
6. When would you use a PostgreSQL schema (namespace) vs a separate database?

---

**← Previous:** [05_normalization.md](05_normalization.md)  
**Next →** [07_storage_engine.md](07_storage_engine.md) *(Module 2 — Core Internals)*
