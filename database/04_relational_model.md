# Chapter 4 — The Relational Model & Keys

The relational model is the mathematical foundation behind every SQL database. Understanding it deeply makes everything else — joins, constraints, normalization — make intuitive sense.

---

## 4.1 Relations, Tuples, and Attributes

The formal terminology:

| Formal Term | SQL Term | Meaning |
|-------------|----------|---------|
| Relation | Table | A set of rows |
| Tuple | Row / Record | One data item |
| Attribute | Column / Field | A property |
| Domain | Data type | Valid values for a column |
| Degree | — | Number of columns in a table |
| Cardinality | — | Number of rows in a table |

A **relation** is a set — meaning:
- No duplicate rows allowed
- Order of rows doesn't matter
- Order of columns doesn't matter (you reference by name, not position)

---

## 4.2 Properties of a Valid Relation

1. Every cell contains exactly one atomic value (no lists, no arrays)
2. All values in a column are from the same domain (same data type)
3. Each column has a unique name
4. No two rows are identical
5. Row order is irrelevant
6. Column order is irrelevant

Rule 1 is the foundation of **First Normal Form** (covered in Chapter 5).

---

## 4.3 Keys — The Most Important Concept in Relational Databases

A **key** is an attribute (or set of attributes) that uniquely identifies a row.

### Super Key
Any set of attributes that uniquely identifies a row.

Table: `employees(id, email, name, phone)`

Super keys:
- `{id}` — unique
- `{email}` — unique
- `{id, name}` — unique (because id alone is already unique)
- `{id, email, name, phone}` — unique (all columns together)

A super key can include redundant attributes.

---

### Candidate Key
A **minimal** super key — no attribute can be removed without losing uniqueness.

From the example:
- `{id}` ✅ candidate key
- `{email}` ✅ candidate key
- `{id, name}` ❌ not minimal — `{id}` alone already works

A table can have **multiple candidate keys**.

---

### Primary Key (PK)
The **chosen** candidate key — the one the designer picks as the official identifier.

Rules:
- Must be **unique** — no two rows can have the same PK value
- Must be **NOT NULL** — a PK can never be empty
- Should be **immutable** — ideally never changes

```sql
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,   -- chosen PK
    email        TEXT   UNIQUE,        -- another candidate key
    name         TEXT   NOT NULL
);
```

---

### Surrogate vs Natural Key

| Type | Description | Example | Pros / Cons |
|------|-------------|---------|-------------|
| **Surrogate** | System-generated, no business meaning | `id SERIAL`, `UUID` | Stable, never changes; meaningless |
| **Natural** | Has business meaning | `email`, `SSN`, `ISBN` | Meaningful but can change |

**Best practice**: Use surrogate keys (serial/UUID) as PK, add UNIQUE constraints on natural keys.

```sql
-- Good
CREATE TABLE users (
    id     SERIAL PRIMARY KEY,
    email  TEXT NOT NULL UNIQUE  -- natural key kept as unique constraint
);
```

---

### Foreign Key (FK)
A **foreign key** is a column that references the primary key of another table. It enforces a **referential integrity** constraint.

```sql
CREATE TABLE departments (
    dept_id  SERIAL PRIMARY KEY,
    name     TEXT NOT NULL
);

CREATE TABLE employees (
    emp_id   SERIAL PRIMARY KEY,
    name     TEXT NOT NULL,
    dept_id  INT REFERENCES departments(dept_id)  -- FK
);
```

Rules enforced by FK:
- You cannot insert an employee with a `dept_id` that doesn't exist in `departments`
- You cannot delete a department if employees reference it (unless you configure cascade)

---

### Composite Key
A primary key made of **two or more columns** together.

Most common in junction tables:

```sql
CREATE TABLE order_items (
    order_id    INT REFERENCES orders(order_id),
    product_id  INT REFERENCES products(product_id),
    quantity    INT NOT NULL,
    PRIMARY KEY (order_id, product_id)   -- composite PK
);
```

Neither `order_id` nor `product_id` alone is unique — but the combination is.

---

### Alternate Key
A candidate key that was **not chosen** as the primary key. Enforced with a UNIQUE constraint.

```sql
-- email is an alternate key
email TEXT NOT NULL UNIQUE
```

---

## 4.4 Key Summary Table

| Key Type | Definition |
|----------|-----------|
| Super key | Any set of attributes that uniquely identifies a row |
| Candidate key | Minimal super key |
| Primary key | The chosen candidate key (NOT NULL + UNIQUE) |
| Foreign key | References a PK in another table |
| Composite key | PK made of multiple columns |
| Alternate key | Candidate key not chosen as PK (UNIQUE constraint) |
| Surrogate key | System-generated PK with no business meaning |
| Natural key | PK with real-world business meaning |

---

## 4.5 Referential Integrity & ON DELETE / ON UPDATE

When a referenced row is deleted or updated, what happens to rows that reference it?

```sql
dept_id INT REFERENCES departments(dept_id)
    ON DELETE CASCADE
    ON UPDATE CASCADE
```

| Action | Behavior |
|--------|---------|
| `RESTRICT` (default) | Block the delete/update if references exist |
| `CASCADE` | Delete/update the referencing rows automatically |
| `SET NULL` | Set the FK column to NULL |
| `SET DEFAULT` | Set the FK column to its default value |
| `NO ACTION` | Like RESTRICT but checked at end of transaction |

**Which to use?**
- `CASCADE` for owned/child data (delete order → delete order_items)
- `RESTRICT` for important references (don't accidentally delete a department)
- `SET NULL` for optional references (employee's manager leaves, set `manager_id` to NULL)

---

## 4.6 Constraints — Enforcing Data Integrity

Keys are just one type of constraint. PostgreSQL supports:

| Constraint | SQL | What it enforces |
|------------|-----|-----------------|
| PRIMARY KEY | `PRIMARY KEY` | Unique + NOT NULL |
| FOREIGN KEY | `REFERENCES` | Referential integrity |
| UNIQUE | `UNIQUE` | No duplicates in column |
| NOT NULL | `NOT NULL` | Column can't be empty |
| CHECK | `CHECK (condition)` | Custom rule |
| DEFAULT | `DEFAULT value` | Value if none provided |
| EXCLUSION | `EXCLUDE USING` | No overlapping ranges (PostgreSQL-specific) |

```sql
CREATE TABLE products (
    product_id  SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    price       NUMERIC(10,2) CHECK (price > 0),
    stock       INT DEFAULT 0 CHECK (stock >= 0),
    sku         TEXT UNIQUE
);
```

---

## 4.7 Indexes vs Keys

These are often confused:

| | Key | Index |
|-|-----|-------|
| Purpose | Enforce uniqueness / identity | Speed up queries |
| Created automatically? | PK and UNIQUE create an index | Must be created manually (non-unique) |
| Stored in table? | Logical concept | Physical structure on disk |

When you define a PRIMARY KEY or UNIQUE constraint, PostgreSQL **automatically creates a B-tree index** for it. This is why PK lookups are fast.

---

## 4.8 NULL — The Billion-Dollar Mistake

`NULL` means "unknown" or "not applicable" — it is **not** zero, not empty string, not false.

Critical rules about NULL:
- `NULL = NULL` → **NULL** (not TRUE — use `IS NULL` instead)
- `NULL <> NULL` → **NULL**
- Any arithmetic with NULL → **NULL**
- A PK column can never be NULL
- COUNT(*) counts NULLs; COUNT(column) does not

```sql
-- Wrong
SELECT * FROM employees WHERE manager_id = NULL;

-- Correct
SELECT * FROM employees WHERE manager_id IS NULL;
```

This "three-valued logic" (TRUE/FALSE/NULL) catches many beginners.

---

## Key Terms

| Term | Meaning |
|------|---------|
| Relation | A table — a set of tuples |
| Tuple | A row |
| Domain | Valid values for a column (data type) |
| Referential Integrity | FK values must exist in the referenced table |
| Three-Valued Logic | SQL has TRUE, FALSE, and UNKNOWN (NULL) |
| Constraint | A rule the database enforces on data |

---

## Practice Questions

1. What is the difference between a super key and a candidate key?
2. A table `flights` has columns `flight_id`, `flight_number`, `departure_date`. Which could be candidate keys?
3. When should you use `ON DELETE CASCADE` vs `ON DELETE RESTRICT`?
4. Why can't a primary key be NULL?
5. What does `SELECT * FROM orders WHERE discount = NULL` return? How do you fix it?
6. You have a `student_courses` junction table. Design its primary key.

---

**← Previous:** [03_er_diagrams.md](03_er_diagrams.md)  
**Next →** [05_normalization.md](05_normalization.md)
