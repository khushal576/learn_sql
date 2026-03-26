-------------------------------------------------
-- CHAPTER 4
-- Inserting, Updating, and Deleting
-------------------------------------------------
-- This chapter covers all DML (Data Manipulation Language) operations:
-- INSERT (single, multi-row, SELECT-based), UPDATE (simple, CASE, subquery,
-- JOIN-style), DELETE (filtered, join-based, duplicate removal), TRUNCATE,
-- UPSERT with ON CONFLICT, and the RETURNING clause.
-- Always test destructive statements with SELECT first.

-------------------------------------------------

-- Insert multiple rows in one statement
insert into dept (deptno, dname, loc)
values
    (60, 'AI', 'SAN JOSE'),
    (70, 'DATA', 'SEATTLE');

-------------------------------------------------

-- Insert rows without specifying column list
-- Only safe when values match exact table structure
insert into dept
values (80, 'SECURITY', 'AUSTIN');

-- Best practice:
-- Always specify column names in INSERT statements.

-------------------------------------------------

-- Insert data generated from expressions
insert into dept (deptno, dname, loc)
values (90, upper('research'), 'LONDON');

-------------------------------------------------

-- Insert rows using SELECT from another table
insert into dept_east (deptno, dname, loc)
select deptno, dname, loc
from dept
where deptno > 30;

-------------------------------------------------

-- Create a table with data copied from another table
create table dept_backup
as
select *
from dept;

-------------------------------------------------

-- Insert data into table with sequence (PostgreSQL)
-- useful for auto increment keys

insert into emp (empno, ename, job, sal, deptno)
values (nextval('emp_seq'), 'JOHN', 'ANALYST', 3000, 20);

-------------------------------------------------

-- Update multiple columns
update emp
set sal = sal * 1.05,
    comm = 500
where job = 'SALESMAN';

-------------------------------------------------

-- Update using CASE expression
update emp
set sal =
    case
        when sal < 2000 then sal * 1.20
        when sal between 2000 and 4000 then sal * 1.10
        else sal
    end;

-------------------------------------------------

-- Update using subquery
update emp
set sal = (
    select avg(sal)
    from emp
)
where deptno = 10;

-------------------------------------------------

-- Update only rows matching another table
update emp e
set sal = ns.sal
from new_sal ns
where e.deptno = ns.deptno;

-------------------------------------------------

-- Update with LIMIT pattern (PostgreSQL workaround)
-- Example: update first 5 rows only

update emp
set sal = sal * 1.02
where empno in (
    select empno
    from emp
    order by empno
    limit 5
);

-------------------------------------------------

-- Delete rows using subquery
delete from emp
where deptno in (
    select deptno
    from dept
    where loc = 'CHICAGO'
);

-------------------------------------------------

-- Delete rows using join
delete from emp
using dept
where emp.deptno = dept.deptno
and dept.loc = 'NEW YORK';

-------------------------------------------------

-- Delete duplicates using ROW_NUMBER
-- keeps first record and removes others

delete from dupes
where id in (
    select id
    from (
        select id,
               row_number() over (partition by name order by id) as rn
        from dupes
    ) x
    where rn > 1
);

-------------------------------------------------

-- Delete all rows quickly
truncate table emp_commission;

-- TRUNCATE is faster than DELETE
-- but cannot be rolled back in some systems.

-------------------------------------------------

-- Safe delete practice
-- always check rows before deleting

select *
from emp
where deptno = 10;

delete from emp
where deptno = 10;

-------------------------------------------------

-- Returning modified rows (PostgreSQL feature)

update emp
set sal = sal * 1.05
where deptno = 30
returning empno, ename, sal;

-------------------------------------------------

-- Insert if not exists pattern

insert into dept (deptno, dname, loc)
select 100, 'CLOUD', 'DALLAS'
where not exists (
    select 1
    from dept
    where deptno = 100
);

-------------------------------------------------

-- Upsert using ON CONFLICT (PostgreSQL)

insert into dept (deptno, dname, loc)
values (10, 'ACCOUNTING', 'NEW YORK')
on conflict (deptno)
do update set
    dname = excluded.dname,
    loc   = excluded.loc;

-------------------------------------------------

-- Copy table structure including constraints (PostgreSQL)

create table dept_clone (like dept including all);

-------------------------------------------------

-- DELETE … RETURNING (PostgreSQL)
-- Returns the deleted rows, useful for audit trails or move-and-archive.

delete from emp_commission
where empno in (7369, 7499)
returning empno, ename, comm;

-- Equivalent pattern: INSERT INTO archive SELECT ... + DELETE in one step
-- Use a transaction to keep both atomic.

-------------------------------------------------

-- MERGE statement (PostgreSQL 15+)
-- Combines INSERT, UPDATE, DELETE into a single idempotent operation.
-- Commonly used for ETL / data synchronisation.

-- merge into dept as target
-- using (values (10, 'ACCOUNTING', 'BOSTON')) as source(deptno, dname, loc)
-- on target.deptno = source.deptno
-- when matched then
--     update set dname = source.dname, loc = source.loc
-- when not matched then
--     insert (deptno, dname, loc) values (source.deptno, source.dname, source.loc);

-- Note: PostgreSQL 15+ only. Use ON CONFLICT for earlier versions (see UPSERT above).

-------------------------------------------------

-- Best Practice Notes
-------------------------------------------------

-- 1. Always test UPDATE and DELETE with SELECT first.

-- 2. Use transactions when modifying large datasets.
-- Example:
-- BEGIN;
-- UPDATE ...
-- DELETE ...
-- COMMIT; -- or ROLLBACK if something looks wrong

-- 3. Always specify column list in INSERT statements.

-- 4. Use TRUNCATE only when you want to remove all rows quickly.
--    TRUNCATE cannot be filtered — it removes every row.

-- 5. Use ON CONFLICT for upserts (PostgreSQL < 15).
--    Use MERGE for more complex upsert logic (PostgreSQL 15+).

-- 6. Avoid deleting duplicates using NOT IN if the table contains NULL values.
--    Prefer the ROW_NUMBER() approach for reliability.

-- 7. Use RETURNING to capture modified rows without a second query.
--    Great for audit logging, returning generated IDs, or move-and-archive patterns.