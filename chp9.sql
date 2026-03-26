-------------------------------------------------
-- CHAPTER 9
-- Common Table Expressions (CTEs)
-------------------------------------------------
-- A CTE (WITH clause) gives a name to a subquery so it can be referenced
-- like a temporary view within the same statement.
-- CTEs improve readability, enable step-by-step logic, and support recursion.
-- This chapter covers: basic CTEs, multiple chained CTEs, CTE in UPDATE/DELETE,
-- recursive CTEs for hierarchies and date series, and materialization hints.

-------------------------------------------------

-- Basic CTE — simplest form
-- Name a subquery and reference it in the main query.
-- Equivalent to an inline subquery but far more readable.

with dept_avg as (
    select deptno,
           avg(sal) as avg_sal
    from emp
    group by deptno
)
select e.ename,
       e.sal,
       d.avg_sal,
       round(e.sal - d.avg_sal, 2) as diff_from_avg
from emp e
join dept_avg d on e.deptno = d.deptno
order by e.deptno, e.sal desc;

-- The CTE dept_avg is computed once and reused in the JOIN.

-------------------------------------------------

-- CTE vs subquery — same result, different readability
-- Subquery version (harder to read):

select e.ename, e.sal, sub.avg_sal
from emp e
join (
    select deptno, avg(sal) as avg_sal
    from emp
    group by deptno
) sub on e.deptno = sub.deptno;

-- CTE version is preferred when the logic is reused or complex.

-------------------------------------------------

-- Multiple chained CTEs
-- Each CTE can reference the one defined before it.

with dept_stats as (
    select deptno,
           count(*)     as headcount,
           avg(sal)     as avg_sal,
           max(sal)     as max_sal,
           min(sal)     as min_sal
    from emp
    group by deptno
),
dept_ranked as (
    select deptno,
           headcount,
           round(avg_sal, 2) as avg_sal,
           max_sal,
           rank() over (order by avg_sal desc) as avg_sal_rank
    from dept_stats
)
select dr.avg_sal_rank,
       d.dname,
       dr.headcount,
       dr.avg_sal,
       dr.max_sal
from dept_ranked dr
join dept d on dr.deptno = d.deptno
order by dr.avg_sal_rank;

-------------------------------------------------

-- CTE for top earner per department
-- Combining CTE with window function to filter top-N per group

with ranked_emp as (
    select ename,
           sal,
           deptno,
           rank() over (partition by deptno order by sal desc) as rnk
    from emp
)
select ename, sal, deptno
from ranked_emp
where rnk = 1
order by deptno;

-- This is the classic "top-N per group" pattern. CTEs make it very clean.

-------------------------------------------------

-- CTE used in UPDATE
-- Identify rows to update using a CTE, then UPDATE referencing it.

with below_avg as (
    select empno
    from emp
    where sal < (select avg(sal) from emp)
)
update emp
set sal = sal * 1.10
where empno in (select empno from below_avg);

-- Give 10% raise to all employees earning below average salary.
-- The CTE isolates the "who" from the "what" — easier to review and audit.

-------------------------------------------------

-- CTE used in DELETE
-- Find and remove rows using a CTE for the filter condition.

with bonus_earners as (
    select empno
    from emp_bonus
)
delete from emp
where empno in (select empno from bonus_earners)
  and job = 'CLERK';

-- Only deletes clerks who are in the bonus table.
-- Test first: replace DELETE with SELECT * to preview affected rows.

-------------------------------------------------

-- Recursive CTE — org hierarchy (manager → employee chain)
-- A recursive CTE has two parts separated by UNION ALL:
--   1. Base case: starting rows (anchor)
--   2. Recursive step: joins back to the CTE itself

with recursive org_tree as (
    -- Anchor: start from the top (no manager)
    select empno,
           ename,
           mgr,
           job,
           1 as depth,
           ename::text as path
    from emp
    where mgr is null

    union all

    -- Recursive step: each employee's direct reports
    select e.empno,
           e.ename,
           e.mgr,
           e.job,
           ot.depth + 1,
           ot.path || ' > ' || e.ename
    from emp e
    join org_tree ot on e.mgr = ot.empno
)
select depth,
       lpad('', (depth - 1) * 4, ' ') || ename as org_chart,
       job,
       path
from org_tree
order by path;

-- depth = level in the hierarchy (1 = CEO/top)
-- path = full chain from top to this employee
-- lpad indentation visually shows the tree structure

-------------------------------------------------

-- Recursive CTE — date series generation
-- Generate every month between two dates without a helper table

with recursive date_series as (
    -- Anchor: start date
    select '1981-01-01'::date as dt

    union all

    -- Recursive step: add 1 month each iteration
    select dt + interval '1 month'
    from date_series
    where dt < '1982-12-01'
)
select dt as month_start,
       to_char(dt, 'Month YYYY') as label
from date_series;

-- Note: GENERATE_SERIES is simpler for date ranges (see Chapter 8).
-- Recursive CTEs are more flexible for complex stopping conditions.

-------------------------------------------------

-- Recursive CTE — running number series (illustrative)

with recursive counter as (
    select 1 as n
    union all
    select n + 1 from counter where n < 10
)
select n from counter;

-------------------------------------------------

-- Materialized CTEs (PostgreSQL 12+)
-- By default, PostgreSQL may inline or materialise a CTE depending on the planner.
-- Use MATERIALIZED to force evaluation once (useful when CTE is expensive).
-- Use NOT MATERIALIZED to let the planner inline it (useful for small CTEs).

with dept_totals as materialized (
    select deptno, sum(sal) as total_sal
    from emp
    group by deptno
)
select d.dname, dt.total_sal
from dept_totals dt
join dept d on dt.deptno = d.deptno;

-- MATERIALIZED: CTE is computed once and stored.
-- NOT MATERIALIZED: CTE is inlined like a subquery (planner can push predicates in).

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Use CTEs for readability — name intermediate steps so the query
--    reads like a narrative (what we compute, then what we do with it).

-- 2. CTEs do NOT always improve performance. In PostgreSQL < 12,
--    CTEs act as optimisation fences (always materialised).
--    In PostgreSQL 12+, the planner may inline them unless MATERIALIZED is specified.

-- 3. For recursive CTEs, always ensure the recursion terminates.
--    Add a WHERE condition or a depth counter to prevent infinite loops.
--    Example safety guard: WHERE depth < 100

-- 4. The "top-N per group" pattern (CTE + RANK/ROW_NUMBER + WHERE rnk = 1)
--    is one of the most common and useful SQL patterns.

-- 5. CTEs can be used in SELECT, INSERT, UPDATE, and DELETE statements.
--    This makes them essential for complex data modifications.

-- 6. When a CTE is used more than once in a query, MATERIALIZED ensures
--    it is computed only once — preventing redundant work.
