# Chapter 26 — Advanced Schema Patterns

Beyond basic normalization, real-world schemas require patterns to handle polymorphism, versioning, hierarchies, and audit trails. This chapter covers the patterns you'll encounter in every mature codebase.

---

## 26.1 Soft Deletes (Revisited and Extended)

Mark rows as deleted instead of removing them:

```sql
ALTER TABLE orders ADD COLUMN deleted_at TIMESTAMPTZ;

-- "Delete"
UPDATE orders SET deleted_at = NOW() WHERE order_id = 42;

-- Query active rows
SELECT * FROM orders WHERE deleted_at IS NULL;

-- Query including deleted
SELECT * FROM orders;  -- includes deleted rows

-- Restore a deleted row
UPDATE orders SET deleted_at = NULL WHERE order_id = 42;
```

### Make it transparent with a view

```sql
CREATE VIEW active_orders AS
    SELECT * FROM orders WHERE deleted_at IS NULL;

-- App always queries the view
SELECT * FROM active_orders WHERE customer_id = 5;
```

### Soft delete with partial unique index

```sql
-- Unique email among active users only
CREATE UNIQUE INDEX idx_users_email_active
    ON users (email)
    WHERE deleted_at IS NULL;
-- Deleted users don't block re-registration with same email
```

### `deleted_at` vs `is_deleted`

| | `deleted_at TIMESTAMPTZ` | `is_deleted BOOLEAN` |
|-|--------------------------|----------------------|
| When deleted | ✅ Recorded | ❌ Not recorded |
| Index selectivity | ✅ (NULL = active = selective) | ❌ (50/50 split = poor) |
| Restore window | ✅ Can expire after N days | ❌ No time info |

Always use `deleted_at` over `is_deleted`.

---

## 26.2 Audit Tables

Track every change to a table with full history:

```sql
CREATE TABLE orders_history (
    history_id  BIGSERIAL PRIMARY KEY,
    order_id    BIGINT NOT NULL,
    operation   TEXT NOT NULL,          -- INSERT, UPDATE, DELETE
    changed_by  TEXT NOT NULL DEFAULT current_user,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    old_data    JSONB,
    new_data    JSONB
);

CREATE OR REPLACE FUNCTION orders_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO orders_history (order_id, operation, old_data, new_data)
    VALUES (
        COALESCE(NEW.order_id, OLD.order_id),
        TG_OP,
        CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE row_to_json(OLD)::JSONB END,
        CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE row_to_json(NEW)::JSONB END
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER orders_audit_trigger
    AFTER INSERT OR UPDATE OR DELETE ON orders
    FOR EACH ROW EXECUTE FUNCTION orders_audit();
```

### Querying audit history

```sql
-- What changed for order 42?
SELECT changed_at, operation, changed_by,
       old_data->>'status' AS old_status,
       new_data->>'status' AS new_status
FROM orders_history
WHERE order_id = 42
ORDER BY changed_at;

-- Reconstruct state at a point in time
SELECT new_data FROM orders_history
WHERE order_id = 42 AND changed_at <= '2024-06-01 12:00:00'
ORDER BY changed_at DESC
LIMIT 1;
```

---

## 26.3 Temporal Tables (Versioned Rows)

Track the full history of every row's state over time — not just audit of changes, but queryable history:

```sql
CREATE TABLE prices (
    product_id   BIGINT NOT NULL,
    price        NUMERIC(12,2) NOT NULL,
    valid_from   TIMESTAMPTZ NOT NULL,
    valid_to     TIMESTAMPTZ,            -- NULL = currently active
    PRIMARY KEY (product_id, valid_from)
);

-- Current prices
SELECT * FROM prices WHERE valid_to IS NULL;

-- Price as of a specific date
SELECT * FROM prices
WHERE product_id = 42
  AND valid_from <= '2024-06-01'
  AND (valid_to IS NULL OR valid_to > '2024-06-01');

-- Full price history for a product
SELECT * FROM prices WHERE product_id = 42 ORDER BY valid_from;
```

### Updating a temporal record

```sql
BEGIN;
  -- Close current version
  UPDATE prices
  SET valid_to = NOW()
  WHERE product_id = 42 AND valid_to IS NULL;

  -- Insert new version
  INSERT INTO prices (product_id, price, valid_from, valid_to)
  VALUES (42, 29.99, NOW(), NULL);
COMMIT;
```

PostgreSQL 15+ supports temporal range constraints natively with `tstzrange`:

```sql
CREATE TABLE prices (
    product_id BIGINT NOT NULL,
    price      NUMERIC(12,2) NOT NULL,
    valid_during TSTZRANGE NOT NULL,
    EXCLUDE USING GIST (product_id WITH =, valid_during WITH &&)
    -- prevents overlapping periods for same product
);
```

---

## 26.4 Polymorphic Associations

One table needs to reference multiple other tables. Example: `comments` can belong to `posts`, `photos`, or `videos`.

### Pattern 1 — Separate FK columns (recommended)

```sql
CREATE TABLE comments (
    comment_id BIGSERIAL PRIMARY KEY,
    body       TEXT NOT NULL,
    post_id    BIGINT REFERENCES posts(id),
    photo_id   BIGINT REFERENCES photos(id),
    video_id   BIGINT REFERENCES videos(id),
    -- Exactly one must be non-null
    CONSTRAINT one_parent CHECK (
        (post_id IS NOT NULL)::int +
        (photo_id IS NOT NULL)::int +
        (video_id IS NOT NULL)::int = 1
    )
);
```

Simple, enforces referential integrity, but requires adding a column for each new type.

### Pattern 2 — Single-table inheritance base table

```sql
CREATE TABLE commentable (
    id   BIGSERIAL PRIMARY KEY,
    type TEXT NOT NULL  -- 'post', 'photo', 'video'
);

CREATE TABLE posts  (id BIGINT PRIMARY KEY REFERENCES commentable(id), ...);
CREATE TABLE photos (id BIGINT PRIMARY KEY REFERENCES commentable(id), ...);

CREATE TABLE comments (
    comment_id    BIGSERIAL PRIMARY KEY,
    commentable_id BIGINT REFERENCES commentable(id),  -- FK to base table
    body          TEXT
);
```

Clean FK — but requires maintaining the base table and complex JOINs.

### Pattern 3 — Type + ID columns (common in ORMs, but fragile)

```sql
CREATE TABLE comments (
    comment_id      BIGSERIAL PRIMARY KEY,
    commentable_type TEXT NOT NULL,  -- 'Post', 'Photo', 'Video'
    commentable_id   BIGINT NOT NULL, -- no FK — no referential integrity
    body            TEXT
);
```

Simple but has no FK constraint — the database cannot enforce referential integrity. Orphan records accumulate. Avoid unless the ORM manages it carefully.

---

## 26.5 EAV — Entity-Attribute-Value

The EAV pattern stores arbitrary key-value pairs to simulate a flexible schema:

```sql
CREATE TABLE product_attributes (
    product_id BIGINT REFERENCES products(id),
    attr_name  TEXT NOT NULL,
    attr_value TEXT,
    PRIMARY KEY (product_id, attr_name)
);

-- Laptop has RAM and CPU attributes
INSERT INTO product_attributes VALUES (1, 'ram_gb', '16');
INSERT INTO product_attributes VALUES (1, 'cpu', 'Intel i7');

-- Shirt has size and color
INSERT INTO product_attributes VALUES (2, 'size', 'M');
INSERT INTO product_attributes VALUES (2, 'color', 'blue');
```

### EAV Problems (why to avoid it)

- No data types — everything is TEXT, no validation
- No constraints per attribute
- Querying is painful: to filter on two attributes requires self-joins
- No foreign key constraints on values
- Terrible performance for complex queries

### Better alternatives to EAV

| Use Case | Better Pattern |
|----------|---------------|
| Truly schema-less attributes | JSONB column |
| Typed attributes per category | Separate tables per product type |
| Fixed known attributes | Regular columns |

```sql
-- Instead of EAV, use JSONB
ALTER TABLE products ADD COLUMN attributes JSONB;

UPDATE products SET attributes = '{"ram_gb": 16, "cpu": "Intel i7"}' WHERE id = 1;
UPDATE products SET attributes = '{"size": "M", "color": "blue"}' WHERE id = 2;

-- Query by attribute
SELECT * FROM products WHERE attributes->>'color' = 'blue';
CREATE INDEX ON products USING GIN (attributes);
```

---

## 26.6 Hierarchical Data

Storing tree structures (categories, org charts, file systems).

### Adjacency List (simplest)

```sql
CREATE TABLE categories (
    id        BIGSERIAL PRIMARY KEY,
    name      TEXT NOT NULL,
    parent_id BIGINT REFERENCES categories(id)  -- NULL = root
);
```

Simple, easy updates. Problem: fetching a full tree requires recursive queries.

```sql
-- Full tree with recursive CTE
WITH RECURSIVE tree AS (
    SELECT id, name, parent_id, 0 AS depth
    FROM categories WHERE parent_id IS NULL   -- roots

    UNION ALL

    SELECT c.id, c.name, c.parent_id, t.depth + 1
    FROM categories c
    JOIN tree t ON c.parent_id = t.id
)
SELECT * FROM tree ORDER BY depth, name;
```

### Materialized Path

```sql
CREATE TABLE categories (
    id   BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    path TEXT NOT NULL  -- e.g., '/1/4/12/' = root 1 → 4 → 12
);

-- All descendants of category 4
SELECT * FROM categories WHERE path LIKE '/1/4/%';

-- All ancestors of category 12
SELECT * FROM categories WHERE '/1/4/12/' LIKE path || '%';
```

Fast reads, but path updates when restructuring.

### Nested Set (ltree extension)

```sql
CREATE EXTENSION ltree;

CREATE TABLE categories (
    id   BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    path LTREE NOT NULL  -- '1.4.12'
);

CREATE INDEX ON categories USING GIST (path);

-- Subtree
SELECT * FROM categories WHERE path <@ '1.4';

-- Ancestors
SELECT * FROM categories WHERE path @> '1.4.12';
```

`ltree` is the recommended approach for hierarchical data in PostgreSQL.

---

## 26.7 Many-to-Many with Extra Data

A junction table that carries more than just the relationship:

```sql
-- Student enrolls in course with a grade and enrollment date
CREATE TABLE enrollments (
    student_id  BIGINT REFERENCES students(id),
    course_id   BIGINT REFERENCES courses(id),
    enrolled_at TIMESTAMPTZ DEFAULT NOW(),
    grade       CHAR(2),
    status      TEXT DEFAULT 'active' CHECK (status IN ('active', 'dropped', 'completed')),
    PRIMARY KEY (student_id, course_id)
);
```

The junction table is a first-class entity — query it directly for reports:

```sql
-- Average grade per course
SELECT c.name, AVG(CASE grade
    WHEN 'A' THEN 4.0 WHEN 'B' THEN 3.0 WHEN 'C' THEN 2.0
    ELSE 0 END) AS gpa
FROM enrollments e
JOIN courses c ON e.course_id = c.id
WHERE e.status = 'completed'
GROUP BY c.name;
```

---

## 26.8 UUID vs Serial for Primary Keys

```sql
-- Serial (auto-increment integer)
id BIGSERIAL PRIMARY KEY  -- 1, 2, 3, ...

-- UUID v4 (random)
id UUID PRIMARY KEY DEFAULT gen_random_uuid()

-- UUID v7 (time-ordered, PostgreSQL 17+ or pg_uuidv7 extension)
id UUID PRIMARY KEY DEFAULT uuid_generate_v7()
```

| | BIGSERIAL | UUID v4 | UUID v7 |
|-|-----------|---------|---------|
| Size | 8 bytes | 16 bytes | 16 bytes |
| Index performance | Excellent (sequential inserts) | Poor (random = index fragmentation) | Good (time-ordered) |
| Globally unique | No (per-table) | Yes | Yes |
| Guessable | Yes | No | Partially |
| Merging databases | Conflicts | No conflicts | No conflicts |

**Use UUID v7** when you need globally unique IDs (distributed systems, exposing IDs in URLs). Use `BIGSERIAL` for internal tables that never need to merge.

---

## Key Terms

| Term | Meaning |
|------|---------|
| Soft delete | Marking rows as deleted rather than removing them |
| Temporal table | Table that stores the full history of row states over time |
| Audit table | A log of all changes with old/new values |
| Polymorphic association | One table referencing multiple other table types |
| EAV | Entity-Attribute-Value — storing arbitrary key-value pairs (usually avoid) |
| Adjacency list | Hierarchical data stored as parent_id FK on same table |
| ltree | PostgreSQL extension for labelled tree data structures |
| UUID v7 | Time-ordered UUID — globally unique + good index performance |

---

## Practice Questions

1. Why is `deleted_at TIMESTAMPTZ` better than `is_deleted BOOLEAN` for soft deletes?
2. Design an audit trigger for a `payments` table that records all changes to `amount` and `status`.
3. You need to store the price history of products so you can query "what was the price on date X?" Design the schema.
4. A `likes` table can reference either a `post` or a `comment`. Show two approaches and their trade-offs.
5. Why is EAV an anti-pattern and what should you use instead in PostgreSQL?
6. When would you choose UUID over BIGSERIAL as a primary key?

---

**← Previous:** [25_security.md](25_security.md)  
**Next →** [27_full_text_search.md](27_full_text_search.md)
