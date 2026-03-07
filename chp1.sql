-------------------------------------------------
-- CHAPTER 1
-- Retrieving Records 
-------------------------------------------------

-- Retrieve rows using comparison operators
select *
from emp
where sal > 3000;

select *
from emp
where sal between 1000 and 3000;

-- Best practice:
-- BETWEEN is inclusive (includes both boundary values)

-- Retrieve rows using NOT condition
select *
from emp
where deptno not in (10,20);

-- Retrieve rows with multiple AND conditions
select *
from emp
where deptno = 20
and sal > 2000;

-- Demonstrating operator precedence
-- AND executes before OR
select *
from emp
where deptno = 10
or deptno = 20 and sal > 2000;

-- Recommended: always use parentheses for clarity
select *
from emp
where (deptno = 10 or deptno = 20)
and sal > 2000;

-------------------------------------------------

-- Removing duplicate rows
select distinct job
from emp;

-- Retrieve unique combinations
select distinct deptno, job
from emp;

-------------------------------------------------

-- Sorting results (ORDER BY)
select *
from emp
order by sal;

-- Descending order
select *
from emp
order by sal desc;

-- Sorting by multiple columns
select *
from emp
order by deptno, sal desc;

-------------------------------------------------

-- Using column alias in ORDER BY
select ename,
       sal as salary
from emp
order by salary desc;

-------------------------------------------------

-- Returning rows with highest salary first
select ename, sal
from emp
order by sal desc
limit 3;

-- Best practice:
-- Always combine LIMIT with ORDER BY when selecting top rows

-------------------------------------------------

-- Retrieve employees whose names start with 'S'
select *
from emp
where ename like 'S%';

-- Names ending with 'R'
select *
from emp
where ename like '%R';

-- Names with exactly 5 characters
select *
from emp
where ename like '_____';

-------------------------------------------------

-- Case-insensitive search (PostgreSQL specific)
select *
from emp
where ename ilike '%smith%';

-------------------------------------------------

-- Checking for NOT NULL values
select *
from emp
where comm is not null;

-------------------------------------------------

-- Replace NULL commission with default value
select ename,
       coalesce(comm,0) as commission
from emp;

-- COALESCE returns first non-null value

-------------------------------------------------

-- Concatenating multiple columns into readable text
select ename || ' earns ' || sal || ' per month' as message
from emp;

-------------------------------------------------

-- Using expressions inside SELECT
select ename,
       sal,
       sal * 12 as annual_salary
from emp;

-------------------------------------------------

-- Using arithmetic operations
select ename,
       sal,
       sal + 500 as revised_salary
from emp;

-------------------------------------------------

-- Using CASE for classification
select ename,
       sal,
       case
           when sal < 1500 then 'LOW'
           when sal between 1500 and 3000 then 'MEDIUM'
           else 'HIGH'
       end as salary_band
from emp;

-------------------------------------------------

-- Using CASE to convert department numbers
select ename,
       deptno,
       case deptno
            when 10 then 'ACCOUNTING'
            when 20 then 'RESEARCH'
            when 30 then 'SALES'
            else 'OTHER'
       end as department_name
from emp;

-------------------------------------------------

-- Filtering rows using computed expression
select *
from emp
where sal * 12 > 30000;

-------------------------------------------------

-- Retrieve rows where salary exists but commission does not
select *
from emp
where sal is not null
and comm is null;

-------------------------------------------------

-- Limiting results with OFFSET
-- Useful for pagination
select *
from emp
order by empno
limit 5 offset 5;

-- Meaning:
-- Skip first 5 rows and return next 5 rows

-------------------------------------------------

-- Check if value exists in list
select *
from emp
where job in ('CLERK','MANAGER');

-------------------------------------------------

-- Negation of IN
select *
from emp
where job not in ('CLERK','SALESMAN');

-------------------------------------------------

-- Example of filtering using subquery
-- (basic exposure, full topic later)
select *
from emp
where deptno in (
    select deptno
    from emp
    where sal > 3000
);

-------------------------------------------------

-- Return rows in random order
select *
from emp
order by random();

-------------------------------------------------

-- Useful debugging query while learning
-- Quickly check number of rows in table
select count(*) from emp;

-------------------------------------------------

-- Best Practice Notes
-------------------------------------------------

-- 1. Avoid SELECT * in production queries
--    Explicit column selection improves performance and readability.

-- 2. Always use parentheses in complex WHERE conditions.

-- 3. Use ORDER BY when using LIMIT to make results deterministic.

-- 4. Use COALESCE when dealing with nullable columns.

-- 5. Prefer meaningful column aliases when presenting results.