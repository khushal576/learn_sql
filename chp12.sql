-------------------------------------------------
-- CHAPTER 12
-- Subqueries Deep Dive
-------------------------------------------------
-- A subquery is a SELECT statement nested inside another SQL statement.
-- This chapter covers: non-correlated vs correlated subqueries,
-- scalar subqueries, subqueries in FROM/WHERE/HAVING/SELECT,
-- EXISTS vs IN performance tradeoffs, and derived tables.
-- Mastering subqueries is one of the most tested intermediate SQL skills.

-------------------------------------------------

-- Non-correlated subquery
-- Executed ONCE, result is reused by the outer query.
-- The inner query does not reference any column from the outer query.

-- Find employees who earn more than the company average
select ename, sal
from emp
where sal > (select avg(sal) from emp);

-- The subquery (select avg(sal) from emp) runs once → returns 2073.
-- The outer query filters using that single value.

-------------------------------------------------

-- Non-correlated subquery with IN
-- Returns a list, outer query checks membership.

-- Find employees in departments located in NEW YORK or DALLAS
select ename, deptno
from emp
where deptno in (
    select deptno
    from dept
    where loc in ('NEW YORK', 'DALLAS')
);

-------------------------------------------------

-- Non-correlated subquery with NOT IN
-- Caution: if the subquery returns any NULL, NOT IN returns no rows.

-- Employees NOT in any department that has a bonus earner
select ename, deptno
from emp
where deptno not in (
    select deptno
    from emp
    where empno in (select empno from emp_bonus)
);

-- Safe NULL-aware version: use NOT EXISTS instead (shown below).

-------------------------------------------------

-- Correlated subquery
-- Executed ONCE PER ROW of the outer query.
-- The inner query references a column from the outer query.

-- Find employees who earn more than the average salary in THEIR department
select e.ename,
       e.deptno,
       e.sal,
       (select avg(sal) from emp where deptno = e.deptno) as dept_avg
from emp e
where e.sal > (
    select avg(sal)
    from emp
    where deptno = e.deptno   -- references e.deptno from outer query
);

-- For each row in emp (alias e), the subquery runs with that row's deptno.
-- This is what makes it "correlated" — it depends on the outer row.

-------------------------------------------------

-- Correlated subquery to find the highest earner per department

select ename, deptno, sal
from emp e
where sal = (
    select max(sal)
    from emp
    where deptno = e.deptno
);

-- For each employee, the subquery finds the max salary in their dept.
-- The outer WHERE keeps only employees matching that max.

-------------------------------------------------

-- Scalar subquery in SELECT clause
-- A subquery that returns exactly one row and one column.
-- Used like a computed column.

select ename,
       sal,
       deptno,
       (select avg(sal) from emp where deptno = e.deptno) as dept_avg,
       (select max(sal) from emp)                          as company_max,
       (select dname from dept where deptno = e.deptno)   as dept_name
from emp e
order by deptno;

-- Scalar subqueries run once per row — can be expensive on large tables.
-- Often better replaced with a JOIN or CTE for performance.

-------------------------------------------------

-- Subquery in FROM clause — derived table (inline view)
-- The subquery is treated as a temporary table.
-- Must have an alias.

select dept_name,
       avg_sal,
       headcount
from (
    select d.dname        as dept_name,
           avg(e.sal)     as avg_sal,
           count(e.empno) as headcount
    from dept d
    left join emp e on d.deptno = e.deptno
    group by d.dname
) dept_summary
where headcount > 0
order by avg_sal desc;

-- The inner query (dept_summary) is computed first.
-- The outer query filters and sorts the result.

-------------------------------------------------

-- Subquery in HAVING clause
-- Filter aggregated groups based on a subquery result.

-- Find departments whose average salary exceeds the company average
select deptno,
       round(avg(sal), 2) as avg_sal
from emp
group by deptno
having avg(sal) > (select avg(sal) from emp)
order by avg_sal desc;

-- HAVING filters AFTER aggregation; subquery provides the threshold.

-------------------------------------------------

-- EXISTS vs IN — key interview topic

-- EXISTS: returns TRUE as soon as the subquery finds one matching row.
-- Stops scanning early — efficient when the subquery has many rows.
-- Handles NULLs safely.

-- Departments that have at least one employee (EXISTS)
select deptno, dname
from dept d
where exists (
    select 1
    from emp e
    where e.deptno = d.deptno
);

-- IN version (equivalent but different execution plan)
select deptno, dname
from dept
where deptno in (
    select deptno
    from emp
);

-------------------------------------------------

-- NOT EXISTS vs NOT IN — the NULL trap

-- NOT IN with a subquery that could return NULL → returns ZERO rows
-- because: value NOT IN (1, 2, NULL) is always UNKNOWN (not TRUE).

-- Safe: NOT EXISTS (handles NULLs correctly)
select dname
from dept d
where not exists (
    select 1
    from emp e
    where e.deptno = d.deptno
);

-- Risky: NOT IN (breaks if subquery contains NULLs)
-- select dname from dept
-- where deptno not in (select deptno from emp);
-- If any emp.deptno is NULL, this returns 0 rows — silent bug.

-- Rule: always prefer NOT EXISTS over NOT IN for safety.

-------------------------------------------------

-- Subquery returning multiple columns — ROW constructor

-- Find employees whose (deptno, job) combination matches a specific pair
select ename, deptno, job
from emp
where (deptno, job) in (
    select deptno, job
    from emp
    where ename = 'SCOTT'
);

-- Returns all employees with the same department AND job as SCOTT.

-------------------------------------------------

-- Subquery vs CTE — same result, CTE is more readable for complex logic

-- Subquery version:
select ename, sal
from (
    select ename, sal,
           rank() over (partition by deptno order by sal desc) as rnk
    from emp
) x
where rnk = 1;

-- CTE version (preferred for readability):
with ranked as (
    select ename, sal,
           rank() over (partition by deptno order by sal desc) as rnk
    from emp
)
select ename, sal
from ranked
where rnk = 1;

-------------------------------------------------

-- Subquery to calculate running difference without window functions
-- (classic interview problem using correlated subquery)

select e1.ename,
       e1.hiredate,
       e1.sal,
       (
           select e2.sal
           from emp e2
           where e2.hiredate = (
               select max(e3.hiredate)
               from emp e3
               where e3.hiredate < e1.hiredate
           )
       ) as prev_sal
from emp e1
order by e1.hiredate;

-- This is the "before window functions" version — shows why LAG() is better.
-- Both produce the same result; LAG is far simpler and faster.

-------------------------------------------------

-- Subquery for pagination (keyset / seek method)
-- More efficient than LIMIT/OFFSET on large tables.

-- Get the next page of employees after empno 7698, ordered by empno
select ename, empno, sal
from emp
where empno > 7698
order by empno
limit 5;

-- This "seek" approach avoids scanning skipped rows unlike OFFSET.

-------------------------------------------------

-- Interview classic: find the Nth highest salary (without window functions)

-- 2nd highest salary using a correlated subquery
select min(sal) as second_highest
from emp
where sal in (
    select distinct sal
    from emp
    order by sal desc
    limit 2
);

-- Cleaner version using window functions (preferred):
select sal
from (
    select sal,
           dense_rank() over (order by sal desc) as rnk
    from emp
) x
where rnk = 2;

-------------------------------------------------

-- Interview classic: employees with salary above their manager's salary

select e.ename   as employee,
       e.sal     as emp_sal,
       m.ename   as manager,
       m.sal     as mgr_sal
from emp e
join emp m on e.mgr = m.empno
where e.sal > m.sal;

-- Self-join version. Can also be written as a correlated subquery:
select ename, sal
from emp e
where sal > (
    select sal
    from emp
    where empno = e.mgr
);

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Non-correlated subqueries run ONCE; correlated run ONCE PER ROW.
--    Prefer non-correlated or CTEs when possible on large datasets.

-- 2. Always use NOT EXISTS instead of NOT IN when the subquery
--    might return NULLs — NOT IN with NULLs silently returns zero rows.

-- 3. EXISTS stops at the first matching row — use it over IN
--    when the subquery table is large.

-- 4. Scalar subqueries in SELECT are convenient but run per-row.
--    Replace with a JOIN or CTE for better performance at scale.

-- 5. Subqueries in FROM (derived tables) must always have an alias.

-- 6. For Nth-highest-salary style problems, DENSE_RANK() is cleaner
--    and more robust than nested subqueries.

-- 7. The seek/keyset pagination pattern (WHERE id > last_seen_id)
--    is far more efficient than LIMIT/OFFSET on large tables.
