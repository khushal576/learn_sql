-------------------------------------------------
-- CHAPTER 25
-- Classic SQL Interview Patterns
-------------------------------------------------
-- These are the patterns that appear most often in SQL technical interviews
-- and real-world data problems. Each section is a named, reusable pattern.
-- Knowing the pattern name lets you recognise the problem and apply the solution.
--
--   Pattern 1  — Gaps and Islands
--   Pattern 2  — Deduplication (keep one, delete the rest)
--   Pattern 3  — Nth Record (without window functions and with)
--   Pattern 4  — Running Totals Without Window Functions
--   Pattern 5  — Consecutive Streaks
--   Pattern 6  — Missing Values in a Sequence
--   Pattern 7  — Top-N Per Group (all approaches)
--
-- All examples use the existing EMP/DEPT tables or small inline CTEs.
-- No schema changes are required.

-------------------------------------------------
-- PATTERN 1: Gaps and Islands
-------------------------------------------------
-- "Islands" are groups of consecutive values; "gaps" are the missing values between them.
-- The key insight: if you subtract ROW_NUMBER() from the value, consecutive values
-- produce the SAME constant. When that constant changes, a new island starts.

-- Example data: empno values in emp are NOT consecutive (7369, 7499, 7521, ...)
-- Find which empno values are MISSING between the min and max:
select gs.missing_empno
from generate_series(
    (select min(empno) from emp),
    (select max(empno) from emp)
) as gs(missing_empno)
left join emp e on e.empno = gs.missing_empno
where e.empno is null
order by gs.missing_empno;

-------------------------------------------------
-- Island detection on consecutive integers
-------------------------------------------------
-- Create sample data with gaps inline using a CTE
with daily_sales(sale_date, amount) as (
    values
        ('2024-01-01'::date, 100),
        ('2024-01-02'::date, 200),
        ('2024-01-03'::date, 150),
        -- gap: Jan 4 and 5 missing
        ('2024-01-06'::date, 300),
        ('2024-01-07'::date, 250),
        -- gap: Jan 8 missing
        ('2024-01-09'::date, 180),
        ('2024-01-10'::date, 90)
),
-- The trick: date - row_number() cast to interval produces the same anchor date
-- for all consecutive dates. Different islands get different anchor dates.
islands as (
    select
        sale_date,
        amount,
        sale_date - (row_number() over (order by sale_date) * interval '1 day')
            as island_id
    from daily_sales
)
select
    min(sale_date) as island_start,
    max(sale_date) as island_end,
    count(*)       as days_in_island,
    sum(amount)    as island_total
from islands
group by island_id
order by island_start;

-- Result: three islands — Jan 1-3, Jan 6-7, Jan 9-10

-------------------------------------------------
-- Find the gaps (not the islands)
-------------------------------------------------
with daily_sales(sale_date) as (
    values ('2024-01-01'::date), ('2024-01-02'::date), ('2024-01-03'::date),
           ('2024-01-06'::date), ('2024-01-07'::date),
           ('2024-01-09'::date), ('2024-01-10'::date)
),
with_next as (
    select
        sale_date,
        lead(sale_date) over (order by sale_date) as next_date
    from daily_sales
)
select
    sale_date + 1              as gap_start,
    next_date - 1              as gap_end,
    next_date - sale_date - 1  as gap_days
from with_next
where next_date - sale_date > 1;   -- more than 1 day apart → there's a gap

-------------------------------------------------
-- PATTERN 2: Deduplication — Keep One, Delete the Rest
-------------------------------------------------
-- The dupes table already contains duplicate rows. Three approaches:

-- Check what's in dupes
select * from dupes order by id;

-- APPROACH A: ROW_NUMBER() — modern, recommended
-- Assign a row number within each group of duplicates. Keep rn=1, delete rn>1.
with ranked as (
    select ctid,
           row_number() over (partition by name order by id) as rn
    from dupes
)
delete from dupes
where ctid in (select ctid from ranked where rn > 1);

-- Verify
select * from dupes;

-- Restore duplicates to demonstrate the next approaches
insert into dupes (id, name) values
    (2, 'NAPOLEON'), (4, 'DYNAMITE'), (6, 'DYNAMITE'), (7, 'NAPOLEON');

-- APPROACH B: DISTINCT ON — PostgreSQL-specific, very concise
-- Keeps the row with the lowest id for each name.
-- Use this when you want to SELECT unique rows without a DELETE.
select distinct on (name) id, name
from dupes
order by name, id;    -- DISTINCT ON keeps the FIRST row per the ORDER BY

-- To actually delete, the standard approach remains ROW_NUMBER() or MIN.

-- APPROACH C: Correlated subquery using MIN (no window functions)
-- Works on databases that do not have window functions.
delete from dupes
where id not in (
    select min(id)
    from dupes
    group by name
);

select * from dupes;

-- Restore again for chapter consistency
insert into dupes (id, name) values
    (2, 'NAPOLEON'), (4, 'DYNAMITE'), (6, 'DYNAMITE'), (7, 'NAPOLEON');

-------------------------------------------------
-- PATTERN 3: Nth Record
-------------------------------------------------
-- Find the employee with the Nth highest salary.

-- APPROACH A: DENSE_RANK() window function — cleanest, handles ties correctly
-- 3rd highest salary:
select empno, ename, sal
from (
    select empno, ename, sal,
           dense_rank() over (order by sal desc) as rnk
    from emp
) ranked
where rnk = 3;

-- APPROACH B: LIMIT/OFFSET — simple but doesn't handle ties
select empno, ename, sal
from emp
order by sal desc
limit 1 offset 2;     -- 0-based offset: skip 2, take 1 → 3rd row

-- APPROACH C: Correlated subquery (no window functions, handles ties)
-- "Find employees whose salary is exceeded by exactly N-1 other distinct salaries"
select empno, ename, sal
from emp e
where 2 = (             -- N-1 = 2 means 3rd highest (0 larger means 1st)
    select count(distinct sal)
    from emp
    where sal > e.sal
);

-- The correlated subquery approach is the one interviewers often ask for
-- to test whether you can write it without modern window functions.

-------------------------------------------------
-- PATTERN 4: Running Totals Without Window Functions
-------------------------------------------------
-- For contrast with the clean window function approach (shown in Ch10).
-- This demonstrates the "triangular self-join" — its O(n²) cost explains
-- WHY window functions were added to SQL.

-- Running total of salary ordered by hiredate — the hard way
select a.empno, a.ename, a.hiredate, a.sal,
       sum(b.sal) as running_total
from emp a
join emp b on b.hiredate <= a.hiredate
             and b.empno  <= a.empno    -- tie-break: ensure stable ordering
group by a.empno, a.ename, a.hiredate, a.sal
order by a.hiredate, a.empno;

-- The same result — the CORRECT way using a window function (O(n))
select empno, ename, hiredate, sal,
       sum(sal) over (
           order by hiredate, empno
           rows between unbounded preceding and current row
       ) as running_total
from emp
order by hiredate, empno;

-- The window function version is simpler AND 100x faster on large datasets.
-- The self-join is here so you understand what the window function is replacing.

-------------------------------------------------
-- PATTERN 5: Consecutive Streaks (Longest Run)
-------------------------------------------------
-- "Find the longest streak of consecutive days each employee logged in."
-- Uses the same island trick as Pattern 1, applied to dates.

-- Sample login data as an inline CTE (no schema change needed)
with logins(emp_id, login_date) as (
    values
        (7369, '2024-03-01'::date),
        (7369, '2024-03-02'::date),
        (7369, '2024-03-03'::date),   -- streak of 3
        (7369, '2024-03-05'::date),   -- gap on 04
        (7369, '2024-03-06'::date),   -- streak of 2
        (7499, '2024-03-01'::date),
        (7499, '2024-03-02'::date),
        (7499, '2024-03-04'::date),
        (7499, '2024-03-05'::date),
        (7499, '2024-03-06'::date)    -- streak of 3
),
-- Subtract row_number (per employee) from date to get a stable island ID
numbered as (
    select emp_id, login_date,
           login_date - row_number() over (
               partition by emp_id order by login_date
           ) * interval '1 day' as island_id
    from logins
),
-- Count streak length per island
streaks as (
    select emp_id, island_id,
           min(login_date) as streak_start,
           max(login_date) as streak_end,
           count(*)        as streak_length
    from numbered
    group by emp_id, island_id
)
-- Return the longest streak per employee
select distinct on (emp_id)
    emp_id, streak_start, streak_end, streak_length
from streaks
order by emp_id, streak_length desc;

-- Result: 7369 has longest streak of 3 (Mar 1-3), 7499 has streak of 3 (Mar 4-6).

-------------------------------------------------
-- PATTERN 6: Missing Values in a Sequence
-------------------------------------------------
-- Find which values are absent from a column that should be sequential.
-- The GENERATE_SERIES left-join approach is the standard technique.

-- Missing employee numbers in the EMP table
select gs.n as missing_empno
from generate_series(
    (select min(empno) from emp),
    (select max(empno) from emp)
) gs(n)
left join emp e on e.empno = gs.n
where e.empno is null
order by 1;

-- Missing dates in a date column (e.g. find days with no hires)
select gs.d::date as date_with_no_hire
from generate_series(
    (select min(hiredate) from emp)::timestamp,
    (select max(hiredate) from emp)::timestamp,
    interval '1 day'
) gs(d)
left join emp e on e.hiredate = gs.d::date
where e.hiredate is null
order by 1
limit 20;

-- Note: this returns dates between the first and last hire that had no hires.

-------------------------------------------------
-- PATTERN 7: Top-N Per Group
-------------------------------------------------
-- "Find the top 2 earners in each department."
-- Three approaches — understand all of them, use ROW_NUMBER() in production.

-- APPROACH A: ROW_NUMBER() — recommended
select empno, ename, deptno, sal
from (
    select empno, ename, deptno, sal,
           row_number() over (partition by deptno order by sal desc) as rn
    from emp
) ranked
where rn <= 2
order by deptno, sal desc;

-- APPROACH B: LATERAL join with LIMIT — also clean, good when you need full row context
select d.deptno, d.dname, e.empno, e.ename, e.sal
from dept d
cross join lateral (
    select empno, ename, sal
    from emp
    where emp.deptno = d.deptno
    order by sal desc
    limit 2
) e
order by d.deptno, e.sal desc;

-- APPROACH C: Correlated subquery — no window functions, works on older databases
-- "Find employees where fewer than 2 other employees in the same dept earn more"
select empno, ename, deptno, sal
from emp e
where (
    select count(*)
    from emp e2
    where e2.deptno = e.deptno
      and e2.sal > e.sal
) < 2
order by deptno, sal desc;

-- Note on ties: ROW_NUMBER() breaks ties arbitrarily (uses whatever row comes first).
-- Use RANK() instead of ROW_NUMBER() if tied employees should BOTH appear in top-N.
-- Use DENSE_RANK() if you want ranks without gaps after a tie.

select empno, ename, deptno, sal,
       rank()       over (partition by deptno order by sal desc) as rnk,
       dense_rank() over (partition by deptno order by sal desc) as dense_rnk
from emp
order by deptno, sal desc;

-------------------------------------------------
-- BONUS: Pivot (all approaches recap)
-------------------------------------------------
-- Already covered in Ch11 (CASE-based) and Ch22 (crosstab extension).
-- Here is the quick decision guide:

-- CASE-based pivot — works everywhere, columns must be hardcoded:
select
    deptno,
    sum(case when job = 'CLERK'    then sal end) as clerk_sal,
    sum(case when job = 'MANAGER'  then sal end) as manager_sal,
    sum(case when job = 'SALESMAN' then sal end) as salesman_sal,
    sum(case when job = 'ANALYST'  then sal end) as analyst_sal
from emp
group by deptno
order by deptno;

-- crosstab() from tablefunc extension — cleaner for many categories:
-- (See Ch22 for full crosstab syntax and dynamic category handling)

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Gaps and Islands: the "value minus ROW_NUMBER()" trick is the canonical approach.
--    For dates, cast ROW_NUMBER() to an interval before subtracting.

-- 2. Deduplication: ROW_NUMBER() + DELETE is safest and most explicit.
--    Use DISTINCT ON for SELECT-only dedup — it's the cleanest PostgreSQL syntax.

-- 3. Nth record: use DENSE_RANK() when ties should count as the same rank.
--    Use ROW_NUMBER() when you want exactly N rows regardless of ties.
--    The correlated subquery is the go-to answer when interviewers ban window functions.

-- 4. Running totals: always use window functions in production — the self-join is O(n²)
--    and becomes unmaintainably slow past ~10,000 rows.

-- 5. Top-N per group: ROW_NUMBER() in a subquery is the standard.
--    LATERAL + LIMIT is preferable when joining the result to other tables.

-- 6. Always clarify tie-breaking with the interviewer before answering Top-N questions.
--    "Top 2 earners" is ambiguous when multiple employees share the 2nd-highest salary.
