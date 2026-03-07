-------------------------------------------------
-- CHAPTER 3
-- Working with Multiple Tables
-------------------------------------------------

-- INNER JOIN example
-- returns rows that have matching keys in both tables
select e.empno, e.ename, d.dname
from emp e
inner join dept d
on e.deptno = d.deptno;

-------------------------------------------------

-- LEFT JOIN
-- returns all rows from left table even if no match in right table
select e.ename, d.dname
from emp e
left join dept d
on e.deptno = d.deptno;

-------------------------------------------------

-- RIGHT JOIN
-- returns all rows from right table
select e.ename, d.dname
from emp e
right join dept d
on e.deptno = d.deptno;

-------------------------------------------------

-- FULL OUTER JOIN
-- returns all rows from both tables
select e.ename, d.dname
from emp e
full join dept d
on e.deptno = d.deptno;

-------------------------------------------------

-- SELF JOIN
-- used when a table references itself
-- Example: employee and their manager

select e.ename as employee,
       m.ename as manager
from emp e
left join emp m
on e.mgr = m.empno;

-------------------------------------------------

-- SELF JOIN example to find employees working in same department
select e1.ename as emp1,
       e2.ename as emp2,
       e1.deptno
from emp e1
join emp e2
on e1.deptno = e2.deptno
and e1.empno < e2.empno;

-------------------------------------------------

-- CROSS JOIN
-- produces Cartesian product (all combinations)

select e.ename, d.dname
from emp e
cross join dept d;

-------------------------------------------------

-- Set Operator: UNION
-- removes duplicates automatically

select deptno
from emp
union
select deptno
from dept;

-------------------------------------------------

-- Set Operator: INTERSECT
-- returns common rows between two queries

select deptno
from emp
intersect
select deptno
from dept;

-------------------------------------------------

-- Set Operator: EXCEPT
-- returns rows from first query not in second

select deptno
from dept
except
select deptno
from emp;

-------------------------------------------------

-- EXISTS example
-- return departments that have employees

select *
from dept d
where exists (
    select 1
    from emp e
    where e.deptno = d.deptno
);

-------------------------------------------------

-- NOT EXISTS example
-- return departments without employees

select *
from dept d
where not exists (
    select 1
    from emp e
    where e.deptno = d.deptno
);

-------------------------------------------------

-- Using EXISTS instead of IN (often more efficient)

select *
from emp e
where exists (
    select 1
    from dept d
    where d.deptno = e.deptno
);

-------------------------------------------------

-- Finding employees working in departments located in NEW YORK

select e.ename, d.loc
from emp e
join dept d
on e.deptno = d.deptno
where d.loc = 'NEW YORK';

-------------------------------------------------

-- Join with filtering on both tables

select e.ename, d.dname, e.sal
from emp e
join dept d
on e.deptno = d.deptno
where e.sal > 2000
and d.loc = 'CHICAGO';

-------------------------------------------------

-- Join three tables example

select e.ename,
       d.dname,
       eb.type
from emp e
join dept d
on e.deptno = d.deptno
left join emp_bonus eb
on e.empno = eb.empno;

-------------------------------------------------

-- Finding employees who do not have bonuses

select e.*
from emp e
left join emp_bonus eb
on e.empno = eb.empno
where eb.empno is null;

-------------------------------------------------

-- Counting employees per department

select d.deptno,
       d.dname,
       count(e.empno) as employee_count
from dept d
left join emp e
on d.deptno = e.deptno
group by d.deptno, d.dname;

-------------------------------------------------

-- Join using USING clause
-- shorthand when column names are identical

select e.ename, d.dname
from emp e
join dept d
using (deptno);

-------------------------------------------------

-- Best Practice Notes
-------------------------------------------------

-- 1. Prefer explicit JOIN syntax over comma joins.
--    It improves readability and avoids accidental Cartesian products.

-- 2. Always specify join condition clearly.

-- 3. EXISTS is usually better than IN for correlated subqueries
--    when working with large datasets.

-- 4. LEFT JOIN + IS NULL is a common pattern
--    to find unmatched rows.

-- 5. Avoid SELECT * in multi-table joins.
--    Explicit column selection prevents ambiguity.

-- 6. CROSS JOIN can produce extremely large result sets.
--    Use carefully.