-------------------------------------------------
-- CHAPTER 5
-- Metadata Queries
-------------------------------------------------

-- List all schemas in database
select schema_name
from information_schema.schemata
order by schema_name;

-------------------------------------------------

-- List all views in a schema
select table_name
from information_schema.views
where table_schema = 'public';

-------------------------------------------------

-- Get view definition
select viewname, definition
from pg_views
where schemaname = 'public';

-------------------------------------------------

-- List all sequences
select sequence_name
from information_schema.sequences
where sequence_schema = 'public';

-------------------------------------------------

-- Find primary key columns of a table
select
    kcu.column_name
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
     on tc.constraint_name = kcu.constraint_name
     and tc.table_schema = kcu.table_schema
where tc.constraint_type = 'PRIMARY KEY'
and tc.table_name = 'emp';

-------------------------------------------------

-- Find foreign keys for a table
select
    tc.constraint_name,
    kcu.column_name,
    ccu.table_name as foreign_table,
    ccu.column_name as foreign_column
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
     on tc.constraint_name = kcu.constraint_name
join information_schema.constraint_column_usage ccu
     on ccu.constraint_name = tc.constraint_name
where tc.constraint_type = 'FOREIGN KEY'
and tc.table_name = 'emp';

-------------------------------------------------

-- List indexes for a table (detailed)
select
    schemaname,
    tablename,
    indexname,
    indexdef
from pg_indexes
where tablename = 'emp';

-------------------------------------------------

-- Find tables without primary key
select table_name
from information_schema.tables t
where table_schema = 'public'
and not exists (
    select 1
    from information_schema.table_constraints tc
    where tc.table_name = t.table_name
    and tc.constraint_type = 'PRIMARY KEY'
);

-------------------------------------------------

-- Find tables larger than certain size
select
    relname as table_name,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size
from pg_catalog.pg_statio_user_tables
order by pg_total_relation_size(relid) desc;

-------------------------------------------------

-- Get row count estimate for tables
select
    relname as table_name,
    n_live_tup as estimated_rows
from pg_stat_user_tables
order by estimated_rows desc;

-------------------------------------------------

-- Find tables that were recently modified
select
    relname as table_name,
    n_tup_ins,
    n_tup_upd,
    n_tup_del
from pg_stat_user_tables
order by (n_tup_ins + n_tup_upd + n_tup_del) desc;

-------------------------------------------------

-- Find unused indexes
select
    relname as table_name,
    indexrelname as index_name,
    idx_scan
from pg_stat_user_indexes
where idx_scan = 0;

-------------------------------------------------

-- Get column default values
select
    column_name,
    column_default
from information_schema.columns
where table_name = 'emp';

-------------------------------------------------

-- Find nullable columns in a table
select column_name
from information_schema.columns
where table_name = 'emp'
and is_nullable = 'YES';

-------------------------------------------------

-- Find columns with specific data type
select table_name, column_name
from information_schema.columns
where data_type = 'timestamp without time zone';

-------------------------------------------------

-- Find tables containing a specific column name
select table_name
from information_schema.columns
where column_name = 'deptno';

-------------------------------------------------

-- Generate DROP TABLE statements
select 'drop table if exists ' || table_name || ' cascade;'
from information_schema.tables
where table_schema = 'public';

-------------------------------------------------

-- Generate TRUNCATE statements
select 'truncate table ' || table_name || ';'
from information_schema.tables
where table_schema = 'public';

-------------------------------------------------

-- Generate SELECT queries for all tables
select 'select * from ' || table_name || ' limit 10;'
from information_schema.tables
where table_schema = 'public';

-------------------------------------------------

-- Find triggers defined in a schema
select tgname as trigger_name,
       relname as table_name
from pg_trigger t
join pg_class c
on t.tgrelid = c.oid
where not t.tgisinternal;

-------------------------------------------------

-- List functions in database
select proname as function_name
from pg_proc
join pg_namespace n
on pg_proc.pronamespace = n.oid
where n.nspname = 'public';

-------------------------------------------------

-- Best Practice Notes
-------------------------------------------------

-- 1. information_schema views are ANSI standard
--    and portable across databases.

-- 2. pg_catalog contains PostgreSQL internal metadata
--    and provides deeper system information.

-- 3. Use pg_stat_* views to analyze database activity
--    and performance statistics.

-- 4. Metadata queries are extremely useful for:
--      - database documentation
--      - automation scripts
--      - migration tools
--      - schema auditing

-- 5. "Using SQL to generate SQL" is a powerful technique
--    for batch operations across many tables.