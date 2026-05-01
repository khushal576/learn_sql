# Chapter 27 — Full-Text Search

PostgreSQL has a powerful built-in full-text search engine — no Elasticsearch required for most use cases. This chapter covers `tsvector`, `tsquery`, ranking, and when to reach for external search tools.

---

## 27.1 What is Full-Text Search?

Full-text search finds documents containing words — with stemming, stop-word removal, and relevance ranking.

```sql
-- LIKE: exact substring match, no ranking, slow
WHERE body LIKE '%database%'   -- won't match "databases" or "DB"

-- Full-text: smart matching with ranking
WHERE to_tsvector('english', body) @@ to_tsquery('english', 'database')
-- matches: "database", "databases", "Database" — ranked by relevance
```

---

## 27.2 tsvector — The Document Representation

A `tsvector` is a sorted, deduplicated list of lexemes (normalized word forms) with position information:

```sql
SELECT to_tsvector('english', 'PostgreSQL is a powerful open-source database system');
-- 'databas':7 'open-sourc':5 'postgreSQL':1 'power':4 'system':8
-- Stop words (is, a) are removed
-- Words are stemmed: "powerful" → "power", "database" → "databas"
```

### Text Search Configuration (Language)

The second argument controls stemming and stop words:

```sql
SELECT to_tsvector('english', 'running quickly') ;   -- 'quick':2 'run':1
SELECT to_tsvector('spanish', 'corriendo rápidamente');
SELECT to_tsvector('simple',  'running quickly');     -- no stemming: 'quickly':2 'running':1

-- List available configurations
SELECT cfgname FROM pg_ts_config;
```

---

## 27.3 tsquery — The Search Query

A `tsquery` represents a search expression:

```sql
-- Single word
SELECT to_tsquery('english', 'database');        -- 'databas'

-- AND: both must appear
SELECT to_tsquery('english', 'database & fast'); -- 'databas' & 'fast'

-- OR: either
SELECT to_tsquery('english', 'postgres | mysql');

-- NOT: must not appear
SELECT to_tsquery('english', 'database & !oracle');

-- Phrase search (adjacent words in order)
SELECT to_tsquery('english', 'open <-> source');  -- "open source"
SELECT to_tsquery('english', 'open <2> source');  -- within 2 words

-- Prefix search
SELECT to_tsquery('english', 'data:*');  -- matches "data", "database", "datastore"

-- plainto_tsquery: plain text, no operators needed
SELECT plainto_tsquery('english', 'open source database');
-- 'open' & 'sourc' & 'databas'

-- websearch_to_tsquery: Google-style syntax
SELECT websearch_to_tsquery('english', '"open source" database -oracle');
-- 'open' <-> 'sourc' & 'databas' & !'oracl'
```

---

## 27.4 The @@ Match Operator

```sql
-- Does this document match this query?
SELECT to_tsvector('english', 'PostgreSQL is a powerful database')
    @@ to_tsquery('english', 'powerful & database');
-- → true

-- Search articles
SELECT title FROM articles
WHERE to_tsvector('english', title || ' ' || body)
    @@ to_tsquery('english', 'machine & learning');
```

---

## 27.5 Indexing for Full-Text Search

Without an index, FTS requires scanning all rows. With a GIN index, it's fast.

### Option 1 — Index on expression (simple, no schema change)

```sql
CREATE INDEX idx_articles_fts
    ON articles
    USING GIN (to_tsvector('english', title || ' ' || body));

-- Query must match the index expression exactly
SELECT * FROM articles
WHERE to_tsvector('english', title || ' ' || body)
    @@ to_tsquery('english', 'database');
```

### Option 2 — Stored tsvector column (recommended for large tables)

```sql
-- Add a generated column
ALTER TABLE articles ADD COLUMN search_vector TSVECTOR
    GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title,'')), 'A') ||
        setweight(to_tsvector('english', coalesce(body,'')), 'B')
    ) STORED;

-- Index the stored column
CREATE INDEX idx_articles_search ON articles USING GIN (search_vector);

-- Query using the column (faster than expression index)
SELECT * FROM articles WHERE search_vector @@ to_tsquery('english', 'database');
```

`GENERATED ALWAYS AS ... STORED` automatically keeps the column up to date on INSERT/UPDATE — no trigger needed.

---

## 27.6 Relevance Ranking

Return results in relevance order using `ts_rank` or `ts_rank_cd`:

```sql
SELECT
    title,
    ts_rank(search_vector, query) AS rank
FROM articles,
     to_tsquery('english', 'database & performance') AS query
WHERE search_vector @@ query
ORDER BY rank DESC
LIMIT 10;
```

`ts_rank_cd` also considers **cover density** (how close the search terms are to each other):

```sql
ts_rank_cd(search_vector, query)  -- better for phrase-like relevance
```

### Boosting by field weight

```sql
-- Title matches are more relevant than body matches
setweight(to_tsvector('english', title), 'A') ||  -- weight A = highest
setweight(to_tsvector('english', body),  'B')     -- weight B = lower

-- Weights: A=1.0, B=0.4, C=0.2, D=0.1
```

---

## 27.7 Highlighting Search Results

Show which parts of the document matched:

```sql
SELECT
    title,
    ts_headline(
        'english',
        body,
        to_tsquery('english', 'database & performance'),
        'MaxWords=50, MinWords=15, ShortWord=3, MaxFragments=3, FragmentDelimiter=" ... "'
    ) AS excerpt
FROM articles
WHERE search_vector @@ to_tsquery('english', 'database & performance')
ORDER BY ts_rank(search_vector, to_tsquery('english', 'database & performance')) DESC;
```

Output:
```
... building a high-performance <b>database</b> requires understanding the <b>performance</b> characteristics ...
```

---

## 27.8 Autocomplete with Full-Text Search

```sql
-- Prefix search for autocomplete
SELECT title FROM articles
WHERE search_vector @@ to_tsquery('english', 'postgre:*')
ORDER BY ts_rank(search_vector, to_tsquery('english', 'postgre:*')) DESC
LIMIT 5;
```

For better autocomplete (trigram-based, works for substring matching):

```sql
CREATE EXTENSION pg_trgm;

CREATE INDEX idx_articles_trgm ON articles USING GIN (title gin_trgm_ops);

-- Search for any substring
SELECT title, similarity(title, 'postgres') AS sim
FROM articles
WHERE title % 'postgres'       -- % = similarity threshold
ORDER BY sim DESC
LIMIT 10;
```

`pg_trgm` also enables `LIKE '%anything%'` to use an index.

---

## 27.9 Multilingual Full-Text Search

```sql
-- Store language per document
ALTER TABLE articles ADD COLUMN language TEXT DEFAULT 'english';
ALTER TABLE articles ADD COLUMN search_vector TSVECTOR;

-- Update trigger using document's own language
CREATE OR REPLACE FUNCTION articles_search_update() RETURNS TRIGGER AS $$
BEGIN
    NEW.search_vector =
        setweight(to_tsvector(NEW.language::regconfig, coalesce(NEW.title,'')), 'A') ||
        setweight(to_tsvector(NEW.language::regconfig, coalesce(NEW.body,'')), 'B');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER articles_search_trigger
    BEFORE INSERT OR UPDATE ON articles
    FOR EACH ROW EXECUTE FUNCTION articles_search_update();

-- Query matching document language
SELECT * FROM articles
WHERE language = 'english'
  AND search_vector @@ to_tsquery('english', 'database');
```

---

## 27.10 When to Use PostgreSQL FTS vs Elasticsearch

| Feature | PostgreSQL FTS | Elasticsearch |
|---------|---------------|---------------|
| Setup | Zero — built-in | Separate cluster |
| Consistency with main data | ✅ Same transaction | ❌ Eventual (sync lag) |
| Basic full-text search | ✅ Excellent | ✅ Excellent |
| Fuzzy search (typo tolerance) | Partial (pg_trgm) | ✅ Built-in |
| Faceted search (filters + aggregations) | Possible but complex | ✅ Native |
| Billions of documents | Scaling required | ✅ Scales horizontally |
| Custom ranking/ML | Limited | ✅ Learning to Rank |
| Geographic search | ✅ PostGIS | ✅ Native geo |

**Use PostgreSQL FTS when**: single-language search, moderate scale (< 10M documents), keeping things simple, or consistency is critical.

**Use Elasticsearch when**: multi-language, faceted search, billions of documents, advanced relevance tuning, log analytics.

---

## Key Terms

| Term | Meaning |
|------|---------|
| tsvector | Normalized list of lexemes (words) from a document |
| tsquery | A search query expression (AND, OR, NOT, phrase) |
| Lexeme | Normalized word form after stemming and stop-word removal |
| `@@` | Operator: does this tsvector match this tsquery? |
| `ts_rank` | Function returning a relevance score |
| `ts_headline` | Function generating a highlighted excerpt |
| `setweight` | Assign importance level to a tsvector (A > B > C > D) |
| pg_trgm | Extension for trigram-based similarity search |

---

## Practice Questions

1. What is the difference between `to_tsquery` and `plainto_tsquery`?
2. Why is a `GENERATED ALWAYS AS ... STORED` tsvector column better than an expression index for large tables?
3. You want to search articles where the title match is more important than the body match. How do you implement this?
4. A user searches for "postgr" and expects autocomplete suggestions. Which technique handles this?
5. Write a query returning the top 5 articles matching "distributed database", ranked by relevance, with a highlighted excerpt.
6. When should you choose Elasticsearch over PostgreSQL full-text search?

---

**← Previous:** [26_advanced_schema_patterns.md](26_advanced_schema_patterns.md)  
**Next →** [28_json_semistructured.md](28_json_semistructured.md)
