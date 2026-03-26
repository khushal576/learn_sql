-------------------------------------------------
-- CHAPTER 10
-- Window Functions
-------------------------------------------------
-- Window functions perform calculations across a set of rows (a "window")
-- that are related to the current row — without collapsing rows like GROUP BY.
-- Syntax: function() OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE BETWEEN ...)
--
-- This chapter covers: ROW_NUMBER, RANK, DENSE_RANK, LAG, LEAD,
-- FIRST_VALUE, LAST_VALUE, NTH_VALUE, running totals, moving averages,
-- NTILE, PERCENT_RANK, CUME_DIST, and named window clauses.

-------------------------------------------------

-- Window function syntax anatomy
-- PARTITION BY: divides rows into groups (like GROUP BY but rows are kept)
-- ORDER BY:     defines the order within each partition
-- ROWS BETWEEN: defines the exact frame (subset of partition to compute over)
--
-- function() OVER (
--     PARTITION BY column         -- reset for each group
--     ORDER BY column             -- row ordering within partition
--     ROWS BETWEEN 2 PRECEDING
--              AND CURRENT ROW    -- frame: 2 rows back + current
-- )

-------------------------------------------------

-- ROW_NUMBER — unique sequential number within each partition
-- No ties: every row gets a distinct number regardless of equal values

select ename,
       deptno,
       sal,
       row_number() over (partition by deptno order by sal desc) as rn
from emp
order by deptno, sal desc;

-- Use case: pick exactly 1 row per group (top earner per dept)

select ename, deptno, sal
from (
    select ename, deptno, sal,
           row_number() over (partition by deptno order by sal desc) as rn
    from emp
) x
where rn = 1;

-------------------------------------------------

-- RANK vs DENSE_RANK — both handle ties, but differently

select ename,
       sal,
       rank()       over (order by sal desc) as rnk,
       dense_rank() over (order by sal desc) as dense_rnk
from emp
order by sal desc;

-- RANK:       skips numbers after ties. Tie at position 2 → next is 4.
-- DENSE_RANK: no gaps. Tie at position 2 → next is 3.

-- Per-department ranking
select ename, deptno, sal,
       rank()       over (partition by deptno order by sal desc) as dept_rank,
       dense_rank() over (partition by deptno order by sal desc) as dept_dense_rank
from emp
order by deptno, sal desc;

-------------------------------------------------

-- LAG — access a previous row's value within the partition

select ename,
       hiredate,
       sal,
       lag(sal)    over (order by hiredate) as prev_sal,
       lag(sal, 2) over (order by hiredate) as sal_2_rows_back
from emp
order by hiredate;

-- LAG(column, offset, default): offset defaults to 1, default to NULL
-- First row has NULL for prev_sal because there is no preceding row.

-- Salary difference from previous hire
select ename,
       hiredate,
       sal,
       sal - lag(sal) over (order by hiredate) as sal_diff
from emp
order by hiredate;

-------------------------------------------------

-- LEAD — access the NEXT row's value

select ename,
       hiredate,
       sal,
       lead(sal) over (order by hiredate) as next_hire_sal,
       lead(ename) over (order by hiredate) as next_hired_person
from emp
order by hiredate;

-- Last row has NULL for lead values (no following row).

-------------------------------------------------

-- FIRST_VALUE and LAST_VALUE — first/last value in the window frame

select ename,
       deptno,
       sal,
       first_value(sal) over (partition by deptno order by sal)         as dept_min_sal,
       last_value(sal)  over (
           partition by deptno
           order by sal
           rows between unbounded preceding and unbounded following
       )                                                                  as dept_max_sal
from emp
order by deptno, sal;

-- IMPORTANT: LAST_VALUE requires "ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING"
-- Without it, the default frame is RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW,
-- so LAST_VALUE always returns the current row's value.

-------------------------------------------------

-- NTH_VALUE — return the value from the nth row in the window

select ename,
       deptno,
       sal,
       nth_value(sal, 2) over (
           partition by deptno
           order by sal desc
           rows between unbounded preceding and unbounded following
       ) as second_highest_sal
from emp
order by deptno, sal desc;

-------------------------------------------------

-- Running total with SUM OVER
-- Accumulates salary as rows are processed in order

select ename,
       deptno,
       sal,
       sum(sal) over (order by hiredate) as running_total
from emp
order by hiredate;

-- Running total per department (resets for each dept)
select ename,
       deptno,
       sal,
       sum(sal) over (
           partition by deptno
           order by hiredate
       ) as dept_running_total
from emp
order by deptno, hiredate;

-------------------------------------------------

-- Moving average using ROWS BETWEEN
-- Average of current row and the 2 rows before it

select ename,
       sal,
       avg(sal) over (
           order by sal
           rows between 2 preceding and current row
       ) as moving_avg_3
from emp
order by sal;

-- ROWS BETWEEN 2 PRECEDING AND CURRENT ROW = window of 3 rows
-- ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING = centered 3-row window

-------------------------------------------------

-- Running COUNT — count rows seen so far

select ename,
       deptno,
       count(*) over (partition by deptno order by sal desc) as running_count,
       count(*) over (partition by deptno)                   as dept_total
from emp
order by deptno, sal desc;

-------------------------------------------------

-- Cumulative percentage of total salary

select ename,
       deptno,
       sal,
       round(
           100.0 * sum(sal) over (order by sal)
                 / sum(sal) over ()
       , 2) as cum_pct_of_total
from emp
order by sal;

-------------------------------------------------

-- NTILE — divide rows into N equal buckets (quartiles, deciles)

select ename,
       sal,
       ntile(4)  over (order by sal) as quartile,
       ntile(10) over (order by sal) as decile
from emp
order by sal;

-- Quartile 1 = lowest paid group, 4 = highest paid group.

-------------------------------------------------

-- PERCENT_RANK — relative rank as a percentage (0.0 to 1.0)
-- CUME_DIST    — fraction of rows with value <= current row

select ename,
       sal,
       round(percent_rank() over (order by sal)::numeric, 4) as pct_rank,
       round(cume_dist()    over (order by sal)::numeric, 4) as cum_dist
from emp
order by sal;

-- percent_rank = 0.0 for the first row, 1.0 for the last.
-- cume_dist = what fraction of all rows have sal <= this row's sal.

-------------------------------------------------

-- Named window clause (WINDOW keyword)
-- Avoid repeating the same OVER (...) specification multiple times.

select ename,
       deptno,
       sal,
       rank()         over w as dept_rank,
       dense_rank()   over w as dept_dense_rank,
       sum(sal)       over w as dept_running_total,
       avg(sal)       over w as dept_running_avg
from emp
window w as (partition by deptno order by sal desc)
order by deptno, sal desc;

-- Define the window once with WINDOW alias, reuse in multiple functions.

-------------------------------------------------

-- Window functions in a subquery — combine with filtering

select ename, deptno, sal, dept_rank
from (
    select ename,
           deptno,
           sal,
           rank() over (partition by deptno order by sal desc) as dept_rank
    from emp
) ranked
where dept_rank <= 2
order by deptno, dept_rank;

-- Returns top 2 earners per department.
-- You cannot filter on window function results directly in WHERE —
-- wrap in a subquery or CTE.

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Window functions do NOT reduce the number of rows (unlike GROUP BY).
--    They add a computed column per row, keeping all original rows.

-- 2. You cannot use a window function in a WHERE clause directly.
--    Wrap the query in a subquery or CTE, then filter on the result.

-- 3. Always specify the frame clause explicitly for LAST_VALUE and NTH_VALUE.
--    The default frame (RANGE UNBOUNDED PRECEDING TO CURRENT ROW) gives
--    unexpected results with those functions.

-- 4. Use ROWS BETWEEN instead of RANGE BETWEEN for moving averages/totals.
--    RANGE treats equal-valued rows as a group; ROWS counts exact row positions.

-- 5. The WINDOW clause avoids repeating long OVER() specifications.
--    Use it when the same partition/order appears in 3+ functions.

-- 6. ROW_NUMBER always produces unique values; use it when you need exactly
--    one row per group (e.g., deduplication, first/latest record per key).

-- 7. Use LAG/LEAD to calculate period-over-period differences without a self-join.
--    This is the standard pattern for YoY, MoM, and sequential comparisons.
