-------------------------------------------------
-- CHAPTER 14
-- Transactions, Views, and Constraints
-------------------------------------------------
-- This chapter covers three pillars of production SQL:
--
-- TRANSACTIONS: grouping statements into atomic units (ACID),
--   BEGIN/COMMIT/ROLLBACK, SAVEPOINTs, and isolation levels.
--
-- VIEWS & MATERIALIZED VIEWS: virtual tables over queries,
--   when to use each, updating through views, and refreshing.
--
-- CONSTRAINTS: enforcing data integrity at the database level —
--   PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK, NOT NULL.
--
-- All three topics are heavily tested in intermediate SQL interviews.

-------------------------------------------------
-- PART 1: TRANSACTIONS
-------------------------------------------------

-- A transaction groups multiple SQL statements into one atomic unit.
-- Either ALL statements succeed (COMMIT) or ALL are rolled back (ROLLBACK).
-- This is the A in ACID: Atomicity.

-- Basic transaction pattern
begin;

update emp set sal = sal * 1.10 where deptno = 20;
update emp set sal = sal * 1.05 where deptno = 30;

commit;   -- both updates are permanently saved together

-- If something goes wrong, rollback both:
begin;

update emp set sal = 9999 where deptno = 10;  -- accidental update
rollback;                                       -- undoes EVERYTHING since BEGIN

-- After ROLLBACK, salaries in dept 10 are unchanged.

-------------------------------------------------

-- SAVEPOINT — partial rollback within a transaction
-- Allows rolling back to a specific point without aborting the whole transaction.

begin;

update emp set sal = sal * 1.10 where deptno = 10;
savepoint after_dept10;

update emp set sal = sal * 1.10 where deptno = 20;
savepoint after_dept20;

update emp set sal = 0 where deptno = 30;  -- mistake!

rollback to savepoint after_dept20;  -- undo only the dept 30 update

-- Dept 10 and dept 20 updates are still in the transaction.
update emp set sal = sal * 1.05 where deptno = 30;  -- correct update

commit;

-- RELEASE SAVEPOINT frees the savepoint without rolling back:
-- release savepoint after_dept10;

-------------------------------------------------

-- Transaction as a safety net for destructive operations
-- Always wrap DELETE/UPDATE in a transaction, verify, then commit.

begin;

-- Preview what will be deleted
select * from emp where deptno = 40;

-- Delete it
delete from emp where deptno = 40;

-- Check row count to verify
select count(*) from emp;

-- If satisfied:
commit;
-- If not:
-- rollback;

-------------------------------------------------

-- ACID properties (interview theory)

-- A — Atomicity:    all statements in a transaction succeed or all fail.
-- C — Consistency:  transaction brings DB from one valid state to another.
-- I — Isolation:    concurrent transactions do not interfere with each other.
-- D — Durability:   committed data survives crashes (written to disk/WAL).

-------------------------------------------------

-- Isolation levels — controls what concurrent transactions can see
-- Set per-transaction with: SET TRANSACTION ISOLATION LEVEL ...

-- PostgreSQL supports 4 isolation levels:

begin;
set transaction isolation level read committed;   -- default in PostgreSQL
-- Can see data committed by OTHER transactions during this transaction.
-- Prevents dirty reads. Does NOT prevent non-repeatable reads.
commit;

begin;
set transaction isolation level repeatable read;
-- Snapshot taken at first statement. Same query returns same result
-- throughout the transaction. Prevents non-repeatable reads.
-- Does NOT prevent phantom reads in some databases (PostgreSQL prevents them here).
commit;

begin;
set transaction isolation level serializable;
-- Strictest level. Transactions behave as if run one at a time.
-- Prevents all anomalies. May cause serialisation failures (retry needed).
commit;

-- Summary of anomalies each level prevents:
-- Level               | Dirty Read | Non-repeatable | Phantom
-- READ COMMITTED       | prevented  | possible       | possible
-- REPEATABLE READ      | prevented  | prevented      | prevented (PG)
-- SERIALIZABLE         | prevented  | prevented      | prevented

-------------------------------------------------

-- Deadlock — two transactions waiting for each other's locks
-- PostgreSQL detects deadlocks and aborts one transaction automatically.

-- Transaction A:                 Transaction B:
-- BEGIN;                         BEGIN;
-- UPDATE emp SET ... WHERE empno = 7369;
--                                UPDATE emp SET ... WHERE empno = 7499;
-- UPDATE emp SET ... WHERE empno = 7499;  ← waits for B
--                                UPDATE emp SET ... WHERE empno = 7369;  ← waits for A
-- DEADLOCK detected → one is killed, other proceeds.

-- Prevention: always lock rows in the same order in all transactions.

-------------------------------------------------
-- PART 2: VIEWS
-------------------------------------------------

-- A VIEW is a stored SELECT statement — a virtual table.
-- No data is physically stored; the query runs each time the view is accessed.

-- Create a view for active employees (non-null salary, in valid departments)
create view v_emp_detail as
select e.empno,
       e.ename,
       e.job,
       e.sal,
       e.hiredate,
       d.dname,
       d.loc
from emp e
join dept d on e.deptno = d.deptno;

-- Use the view like a table:
select * from v_emp_detail where loc = 'DALLAS';
select dname, count(*), avg(sal) from v_emp_detail group by dname;

-------------------------------------------------

-- Create a view for high earners
create view v_high_earners as
select ename, sal, deptno
from emp
where sal >= 3000;

select * from v_high_earners;

-------------------------------------------------

-- Updatable view — simple views (single table, no aggregation)
-- can be updated through the view.

create view v_dept10 as
select empno, ename, sal
from emp
where deptno = 10;

-- This UPDATE goes through the view and affects the base table:
update v_dept10 set sal = sal * 1.05 where ename = 'CLARK';

-- SELECT through view to verify:
select * from v_dept10;

-------------------------------------------------

-- WITH CHECK OPTION — prevents inserts/updates that violate the view's WHERE

create view v_dept20_safe as
select empno, ename, sal, deptno
from emp
where deptno = 20
with check option;

-- This insert would succeed (deptno = 20):
-- insert into v_dept20_safe (empno, ename, sal, deptno)
-- values (9999, 'TESTER', 2000, 20);

-- This would FAIL (deptno = 30 violates the view's WHERE deptno = 20):
-- insert into v_dept20_safe (empno, ename, sal, deptno)
-- values (9998, 'SNEAKY', 2000, 30);

-------------------------------------------------

-- Listing and dropping views

-- List all views in public schema:
select table_name
from information_schema.views
where table_schema = 'public';

-- Drop a view:
drop view if exists v_high_earners;

-------------------------------------------------

-- MATERIALIZED VIEW
-- Unlike a regular view, a materialised view STORES the query result physically.
-- Must be manually REFRESHED to pick up new data.
-- Use when the query is expensive and you can tolerate slightly stale data.

create materialized view mv_dept_summary as
select d.dname,
       count(e.empno)     as headcount,
       round(avg(e.sal), 2) as avg_sal,
       sum(e.sal)          as total_sal
from dept d
left join emp e on d.deptno = e.deptno
group by d.dname
order by d.dname;

-- Query it like a table (uses stored data, not live query):
select * from mv_dept_summary;

-- Refresh when underlying data changes:
refresh materialized view mv_dept_summary;

-- Refresh without locking (allows reads during refresh — PostgreSQL 9.4+):
-- Requires a unique index on the materialised view.
create unique index idx_mv_dept on mv_dept_summary(dname);
refresh materialized view concurrently mv_dept_summary;

-------------------------------------------------

-- View vs Materialised View — when to use each

-- Regular VIEW:
--   + Always shows current data (live query)
--   + No extra storage
--   - Query runs every time — expensive for complex queries

-- Materialised View:
--   + Stored result — very fast reads
--   + Can be indexed like a real table
--   - Data is stale until REFRESH is run
--   - Uses extra storage
--   Best for: dashboards, reports, pre-aggregated summaries

-------------------------------------------------
-- PART 3: CONSTRAINTS
-------------------------------------------------

-- Constraints enforce data integrity at the database level.
-- They are checked on every INSERT, UPDATE, and (for FK) DELETE.

-------------------------------------------------

-- PRIMARY KEY constraint
-- Uniquely identifies each row. Implies NOT NULL + UNIQUE.
-- Creates a B-tree index automatically.

create table dept_constrained (
    deptno  integer     primary key,
    dname   varchar(14) not null,
    loc     varchar(13)
);

-- Composite primary key (spanning two columns):
create table emp_project (
    empno   integer,
    proj_id integer,
    role    varchar(20),
    primary key (empno, proj_id)
);

-------------------------------------------------

-- FOREIGN KEY constraint
-- Ensures referential integrity: every value must exist in the parent table.

create table emp_constrained (
    empno   integer     primary key,
    ename   varchar(10) not null,
    deptno  integer     references dept_constrained(deptno)
    -- ON DELETE CASCADE  → delete employee when dept is deleted
    -- ON DELETE SET NULL → set deptno to NULL when dept is deleted
    -- ON DELETE RESTRICT → block deletion of dept if employees exist (default)
);

-- Test: try inserting an employee for a non-existent department
-- insert into emp_constrained values (1, 'TEST', 99);
-- ERROR: insert or update on table "emp_constrained" violates foreign key constraint

-------------------------------------------------

-- UNIQUE constraint
-- Ensures all values in a column (or combination) are distinct.
-- Allows NULLs (multiple NULLs are allowed — they are not equal to each other).

alter table emp add constraint uq_emp_ename unique (ename);

-- Test uniqueness:
-- insert into emp (empno, ename, deptno) values (9000, 'SMITH', 10);
-- ERROR: duplicate key value violates unique constraint

-- Remove the constraint:
alter table emp drop constraint uq_emp_ename;

-------------------------------------------------

-- CHECK constraint
-- Validates that column values meet a custom condition.

create table salary_bands (
    id      serial      primary key,
    ename   varchar(20) not null,
    sal     numeric     check (sal > 0),                 -- must be positive
    grade   char(1)     check (grade in ('A','B','C')),  -- allowed values
    bonus_pct numeric   check (bonus_pct between 0 and 100)
);

-- Multi-column CHECK constraint (table-level):
create table emp_audit (
    empno     integer,
    start_dt  date,
    end_dt    date,
    check (end_dt > start_dt)   -- end must be after start
);

-- Add a CHECK to an existing table:
alter table emp add constraint chk_sal_positive check (sal > 0);

-- Remove it:
alter table emp drop constraint chk_sal_positive;

-------------------------------------------------

-- NOT NULL constraint
-- Prevents NULL values in a column.

alter table emp alter column ename set not null;

-- Remove:
alter table emp alter column ename drop not null;

-------------------------------------------------

-- Viewing constraints on a table

select constraint_name,
       constraint_type,
       table_name
from information_schema.table_constraints
where table_name in ('emp', 'dept')
  and table_schema = 'public'
order by constraint_type;

-------------------------------------------------

-- DEFERRABLE constraints (interview topic)
-- By default, constraints are checked immediately after each statement.
-- DEFERRABLE INITIALLY DEFERRED delays the check to end of transaction.
-- Useful when inserting mutually-referencing rows.

create table parent_demo (
    id      integer primary key
);

create table child_demo (
    id        integer primary key,
    parent_id integer references parent_demo(id)
        deferrable initially deferred
);

begin;
-- Insert child first (FK check is deferred until COMMIT)
insert into child_demo values (1, 99);
-- Insert parent second
insert into parent_demo values (99);
commit;
-- FK check passes at commit time — both rows exist.

-------------------------------------------------

-- Clean up objects created in this chapter
drop materialized view if exists mv_dept_summary;
drop view if exists v_emp_detail;
drop view if exists v_dept10;
drop view if exists v_dept20_safe;
drop table if exists salary_bands;
drop table if exists emp_audit;
drop table if exists child_demo;
drop table if exists parent_demo;
drop table if exists emp_project;
drop table if exists emp_constrained;
drop table if exists dept_constrained;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- TRANSACTIONS
-- 1. Wrap all multi-statement data modifications in a transaction.
--    A partial failure without a transaction leaves data in an inconsistent state.
-- 2. Keep transactions short — long-running transactions hold locks
--    and block other sessions.
-- 3. Use SAVEPOINT when you want selective rollback within a complex workflow.
-- 4. Default isolation level (READ COMMITTED) is fine for most OLTP work.
--    Use SERIALIZABLE only when strict consistency is required.

-- VIEWS
-- 5. Use views to simplify complex queries and enforce consistent column selection.
-- 6. Use materialised views for expensive aggregations that are queried frequently
--    and can tolerate stale data (e.g., daily reporting dashboards).
-- 7. Always add a unique index to a materialised view before using
--    REFRESH MATERIALIZED VIEW CONCURRENTLY.

-- CONSTRAINTS
-- 8. Declare PRIMARY KEY on every table — it enforces uniqueness and
--    creates the primary index automatically.
-- 9. Declare FOREIGN KEY constraints to let the database enforce referential
--    integrity instead of relying on application code.
-- 10. Use CHECK constraints to encode business rules (positive salary, valid status)
--     directly in the schema — they are enforced on every write path.
-- 11. UNIQUE constraints allow multiple NULLs — NULLs are not considered equal.
--     Use a partial unique index if you need "at most one NULL" semantics.
