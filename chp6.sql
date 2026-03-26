-------------------------------------------------
-- CHAPTER 6
-- Working with Strings
-------------------------------------------------
-- This chapter covers the full toolkit for string manipulation in PostgreSQL:
-- case conversion, trimming, position finding, substring extraction,
-- replacement, splitting, regex operations, aggregation, padding,
-- character iteration, and complex parsing patterns.
-- All examples use the EMP/DEPT schema plus inline literals.

-------------------------------------------------

-- Convert case of text
-- Often used when normalizing user input.

select upper(ename) as upper_name,
       lower(ename) as lower_name,
       initcap(ename) as proper_case
from emp;

-------------------------------------------------

-- Remove spaces from both sides of string
-- Very common when cleaning imported CSV data.

select trim('   hello world   ');


-------------------------------------------------

-- Remove leading or trailing spaces

select ltrim('   hello');
select rtrim('hello   ');


-------------------------------------------------

-- Find position of substring inside string

select strpos('DATABASE','BASE') as position;

-- Returns: 5


-------------------------------------------------

-- Extract substring from string

select substr('DATABASE',5,4);

-- Result: BASE


-------------------------------------------------

-- Replace part of a string

select replace('hello world','world','SQL');

-- Result: hello SQL


-------------------------------------------------

-- Remove all spaces inside a string

select replace('hello world',' ','');


-------------------------------------------------

-- Split string using delimiter
-- Very common for CSV-like data

select split_part('A,B,C,D',',',2);

-- Result: B


-------------------------------------------------

-- Convert delimited string into rows

select unnest(string_to_array('A,B,C,D',',')) as value;


-------------------------------------------------

-- Extract domain from email

select split_part('user@example.com','@',2);

-- Result: example.com


-------------------------------------------------

-- Extract file extension

select split_part('report.pdf','.',2);


-------------------------------------------------

-- Remove special characters using regex

select regexp_replace('abc$%123!','[^a-zA-Z0-9]','','g');

-- Result: abc123


-------------------------------------------------

-- Check if string contains digits

select 'abc123' ~ '[0-9]' as has_number;


-------------------------------------------------

-- Reverse string

select reverse('DATABASE');


-------------------------------------------------

-- Build comma separated list from rows
-- Very common reporting requirement

select deptno,
       string_agg(ename, ',')
from emp
group by deptno;


-------------------------------------------------

-- Build ordered comma separated list

select deptno,
       string_agg(ename, ',' order by sal desc)
from emp
group by deptno;


-------------------------------------------------

-- Remove duplicates inside aggregated list

select deptno,
       string_agg(distinct ename, ',')
from emp
group by deptno;


-- Walking a String
-- Goal: Iterate through each character of a string and return one row per character.
-- Useful when we need to analyze or process each character individually.

select substr(e.ename,iter.pos,1) as C
from (select ename from emp where ename = 'KING') e,
(select id as pos from t10) iter
where iter.pos <= length(e.ename);

-- Explanation:
-- t10 is assumed to be a helper table containing numbers (1..10).
-- iter.pos generates positions inside the string.
-- substr(string,position,length) extracts one character at a time.
-- length(e.ename) ensures we do not exceed the string size.



-- Embedding Quotes Within String Literals
-- SQL uses single quotes for string literals.
-- To include a quote inside a string we double it ('').

select 'g''day mate' qmarks from t1 union all
select 'beavers'' teeth' from t1 union all
select '''' from t1;

-- Example results:
-- g'day mate
-- beavers' teeth
-- '



select 'apples core', 'apple''s core',
 case when '' is null then 0 else 1 end
 from t1;

-- '' is an empty string, not NULL.
-- Therefore the CASE expression returns 1.



-- Counting the Occurrences of a Character in a String
-- This trick counts how many commas exist in a string.

select (length('10,CLARK,MANAGER')-
length(replace('10,CLARK,MANAGER',',','')))/length(',')
as cnt
from t1;

-- Explanation:
-- Step1: length(original string)
-- Step2: remove commas using replace
-- Step3: difference in lengths = number of commas



select
 (length('HELLO HELLO')-
 length(replace('HELLO HELLO','LL','')))/length('LL')
 as correct_cnt,
 (length('HELLO HELLO')-
 length(replace('HELLO HELLO','LL',''))) as incorrect_cnt
 from t1;

-- Demonstrates correct vs incorrect counting of substring occurrences.



-- Removing Unwanted Characters from a String
-- translate() replaces characters using position mapping.
-- replace() removes them afterward.

select ename,
replace(translate(ename,'AEIOU','aaaaa'),'a','') as stripped1,
sal,
replace(cast(sal as char(4)),'0','') as stripped2
from emp;

-- translate(ename, 'AEIOU', 'aaaaa'): replaces every vowel with 'a'
-- replace(..., 'a', ''): then removes all 'a's → vowels removed
-- translate(): character substitution
-- replace(): remove specific characters



-- Separating Numeric and Character Data
-- This query separates alphabetic and numeric portions of a mixed string.

select replace(
translate(data,'0123456789','0000000000'),'0','') as ename,
cast(
replace(
translate(lower(data),
'abcdefghijklmnopqrstuvwxyz',
rpad('z',26,'z')),'z','') as integer) as sal
from (
select ename||sal as data
from emp
) x;

-- Example:
-- Input: KING5000
-- Output:
-- name = KING
-- salary = 5000



-- Determining Whether a String Is Alphanumeric
-- Checks if string contains only letters or numbers.

select data
from V4
where translate(lower(data),
'0123456789abcdefghijklmnopqrstuvwxyz',
rpad('a',36,'a')) = rpad('a',length(data),'a');

-- If translation results in same length string, then data is alphanumeric.



-- Extracting Initials from a Name
-- Convert letters into a placeholder to isolate initials.

select translate(replace('Stewie Griffin','.',''),
 'abcdefghijklmnopqrstuvwxyz',
 rpad('#',26,'#'))
from t1;



-- Ordering by Parts of a String
-- Natural sorting when numbers exist inside text.

select data
from V5
order by
cast(
replace(
translate(data,
replace(
translate(data,'0123456789','##########'),
'#',''),rpad('#',20,'#')),'#','') as integer);

-- Example:
-- A2
-- A10
-- A100
-- Sorted numerically rather than lexicographically.



-- Creating a Delimited List from Table Rows
-- Converts multiple rows into a comma separated string.

select deptno,
string_agg(ename, ',' order by empno) as emps
from emp
group by deptno;

-- string_agg(value, delimiter ORDER BY ...) is the correct PostgreSQL syntax.
-- string_agg() is extremely useful in reporting queries.



-- Converting Delimited Data into a Multivalued IN-List
-- Converts CSV text into rows usable in SQL filtering.

select ename,sal,deptno
from emp
where empno in (
select cast(empno as integer) as empno
from (
select split_part(list.vals,',',iter.pos) as empno
from (select id as pos from t10) iter,
(select ','||'7654,7698,7782,7788'||',' as vals
from t1) list
where iter.pos <=
length(list.vals)-length(replace(list.vals,',',''))
) z
where length(empno) > 0);

-- split_part() extracts nth element from a delimited string.



-- Identifying Strings That Can Be Treated as Numbers
-- Detects numeric content inside mixed strings.

select cast(
case
when
replace(translate(mixed,'0123456789','9999999999'),'9','')
is not null
then
replace(
translate(mixed,
replace(
translate(mixed,'0123456789','9999999999'),'9',''),
rpad('#',length(mixed),'#')),'#','')
else
mixed
end as integer ) as mixed
from V6
where strpos(translate(mixed,'0123456789','9999999999'),'9') > 0;



-- Extracting the nth Delimited Substring
-- Example: return second value from comma separated list.

 select name
from (
select iter.pos, split_part(src.name,',',iter.pos) as name
from (select id as pos from t10) iter,
(select cast(name as text) as name from v7) src
where iter.pos <=
length(src.name)-length(replace(src.name,',',''))+1
) x
where pos = 2;



-- Parsing an IP Address
-- Splits IP address into four octets.

select split_part(y.ip,'.',1) as a,
split_part(y.ip,'.',2) as b,
split_part(y.ip,'.',3) as c,
split_part(y.ip,'.',4) as d
from (select cast('92.111.0.2' as text) as ip from t1) as y;

-- Result:
-- a = 92
-- b = 111
-- c = 0
-- d = 2



-------------------------------------------------

-- LPAD and RPAD — pad strings to a fixed width
-- Common use: formatting report columns, zero-padding employee numbers

select ename,
       lpad(ename, 10, ' ')  as right_aligned,
       rpad(ename, 10, '-')  as left_aligned_dashes,
       lpad(cast(empno as text), 6, '0') as zero_padded_id
from emp;

-- lpad(string, length, fill): pads on the LEFT
-- rpad(string, length, fill): pads on the RIGHT
-- If string is longer than length, it is truncated.

-------------------------------------------------

-- FORMAT — printf-style string templating (PostgreSQL)
-- Cleaner than multiple concatenations for building messages.

select format('Employee %s earns $%s in department %s',
              ename, sal, deptno) as summary
from emp;

-- %s = string substitution
-- %I = identifier (quoted if needed, useful for dynamic SQL)
-- %L = literal value (properly quoted, useful for dynamic SQL)

-- Dynamic SQL example using %I and %L:
-- execute format('select * from %I where deptno = %L', 'emp', 30);

-------------------------------------------------

-- Best Practice Notes
-------------------------------------------------

-- 1. Use split_part() for simple delimiter parsing.
-- 2. Use regexp_replace() for complex string cleaning.
-- 3. string_agg() is extremely useful when building reports.
-- 4. Avoid heavy string manipulation inside WHERE clause on large tables
--    because it prevents index usage.
-- 5. translate() is faster than multiple replace() calls.
-- 6. Use LPAD/RPAD to produce fixed-width output for reports and exports.
-- 7. Use FORMAT() instead of string concatenation (||) when building
--    complex messages or dynamic SQL — it is safer and more readable.