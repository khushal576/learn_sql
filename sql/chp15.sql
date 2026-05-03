-------------------------------------------------
-- CHAPTER 15
-- PL/pgSQL — Stored Functions and Procedures
-------------------------------------------------
-- PL/pgSQL is PostgreSQL's procedural language for writing
-- functions and procedures that run inside the database engine.
-- Functions return a value; procedures (PG 11+) do not return a value
-- but can manage transactions.
-- This chapter covers: CREATE FUNCTION, RETURNS TABLE, DECLARE/BEGIN/END,
-- IF/ELSIF/LOOP, exception handling, CREATE PROCEDURE, and calling conventions.

-------------------------------------------------

-- Simplest function — returns a scalar value
-- LANGUAGE sql: plain SQL body, no procedural logic needed

create or replace function get_employee_count()
returns integer
language sql
as $$
    select count(*)::integer from emp;
$$;

-- Call it:
select get_employee_count();

-------------------------------------------------

-- Function with input parameter

create or replace function get_dept_headcount(p_deptno integer)
returns integer
language sql
as $$
    select count(*)::integer
    from emp
    where deptno = p_deptno;
$$;

select get_dept_headcount(20);
select get_dept_headcount(30);

-------------------------------------------------

-- Function returning a table (set-returning function)
-- Use RETURNS TABLE to return multiple rows and columns.

create or replace function get_dept_employees(p_deptno integer)
returns table (
    empno   integer,
    ename   varchar,
    job     varchar,
    sal     integer
)
language sql
as $$
    select empno, ename, job, sal
    from emp
    where deptno = p_deptno
    order by sal desc;
$$;

-- Call like a table:
select * from get_dept_employees(20);

-- Join with other tables:
select f.ename, f.sal, d.loc
from get_dept_employees(20) f
join dept d on d.deptno = 20;

-------------------------------------------------

-- PL/pgSQL function — procedural body with DECLARE and IF/ELSE
-- LANGUAGE plpgsql: enables variables, conditionals, loops, exceptions.

create or replace function salary_band(p_sal integer)
returns text
language plpgsql
as $$
declare
    v_band text;
begin
    if p_sal < 1500 then
        v_band := 'LOW';
    elsif p_sal between 1500 and 3000 then
        v_band := 'MEDIUM';
    else
        v_band := 'HIGH';
    end if;

    return v_band;
end;
$$;

select ename, sal, salary_band(sal) as band from emp order by sal;

-------------------------------------------------

-- PL/pgSQL function with a local variable and query result

create or replace function get_avg_sal_for_dept(p_deptno integer)
returns numeric
language plpgsql
as $$
declare
    v_avg numeric;
begin
    select avg(sal)
    into v_avg
    from emp
    where deptno = p_deptno;

    return round(v_avg, 2);
end;
$$;

select deptno,
       get_avg_sal_for_dept(deptno) as avg_sal
from dept
order by deptno;

-------------------------------------------------

-- LOOP — iterate a fixed number of times

create or replace function sum_to_n(p_n integer)
returns integer
language plpgsql
as $$
declare
    v_total integer := 0;
    v_i     integer := 1;
begin
    loop
        exit when v_i > p_n;
        v_total := v_total + v_i;
        v_i := v_i + 1;
    end loop;

    return v_total;
end;
$$;

select sum_to_n(10);   -- 55

-------------------------------------------------

-- FOR loop over a query result (RECORD variable)

create or replace function log_high_earners()
returns text
language plpgsql
as $$
declare
    rec     record;
    v_list  text := '';
begin
    for rec in
        select ename, sal from emp where sal > 2500 order by sal desc
    loop
        v_list := v_list || rec.ename || '(' || rec.sal || ') ';
    end loop;

    return trim(v_list);
end;
$$;

select log_high_earners();

-------------------------------------------------

-- WHILE loop

create or replace function countdown(p_n integer)
returns text
language plpgsql
as $$
declare
    v_n    integer := p_n;
    v_out  text    := '';
begin
    while v_n > 0 loop
        v_out := v_out || v_n || ' ';
        v_n := v_n - 1;
    end loop;

    return trim(v_out);
end;
$$;

select countdown(5);   -- '5 4 3 2 1'

-------------------------------------------------

-- Exception handling — EXCEPTION WHEN
-- Catches runtime errors and returns a safe fallback value.

create or replace function safe_divide(p_num integer, p_den integer)
returns numeric
language plpgsql
as $$
begin
    return p_num / p_den;
exception
    when division_by_zero then
        return null;
    when others then
        raise notice 'Unexpected error: %', sqlerrm;
        return null;
end;
$$;

select safe_divide(10, 2);   -- 5
select safe_divide(10, 0);   -- NULL (no crash)

-- SQLERRM: the error message string.
-- SQLSTATE: the 5-character error code.
-- RAISE NOTICE: prints a message to the client (like a debug log).

-------------------------------------------------

-- RAISE — emit messages from a function

create or replace function greet_employee(p_empno integer)
returns text
language plpgsql
as $$
declare
    v_name text;
begin
    select ename into v_name from emp where empno = p_empno;

    if not found then
        raise exception 'Employee % not found', p_empno;
    end if;

    raise notice 'Greeting employee: %', v_name;
    return 'Hello, ' || v_name || '!';
end;
$$;

select greet_employee(7369);     -- Hello, SMITH!
-- select greet_employee(9999);  -- ERROR: Employee 9999 not found

-- RAISE levels: DEBUG, LOG, INFO, NOTICE, WARNING, EXCEPTION
-- EXCEPTION rolls back the current transaction.

-------------------------------------------------

-- Function with OUT parameters (multiple return values without RETURNS TABLE)

create or replace function dept_stats(
    p_deptno  integer,
    out o_count   integer,
    out o_avg_sal numeric,
    out o_max_sal integer
)
language sql
as $$
    select count(*)::integer,
           round(avg(sal), 2),
           max(sal)
    from emp
    where deptno = p_deptno;
$$;

select * from dept_stats(20);

-------------------------------------------------

-- IMMUTABLE / STABLE / VOLATILE — function volatility categories
-- These affect query optimisation and caching behaviour.

-- IMMUTABLE: same inputs always return same output, no DB access.
--   → Can be inlined and cached aggressively.
create or replace function add_tax(p_sal integer, p_rate numeric)
returns numeric
language sql
immutable
as $$
    select p_sal * (1 + p_rate / 100);
$$;

-- STABLE: same inputs return same output WITHIN a transaction.
--   → Cannot modify the DB but can read it.
--   Default for functions that SELECT from tables.

-- VOLATILE (default): can return different results on every call,
-- can have side effects. All DML functions should be VOLATILE.

-------------------------------------------------

-- CREATE PROCEDURE (PostgreSQL 11+)
-- Unlike functions, procedures do not return a value.
-- Procedures CAN call COMMIT/ROLLBACK — functions cannot.

create or replace procedure give_raise(p_deptno integer, p_pct numeric)
language plpgsql
as $$
begin
    update emp
    set sal = sal * (1 + p_pct / 100)
    where deptno = p_deptno;

    raise notice 'Raise applied to department %', p_deptno;
end;
$$;

-- Call with CALL (not SELECT):
call give_raise(20, 10);

-- Verify:
select ename, sal from emp where deptno = 20;

-------------------------------------------------

-- Listing functions in the database

select routine_name,
       routine_type,
       data_type as return_type
from information_schema.routines
where routine_schema = 'public'
  and routine_type in ('FUNCTION', 'PROCEDURE')
order by routine_type, routine_name;

-------------------------------------------------

-- Dropping functions and procedures

drop function if exists get_employee_count();
drop function if exists get_dept_headcount(integer);
drop function if exists get_dept_employees(integer);
drop function if exists salary_band(integer);
drop function if exists get_avg_sal_for_dept(integer);
drop function if exists sum_to_n(integer);
drop function if exists log_high_earners();
drop function if exists countdown(integer);
drop function if exists safe_divide(integer, integer);
drop function if exists greet_employee(integer);
drop function if exists dept_stats(integer);
drop function if exists add_tax(integer, numeric);
drop procedure if exists give_raise(integer, numeric);

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Use LANGUAGE sql for simple functions with no procedural logic.
--    Use LANGUAGE plpgsql only when you need variables, loops, or exceptions.

-- 2. Mark functions IMMUTABLE or STABLE when correct — the planner
--    can cache results and optimise calls significantly.

-- 3. Always handle exceptions in functions that interact with data.
--    Use EXCEPTION WHEN ... THEN to return safe values instead of crashing.

-- 4. Use CREATE OR REPLACE FUNCTION to update functions without DROP/CREATE.
--    Note: you cannot change the return type with OR REPLACE — must DROP first.

-- 5. RETURNS TABLE is the cleanest way to return multiple rows/columns.
--    Equivalent to RETURNS SETOF some_type but self-documenting.

-- 6. Use CALL for procedures, SELECT for functions.
--    Procedures can manage their own transactions; functions cannot.

-- 7. Prefer RAISE EXCEPTION over bare errors — it lets you control the
--    error message and code that the application receives.
