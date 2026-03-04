---------------------------------------------------
-- CHAPTER 4:  Inserting, Updating, and Deleting
---------------------------------------------------

-- Inserting a New Record
-- select * from dept;
insert into dept (deptno,dname,loc)
values (50,'PROGRAMMING','BALTIMORE');

-- Inserting Default Values
-- select * from D;
insert into D (id) values (default);

-- Overriding a Default Value with NULL
-- if we pass null in insert it will consider it null not use default value.
-- select * from D1;
insert into D1 (id, foo) values (null, 'Brighten');

-- Copying Rows from One Table into Another
-- select * from dept_east;
insert into dept_east (deptno,dname,loc)
select deptno,dname,loc
from dept
where loc in ( 'NEW YORK','BOSTON');

-- Copying a Table Definition
-- select * from dept_2;
-- it will just create dont add data;
create table dept_2
as select *
   from dept
where 1 = 0;

-- Blocking Inserts to Certain Columns
-- to block some column entry dont give insert access to that user 
-- create a view with allowed column and give access to that view
-- when insert in view data comes in table.
-- select * from emp;
insert into new_emps (empno, ename, job)
values (1, 'Jonathan', 'Editor');

-- Modifying Records in a Table
-- select * from emp;
update emp
set sal = sal*1.10
where deptno = 20;

-- Updating with Values from Another Table
update emp
	set sal = ns.sal,
	comm = ns.sal/2
from new_sal ns
where ns.deptno = emp.deptno;

-- Merging Records
-- MERGE allows you to:
-- Insert, Update, or Delete rows in a target table
-- based on matching condition with a source table — in a single statement.

MERGE INTO emp_commission ec
USING emp
ON (ec.empno = emp.empno)
WHEN MATCHED AND emp.sal < 2000 THEN
    DELETE
WHEN MATCHED THEN
    UPDATE SET comm = 1000
WHEN NOT MATCHED THEN
    INSERT (empno, ename, deptno, comm)
    VALUES (emp.empno, emp.ename, emp.deptno, emp.comm);


-- Deleting All Records from a Table
-- select * from emp_commission;
-- delete from emp_commission;

-- Deleting Specific Records
-- delete from emp where deptno = 10;

-- Deleting a Single Record
-- delete from emp where empno = 7782;

-- Deleting Referential Integrity Violations
delete from emp
where not exists (select * from dept
                where dept.deptno = emp.deptno);

-- Deleting Duplicate Records
-- select * from dupes order by 1;
delete from dupes
where id not in (select min(id)
                  from dupes
				  group by name);