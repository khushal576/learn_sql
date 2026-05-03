-------------------------------------------------
-- CHAPTER 7
-- Working with Numbers
-------------------------------------------------
-- This chapter covers numeric aggregation (AVG, MIN, MAX, SUM, COUNT),
-- running totals, moving averages, mode, median, percentile functions,
-- basic math (ROUND, CEIL, FLOOR, ABS, POWER, SQRT, MOD),
-- ranking window functions, histogram bucketing, and division-by-zero safety.

-------------------------------------------------

-- Computing an Average
-- AVG() calculates the average value of a numeric column.
-- NULL values are automatically ignored.

select avg(sal) as avg_sal
from emp;


-- Finding the Min/Max Value in a Column
-- MIN() returns the smallest value
-- MAX() returns the largest value

select min(sal) as min_sal, max(sal) as max_sal
from emp;



-- Summing the Values in a Column
-- SUM() adds all numeric values in the column.

select sum(sal)
from emp;


-- Counting Rows in a Table
-- COUNT(*) counts all rows including rows containing NULL values.

select count(*)
from emp;



-- Count rows per department
-- GROUP BY divides rows into groups before aggregation.

select deptno, count(*)
from emp
group by deptno;



-- Counting Values in a Column
-- COUNT(column_name) counts only NON-NULL values.

-- Count the number of non-NULL values in the EMP table’s COMM column:
select count(comm)
 from emp;



-- Generating a Running Total
-- Window functions allow cumulative calculations across rows.
-- Here salary is accumulated in sorted order.

select ename, sal,
sum(sal) over (order by sal,empno) as running_total
from emp
order by 2;



-- Generating a Running Product
-- Since SQL doesn't provide PRODUCT() aggregation,
-- we use mathematical identity:
-- product(x) = exp(sum(ln(x)))

select empno,ename,sal,
exp(sum(ln(sal))over(order by sal,empno)) as running_prod
from emp
where deptno = 10;



-- smoothing a Series of Values
-- Moving average calculation using LAG().
-- Useful in time-series analysis.

select date1, sales,
lag(sales,1) over(order by date1) as salesLagOne,
lag(sales,2) over(order by date1) as salesLagTwo,
(sales
+ (lag(sales,1) over(order by date1))
+ lag(sales,2) over(order by date1))/3 as MovingAverage
from sales;



-- Calculating a Mode
-- Mode = most frequently occurring value.

select sal
from (
select sal,
dense_rank()over( order by cnt desc) as rnk
from (
select sal, count(*) as cnt
from emp
where deptno = 20
group by sal) x
) y
where rnk = 1;



-- Calculating a Median
-- percentile_cont() computes median or other percentiles.

select percentile_cont(0.5)
within group(order by sal)
from emp
where deptno=20;



-- Determining the Percentage of a Total
-- Calculates contribution of department 10 salary to total salary.

select (sum(
case when deptno = 10 then sal end)/sum(sal)
)*100 as pct
from emp;



-- Aggregating Nullable Columns
-- COALESCE converts NULL to zero before aggregation.

select avg(coalesce(comm,0)) as avg_comm
from emp;



-- Computing Averages Without High and Low Values
-- Removes extreme values (min and max) before averaging.

select avg(sal)
from emp
where sal not in (
(select min(sal) from emp),
(select max(sal) from emp));



-- Converting Alphanumeric Strings into Numbers
-- Extract numeric part from mixed string.

select cast(
replace(
translate( 'paul123f321',
'abcdefghijklmnopqrstuvwxyz',
rpad('#',26,'#')),'#','')
as integer ) as num
from t1;



-------------------------------------------------
-- Widely Used Numeric Queries
-------------------------------------------------

-- Rounding numbers
-- ROUND(number,decimal_places)

select round(123.4567,2);



-- Ceiling (round up)

select ceil(123.2);



-- Floor (round down)

select floor(123.9);



-- Absolute value

select abs(-45);



-- Power function

select power(2,10);



-- Square root

select sqrt(144);



-- Modulus (remainder)

select mod(10,3);



-- Percentage calculation example

select ename,
sal,
sal * 0.10 as bonus
from emp;



-- Calculate percent of total using window function
-- Widely used in reporting dashboards.

select ename,
sal,
sal / sum(sal) over() * 100 as percent_of_total
from emp;



-- Rank values

select ename,sal,
rank() over(order by sal desc) as rank_sal
from emp;



-- Dense rank

select ename,sal,
dense_rank() over(order by sal desc) as dense_rank_sal
from emp;



-- Row number

select ename,sal,
row_number() over(order by sal desc)
from emp;



-- Difference between rows

select ename,sal,
sal - lag(sal) over(order by sal) as diff
from emp;



-- Cumulative percentage

select ename,sal,
sum(sal) over(order by sal)
/
sum(sal) over() * 100 as cumulative_pct
from emp;



-- NTILE: divide rows into N equal buckets (quartiles, deciles, etc.)
-- Very useful in reporting to label top/bottom performers.

select ename, sal,
ntile(4) over(order by sal) as quartile
from emp;

-- quartile = 1 means lowest paid group, 4 = highest paid group



-- PERCENT_RANK: relative rank of a row as a percentage (0.0 to 1.0)
-- CUME_DIST: cumulative distribution (fraction of rows <= current row)
-- Both widely used in analytics and percentile reports.

select ename, sal,
round(percent_rank() over(order by sal)::numeric, 2) as pct_rank,
round(cume_dist()    over(order by sal)::numeric, 2) as cum_dist
from emp
order by sal;



-- NULLIF to avoid division by zero
-- Best practice: wrap divisor with NULLIF(column, 0)
-- so division returns NULL instead of crashing.

select ename,
sal,
comm,
sal / nullif(comm, 0) as sal_per_comm
from emp;



-- GENERATE_SERIES — produce a set of numeric values
-- Extremely useful for testing, date ranges, and iteration without a helper table.

select generate_series(1, 10) as n;

-- Generate a multiplication table column
select n, n * n as squared
from generate_series(1, 10) as gs(n);

-- Use as a row-iteration replacement for T10 helper table
select substr('SMITH', gs.n, 1) as char
from generate_series(1, length('SMITH')) as gs(n);

-------------------------------------------------

-- WIDTH_BUCKET — histogram bucketing
-- Divides a numeric range into equal-width buckets.
-- Useful for salary distribution analysis, age groupings, etc.

select ename,
       sal,
       width_bucket(sal, 700, 5100, 5) as salary_bucket
from emp
order by sal;

-- width_bucket(value, min, max, buckets)
-- Returns the bucket number (1 = lowest, n = highest).
-- Bucket 1: 700–1480, Bucket 2: 1480–2260, ... Bucket 5: 4320–5100
-- Values outside range return 0 or buckets+1.

-------------------------------------------------

-- Best Practice Notes
-------------------------------------------------

-- 1. COUNT(*) is faster and safer than COUNT(column).
-- 2. Window functions (OVER()) are extremely powerful
--    for analytics such as running totals, ranking, etc.
-- 3. Avoid dividing by zero — use NULLIF(column,0).
--    Example: select sal / NULLIF(comm,0) from emp;
-- 4. COALESCE() is widely used when working with numeric NULL values.
-- 5. Percent calculations are often easier using window functions.
-- 6. Use GENERATE_SERIES instead of helper tables (T10, T100) for iteration.
--    It is more flexible and requires no pre-inserted data.
-- 7. WIDTH_BUCKET is the cleanest way to build histograms without many CASE branches.