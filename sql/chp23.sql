-------------------------------------------------
-- CHAPTER 23
-- Custom Data Types and Advanced Constraints
-------------------------------------------------
-- PostgreSQL has a rich type system far beyond what the SQL standard requires.
-- This chapter covers types and constraints that let you model data more
-- precisely and enforce rules at the database level instead of in application code.
--
--   ENUM types         — ordered sets of labeled values
--   Array types        — multi-value columns
--   Composite types    — row-shaped column values
--   Range types        — intervals with built-in overlap logic
--   Exclusion constraints — prevent overlapping values (e.g. booking conflicts)
--   Deferrable constraints — FK checks deferred until commit
--   Generated columns  — computed columns stored on disk
--   Sequences & IDENTITY — auto-increment the right way
--   Table inheritance  — parent/child table hierarchies

-------------------------------------------------
-- PART 1: ENUM Types
-------------------------------------------------
-- An ENUM is an ordered list of allowed string values.
-- The database rejects any value not in the list — no application validation needed.
-- Stored as 4 bytes (an integer OID lookup), so very efficient.

create type job_grade as enum ('TRAINEE', 'JUNIOR', 'SENIOR', 'LEAD', 'MANAGER');

-- Using ENUM in a table
create table if not exists staff_grade (
    empno     int references emp(empno),
    grade     job_grade not null,
    reviewed  date default current_date
);

insert into staff_grade (empno, grade) values (7369, 'JUNIOR');
insert into staff_grade (empno, grade) values (7839, 'MANAGER');

-- Enum values are ordered — comparisons work naturally
select empno, grade
from staff_grade
where grade >= 'SENIOR';   -- SENIOR, LEAD, MANAGER

-- List all values in an enum type
select enumlabel, enumsortorder
from pg_enum
join pg_type on pg_type.oid = pg_enum.enumtypid
where typname = 'job_grade'
order by enumsortorder;

-- Add a new value (can specify position)
alter type job_grade add value 'PRINCIPAL' after 'LEAD';

-- Casting a text value to enum
select 'JUNIOR'::job_grade;

-- Note: you cannot remove an enum value or change its order without recreating the type.
-- Plan your enum values carefully before deploying to production.

drop table if exists staff_grade;
drop type if exists job_grade;

-------------------------------------------------
-- PART 2: Array Types
-------------------------------------------------
-- Any PostgreSQL data type can be stored as an array.
-- Arrays are useful for tags, phone numbers, or any one-to-few relationship
-- where a separate table would be excessive.

create table if not exists emp_skills (
    empno     int references emp(empno),
    skills    text[],          -- variable-length text array
    scores    integer[]        -- integer array
);

insert into emp_skills values (7369, ARRAY['SQL','Python','Excel'],   ARRAY[90, 75, 80]);
insert into emp_skills values (7499, ARRAY['SQL','Java'],             ARRAY[85, 70]);
insert into emp_skills values (7521, ARRAY['SQL','Python','R'],       ARRAY[95, 88, 92]);
insert into emp_skills values (7839, ARRAY['SQL','Leadership'],       ARRAY[99, 95]);

-- Access by index (1-based in PostgreSQL)
select empno, skills[1] as first_skill
from emp_skills;

-- Array slicing [from:to]
select empno, skills[1:2] as first_two
from emp_skills;

-- Check if array contains a value
select empno, skills
from emp_skills
where skills @> ARRAY['Python'];   -- @> means "contains"

-- ANY — check if a value matches any element in an array
select empno, skills
from emp_skills
where 'SQL' = any(skills);

-- ALL — all scores must be above threshold
select empno
from emp_skills
where 80 < all(scores);

-- unnest — expand array elements into rows
select empno, unnest(skills) as skill
from emp_skills
order by empno;

-- array_agg — reverse: collapse rows back into an array
select array_agg(ename order by ename) as all_names
from emp;

-- array_length, array_upper, cardinality
select empno,
       cardinality(skills)     as skill_count,
       array_length(skills, 1) as skill_count_alt
from emp_skills;

-- Append to an array
update emp_skills
set skills = array_append(skills, 'Git')
where empno = 7369;

-- Remove from an array
update emp_skills
set skills = array_remove(skills, 'Git')
where empno = 7369;

drop table if exists emp_skills;

-------------------------------------------------
-- PART 3: Composite Types
-------------------------------------------------
-- A composite type is a named row structure — like a struct.
-- Use it when several columns logically belong together (e.g. an address).

create type address_t as (
    street  text,
    city    text,
    country text,
    zip     text
);

create table if not exists emp_contacts (
    empno       int references emp(empno) primary key,
    home_addr   address_t,
    work_addr   address_t
);

insert into emp_contacts values (
    7369,
    ROW('123 Main St', 'New York', 'USA', '10001'),
    ROW('1 Business Ave', 'New York', 'USA', '10002')
);

-- Access a field with (col).field syntax (parentheses are required)
select empno,
       (home_addr).city    as home_city,
       (work_addr).city    as work_city
from emp_contacts;

-- Filter on a sub-field
select empno
from emp_contacts
where (home_addr).country = 'USA';

-- Update a single field inside a composite column
update emp_contacts
set home_addr.zip = '10005'
where empno = 7369;

-- Composites are also useful as function return types (see Ch15 for functions).

drop table if exists emp_contacts;
drop type if exists address_t;

-------------------------------------------------
-- PART 4: Range Types
-------------------------------------------------
-- Range types store an interval between two values with precise boundary semantics.
-- Built-in range types: int4range, int8range, numrange, daterange, tsrange, tstzrange.
-- Boundary notation: '[' = inclusive, '(' = exclusive.
--   [1,5]  → 1,2,3,4,5
--   [1,5)  → 1,2,3,4
--   (1,5)  → 2,3,4

-- Basic construction
select int4range(1, 10);           -- [1,10)  lower inclusive, upper exclusive by default
select int4range(1, 10, '[]');     -- [1,10]  both inclusive
select daterange('2024-01-01', '2024-12-31', '[]');

-- Range operators
select int4range(1,10) @> 5;      -- contains point: true
select int4range(1,10) @> int4range(3,7);  -- contains range: true
select int4range(1,5)  && int4range(3,8);  -- overlaps: true
select int4range(1,5)  -|- int4range(5,9); -- adjacent (upper of first = lower of second): true
select int4range(1,5)  * int4range(3,8);   -- intersection: [3,5)
select int4range(1,5)  + int4range(3,8);   -- union (must be contiguous or overlapping): [1,8)

-- Using ranges in a table
create table if not exists project_timeline (
    project_id  serial primary key,
    proj_name   text,
    active_period daterange
);

insert into project_timeline (proj_name, active_period) values
    ('Alpha',   daterange('2024-01-01', '2024-06-30', '[]')),
    ('Beta',    daterange('2024-04-01', '2024-09-30', '[]')),
    ('Gamma',   daterange('2024-10-01', '2025-03-31', '[]'));

-- Which projects were active on a specific date?
select proj_name
from project_timeline
where active_period @> '2024-05-15'::date;

-- Which projects overlap with a given period?
select proj_name
from project_timeline
where active_period && daterange('2024-06-01', '2024-08-01', '[]');

-- GiST index speeds up @> and && range queries
create index if not exists idx_proj_period on project_timeline using gist(active_period);

drop index if exists idx_proj_period;
drop table if exists project_timeline;

-------------------------------------------------
-- PART 5: Exclusion Constraints
-------------------------------------------------
-- Exclusion constraints prevent rows where ALL specified conditions hold simultaneously.
-- Classic use case: no two bookings for the same room in overlapping time periods.
-- Requires the btree_gist extension for GiST indexing on scalar types like integers.

create extension if not exists btree_gist;

create table if not exists room_booking (
    booking_id  serial primary key,
    room_no     integer,
    guest_name  text,
    stay        daterange,
    -- Prevent: same room AND overlapping dates
    exclude using gist (
        room_no with =,      -- room must be the same...
        stay    with &&      -- ...AND dates must overlap
    )
);

insert into room_booking (room_no, guest_name, stay) values
    (101, 'Alice', daterange('2024-07-01', '2024-07-05', '[]')),
    (101, 'Bob',   daterange('2024-07-08', '2024-07-10', '[]')),  -- OK: different dates
    (102, 'Carol', daterange('2024-07-01', '2024-07-03', '[]'));   -- OK: different room

-- This will fail — same room, overlapping dates:
-- insert into room_booking (room_no, guest_name, stay)
-- values (101, 'Dave', daterange('2024-07-04', '2024-07-09', '[]'));
-- ERROR: conflicting key value violates exclusion constraint

-- A UNIQUE constraint cannot do this — it only checks exact equality, not overlap.
-- Only exclusion constraints can express "no overlap" semantics.

drop table if exists room_booking;

-------------------------------------------------
-- PART 6: Deferrable Constraints
-------------------------------------------------
-- By default, constraint checks fire immediately after each statement.
-- DEFERRABLE constraints can be postponed until the transaction commits.
-- This is essential when you need to swap two FK-referenced values in a transaction.

create table if not exists emp_rank (
    empno  int primary key,
    rank   int unique deferrable initially deferred
);

insert into emp_rank values (7369, 1), (7499, 2), (7521, 3);

-- Swap ranks 1 and 2 — would fail if the unique check ran after each statement
-- because rank=1 would exist twice momentarily.
begin;
    -- With DEFERRABLE INITIALLY DEFERRED the unique check waits until COMMIT
    update emp_rank set rank = 1 where empno = 7499;
    update emp_rank set rank = 2 where empno = 7369;
commit;

select * from emp_rank order by rank;

-- You can also override deferral mode within a transaction:
-- SET CONSTRAINTS emp_rank_rank_key IMMEDIATE;  -- check right now
-- SET CONSTRAINTS emp_rank_rank_key DEFERRED;   -- check at commit

-- DEFERRABLE INITIALLY IMMEDIATE is the safer default:
-- it checks immediately but lets you opt-in to deferred mode per-transaction.

drop table if exists emp_rank;

-------------------------------------------------
-- PART 7: Generated Columns
-------------------------------------------------
-- A generated column computes its value automatically from other columns.
-- STORED means the value is calculated on INSERT/UPDATE and saved to disk.
-- PostgreSQL supports STORED generated columns (not VIRTUAL).

create table if not exists emp_extended (
    empno       int        primary key,
    ename       text,
    sal         numeric(7,2),
    comm        numeric(7,2) default 0,
    annual_sal  numeric(9,2) generated always as (sal * 12 + coalesce(comm, 0)) stored,
    sal_band    text        generated always as (
                    case
                        when sal < 1500 then 'LOW'
                        when sal < 3000 then 'MID'
                        else 'HIGH'
                    end
                ) stored
);

insert into emp_extended (empno, ename, sal, comm)
select empno, ename, sal, coalesce(comm, 0) from emp;

-- Generated columns are computed automatically — never supply them in INSERT/UPDATE
select empno, ename, sal, annual_sal, sal_band
from emp_extended
order by sal desc;

-- Generated columns cannot reference other generated columns.
-- They cannot have a DEFAULT clause (the expression IS the default).

drop table if exists emp_extended;

-------------------------------------------------
-- PART 8: Sequences and IDENTITY Columns
-------------------------------------------------
-- Auto-incrementing primary keys are fundamental. PostgreSQL offers three approaches,
-- from legacy to modern. Prefer IDENTITY for new tables.

-- APPROACH 1: SERIAL (legacy syntactic sugar — avoid in new code)
-- SERIAL creates a sequence behind the scenes and wires it to the column default.
-- The sequence is owned separately, which can cause surprises during dumps/restores.
create table if not exists serial_demo (
    id    serial primary key,
    name  text
);
insert into serial_demo (name) values ('Alice'), ('Bob');
select * from serial_demo;
drop table if exists serial_demo;

-- APPROACH 2: Manual SEQUENCE (useful when you need fine-grained control)
create sequence if not exists order_seq
    start with 1000
    increment by 1
    no maxvalue
    cache 5;           -- cache 5 values per session for performance

select nextval('order_seq');   -- 1000
select nextval('order_seq');   -- 1001
select currval('order_seq');   -- current value in this session
select lastval();              -- last value returned by any sequence in this session
select setval('order_seq', 2000);  -- jump the sequence to 2000

-- Inspect sequence state
select * from order_seq;   -- shows last_value, log_cnt, is_called

drop sequence if exists order_seq;

-- APPROACH 3: IDENTITY columns (SQL standard, preferred in PostgreSQL 10+)
-- GENERATED ALWAYS  — cannot override with explicit values (safer)
-- GENERATED BY DEFAULT — can override (useful for migrations/data loads)

create table if not exists orders (
    order_id    int generated always as identity primary key,
    customer    text,
    amount      numeric(10,2)
);

insert into orders (customer, amount) values
    ('Alice', 150.00),
    ('Bob',   320.50),
    ('Carol',  75.00);

select * from orders;

-- Restart the sequence if needed (e.g. after truncating a table)
alter table orders alter column order_id restart with 1;

-- GENERATED BY DEFAULT allows explicit values (useful for migrations)
create table if not exists orders_migrate (
    order_id    int generated by default as identity primary key,
    customer    text
);
-- Override is allowed with GENERATED BY DEFAULT:
insert into orders_migrate (order_id, customer) values (999, 'Legacy Row');
insert into orders_migrate (customer) values ('New Row');  -- auto-generates

drop table if exists orders;
drop table if exists orders_migrate;

-- bigserial / bigint identity — use when you expect more than 2 billion rows
create table if not exists events (
    event_id  bigint generated always as identity primary key,
    event_ts  timestamptz default now(),
    payload   text
);
drop table if exists events;

-------------------------------------------------
-- PART 9: Table Inheritance
-------------------------------------------------
-- Table inheritance lets a child table inherit columns from a parent.
-- Useful for "type hierarchies" but largely replaced by declarative partitioning (Ch18).
-- Included here for completeness — you may encounter it in older codebases.

create table if not exists employee_base (
    empno   int primary key,
    ename   text,
    sal     numeric(7,2)
);

create table if not exists manager_emp (
    dept_budget  numeric(10,2)
) inherits (employee_base);

create table if not exists clerk_emp (
    typing_speed  int   -- words per minute
) inherits (employee_base);

insert into employee_base values (9001, 'Generic', 1500.00);
insert into manager_emp  values (9002, 'Boss', 5000.00, 100000.00);
insert into clerk_emp    values (9003, 'Typist', 900.00, 65);

-- Querying the parent includes rows from all child tables
select empno, ename, sal from employee_base;     -- returns 9001, 9002, 9003

-- ONLY keyword restricts to the parent table only
select empno, ename, sal from only employee_base;  -- returns only 9001

-- Check which table each row physically lives in
select tableoid::regclass as source_table, empno, ename
from employee_base;

-- Note: Unique constraints and foreign keys on the parent do NOT propagate to children.
-- Primary keys must be managed carefully in inheritance hierarchies.
-- For range/list/hash data splitting, use PARTITION BY (Ch18) instead.

drop table if exists clerk_emp;
drop table if exists manager_emp;
drop table if exists employee_base;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Prefer ENUM over free-text columns when the set of values is small and stable.
--    Misspellings are impossible, sorting is meaningful, storage is efficient.

-- 2. Use ARRAY columns for small, fixed-purpose lists (tags, phone numbers).
--    For large or frequently queried sets, a normalised child table is better.

-- 3. Use Composite types to group logically related fields (address, money+currency).
--    Access sub-fields with (col).field — the outer parentheses are required.

-- 4. Range types + exclusion constraints are the correct way to prevent booking conflicts.
--    A UNIQUE constraint cannot express "no overlap" — only exclusion constraints can.

-- 5. Use GENERATED ALWAYS AS IDENTITY for new primary keys.
--    Avoid SERIAL — it creates hidden sequence coupling that surprises pg_dump users.

-- 6. DEFERRABLE INITIALLY DEFERRED is ideal when you need to swap FK-referenced values
--    in a single transaction. Use INITIALLY IMMEDIATE as the safer default otherwise.

-- 7. Generated columns remove a class of data-consistency bugs:
--    computed values stay correct even if someone updates sal directly.

-- 8. Prefer declarative partitioning (CREATE TABLE ... PARTITION BY) over inheritance
--    for data splitting. Partitioning has better optimizer support and tooling.
