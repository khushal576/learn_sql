-------------------------------------------------
-- CHAPTER 11
-- Advanced Aggregation and Pivoting
-------------------------------------------------
-- This chapter covers powerful aggregation techniques beyond basic GROUP BY:
-- the FILTER clause for conditional aggregation, pivot-style queries using
-- CASE expressions, and multi-dimensional grouping with GROUPING SETS,
-- ROLLUP, and CUBE. It also covers array and JSON aggregation for
-- modern API and reporting use cases.
-- All examples use the EMP/DEPT schema.

-------------------------------------------------

-- FILTER clause — conditional aggregation
-- A cleaner, more readable alternative to SUM(CASE WHEN ... END).
-- Counts/sums only rows that satisfy the filter condition.

select deptno,
       count(*)                                   as total_emp,
       count(*) filter (where job = 'CLERK')      as clerk_count,
       count(*) filter (where job = 'MANAGER')    as manager_count,
       count(*) filter (where job = 'ANALYST')    as analyst_count,
       count(*) filter (where sal > 2000)         as high_earners,
       sum(sal) filter (where job = 'SALESMAN')   as salesman_sal_total
from emp
group by deptno
order by deptno;

-- FILTER works with any aggregate: COUNT, SUM, AVG, MAX, MIN, etc.
-- Only the rows passing the WHERE condition inside FILTER are included.

-------------------------------------------------

-- FILTER vs CASE — same result, different style
-- FILTER is cleaner; CASE is compatible with older databases.

-- Using CASE (old style):
select deptno,
       sum(case when job = 'CLERK'   then 1 else 0 end) as clerk_count_case,
       sum(case when job = 'MANAGER' then 1 else 0 end) as manager_count_case
from emp
group by deptno;

-- Using FILTER (modern, PostgreSQL 9.4+):
select deptno,
       count(*) filter (where job = 'CLERK')    as clerk_count_filter,
       count(*) filter (where job = 'MANAGER')  as manager_count_filter
from emp
group by deptno;

-------------------------------------------------

-- Pivot-style query using conditional aggregation
-- Turn rows into columns — one column per job type, showing avg salary.

select deptno,
       round(avg(case when job = 'CLERK'    then sal end), 2) as avg_clerk,
       round(avg(case when job = 'ANALYST'  then sal end), 2) as avg_analyst,
       round(avg(case when job = 'MANAGER'  then sal end), 2) as avg_manager,
       round(avg(case when job = 'SALESMAN' then sal end), 2) as avg_salesman
from emp
group by deptno
order by deptno;

-- NULL appears where no employee of that job exists in the department.
-- Wrap with COALESCE(..., 0) to show 0 instead of NULL.

-------------------------------------------------

-- GROUPING SETS — compute multiple GROUP BY levels in one query
-- Eliminates the need for UNION ALL of multiple aggregations.

select deptno,
       job,
       count(*)    as headcount,
       sum(sal)    as total_sal
from emp
group by grouping sets (
    (deptno, job),   -- subtotal per dept + job combination
    (deptno),        -- subtotal per dept only
    (job),           -- subtotal per job only
    ()               -- grand total (empty grouping = all rows)
)
order by deptno nulls last, job nulls last;

-- NULL in a column means "this row is a subtotal for all values of that column".

-------------------------------------------------

-- GROUPING() function — identify which column is the subtotal dimension
-- Returns 1 if the column is "rolled up" (NULL due to grouping), 0 otherwise.

select
    case when grouping(deptno) = 1 then 'ALL DEPTS' else cast(deptno as text) end as dept,
    case when grouping(job)    = 1 then 'ALL JOBS'  else job end                  as job,
    count(*) as headcount,
    sum(sal) as total_sal
from emp
group by grouping sets (
    (deptno, job),
    (deptno),
    (job),
    ()
)
order by grouping(deptno), deptno nulls last, grouping(job), job nulls last;

-------------------------------------------------

-- ROLLUP — hierarchical subtotals (subset of GROUPING SETS)
-- ROLLUP(a, b, c) generates: (a,b,c), (a,b), (a), ()
-- Perfect for reports that need subtotals per group and a grand total.

select deptno,
       job,
       count(*)  as headcount,
       sum(sal)  as total_sal
from emp
group by rollup(deptno, job)
order by deptno nulls last, job nulls last;

-- Produces:
--   deptno + job subtotals
--   deptno subtotals (job = NULL)
--   grand total (deptno = NULL, job = NULL)

-------------------------------------------------

-- CUBE — all possible combinations (superset of ROLLUP)
-- CUBE(a, b) generates: (a,b), (a), (b), ()
-- Use when you need every combination of grouping dimensions.

select deptno,
       job,
       count(*)  as headcount,
       sum(sal)  as total_sal
from emp
group by cube(deptno, job)
order by deptno nulls last, job nulls last;

-- More combinations than ROLLUP — includes cross-dimension subtotals.
-- For 3 columns, CUBE produces 2^3 = 8 groupings.

-------------------------------------------------

-- ARRAY_AGG — aggregate column values into a PostgreSQL array
-- Useful when you need a list of values per group as a structured type.

select deptno,
       array_agg(ename order by ename) as employees,
       array_agg(sal   order by sal desc) as salaries
from emp
group by deptno
order by deptno;

-- Access element: array[1] (1-based in PostgreSQL)
-- Check membership: 'KING' = any(array_agg(ename))

-------------------------------------------------

-- JSON_AGG — aggregate rows into a JSON array
-- Each row becomes a JSON object; the result is a JSON array.

select deptno,
       json_agg(
           json_build_object(
               'name', ename,
               'job',  job,
               'sal',  sal
           )
           order by sal desc
       ) as employees_json
from emp
group by deptno
order by deptno;

-- json_build_object(key, value, key, value...) builds a single JSON object.
-- json_agg collects them into a JSON array.

-------------------------------------------------

-- JSONB_AGG — same as JSON_AGG but returns JSONB (binary JSON)
-- JSONB is indexable and supports operators like @>, ?, etc.

select deptno,
       jsonb_agg(
           jsonb_build_object('name', ename, 'sal', sal)
           order by sal desc
       ) as employees_jsonb
from emp
group by deptno;

-------------------------------------------------

-- STRING_AGG with ORDER BY inside the aggregate
-- (Covered briefly in Ch6, reinforced here with ordering)

select deptno,
       string_agg(ename, ', ' order by sal desc) as emp_list_by_sal,
       string_agg(ename, ', ' order by ename)    as emp_list_alpha
from emp
group by deptno
order by deptno;

-- Always specify ORDER BY inside string_agg for deterministic output.

-------------------------------------------------

-- Combining FILTER + ROLLUP for a full summary report

select
    coalesce(cast(deptno as text), 'ALL') as dept,
    count(*)                                             as total,
    count(*) filter (where sal >= 2000)                  as high_earners,
    round(avg(sal), 2)                                   as avg_sal,
    sum(sal)                                             as total_sal
from emp
group by rollup(deptno)
order by deptno nulls last;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Prefer FILTER over CASE for conditional aggregation.
--    FILTER is cleaner, more readable, and slightly faster in PostgreSQL.

-- 2. ROLLUP is the most common advanced grouping — use it for any
--    report that needs row subtotals and a grand total row.

-- 3. CUBE generates all combinations. Use it only when you genuinely need
--    every cross-dimension subtotal. For 4+ columns it can be expensive.

-- 4. Use GROUPING SETS when you need a specific subset of grouping levels
--    that neither ROLLUP nor CUBE produces exactly.

-- 5. Use the GROUPING() function (returns 0 or 1) to distinguish real NULLs
--    from subtotal NULLs introduced by ROLLUP/CUBE.

-- 6. JSON_AGG / JSONB_AGG are powerful for building API-ready payloads
--    directly in SQL, avoiding multiple round-trips from the application.

-- 7. ARRAY_AGG is useful when downstream code needs a PostgreSQL array
--    (e.g., using the ANY() operator or unnesting later).

-- 8. Always include ORDER BY inside STRING_AGG and JSON_AGG
--    to guarantee deterministic output.
