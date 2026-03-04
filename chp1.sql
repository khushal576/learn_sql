---------------------------------------------
-- CHAPTER 1:  Retrieving Records
---------------------------------------------

-- Retrieving All Rows and Columns from a Table
select * from emp;

-- Retrieving a Subset of Rows from a Table
select * from emp
where deptno = 10;

-- Finding Rows That Satisfy Multiple Conditions
select *
from emp
where deptno = 10
or comm is not null
or sal <= 2000 and deptno=20;

-- Retrieving a Subset of Columns from a Table
select ename, deptno, sal
from emp;

-- Providing Meaningful Names for Columns
select sal as salary,
       comm as commission
from emp;

-- Referencing an Aliased Column in the WHERE Clause
select *
from (
   select sal as salary, comm as commission
   from emp) x
where salary < 5000;

-- Concatenating Column Values
select ename||' WORKS AS A '||job as msg
from emp
where deptno=10;

-- Using Conditional Logic in a SELECT Statement
select ename,sal,
    case when sal <= 2000 then 'UNDERPAID'
         when sal >= 4000 then 'OVERPAID'
         else 'OK'
    end as status
from emp;

-- Limiting the Number of Rows Returned
select *
from emp limit 5;

-- Returning n Random Records from a Table
select ename,job
from emp
order by random() limit 5;

-- Finding Null Values
select *
from emp
where comm is null;

-- Transforming Nulls into Real Values
select coalesce(comm,0)
from emp;

-- Searching for Patterns
select ename, job
from emp
where deptno in (10,20)
and (ename like '%I%' or job like '%ER');