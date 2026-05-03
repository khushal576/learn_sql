# Chapter 28 — JSON & Semi-Structured Data

PostgreSQL's JSONB support lets you store, query, and index JSON documents natively — combining the flexibility of a document store with the power of relational SQL.

---

## 28.1 JSON vs JSONB

PostgreSQL has two JSON types:

| | `JSON` | `JSONB` |
|-|--------|---------|
| Storage | Text (preserved exactly) | Binary (parsed, optimized) |
| Whitespace | Preserved | Removed |
| Duplicate keys | Kept (last wins on read) | Last wins, stored once |
| Key order | Preserved | Not guaranteed |
| Read speed | Slower (re-parse each time) | Faster (pre-parsed) |
| Write speed | Faster (no parse) | Slower (parse + convert) |
| Indexing | ❌ No index support | ✅ GIN, btree indexes |
| Operators | Basic | Full set |

**Always use JSONB** unless you specifically need exact text preservation (rare).

---

## 28.2 Creating and Inserting JSONB

```sql
CREATE TABLE products (
    product_id BIGSERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    price      NUMERIC(12,2) NOT NULL,
    attributes JSONB
);

INSERT INTO products (name, price, attributes) VALUES
('Laptop Pro', 1299.99, '{
    "brand": "TechCo",
    "specs": {"ram_gb": 16, "cpu": "Intel i7", "storage_gb": 512},
    "colors": ["silver", "space-grey"],
    "is_refurbished": false
}'),
('USB Hub', 29.99, '{
    "brand": "ConnectX",
    "ports": 7,
    "colors": ["black"]
}');
```

---

## 28.3 JSONB Operators

### Extraction Operators

```sql
-- -> returns JSONB value
SELECT attributes -> 'brand' FROM products;              -- "TechCo"

-- ->> returns TEXT value (no quotes)
SELECT attributes ->> 'brand' FROM products;             -- TechCo

-- Path navigation
SELECT attributes -> 'specs' -> 'ram_gb' FROM products;  -- 16
SELECT attributes #> '{specs,ram_gb}' FROM products;     -- 16 (array path)
SELECT attributes #>> '{specs,cpu}' FROM products;       -- Intel i7

-- Array element
SELECT attributes -> 'colors' -> 0 FROM products;        -- "silver"
SELECT attributes -> 'colors' ->> 0 FROM products;       -- silver
```

### Containment Operators

```sql
-- @>  Does left contain right? (right is subset of left)
SELECT * FROM products
WHERE attributes @> '{"brand": "TechCo"}';

SELECT * FROM products
WHERE attributes @> '{"specs": {"ram_gb": 16}}';

-- <@  Is left contained in right?
SELECT '{"a":1}'::jsonb <@ '{"a":1,"b":2}'::jsonb;  -- true

-- ?  Does key exist?
SELECT * FROM products WHERE attributes ? 'brand';

-- ?|  Does any key exist?
SELECT * FROM products WHERE attributes ?| ARRAY['brand', 'ports'];

-- ?&  Do all keys exist?
SELECT * FROM products WHERE attributes ?& ARRAY['brand', 'colors'];
```

### Modification Operators

```sql
-- ||  Merge / update keys
UPDATE products
SET attributes = attributes || '{"in_stock": true}'
WHERE product_id = 1;

-- -   Remove key
UPDATE products
SET attributes = attributes - 'is_refurbished'
WHERE product_id = 1;

-- #-  Remove nested key
UPDATE products
SET attributes = attributes #- '{specs,storage_gb}'
WHERE product_id = 1;

-- jsonb_set: update nested value
UPDATE products
SET attributes = jsonb_set(attributes, '{specs,ram_gb}', '32')
WHERE product_id = 1;
```

---

## 28.4 Querying Arrays in JSONB

```sql
-- Products that include 'silver' in their colors array
SELECT * FROM products
WHERE attributes @> '{"colors": ["silver"]}';

-- Expand JSONB array to rows
SELECT product_id, jsonb_array_elements_text(attributes->'colors') AS color
FROM products;
-- product_id | color
-- -----------+-------
-- 1          | silver
-- 1          | space-grey
-- 2          | black

-- Count array elements
SELECT product_id, jsonb_array_length(attributes->'colors')
FROM products;
```

---

## 28.5 Indexing JSONB

### GIN Index (for @>, ?, ?|, ?& operators)

```sql
-- Index the entire JSONB column (most common)
CREATE INDEX idx_products_attrs ON products USING GIN (attributes);

-- Now these queries use the index:
SELECT * FROM products WHERE attributes @> '{"brand": "TechCo"}';
SELECT * FROM products WHERE attributes ? 'brand';
```

### Expression Index (for specific key comparisons)

```sql
-- Index on a specific key extracted as text
CREATE INDEX idx_products_brand
    ON products ((attributes->>'brand'));

-- Used by:
SELECT * FROM products WHERE attributes->>'brand' = 'TechCo';
```

### jsonb_path_ops (smaller, faster for @> only)

```sql
CREATE INDEX idx_products_attrs_path
    ON products USING GIN (attributes jsonb_path_ops);
-- Smaller index, only supports @> operator
```

---

## 28.6 JSONB Functions

```sql
-- Pretty print
SELECT jsonb_pretty(attributes) FROM products WHERE product_id = 1;

-- Build JSONB from key-value pairs
SELECT jsonb_build_object('name', name, 'price', price) FROM products;

-- Convert row to JSONB
SELECT row_to_json(products) FROM products LIMIT 1;

-- Aggregate rows into JSON array
SELECT jsonb_agg(jsonb_build_object('id', product_id, 'name', name))
FROM products;

-- Key-value pairs as rows
SELECT key, value
FROM products, jsonb_each(attributes)
WHERE product_id = 1;
-- key   | value
-- ------+--------
-- brand | "TechCo"
-- specs | {"ram_gb":16,...}
-- colors| ["silver","space-grey"]

-- All keys in a JSONB object
SELECT jsonb_object_keys(attributes) FROM products WHERE product_id = 1;
```

---

## 28.7 JSONPath — XPath for JSON

PostgreSQL 12+ supports SQL/JSON path queries:

```sql
-- Find products with RAM > 8GB
SELECT * FROM products
WHERE attributes @? '$.specs.ram_gb ? (@ > 8)';

-- Extract all color values matching a condition
SELECT jsonb_path_query(attributes, '$.colors[*] ? (@ like_regex "grey")')
FROM products;

-- Check existence
SELECT jsonb_path_exists(attributes, '$.specs.ram_gb');
```

---

## 28.8 JSONB for Semi-Structured Data Patterns

### Product Catalog (varying attributes per category)

```sql
CREATE TABLE products (
    product_id  BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    category    TEXT NOT NULL,
    price       NUMERIC(12,2) NOT NULL,
    -- Structured for known attributes
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    -- Flexible for category-specific attributes
    attributes  JSONB
);

-- Laptops have ram_gb, cpu, storage_gb
-- Shirts have size, color, material
-- Both queryable via GIN index on attributes
```

### User Settings / Feature Flags

```sql
CREATE TABLE user_preferences (
    user_id     BIGINT PRIMARY KEY REFERENCES users(id),
    preferences JSONB NOT NULL DEFAULT '{}'
);

-- Set a preference
UPDATE user_preferences
SET preferences = jsonb_set(preferences, '{theme}', '"dark"')
WHERE user_id = 42;

-- Query users with dark theme
SELECT user_id FROM user_preferences
WHERE preferences @> '{"theme": "dark"}';
```

### Event Log with Variable Payload

```sql
CREATE TABLE events (
    event_id   BIGSERIAL PRIMARY KEY,
    event_type TEXT NOT NULL,
    user_id    BIGINT,
    occurred_at TIMESTAMPTZ DEFAULT NOW(),
    payload    JSONB NOT NULL DEFAULT '{}'
);

INSERT INTO events (event_type, user_id, payload) VALUES
('purchase', 42, '{"order_id": 1001, "amount": 99.99, "items": 3}'),
('login',    42, '{"ip": "192.168.1.1", "device": "mobile"}'),
('search',   42, '{"query": "laptop", "results": 15}');

-- Find all purchase events over $50
SELECT * FROM events
WHERE event_type = 'purchase'
  AND (payload->>'amount')::numeric > 50;
```

---

## 28.9 Hybrid Schema — Relational + JSONB

The most powerful pattern: structured columns for known, queryable fields; JSONB for flexible, extensible attributes.

```sql
CREATE TABLE orders (
    -- Relational core (always queried, indexed, FK-constrained)
    order_id    BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES customers(id),
    status      TEXT NOT NULL,
    total       NUMERIC(12,2) NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Flexible extension (varies per order type)
    metadata    JSONB
    -- shipping address, promo codes, custom notes, etc.
);

-- Core queries use relational columns (fast, indexed normally)
SELECT * FROM orders WHERE customer_id = 42 AND status = 'pending';

-- Extended queries use JSONB
SELECT * FROM orders WHERE metadata @> '{"promo_code": "SAVE20"}';
```

This beats pure JSONB (gives you SQL joins, FK constraints, type safety) and beats pure EAV (gives you flexibility without the painful querying).

---

## 28.10 When to Use JSONB vs Separate Columns

| Scenario | Use |
|----------|-----|
| Always queried in WHERE or JOIN | Separate column |
| Needs FK constraint | Separate column |
| Needs unique constraint | Separate column |
| Varies per row (optional attributes) | JSONB |
| Known only at runtime | JSONB |
| Rarely queried, just stored and returned | JSONB |
| Replacing an EAV pattern | JSONB |
| Syncing from an external JSON API | JSONB |

Rule of thumb: if you query it with SQL filters regularly, it should be a column. If it's metadata that varies, use JSONB.

---

## Key Terms

| Term | Meaning |
|------|---------|
| JSONB | Binary JSON — parsed, indexed, fast for reads |
| `->` | Extract JSONB value by key |
| `->>` | Extract TEXT value by key |
| `@>` | Does left JSONB contain right? (containment) |
| `?` | Does key exist in JSONB? |
| GIN index | Inverted index for JSONB containment and key existence |
| `jsonb_set` | Update a value at a path in a JSONB document |
| JSONPath | SQL/JSON standard query language for navigating JSONB |
| Hybrid schema | Relational columns for known fields + JSONB for flexible fields |

---

## Practice Questions

1. You have `attributes JSONB`. Write a query to find all products where `attributes->>'brand' = 'TechCo'` and RAM > 8GB.
2. What is the difference between `->` and `->>` operators?
3. You want to find all rows where the JSONB column contains `{"status": "active"}`. Which operator do you use and what index supports it?
4. When would you use `jsonb_path_ops` instead of the default GIN index?
5. Design a schema for a survey builder where each survey has different question types (text, multiple choice, rating). Use a hybrid approach.
6. A JSONB column stores an array of tags. Write a query to find rows where `"postgresql"` is in the tags array.

---

**← Previous:** [27_full_text_search.md](27_full_text_search.md)  
**Next →** [29_performance_tuning.md](29_performance_tuning.md)
