-------------------------------------------------
-- CHAPTER 8
-- Working with Dates and Times
-------------------------------------------------
-- This chapter covers all date/time operations in PostgreSQL:
-- getting the current date/time, extracting parts, formatting,
-- arithmetic with intervals, truncation, conversion, finding
-- first/last day of a month, day-of-week filtering, date differences,
-- and timezone handling.
-- All examples use emp.hiredate and sales.date1 from the schema.

-------------------------------------------------

-- Getting the current date and time
-- CURRENT_DATE returns today's date (no time)
-- CURRENT_TIMESTAMP returns date + time with timezone
-- NOW() is equivalent to CURRENT_TIMESTAMP in PostgreSQL

select current_date            as today,
       current_timestamp       as now_with_tz,
       now()                   as also_now,
       current_time            as time_only,
       localtimestamp          as now_no_tz;

-------------------------------------------------

-- Extracting parts from a date
-- EXTRACT returns a double precision number
-- Useful parts: YEAR, MONTH, DAY, HOUR, MINUTE, SECOND, DOW, DOY, WEEK, QUARTER

select ename,
       hiredate,
       extract(year    from hiredate) as hire_year,
       extract(month   from hiredate) as hire_month,
       extract(day     from hiredate) as hire_day,
       extract(dow     from hiredate) as day_of_week,  -- 0=Sunday, 6=Saturday
       extract(doy     from hiredate) as day_of_year,
       extract(quarter from hiredate) as hire_quarter
from emp;

-------------------------------------------------

-- DATE_PART — alternative to EXTRACT, same result, function syntax
-- Preferred by some for readability

select ename,
       date_part('year',  hiredate) as hire_year,
       date_part('month', hiredate) as hire_month,
       date_part('dow',   hiredate) as day_of_week
from emp;

-------------------------------------------------

-- Formatting dates with TO_CHAR
-- TO_CHAR is the most flexible date formatting function in PostgreSQL

select ename,
       hiredate,
       to_char(hiredate, 'YYYY-MM-DD')          as iso_format,
       to_char(hiredate, 'DD/MM/YYYY')          as uk_format,
       to_char(hiredate, 'Month DD, YYYY')      as long_format,
       to_char(hiredate, 'Day, DD Mon YYYY')    as full_day_format,
       to_char(hiredate, 'YYYY-MM-DD HH24:MI:SS') as with_time
from emp;

-- Common format masks:
-- YYYY = 4-digit year    YY = 2-digit year
-- MM = month number      Month = full month name   Mon = abbreviated
-- DD = day number        Day = full day name        Dy = abbreviated
-- HH24 = 24-hour         HH12 = 12-hour             MI = minutes   SS = seconds

-------------------------------------------------

-- Date arithmetic using intervals
-- PostgreSQL supports adding/subtracting intervals directly

select ename,
       hiredate,
       hiredate + interval '1 year'   as one_year_later,
       hiredate - interval '6 months' as six_months_before,
       hiredate + interval '90 days'  as ninety_days_after,
       hiredate + interval '2 hours'  as two_hours_later
from emp;

-- Intervals can combine units: interval '1 year 3 months 5 days'

-------------------------------------------------

-- AGE function — human-readable interval between two dates
-- Great for calculating tenure, age, or time elapsed

select ename,
       hiredate,
       age(hiredate)                         as tenure,
       age(current_date, hiredate)           as tenure_explicit,
       extract(year from age(hiredate))      as years_employed,
       extract(month from age(hiredate))     as months_in_current_year
from emp
order by hiredate;

-------------------------------------------------

-- Difference in days between two dates
-- Subtracting two DATE values returns an integer (number of days)

select ename,
       hiredate,
       current_date - hiredate                       as days_employed,
       (current_date - hiredate) / 365               as approx_years,
       round((current_date - hiredate) / 365.0, 1)   as years_decimal
from emp
order by hiredate;

-------------------------------------------------

-- DATE_TRUNC — truncate a date to a specific precision
-- Very useful for grouping by month, year, week, etc.

select ename,
       hiredate,
       date_trunc('year',    hiredate) as start_of_year,
       date_trunc('month',   hiredate) as start_of_month,
       date_trunc('week',    hiredate) as start_of_week,
       date_trunc('quarter', hiredate) as start_of_quarter
from emp;

-- date_trunc sets all smaller units to zero/first, returning a timestamp.
-- To get a DATE, cast: date_trunc('month', hiredate)::date

-------------------------------------------------

-- Count employees hired per month (DATE_TRUNC grouping pattern)

select date_trunc('month', hiredate)::date as hire_month,
       count(*) as headcount
from emp
group by hire_month
order by hire_month;

-------------------------------------------------

-- First and last day of a month

select hiredate,
       date_trunc('month', hiredate)::date                             as first_day,
       (date_trunc('month', hiredate) + interval '1 month - 1 day')::date as last_day
from emp;

-- First day: truncate to start of month.
-- Last day: add 1 month then subtract 1 day.

-------------------------------------------------

-- Day-of-week filtering
-- DOW: 0 = Sunday, 1 = Monday, ..., 6 = Saturday

-- Find employees hired on a Monday
select ename, hiredate,
       to_char(hiredate, 'Day') as day_name
from emp
where extract(dow from hiredate) = 1;

-- Find employees hired on a weekend
select ename, hiredate,
       to_char(hiredate, 'Dy') as day_abbrev
from emp
where extract(dow from hiredate) in (0, 6);

-------------------------------------------------

-- Converting strings to dates with TO_DATE

select to_date('25-12-2024', 'DD-MM-YYYY')  as christmas,
       to_date('2024/01/15', 'YYYY/MM/DD')  as january_15,
       '2024-06-01'::date                   as june_1_cast;

-- to_date(string, format): parses string into a DATE
-- ::date is PostgreSQL cast shorthand

-------------------------------------------------

-- Filtering by date range — best practice: use DATE_TRUNC or explicit bounds

-- Find employees hired in 1981
select ename, hiredate
from emp
where hiredate >= '1981-01-01'
  and hiredate <  '1982-01-01';

-- Alternatively using DATE_TRUNC
select ename, hiredate
from emp
where date_trunc('year', hiredate) = '1981-01-01';

-- Avoid: WHERE EXTRACT(YEAR FROM hiredate) = 1981
-- That expression prevents index usage on hiredate.

-------------------------------------------------

-- Timezone handling — AT TIME ZONE
-- Convert a timestamp from one timezone to another

select now()                                           as utc_now,
       now() at time zone 'America/New_York'           as eastern_time,
       now() at time zone 'Asia/Kolkata'               as india_time,
       now() at time zone 'Europe/London'              as london_time;

-- List available timezone names:
-- SELECT name FROM pg_timezone_names ORDER BY name;

-------------------------------------------------

-- Working with the sales table (date1 column)

select date1,
       extract(year  from date1) as yr,
       extract(month from date1) as mo,
       to_char(date1, 'Month YYYY') as period
from sales
order by date1;

-------------------------------------------------

-- Generate a date series (no helper table needed)
-- Useful for filling gaps in time-series data

select generate_series(
           '1981-01-01'::date,
           '1981-12-31'::date,
           '1 month'::interval
       )::date as month_start;

-------------------------------------------------

-- Find gaps: months with no hiring activity

select gs.month_start
from generate_series(
         '1980-01-01'::date,
         '1983-12-01'::date,
         '1 month'::interval
     ) as gs(month_start)
where not exists (
    select 1
    from emp
    where date_trunc('month', hiredate)::date = gs.month_start::date
)
order by gs.month_start;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Always store dates in UTC in the database.
--    Convert to local timezone at the application layer.

-- 2. Use DATE_TRUNC for range queries — it keeps the expression sargable
--    (index-friendly) when used with >= and < bounds:
--    WHERE hiredate >= date_trunc('year', now())
--    instead of: WHERE EXTRACT(YEAR FROM hiredate) = 2024

-- 3. Use TO_CHAR for display/formatting only.
--    Store dates as DATE or TIMESTAMP, never as VARCHAR.

-- 4. Subtracting two DATE values gives an integer (days).
--    Use AGE() when you need a human-readable interval (years, months, days).

-- 5. Use GENERATE_SERIES to create date ranges — it replaces helper tables
--    and makes gap-finding and time-series joins straightforward.

-- 6. Prefer TIMESTAMPTZ (timestamp with time zone) over TIMESTAMP
--    for any date that has a timezone context.
