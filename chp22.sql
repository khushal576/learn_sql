-------------------------------------------------
-- CHAPTER 22
-- Extensions and the PostgreSQL Ecosystem
-------------------------------------------------
-- PostgreSQL's superpower is its extension system.
-- Extensions add new data types, functions, operators, and index methods
-- without changing the core database.
--
-- This chapter covers the most useful production extensions:
--   pg_trgm       — trigram similarity and fast LIKE/ILIKE searches
--   uuid-ossp     — UUID generation
--   hstore        — key-value store in a column
--   pgcrypto      — password hashing and encryption
--   pg_stat_statements — query performance tracking (covered in Ch21 too)
--   tablefunc     — crosstab (true SQL PIVOT)
--   PostGIS       — geospatial / geographic queries (overview)
-- Plus: managing extensions and discovering what's available.

-------------------------------------------------

-- Managing extensions
create extension if not exists pg_trgm;
create extension if not exists "uuid-ossp";
create extension if not exists hstore;
create extension if not exists pgcrypto;
create extension if not exists tablefunc;

-- List installed extensions:
select extname, extversion
from pg_extension
order by extname;

-- List all available extensions (installed or not):
select name, default_version, installed_version, comment
from pg_available_extensions
order by name;

-- Remove an extension:
-- drop extension if exists hstore;

-------------------------------------------------
-- PART 1: pg_trgm — Trigram Similarity & Fast LIKE Search
-------------------------------------------------
-- A trigram is a group of 3 consecutive characters.
-- "hello" → " h", "he", "hel", "ell", "llo", "lo "
-- Similarity between two strings = shared trigrams / total trigrams.
-- A GIN/GiST index on trigrams lets PostgreSQL do fast LIKE '%pattern%'.

-- Similarity score (0.0 to 1.0)
select similarity('SMITH', 'SMYTH');     -- typo tolerance
select similarity('PostgreSQL', 'MySQL');
select similarity('hello world', 'helo world');

-- % operator — TRUE if similarity >= pg_trgm.similarity_threshold (default 0.3)
select 'SMITH' % 'SMYTH';      -- true
select 'SMITH' % 'JONES';      -- false

-- <-> distance operator — 1 - similarity (smaller = more similar)
select 'SMITH' <-> 'SMYTH';

-------------------------------------------------

-- Fuzzy name search using pg_trgm
create table if not exists names_demo (
    id    serial primary key,
    name  text not null
);

insert into names_demo (name) values
('Smith'), ('Smyth'), ('Smithe'), ('Schmidt'),
('Jones'), ('Johnson'), ('Johnston'),
('Williams'), ('Wilson'), ('Willis');

-- Find names similar to a search term, ranked by similarity:
select name,
       similarity(name, 'Smit') as score
from names_demo
where name % 'Smit'
order by score desc;

-------------------------------------------------

-- GIN trigram index — makes LIKE '%pattern%' fast
create index idx_names_trgm on names_demo using gin (name gin_trgm_ops);

-- Now this query uses the index (impossible with a regular B-tree):
explain
select * from names_demo where name ilike '%mith%';

-- Case-insensitive fuzzy search:
select * from names_demo
where name ilike '%smit%'
order by similarity(name, 'smit') desc;

drop table if exists names_demo;

-------------------------------------------------

-- Show/set similarity threshold:
select show_trgm('hello');             -- see trigrams for a string
show pg_trgm.similarity_threshold;    -- default 0.3
set pg_trgm.similarity_threshold = 0.4;
reset pg_trgm.similarity_threshold;

-------------------------------------------------
-- PART 2: uuid-ossp — UUID Generation
-------------------------------------------------
-- UUIDs are 128-bit identifiers — globally unique, no central coordination.
-- Common as primary keys in distributed systems and APIs.

-- Generate a random UUID (version 4 — most common):
select gen_random_uuid();          -- built into PostgreSQL 13+ (no extension needed)
select uuid_generate_v4();         -- uuid-ossp version

-- UUID v1 — based on MAC address + timestamp (exposes machine info — avoid in public APIs):
select uuid_generate_v1();

-- UUID v5 — deterministic, based on namespace + name (reproducible):
select uuid_generate_v5(uuid_ns_url(), 'https://example.com');

-- Use as a primary key:
create table if not exists api_tokens (
    token_id  uuid         primary key default gen_random_uuid(),
    user_id   integer      not null,
    token     text         not null,
    created   timestamptz  default now()
);

insert into api_tokens (user_id, token)
values (7369, 'tok_abc123'), (7499, 'tok_xyz789');

select * from api_tokens;

drop table if exists api_tokens;

-------------------------------------------------
-- PART 3: hstore — Key-Value Store in a Column
-------------------------------------------------
-- hstore stores arbitrary key→value pairs in a single column.
-- Predecessor to JSONB — JSONB is more flexible, but hstore is simpler
-- for flat key-value structures and has excellent operator support.

create table if not exists emp_attributes (
    empno  integer primary key,
    attrs  hstore
);

insert into emp_attributes values
(7369, 'office=>Dallas, badge=>A001, parking=>B2'),
(7499, 'office=>Chicago, badge=>A002, phone=>555-1234'),
(7698, 'office=>Chicago, badge=>A003, parking=>A1, level=>manager');

-- Fetch a specific key with -> operator:
select empno,
       attrs -> 'office'  as office,
       attrs -> 'parking' as parking
from emp_attributes;

-- Check if a key exists:
select empno, attrs
from emp_attributes
where attrs ? 'parking';

-- Check if all keys exist:
select empno from emp_attributes
where attrs ?& array['office', 'badge'];

-- Filter by key=value:
select empno from emp_attributes
where attrs @> 'office=>Chicago';

-- Add/update a key:
update emp_attributes
set attrs = attrs || 'desk=>4B'::hstore
where empno = 7369;

-- Delete a key:
update emp_attributes
set attrs = delete(attrs, 'parking')
where empno = 7698;

-- Convert hstore to table of key-value rows:
select empno, (each(attrs)).key, (each(attrs)).value
from emp_attributes
order by empno, key;

-- hstore → JSON (easy bridge to JSONB world):
select empno, hstore_to_jsonb(attrs) as json_attrs
from emp_attributes;

drop table if exists emp_attributes;

-------------------------------------------------
-- PART 4: pgcrypto — Password Hashing and Encryption
-------------------------------------------------
-- pgcrypto provides cryptographic functions for password storage,
-- symmetric/asymmetric encryption, and hashing.

-- Password hashing with bcrypt (secure, adaptive cost factor)
-- crypt(password, gen_salt(algorithm)) — NEVER store plain text passwords.

select crypt('my_secret_password', gen_salt('bf', 10)) as hashed;
-- bf = blowfish (bcrypt), cost factor 10 (higher = slower = more secure)

-- Verify a password (compare plain to stored hash):
select (crypt('my_secret_password', stored_hash) = stored_hash) as is_valid
from (select crypt('my_secret_password', gen_salt('bf', 10)) as stored_hash) t;

-- Practical usage in a users table:
create table if not exists app_users (
    user_id   serial primary key,
    username  text unique not null,
    pw_hash   text not null
);

insert into app_users (username, pw_hash)
values ('alice', crypt('alicepass', gen_salt('bf', 10)));

-- Login check:
select user_id, username
from app_users
where username = 'alice'
  and pw_hash = crypt('alicepass', pw_hash);   -- correct password → row returned

-- Wrong password check:
select user_id from app_users
where username = 'alice'
  and pw_hash = crypt('wrongpass', pw_hash);   -- no row returned

-------------------------------------------------

-- Hash functions (one-way):
select encode(digest('hello world', 'sha256'), 'hex') as sha256_hash;
select encode(digest('hello world', 'md5'),    'hex') as md5_hash;
-- Note: MD5 is broken for security — use SHA-256 or SHA-512 for integrity checks.

-- Symmetric encryption (AES):
select encrypt('secret data'::bytea, 'encryption_key'::bytea, 'aes') as encrypted;

-- Decrypt:
select convert_from(
    decrypt(
        encrypt('secret data'::bytea, 'encryption_key'::bytea, 'aes'),
        'encryption_key'::bytea,
        'aes'
    ),
    'UTF8'
) as decrypted;

drop table if exists app_users;

-------------------------------------------------
-- PART 5: tablefunc — CROSSTAB (True SQL PIVOT)
-------------------------------------------------
-- crosstab() converts rows into columns — a true PIVOT.
-- More reliable than manual CASE-based pivoting (Ch11) for dynamic categories.

-- Setup: sales by department and job
create table if not exists dept_job_sal (
    deptno  integer,
    job     text,
    avg_sal numeric
);

insert into dept_job_sal
select deptno, job, round(avg(sal), 0)
from emp
group by deptno, job
order by deptno, job;

-- Pivot: departments as rows, jobs as columns
select *
from crosstab(
    -- Source query: must return (row_name, category, value)
    'select deptno::text, job, avg_sal
     from dept_job_sal
     order by 1, 2',
    -- Category list (column names for pivoted columns):
    'select distinct job from dept_job_sal order by 1'
) as ct (
    deptno  text,
    analyst numeric,
    clerk   numeric,
    manager numeric,
    president numeric,
    salesman  numeric
);

drop table if exists dept_job_sal;

-------------------------------------------------
-- PART 6: PostGIS — Geospatial Queries (Overview)
-------------------------------------------------
-- PostGIS adds geographic data types (POINT, POLYGON, LINESTRING),
-- spatial functions, and spatial indexes to PostgreSQL.
-- Most commonly used for: store locators, delivery routing, geo-fencing,
-- mapping applications.

-- NOTE: PostGIS requires a separate installation.
-- create extension if not exists postgis;

-- Example (conceptual — requires PostGIS installed):
-- CREATE TABLE locations (
--     id    serial primary key,
--     name  text,
--     geom  geometry(Point, 4326)  -- 4326 = WGS84 (GPS coordinates)
-- );
--
-- INSERT INTO locations (name, geom) VALUES
-- ('New York',  ST_SetSRID(ST_MakePoint(-74.0060, 40.7128), 4326)),
-- ('London',    ST_SetSRID(ST_MakePoint(-0.1276,  51.5074), 4326)),
-- ('Tokyo',     ST_SetSRID(ST_MakePoint(139.6917, 35.6895), 4326));
--
-- -- Distance between two points (in degrees; use ST_Distance with geography type for meters):
-- SELECT ST_Distance(
--     ST_SetSRID(ST_MakePoint(-74.0060, 40.7128), 4326)::geography,
--     ST_SetSRID(ST_MakePoint(-0.1276,  51.5074), 4326)::geography
-- ) / 1000 AS distance_km;
--
-- -- Find all locations within 1000km of New York:
-- SELECT name FROM locations
-- WHERE ST_DWithin(
--     geom::geography,
--     ST_SetSRID(ST_MakePoint(-74.0060, 40.7128), 4326)::geography,
--     1000000   -- metres
-- );
--
-- -- Spatial index (essential for performance):
-- CREATE INDEX idx_locations_geom ON locations USING gist(geom);

-------------------------------------------------
-- PART 7: Discovering the Ecosystem
-------------------------------------------------

-- Find all available extensions on your PostgreSQL install:
select name,
       default_version,
       installed_version,
       left(comment, 60) as description
from pg_available_extensions
order by name;

-- Popular extensions you should know about:
-- pg_trgm           — trigram similarity + fast LIKE search
-- uuid-ossp         — UUID generation
-- pgcrypto          — cryptographic functions
-- hstore            — key-value column type
-- tablefunc         — crosstab / pivot
-- pg_stat_statements— query statistics (install on every production DB)
-- pg_partman        — partition management automation
-- timescaledb       — time-series optimisation (external)
-- PostGIS           — geospatial (external)
-- pg_cron           — schedule SQL jobs inside PostgreSQL
-- plpgsql_check     — static analysis for PL/pgSQL code
-- pgjwt             — JSON Web Token (JWT) generation
-- pg_audit          — detailed audit logging

-------------------------------------------------

-- Clean up extensions created in this chapter
-- (leave pg_trgm installed — useful for future work)
-- drop extension if exists "uuid-ossp";
-- drop extension if exists hstore;
-- drop extension if exists pgcrypto;
-- drop extension if exists tablefunc;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Install pg_stat_statements on EVERY production database.
--    It has near-zero overhead and is the fastest way to find slow queries.

-- 2. Use gen_random_uuid() (built-in PG 13+) instead of uuid-ossp
--    for random UUIDs — no extension needed.

-- 3. NEVER store plain-text passwords. Use pgcrypto's crypt() with bcrypt
--    (gen_salt('bf', 10)) — the cost factor makes brute-force impractical.

-- 4. Use pg_trgm + GIN index for any LIKE '%pattern%' or fuzzy matching.
--    B-tree indexes cannot help with leading wildcards.

-- 5. Use tablefunc crosstab() for dynamic pivots instead of manual CASE.
--    CASE-based pivots require hardcoding each category in the query.

-- 6. JSONB has largely replaced hstore for new projects.
--    hstore is still useful for simple flat key-value structures
--    or legacy systems where JSONB wasn't available.

-- 7. Extensions are schema-aware — create them in a dedicated schema
--    (e.g., extensions) to keep public clean:
--    create schema if not exists extensions;
--    create extension pg_trgm schema extensions;
