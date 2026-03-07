-------------------------------------------------
-- CHAPTER 2
-- Sorting Query Results
-------------------------------------------------

-- Default sort order is ASC (ascending)
select ename, sal
from emp
order by sal;

-------------------------------------------------

-- Sorting by column position
-- Here "2" refers to the second column in SELECT list
select ename, sal
from emp
order by 2 desc;

-- Best practice:
-- Avoid column positions in production queries
-- because query becomes fragile if column order changes.

-------------------------------------------------

-- Sorting using column alias
select ename,
       sal * 12 as annual_salary
from emp
order by annual_salary desc;

-------------------------------------------------

-- Sorting text columns alphabetically
select ename
from emp
order by ename;

-------------------------------------------------

-- Case insensitive sorting
select ename
from emp
order by lower(ename);

-------------------------------------------------

-- Sorting by length of string
select ename
from emp
order by length(ename);

-------------------------------------------------

-- Sorting by derived expression
select ename,
       sal,
       sal * 12 as annual_salary
from emp
order by sal * 12 desc;

-------------------------------------------------

-- Sorting using multiple computed columns
select ename,
       deptno,
       sal
from emp
order by deptno asc, sal desc;

-------------------------------------------------

-- Sorting by substring example
-- Sort employees by first 3 letters of name
select ename
from emp
order by substr(ename,1,3);

-------------------------------------------------

-- Sorting numeric values stored as text
-- Example scenario: table contains text values '1','2','10'
select data
from V
order by cast(data as integer);

-- Useful when numeric values are stored as VARCHAR

-------------------------------------------------

-- Reverse alphabetical order
select ename
from emp
order by ename desc;

-------------------------------------------------

-- Sorting using CASE expression
-- Example: Managers first, then others
select ename, job
from emp
order by case
           when job = 'MANAGER' then 1
           else 2
         end;

-------------------------------------------------

-- Custom sorting priority
-- Example: SALESMAN first, MANAGER second, others last
select ename, job
from emp
order by case job
           when 'SALESMAN' then 1
           when 'MANAGER' then 2
           else 3
         end;

-------------------------------------------------

-- Sorting NULL values explicitly
select ename, comm
from emp
order by comm nulls last;

-------------------------------------------------

-- Sorting by multiple keys with NULL handling
select ename, deptno, comm
from emp
order by deptno, comm nulls last;

-------------------------------------------------

-- Random sorting (useful for sampling)
select *
from emp
order by random();

-------------------------------------------------

-- Sorting after filtering
select ename, sal
from emp
where sal > 2000
order by sal desc;

-------------------------------------------------

-- Sorting with LIMIT (Top-N query)
select ename, sal
from emp
order by sal desc
limit 5;

-------------------------------------------------

-- Sorting with OFFSET (pagination)
select ename, sal
from emp
order by sal desc
limit 5 offset 5;

-------------------------------------------------

-- Example: Sorting employees by performance rule
-- Salesmen sorted by commission
-- Others sorted by salary
select ename, job, sal, comm
from emp
order by case
            when job = 'SALESMAN' then comm
            else sal
         end desc;

-------------------------------------------------

-- Best Practice Notes
-------------------------------------------------

-- 1. Always combine ORDER BY with LIMIT when retrieving Top-N rows.

-- 2. Avoid ORDER BY column_position in production queries.

-- 3. Sorting large datasets can be expensive.
--    Use indexes when possible on frequently sorted columns.

-- 4. Use explicit NULLS FIRST / NULLS LAST for predictable ordering.

-- 5. Sorting using expressions prevents index usage in many cases.
--    Example:
--        ORDER BY lower(name)
--    may require full sort instead of index scan.