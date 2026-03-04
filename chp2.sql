---------------------------------------------
-- CHAPTER 2:  Sorting Query Results
----------------------------------------------

-- Returning Query Results in a Specified Order
select ename,job,sal
from emp
where deptno = 10
order by sal asc;

-- Sorting by Multiple Fields
select empno,deptno,sal,ename,job
from emp
order by deptno, sal desc;

-- Sorting by Substrings
-- substr(string, start_position, length)
-- eg. sort by the last two characters in the JOB field.
select ename,job
from emp
order by substr(job,length(job)-1);

-- Sorting Mixed Alphanumeric Data
-- It replaces all digits in the string with #, 
-- then removes those # to get the non-numeric part (like A from A10).
-- Then it removes that non-numeric part from the original string,
-- leaving only the number part, and sorts by that value.

select data
from V
order by replace(
           data,
           replace(
               translate(data,'0123456789','##########'),
               '#',''
           ),
           ''
       );

-- Dealing with Nulls When Sorting
-- PostgreSQL treats NULL as larger than any non-null value when sorting.
select ename,sal,comm
from emp
order by comm asc;

-- we can also control null postion by 
select ename,sal,comm
from emp
ORDER BY comm ASC NULLS FIRST;

-- OR ORDER BY comm DESC NULLS LAST;

-- Sorting on a Data-Dependent Key
select ename,sal,job,comm
from emp
order by case when job = 'SALESMAN' then comm
      else sal end;