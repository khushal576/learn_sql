-------------------------------------------------
-- CHAPTER 19
-- Full-Text Search (FTS)
-------------------------------------------------
-- Full-text search lets you find documents containing keywords,
-- ranked by relevance — far more powerful than LIKE '%keyword%'.
--
-- Two core types:
--   tsvector  — a processed, normalised document (list of lexemes)
--   tsquery   — a search query (keywords + boolean operators)
--
-- The @@ operator checks if a tsquery matches a tsvector.
-- GIN/GiST indexes make this fast at scale.
--
-- All examples use a job_posts table created below.

-------------------------------------------------

-- Setup: job posts table for FTS examples
create table if not exists job_posts (
    id          serial primary key,
    title       text not null,
    description text not null,
    posted_date date default current_date
);

insert into job_posts (title, description) values
('Senior PostgreSQL DBA',
 'Looking for an experienced database administrator with deep PostgreSQL knowledge. Must know indexing, query optimisation, replication and vacuuming.'),
('Python Data Engineer',
 'Build and maintain data pipelines using Python and SQL. Experience with PostgreSQL, Airflow, and cloud platforms required.'),
('Backend Software Engineer',
 'Develop REST APIs using Python or Go. Strong SQL skills required. Experience with PostgreSQL and Redis preferred.'),
('Data Analyst',
 'Analyse business data using SQL and Python. Create dashboards and reports. PostgreSQL experience is a plus.'),
('Machine Learning Engineer',
 'Design and deploy machine learning models. Python expertise required. SQL knowledge helpful for data extraction.'),
('Junior SQL Developer',
 'Write and optimise SQL queries. Learn database design and PostgreSQL administration basics.');

-------------------------------------------------

-- tsvector — converting text into a searchable document
-- to_tsvector(config, text) tokenises and normalises (stems) words.
-- Stop words (the, and, is...) are removed automatically.

select to_tsvector('english', 'The quick brown fox jumps over the lazy dog');
-- Result: 'brown':3 'dog':9 'fox':4 'jump':5 'lazi':8 'quick':2
-- Note: "The", "over" removed (stop words); "jumps"→"jump", "lazy"→"lazi" (stemmed)

-- See what a document looks like as tsvector:
select id, title,
       to_tsvector('english', title || ' ' || description) as doc_vector
from job_posts
limit 2;

-------------------------------------------------

-- tsquery — building a search query
-- to_tsquery: strict (must be valid lexemes, use & | ! operators)
-- plainto_tsquery: natural language, spaces become AND
-- websearch_to_tsquery: Google-style (quoted phrases, - for NOT)
-- phraseto_tsquery: words must appear in order

select to_tsquery('english', 'PostgreSQL & indexing');
select plainto_tsquery('english', 'PostgreSQL indexing');
select websearch_to_tsquery('english', 'PostgreSQL indexing -replication');
select phraseto_tsquery('english', 'query optimisation');

-------------------------------------------------

-- @@ operator — does the document match the query?

-- Find all posts mentioning PostgreSQL:
select id, title
from job_posts
where to_tsvector('english', title || ' ' || description)
   @@ to_tsquery('english', 'PostgreSQL');

-- Find posts about Python AND SQL:
select id, title
from job_posts
where to_tsvector('english', title || ' ' || description)
   @@ plainto_tsquery('english', 'Python SQL');

-- Find posts about PostgreSQL but NOT replication:
select id, title
from job_posts
where to_tsvector('english', title || ' ' || description)
   @@ websearch_to_tsquery('english', 'PostgreSQL -replication');

-------------------------------------------------

-- Boolean operators in tsquery
-- & = AND    | = OR    ! = NOT    <-> = FOLLOWED BY (phrase)

select id, title
from job_posts
where to_tsvector('english', title || ' ' || description)
   @@ to_tsquery('english', 'Python | Go');

select id, title
from job_posts
where to_tsvector('english', title || ' ' || description)
   @@ to_tsquery('english', 'data & engineer & !machine');

-- Phrase search: "data pipeline" (words adjacent in order)
select id, title
from job_posts
where to_tsvector('english', title || ' ' || description)
   @@ to_tsquery('english', 'data <-> pipeline');

-------------------------------------------------

-- ts_rank — score relevance of a match (0.0 to 1.0)
-- Higher rank = more mentions / better match

select id,
       title,
       ts_rank(
           to_tsvector('english', title || ' ' || description),
           plainto_tsquery('english', 'SQL PostgreSQL')
       ) as rank
from job_posts
where to_tsvector('english', title || ' ' || description)
   @@ plainto_tsquery('english', 'SQL PostgreSQL')
order by rank desc;

-------------------------------------------------

-- ts_rank_cd — cover density ranking
-- Rewards matches where keywords appear close together.

select id,
       title,
       ts_rank_cd(
           to_tsvector('english', title || ' ' || description),
           plainto_tsquery('english', 'PostgreSQL database')
       ) as rank_cd
from job_posts
where to_tsvector('english', title || ' ' || description)
   @@ plainto_tsquery('english', 'PostgreSQL database')
order by rank_cd desc;

-------------------------------------------------

-- ts_headline — highlight matching terms in the result
-- Wraps matched words in <b>...</b> by default.

select id,
       title,
       ts_headline(
           'english',
           description,
           plainto_tsquery('english', 'PostgreSQL indexing'),
           'StartSel=<mark>, StopSel=</mark>, MaxWords=20, MinWords=10'
       ) as snippet
from job_posts
where to_tsvector('english', description)
   @@ plainto_tsquery('english', 'PostgreSQL indexing');

-- Options: StartSel, StopSel (highlight tags), MaxWords, MinWords,
--          MaxFragments (number of snippets), HighlightAll (highlight full text)

-------------------------------------------------

-- Stored tsvector column — best practice for production
-- Recomputing to_tsvector on every query is expensive.
-- Store it as a GENERATED column — auto-updated on INSERT/UPDATE.

alter table job_posts
    add column search_vector tsvector
        generated always as (
            to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, ''))
        ) stored;

-- Now query the pre-computed column directly:
select id, title
from job_posts
where search_vector @@ plainto_tsquery('english', 'PostgreSQL');

-- Much faster with an index (see below).

-------------------------------------------------

-- GIN index on the stored tsvector column
-- Makes FTS queries fast on millions of rows.

create index idx_job_posts_fts on job_posts using gin (search_vector);

explain
select id, title
from job_posts
where search_vector @@ plainto_tsquery('english', 'PostgreSQL');
-- Should show: Bitmap Index Scan on idx_job_posts_fts

-------------------------------------------------

-- GiST index (alternative to GIN)
-- GiST: smaller index, slower queries, faster to update
-- GIN:  larger index, faster queries, slower to update
-- Rule: use GIN for read-heavy FTS, GiST if the table has very frequent updates.

-- create index idx_job_posts_gist on job_posts using gist (search_vector);

-------------------------------------------------

-- FTS configurations — language-specific stemming and stop words
-- 'english' is the default. PostgreSQL ships with many configurations.

select cfgname from pg_ts_config order by cfgname;

-- Examples: english, french, german, spanish, simple
-- 'simple' does no stemming — useful for names, codes, exact matching.

select to_tsvector('simple', 'Running runs runner');
-- Result: 'runner':3 'running':1 'runs':2  (no stemming)

select to_tsvector('english', 'Running runs runner');
-- Result: 'run':1,2,3  (all stemmed to "run")

-------------------------------------------------

-- Multi-column FTS with different weights
-- setweight() assigns A/B/C/D to boost title matches over description matches.

select id,
       title,
       ts_rank(
           setweight(to_tsvector('english', title),       'A') ||
           setweight(to_tsvector('english', description), 'B'),
           plainto_tsquery('english', 'PostgreSQL')
       ) as weighted_rank
from job_posts
where (
    setweight(to_tsvector('english', title),       'A') ||
    setweight(to_tsvector('english', description), 'B')
) @@ plainto_tsquery('english', 'PostgreSQL')
order by weighted_rank desc;

-- Weight A matches (title) score higher than weight B (description).
-- Weights: A > B > C > D in scoring importance.

-------------------------------------------------

-- Clean up
drop index if exists idx_job_posts_fts;
drop table if exists job_posts;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Always use a stored GENERATED tsvector column in production.
--    Calling to_tsvector() inline on every query is expensive at scale.

-- 2. Create a GIN index on the stored tsvector column.
--    Without it, FTS is a full table scan on the tsvector column.

-- 3. Use plainto_tsquery or websearch_to_tsquery for user-facing search.
--    to_tsquery requires valid syntax — it will throw errors on raw user input.

-- 4. Use setweight() to boost title/subject matches over body matches.
--    This produces much more relevant rankings.

-- 5. ts_rank and ts_rank_cd only differ in algorithm:
--    ts_rank_cd rewards keyword proximity; use it for paragraph-level docs.

-- 6. Use 'simple' configuration when you need exact matching
--    (codes, names, tags) — it skips stemming and stop-word removal.

-- 7. For arbitrary substring search (LIKE '%pattern%'),
--    use pg_trgm + GIN index (see Chapter 22) — it is faster than FTS
--    for that specific use case.
