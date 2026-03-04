---------------------------------------------------
-- CHAPTER 5:  Metadata Queries
---------------------------------------------------

-- Listing Tables in a Schema
select table_name
from information_schema.tables
where table_schema = 'public';

-- Listing a Table’s Columns
select column_name, data_type, ordinal_position
from information_schema.columns
where table_schema = 'public'
and table_name = 'emp';

-- or more details with.
SELECT 
    column_name,
    CASE 
        WHEN data_type = 'character varying' 
            THEN 'varchar(' || character_maximum_length || ')'
        
        WHEN data_type = 'numeric' 
            THEN 'numeric(' || numeric_precision || ',' || numeric_scale || ')'
        
        ELSE data_type
    END AS data_type,
    ordinal_position
FROM information_schema.columns
WHERE table_schema = 'public'
AND table_name = 'emp'
ORDER BY ordinal_position;

-- Listing Indexed Columns for a Table
select a.tablename,a.indexname,b.column_name
from pg_catalog.pg_indexes a,
information_schema.columns b
where a.schemaname = 'public'
and a.tablename = b.table_name;

-- Listing Constraints on a Table
select a.table_name,
 a.constraint_name,
 b.column_name,
 a.constraint_type
 from information_schema.table_constraints a,
 information_schema.key_column_usage b
 where a.table_name = 'emp'
 and a.table_schema = 'public'
 and a.table_name = b.table_name
and a.table_schema = b.table_schema
and a.constraint_name = b.constraint_name;

-- Using SQL to Generate SQL
select 'select count(*) from '||table_name||';' cnts
 from information_schema.tables
 where table_schema='public';


 --------------------------------------------------------
 -- Core System Catalog Tables (pg_catalog)

-- eg. use
SELECT * FROM pg_catalog.pg_class WHERE relkind = 'r';

 -- 1. List of all databases
pg_database
-- Stores: database names, owner, encoding, permissions

-- 2. List of all tables, indexes, views, sequences
pg_class
-- Stores: relation name, type (table/index/view), size info

-- 3. Table columns
pg_attribute
-- Stores: column name, data type, position, nullability

-- 4. Data types
pg_type
-- Stores: datatype definitions (int4, varchar, numeric etc.)

-- 5. Schemas
pg_namespace
-- Stores: schema names (public, pg_catalog, custom schemas)

-- 6. Constraints
pg_constraint
-- Stores: primary key, foreign key, unique, check constraints

-- 7. Indexes
pg_index
-- Stores: index-to-table mapping and index properties

-- 8. Functions / procedures
pg_proc
-- Stores: stored procedures and functions

-- 9. Users / roles
pg_roles
-- Stores: login roles and permissions

-- 10. Privileges / access control
pg_auth_members
-- Stores: role membership

-- 11. Sequences
pg_sequence
-- Stores: sequence properties (increment, min, max)

-- 12. Triggers
pg_trigger
-- Stores: trigger definitions

-- 13. Views definition
pg_views
-- Stores: view SQL definitions

----------------------------------------------------------
-- Information Schema (ANSI Standard Metadata)

information_schema.tables
-- All tables & views

information_schema.columns
-- Column details

information_schema.table_constraints
-- PK, FK, UNIQUE, CHECK

information_schema.key_column_usage
-- Which column belongs to which constraint

information_schema.referential_constraints
-- Foreign key relationships