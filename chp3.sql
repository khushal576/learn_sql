---------------------------------------------
-- CHAPTER 3:  Working with Multiple Tables
----------------------------------------------

-- Stacking One Rowset atop Another
-- use UNION ALL to combine rows from multiple tables:
select ename as ename_and_dname, deptno
from emp
where deptno = 10
union all
select '----------', null
from t1
union all
select dname, deptno
from dept;

-- Combining Related Rows
-- joins

select e.ename, d.loc
from emp e, dept d
where e.deptno = d.deptno
and e.deptno = 10;
-- another way to write above query
SELECT e.ename, d.loc
FROM emp e
INNER JOIN dept d
ON e.deptno = d.deptno
WHERE e.deptno = 10;

-- Finding Rows in Common Between Two Tables
-- return only row which is in both view2 and emp
select empno,ename,job,sal,deptno
from emp
where (ename,job,sal) in (
     select ename,job,sal from emp
     intersect
     select ename,job,sal from V2);

-- Retrieving Values from One Table That Do Not Exist in Another
-- fetch deptno which is not in emp table
select distinct deptno
from dept
where deptno not in (select deptno from emp);

-- Retrieving Rows from One Table That Do Not Correspond to Rows in Another
-- Returns departments that have no matching employees (i.e., unmatched rows from dept using a LEFT JOIN).
select d.*
from dept d left outer join emp e
on (d.deptno = e.deptno)
where e.deptno is null;

-- Adding Joins to a Query Without Interfering with Other Joins
-- in second we have used left join becuase we dont want to lost any other row.
select e.ename, d.loc, eb.received
from emp e 
join dept d
on (e.deptno=d.deptno)
left join emp_bonus eb
on (e.empno=eb.empno)
order by 2;

-- Determining Whether Two Tables Have the Same Data
-- Find rows that exist in V but not in emp, and rows that exist in emp but not in V.
-- emp EXCEPT V inds rows present in emp but not in V.
(
    SELECT empno, ename, job, mgr, hiredate, sal, comm, deptno,
           COUNT(*) AS cnt
    FROM v3
    GROUP BY empno, ename, job, mgr, hiredate, sal, comm, deptno
    EXCEPT
    SELECT empno, ename, job, mgr, hiredate, sal, comm, deptno,
           COUNT(*) AS cnt
    FROM emp
    GROUP BY empno, ename, job, mgr, hiredate, sal, comm, deptno
)
UNION ALL
(
    SELECT empno, ename, job, mgr, hiredate, sal, comm, deptno,
           COUNT(*) AS cnt
    FROM emp
    GROUP BY empno, ename, job, mgr, hiredate, sal, comm, deptno
    EXCEPT
    SELECT empno, ename, job, mgr, hiredate, sal, comm, deptno,
           COUNT(*) AS cnt
    FROM v3
    GROUP BY empno, ename, job, mgr, hiredate, sal, comm, deptno
);

-- Identifying and Avoiding Cartesian Products
-- Cartesian Products it gives all posible combination not specific rows
select e.ename, d.loc
 from emp e, dept d
 where e.deptno = 10;

-- use join
select e.ename, d.loc
from emp e, dept d
where e.deptno = 10
and d.deptno = e.deptno;

-- Using NULLs in Operations and Comparisons
-- if we dont do null will never come in result.
select ename,comm
from emp
where coalesce(comm,0) < ( select comm
from emp
where ename = 'WARD' );