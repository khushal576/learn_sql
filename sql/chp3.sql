-------------------------------------------------
-- CHAPTER 3
-- Working with Multiple Tables
-------------------------------------------------
-- This chapter covers combining data from multiple tables:
-- INNER, LEFT, RIGHT, FULL OUTER, SELF, and CROSS JOINs,
-- set operators (UNION, INTERSECT, EXCEPT), EXISTS/NOT EXISTS,
-- the USING clause shorthand, LATERAL joins for correlated logic,
-- and an introduction to CTEs (covered in depth in Chapter 9).

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

-------------------------------------------------

-- NATURAL JOIN
-- Automatically joins on all columns that share the same name.
-- Caution: fragile — adding a column to either table can silently break the query.

select e.ename, d.dname
from emp e
natural join dept d;

-- Best practice: avoid NATURAL JOIN in production. Use explicit ON or USING instead.

-------------------------------------------------

-- LATERAL join
-- Allows a subquery on the right side to reference columns from the left side.
-- Equivalent to a correlated subquery but returns multiple rows/columns.

select e.ename,
       e.sal,
       top_dept.dname,
       top_dept.avg_sal
from emp e
cross join lateral (
    select d.dname,
           avg(e2.sal) as avg_sal
    from dept d
    join emp e2 on e2.deptno = d.deptno
    where d.deptno = e.deptno
    group by d.dname
) top_dept;

-- LATERAL lets the inner subquery see e.deptno from the outer FROM clause.
-- Very powerful for per-row computations and top-N per group patterns.

-------------------------------------------------

-- CTE (Common Table Expression) using WITH clause
-- One of the most widely used modern SQL features.
-- Makes complex queries readable by naming intermediate results.

with dept_headcount as (
    select deptno,
           count(*) as headcount
    from emp
    group by deptno
),
high_headcount as (
    select deptno
    from dept_headcount
    where headcount >= 3
)
select e.ename, d.dname, e.sal
from emp e
join dept d on e.deptno = d.deptno
where e.deptno in (select deptno from high_headcount)
order by d.dname, e.sal desc;

-- CTEs can reference each other in sequence.
-- Each named block (dept_headcount, high_headcount) is like a temp view.

-------------------------------------------------

-- Recursive CTE
-- Useful for hierarchical data like org charts.

with recursive emp_hierarchy as (
    -- base case: top of org (no manager)
    select empno, ename, mgr, 1 as level
    from emp
    where mgr is null

    union all

    -- recursive step: join employees to their manager
    select e.empno, e.ename, e.mgr, h.level + 1
    from emp e
    join emp_hierarchy h on e.mgr = h.empno
)
select level, ename
from emp_hierarchy
order by level, ename;

-------------------------------------------------

-- Best Practice Notes
-------------------------------------------------

-- 1. Prefer explicit JOIN syntax over comma joins.
--    It improves readability and avoids accidental Cartesian products.

-- 2. Always specify join conditions clearly (ON or USING).

-- 3. EXISTS is usually better than IN for correlated subqueries
--    when working with large datasets.

-- 4. LEFT JOIN + IS NULL is a common pattern to find unmatched rows.

-- 5. Avoid SELECT * in multi-table joins.
--    Explicit column selection prevents ambiguity.

-- 6. CROSS JOIN can produce extremely large result sets — use carefully.

-- 7. Avoid NATURAL JOIN in production code; column additions can silently
--    change join behaviour without any syntax error.

-- 8. Use LATERAL when you need per-row correlated logic that returns
--    multiple columns or rows (more readable than deeply nested subqueries).