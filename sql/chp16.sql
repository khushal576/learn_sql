-------------------------------------------------
-- CHAPTER 16
-- Triggers and Dynamic SQL
-------------------------------------------------
-- A TRIGGER automatically fires a function in response to a table event
-- (INSERT, UPDATE, DELETE, TRUNCATE).
-- Dynamic SQL lets you build and execute SQL statements as strings at runtime —
-- essential for meta-programming, multi-tenant systems, and generic utilities.
--
-- This chapter covers: BEFORE/AFTER row and statement triggers,
-- NEW/OLD pseudo-records, INSTEAD OF triggers on views,
-- audit logging pattern, conditional triggers, EXECUTE for dynamic SQL,
-- and FORMAT with %I/%L for safe identifier/literal injection.

-------------------------------------------------
-- PART 1: TRIGGERS
-------------------------------------------------

-- Setup: audit log table (used throughout this chapter)
create table if not exists emp_audit_log (
    log_id      serial      primary key,
    empno       integer,
    ename       text,
    operation   text,          -- INSERT / UPDATE / DELETE
    old_sal     integer,
    new_sal     integer,
    changed_by  text default current_user,
    changed_at  timestamptz default now()
);

-------------------------------------------------

-- Step 1: Create the trigger FUNCTION
-- Trigger functions must return TRIGGER (not a regular type).
-- NEW = the new row (available in INSERT and UPDATE).
-- OLD = the old row (available in UPDATE and DELETE).

create or replace function trg_emp_audit()
returns trigger
language plpgsql
as $$
begin
    if tg_op = 'INSERT' then
        insert into emp_audit_log (empno, ename, operation, new_sal)
        values (new.empno, new.ename, 'INSERT', new.sal);

    elsif tg_op = 'UPDATE' then
        insert into emp_audit_log (empno, ename, operation, old_sal, new_sal)
        values (new.empno, new.ename, 'UPDATE', old.sal, new.sal);

    elsif tg_op = 'DELETE' then
        insert into emp_audit_log (empno, ename, operation, old_sal)
        values (old.empno, old.ename, 'DELETE', old.sal);
    end if;

    return new;   -- for DELETE triggers, can return OLD or NULL
end;
$$;

-------------------------------------------------

-- Step 2: Attach the trigger to the table
-- AFTER: fires after the row is changed (good for audit logs)
-- FOR EACH ROW: fires once per affected row (vs once per statement)

create or replace trigger trg_emp_changes
after insert or update or delete
on emp
for each row
execute function trg_emp_audit();

-- Test: trigger fires automatically on any DML
insert into emp (empno, ename, job, sal, deptno)
values (9001, 'TESTER', 'ANALYST', 2500, 20);

update emp set sal = 3000 where empno = 9001;

delete from emp where empno = 9001;

-- Check the audit trail:
select * from emp_audit_log order by log_id;

-------------------------------------------------

-- BEFORE trigger — modify data BEFORE it is written
-- Useful for: validation, defaulting values, normalising data.

create or replace function trg_emp_normalise()
returns trigger
language plpgsql
as $$
begin
    -- Force employee names to uppercase
    new.ename := upper(new.ename);

    -- Reject negative salaries
    if new.sal < 0 then
        raise exception 'Salary cannot be negative: %', new.sal;
    end if;

    -- Default commission to 0 for non-salesmen
    if new.job <> 'SALESMAN' then
        new.comm := 0;
    end if;

    return new;   -- MUST return NEW in BEFORE trigger to apply modifications
end;
$$;

create or replace trigger trg_emp_before_insert
before insert or update
on emp
for each row
execute function trg_emp_normalise();

-- Test:
insert into emp (empno, ename, job, sal, deptno)
values (9002, 'newperson', 'CLERK', 1200, 10);

select ename, sal, comm from emp where empno = 9002;
-- ename will be 'NEWPERSON' (normalised), comm will be 0

-- Cleanup test row:
delete from emp where empno = 9002;

-------------------------------------------------

-- Conditional trigger — WHEN clause
-- Fire the trigger only when specific columns change.

create or replace function trg_sal_change_alert()
returns trigger
language plpgsql
as $$
begin
    raise notice 'Salary changed for %: % → %', new.ename, old.sal, new.sal;
    return new;
end;
$$;

create or replace trigger trg_sal_changed
after update of sal     -- fires ONLY when sal column is updated
on emp
for each row
when (old.sal is distinct from new.sal)   -- extra guard: value actually changed
execute function trg_sal_change_alert();

-- Test: update salary → notice fires
update emp set sal = 3200 where ename = 'SCOTT';

-- Test: update a different column → trigger does NOT fire
update emp set job = 'SENIOR ANALYST' where ename = 'SCOTT';

-- Reset:
update emp set sal = 3000, job = 'ANALYST' where ename = 'SCOTT';

-------------------------------------------------

-- Statement-level trigger (FOR EACH STATEMENT)
-- Fires once per SQL statement, not per row.
-- NEW and OLD are not available at statement level.

create table if not exists emp_bulk_log (
    operation   text,
    ts          timestamptz default now(),
    exec_user   text default current_user
);

create or replace function trg_emp_bulk_log()
returns trigger
language plpgsql
as $$
begin
    insert into emp_bulk_log (operation)
    values (tg_op || ' on emp');
    return null;   -- return value is ignored for statement-level triggers
end;
$$;

create or replace trigger trg_emp_statement
after insert or update or delete
on emp
for each statement
execute function trg_emp_bulk_log();

-- One bulk UPDATE → one log row regardless of rows affected:
update emp set comm = coalesce(comm, 0) where deptno = 30;
select * from emp_bulk_log;

-------------------------------------------------

-- INSTEAD OF trigger — make a non-updatable view writable
-- Regular views with joins/aggregates cannot be updated directly.
-- INSTEAD OF redirects the DML to custom logic.

create or replace view v_emp_dept as
select e.empno,
       e.ename,
       e.sal,
       d.dname,
       d.deptno
from emp e
join dept d on e.deptno = d.deptno;

create or replace function trg_v_emp_dept_insert()
returns trigger
language plpgsql
as $$
declare
    v_deptno integer;
begin
    -- Lookup deptno from dname supplied through the view
    select deptno into v_deptno
    from dept
    where dname = new.dname;

    if not found then
        raise exception 'Department not found: %', new.dname;
    end if;

    insert into emp (empno, ename, sal, deptno)
    values (new.empno, new.ename, new.sal, v_deptno);

    return new;
end;
$$;

create or replace trigger trg_v_emp_dept_ins
instead of insert
on v_emp_dept
for each row
execute function trg_v_emp_dept_insert();

-- Now we can insert through the view:
insert into v_emp_dept (empno, ename, sal, dname)
values (9003, 'VIEWTEST', 2000, 'RESEARCH');

select * from v_emp_dept where empno = 9003;

-- Cleanup:
delete from emp where empno = 9003;

-------------------------------------------------

-- List all triggers in the database

select tgname        as trigger_name,
       relname       as table_name,
       tgenabled     as enabled
from pg_trigger t
join pg_class c on t.tgrelid = c.oid
where not t.tgisinternal
order by relname, tgname;

-------------------------------------------------

-- Dropping triggers

drop trigger if exists trg_emp_changes      on emp;
drop trigger if exists trg_emp_before_insert on emp;
drop trigger if exists trg_sal_changed      on emp;
drop trigger if exists trg_emp_statement    on emp;
drop trigger if exists trg_v_emp_dept_ins   on v_emp_dept;

-------------------------------------------------
-- PART 2: DYNAMIC SQL
-------------------------------------------------

-- Dynamic SQL builds a query string at runtime and executes it with EXECUTE.
-- Use cases: generic utilities, multi-tenant schemas, batch DDL, meta-programming.

-------------------------------------------------

-- Basic EXECUTE inside a PL/pgSQL function

create or replace function count_rows(p_table text)
returns bigint
language plpgsql
as $$
declare
    v_count bigint;
begin
    execute format('select count(*) from %I', p_table)
    into v_count;

    return v_count;
end;
$$;

select count_rows('emp');
select count_rows('dept');

-- format('%I', name) quotes the identifier safely (prevents SQL injection).
-- Never concatenate table names directly: 'select * from ' || p_table
-- → SQL injection risk if p_table = 'emp; drop table emp;'

-------------------------------------------------

-- FORMAT specifiers for dynamic SQL

-- %I → identifier (table name, column name) — quoted with double quotes if needed
-- %L → literal value — quoted with single quotes, safely escaped
-- %s → plain string substitution (no quoting — use only for trusted values)

create or replace function get_column_value(
    p_table  text,
    p_column text,
    p_empno  integer
)
returns text
language plpgsql
as $$
declare
    v_result text;
begin
    execute format(
        'select %I::text from %I where empno = %L',
        p_column, p_table, p_empno
    )
    into v_result;

    return v_result;
end;
$$;

select get_column_value('emp', 'ename', 7369);   -- SMITH
select get_column_value('emp', 'sal',   7369);   -- 800

-------------------------------------------------

-- Dynamic DDL — create a table with a dynamic name

create or replace procedure create_dept_snapshot(p_suffix text)
language plpgsql
as $$
begin
    execute format(
        'create table if not exists dept_snapshot_%I as select * from dept',
        p_suffix
    );

    raise notice 'Created table: dept_snapshot_%', p_suffix;
end;
$$;

call create_dept_snapshot('2024_q1');

-- Verify:
select * from dept_snapshot_2024_q1;

-- Cleanup:
drop table if exists dept_snapshot_2024_q1;

-------------------------------------------------

-- Dynamic WHERE clause — build filter conditions at runtime

create or replace function search_emp(
    p_deptno  integer default null,
    p_job     text    default null,
    p_min_sal integer default null
)
returns table (empno integer, ename varchar, job varchar, sal integer, deptno integer)
language plpgsql
as $$
declare
    v_sql    text := 'select empno, ename, job, sal, deptno from emp where 1=1';
    v_params text[] := '{}';
    v_n      integer := 1;
begin
    if p_deptno is not null then
        v_sql := v_sql || format(' and deptno = $%s', v_n);
        v_params := v_params || p_deptno::text;
        v_n := v_n + 1;
    end if;

    if p_job is not null then
        v_sql := v_sql || format(' and job = $%s', v_n);
        v_params := v_params || p_job;
        v_n := v_n + 1;
    end if;

    if p_min_sal is not null then
        v_sql := v_sql || format(' and sal >= $%s', v_n);
        v_params := v_params || p_min_sal::text;
        v_n := v_n + 1;
    end if;

    return query execute v_sql using
        p_deptno, p_job, p_min_sal;
end;
$$;

-- All filters:
select * from search_emp(p_deptno => 20, p_min_sal => 2000);

-- Only job filter:
select * from search_emp(p_job => 'CLERK');

-------------------------------------------------

-- EXECUTE ... USING — parameterised dynamic SQL (safe, no injection)
-- Values after USING are passed as $1, $2, ... — never concatenated.

create or replace function safe_update_sal(p_empno integer, p_new_sal integer)
returns void
language plpgsql
as $$
begin
    execute 'update emp set sal = $1 where empno = $2'
    using p_new_sal, p_empno;
end;
$$;

call safe_update_sal(7369, 900);

-------------------------------------------------

-- Clean up
drop function if exists count_rows(text);
drop function if exists get_column_value(text, text, integer);
drop procedure if exists create_dept_snapshot(text);
drop function if exists search_emp(integer, text, integer);
drop function if exists safe_update_sal(integer, integer);
drop function if exists trg_emp_audit();
drop function if exists trg_emp_normalise();
drop function if exists trg_sal_change_alert();
drop function if exists trg_emp_bulk_log();
drop function if exists trg_v_emp_dept_insert();
drop table if exists emp_audit_log;
drop table if exists emp_bulk_log;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- TRIGGERS
-- 1. BEFORE triggers can modify NEW before the row is written.
--    AFTER triggers are better for side effects like audit logging.
-- 2. Use FOR EACH ROW for per-row logic; FOR EACH STATEMENT for bulk events.
-- 3. Keep trigger functions short and focused.
--    Heavy logic in triggers makes DML slow and hard to debug.
-- 4. Use the WHEN clause to prevent unnecessary trigger fires
--    (e.g., only fire when sal actually changes).
-- 5. INSTEAD OF triggers are the standard way to make complex views writable.

-- DYNAMIC SQL
-- 6. Always use %I (FORMAT) for identifiers and %L for literal values.
--    Never concatenate user input directly into SQL strings — SQL injection risk.
-- 7. Use EXECUTE ... USING $1, $2 for parameterised values.
--    This is both safe and avoids repeated query planning.
-- 8. Avoid dynamic SQL when static SQL works — it is harder to debug,
--    not type-checked at compile time, and skips plan caching.
-- 9. Dynamic SQL is most justified for: generic utilities, multi-schema
--    architectures, runtime DDL, and building query builders.
