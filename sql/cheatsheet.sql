-------------------------------------------------
-- PostgreSQL Quick Reference Cheatsheet
-- One-stop syntax recall for all 25 chapters
-- Open in any SQL client — syntax highlighting works automatically
-------------------------------------------------
-- Usage: Find the section you need, copy the syntax, adapt to your table.
-- For full explanations and examples, open the corresponding chapter file.
-------------------------------------------------

-------------------------------------------------
-- SECTION 1: Filtering & Sorting  (Ch1, Ch2)
-------------------------------------------------

-- Basic WHERE
select * from emp where sal > 2000;
select * from emp where sal between 1000 and 3000;       -- inclusive both ends
select * from emp where deptno in (10, 20);
select * from emp where ename like 'S%';                  -- case sensitive
select * from emp where ename ilike 's%';                 -- case insensitive (PostgreSQL)
select * from emp where comm is null;
select * from emp where comm is not null;

-- CASE expression
select ename,
       case when sal >= 3000 then 'HIGH'
            when sal >= 1500 then 'MID'
            else 'LOW'
       end as band
from emp;

-- COALESCE — return first non-null value
select ename, coalesce(comm, 0) as commission from emp;

-- NULLIF — return null if two values are equal (avoid division by zero)
select sal / nullif(comm, 0) from emp;

-- Limit rows
select * from emp order by sal desc fetch first 5 rows only;  -- SQL standard
select * from emp order by sal desc limit 5;                  -- PostgreSQL shorthand
select * from emp order by sal desc limit 5 offset 10;        -- pagination

-- ORDER BY
select * from emp order by deptno asc, sal desc;
select * from emp order by sal desc nulls last;               -- NULLs at end
select * from emp order by case job when 'MANAGER' then 1 else 2 end;  -- custom sort

-------------------------------------------------
-- SECTION 2: Joins & Set Operations  (Ch3)
-------------------------------------------------

-- INNER JOIN
select e.ename, d.dname from emp e join dept d on e.deptno = d.deptno;

-- LEFT JOIN (keep all emp rows, even those with no dept)
select e.ename, d.dname from emp e left join dept d on e.deptno = d.deptno;

-- FULL OUTER JOIN
select e.ename, d.dname from emp e full join dept d on e.deptno = d.deptno;

-- SELF JOIN (manager name)
select e.ename as employee, m.ename as manager
from emp e left join emp m on e.mgr = m.empno;

-- CROSS JOIN (every combination)
select e.ename, d.dname from emp e cross join dept d;

-- LATERAL join (correlated subquery as a join)
select d.dname, top_e.ename, top_e.sal
from dept d
cross join lateral (
    select ename, sal from emp where deptno = d.deptno order by sal desc limit 1
) top_e;

-- Set operations
select deptno from emp union select deptno from dept;          -- distinct rows
select deptno from emp union all select deptno from dept;      -- all rows
select deptno from dept intersect select deptno from emp;      -- in both
select deptno from dept except  select deptno from emp;        -- in first, not second

-- EXISTS
select * from dept d where exists (select 1 from emp e where e.deptno = d.deptno);

-------------------------------------------------
-- SECTION 3: DML  (Ch4)
-------------------------------------------------

-- INSERT
insert into emp (empno, ename, job, sal, deptno) values (9999, 'TEST', 'CLERK', 1000, 30);
insert into emp (empno, ename, job, sal, deptno) select ...;   -- INSERT from SELECT

-- UPDATE
update emp set sal = sal * 1.10 where deptno = 20;

-- DELETE
delete from emp where empno = 9999;

-- TRUNCATE (fast delete all rows, resets sequences)
truncate table emp_staging;

-- ON CONFLICT (upsert)
insert into emp (empno, ename, sal) values (7369, 'SMITH', 1000)
on conflict (empno) do update set sal = excluded.sal;

-- ON CONFLICT do nothing
insert into emp (empno, ename, sal) values (7369, 'SMITH', 1000)
on conflict (empno) do nothing;

-- RETURNING — get values from affected rows
insert into orders (customer) values ('Alice') returning order_id, created_at;
delete from emp where empno = 9999 returning *;

-- MERGE (PostgreSQL 15+)
merge into target_table t
using source_table s on t.id = s.id
when matched     then update set t.val = s.val
when not matched then insert (id, val) values (s.id, s.val);

-------------------------------------------------
-- SECTION 4: String Functions  (Ch6)
-------------------------------------------------

select upper('hello'), lower('HELLO');
select length('hello'), char_length('hello');
select trim('  hello  '), ltrim('  hello'), rtrim('hello  ');
select substr('hello world', 7, 5);        -- 'world' (1-based, length)
select left('hello', 3), right('hello', 3);
select replace('foo bar', 'foo', 'baz');   -- 'baz bar'
select split_part('a,b,c', ',', 2);        -- 'b'
select lpad('5', 3, '0'), rpad('5', 3, '0');  -- '005', '500'
select regexp_replace('abc123', '\d+', 'NUM');  -- 'abcNUM'
select regexp_replace('abc123def456', '\d+', 'N', 'g');  -- all occurrences: 'abcNdefN'
select string_agg(ename, ', ' order by ename) from emp;  -- 'ADAMS, ALLEN, ...'
select format('Hello %s, your sal is %s', ename, sal) from emp;
select position('ell' in 'hello');         -- 2
select concat('a', 'b', 'c');             -- 'abc'
select 'a' || 'b' || 'c';                -- 'abc' (operator form)

-------------------------------------------------
-- SECTION 5: Numeric & Aggregation  (Ch7)
-------------------------------------------------

select sum(sal), avg(sal), min(sal), max(sal), count(*), count(comm) from emp;
select round(3.14159, 2);         -- 3.14
select ceil(3.1), floor(3.9);    -- 4, 3
select abs(-5), mod(10, 3);      -- 5, 1
select power(2, 10), sqrt(144);  -- 1024, 12
select trunc(3.999, 1);          -- 3.9 (truncate, not round)

-- Median
select percentile_cont(0.5) within group (order by sal) as median_sal from emp;

-- Mode
select mode() within group (order by job) as most_common_job from emp;

-- Histogram buckets
select width_bucket(sal, 0, 5000, 5) as bucket, count(*) from emp group by bucket order by bucket;

-- Division — always cast to avoid integer division
select 7 / 2;              -- 3 (integer division!)
select 7.0 / 2;            -- 3.5
select 7::numeric / 2;     -- 3.5

-------------------------------------------------
-- SECTION 6: Date & Time  (Ch8)
-------------------------------------------------

select current_date, current_time, current_timestamp, now();
select extract(year from hiredate), extract(month from hiredate) from emp;
select date_part('year', hiredate), date_part('dow', hiredate) from emp;   -- dow: 0=Sunday
select date_trunc('month', hiredate) from emp;   -- 1st of the month
select to_char(hiredate, 'YYYY-MM-DD Day')  from emp;
select to_char(sal,      'FM$999,999.00')   from emp;
select age(hiredate), age(current_date, hiredate) from emp;  -- interval

-- Interval arithmetic
select hiredate + interval '30 days'  from emp;
select hiredate + interval '1 year 3 months' from emp;
select current_date - hiredate        from emp;   -- returns integer (days)

-- Timezone
select now() at time zone 'America/New_York';
select now() at time zone 'UTC';

-------------------------------------------------
-- SECTION 7: CTEs  (Ch9)
-------------------------------------------------

-- Basic CTE
with dept_avg as (
    select deptno, avg(sal) as avg_sal from emp group by deptno
)
select e.ename, e.sal, d.avg_sal
from emp e join dept_avg d on e.deptno = d.deptno;

-- Multiple CTEs (chained)
with a as (select ...),
     b as (select ... from a)
select * from b;

-- Recursive CTE (org hierarchy)
with recursive org(empno, ename, mgr, depth) as (
    select empno, ename, mgr, 0 from emp where mgr is null    -- anchor
    union all
    select e.empno, e.ename, e.mgr, o.depth + 1              -- recursive
    from emp e join org o on e.mgr = o.empno
)
select * from org order by depth;

-- Force CTE to materialise (prevent inlining — PG 12+)
with expensive as materialized (select ...)
select * from expensive;

-------------------------------------------------
-- SECTION 8: Window Functions  (Ch10)
-------------------------------------------------

-- Syntax: function() OVER (PARTITION BY ... ORDER BY ... frame_clause)
select empno, deptno, sal,
       row_number()  over (partition by deptno order by sal desc) as rn,
       rank()        over (partition by deptno order by sal desc) as rnk,
       dense_rank()  over (partition by deptno order by sal desc) as dense_rnk,
       lag(sal, 1)   over (partition by deptno order by sal)      as prev_sal,
       lead(sal, 1)  over (partition by deptno order by sal)      as next_sal,
       first_value(sal) over (partition by deptno order by sal)   as min_sal_in_dept,
       last_value(sal)  over (
           partition by deptno order by sal
           rows between unbounded preceding and unbounded following
       )                                                          as max_sal_in_dept
from emp;

-- Running total
select empno, sal,
       sum(sal) over (order by hiredate rows between unbounded preceding and current row) as running_total
from emp;

-- Moving average (last 3 rows)
select empno, sal,
       avg(sal) over (order by hiredate rows between 2 preceding and current row) as moving_avg_3
from emp;

-- NTILE — split into N equal buckets
select empno, sal, ntile(4) over (order by sal) as quartile from emp;

-- PERCENT_RANK, CUME_DIST
select empno, sal,
       percent_rank() over (order by sal) as pct_rank,
       cume_dist()    over (order by sal) as cume_dist
from emp;

-- Reuse window definition with named WINDOW clause
select empno, deptno, sal,
       sum(sal)  over w as dept_total,
       avg(sal)  over w as dept_avg,
       count(*)  over w as dept_headcount
from emp
window w as (partition by deptno);

-------------------------------------------------
-- SECTION 9: Aggregation — Advanced  (Ch11)
-------------------------------------------------

-- FILTER — conditional aggregate
select count(*) filter (where sal > 2000) as high_earners,
       avg(sal)  filter (where deptno = 10) as dept10_avg
from emp;

-- GROUPING SETS — multiple GROUP BY levels in one query
select deptno, job, sum(sal)
from emp
group by grouping sets ((deptno, job), (deptno), ());

-- ROLLUP — subtotals + grand total
select deptno, job, sum(sal)
from emp
group by rollup (deptno, job);

-- CUBE — all combinations of grouping
select deptno, job, sum(sal)
from emp
group by cube (deptno, job);

-- GROUPING() — detect which columns are in the current grouping level
select deptno, job,
       grouping(deptno) as is_dept_rollup,
       sum(sal)
from emp
group by rollup (deptno, job);

-------------------------------------------------
-- SECTION 10: Subqueries  (Ch12)
-------------------------------------------------

-- Scalar subquery (single value)
select ename, sal, (select avg(sal) from emp) as overall_avg from emp;

-- Derived table (subquery in FROM)
select d.job, d.avg_sal from (select job, avg(sal) as avg_sal from emp group by job) d;

-- EXISTS vs IN — prefer EXISTS for large subqueries
select * from dept d where exists (select 1 from emp e where e.deptno = d.deptno);
select * from emp where deptno in (select deptno from dept);

-- NOT IN NULL trap — if subquery returns any NULL, NOT IN returns no rows
-- Safer: use NOT EXISTS
select * from dept d where not exists (select 1 from emp e where e.deptno = d.deptno);

-- Correlated subquery — references the outer query
select ename, sal from emp e
where sal > (select avg(sal) from emp where deptno = e.deptno);

-------------------------------------------------
-- SECTION 11: Indexes & Performance  (Ch13)
-------------------------------------------------

-- Create index types
create index idx_emp_sal       on emp (sal);                         -- B-tree (default)
create index idx_emp_sal_desc  on emp (sal desc);                    -- descending B-tree
create index idx_emp_job_sal   on emp (job, sal);                    -- composite
create index idx_emp_upper_name on emp (upper(ename));               -- functional
create index idx_emp_active    on emp (sal) where comm is not null;  -- partial
create index idx_emp_covering  on emp (deptno) include (ename, sal); -- covering (index-only scan)
create index idx_skills_gin    on emp_skills using gin (skills);     -- GIN for arrays/JSON/FTS

-- EXPLAIN — show query plan
explain select * from emp where sal > 2000;
explain (analyze, buffers) select * from emp where sal > 2000;
explain (analyze, format json) select * from emp where sal > 2000;

-- Check index usage
select indexrelname, idx_scan, idx_tup_read
from pg_stat_user_indexes
where relname = 'emp';

-- Remove duplicate or unused indexes
drop index concurrently idx_emp_sal;   -- CONCURRENTLY avoids locking the table

-------------------------------------------------
-- SECTION 12: Transactions, Views, Constraints  (Ch14)
-------------------------------------------------

-- Transaction control
begin;
    update emp set sal = sal + 100 where deptno = 10;
    savepoint before_dept20;
    update emp set sal = sal + 100 where deptno = 20;
    rollback to before_dept20;   -- undo dept20 change only
commit;

-- Isolation levels
set transaction isolation level read committed;    -- default
set transaction isolation level repeatable read;
set transaction isolation level serializable;

-- CREATE VIEW
create or replace view high_earners as
    select empno, ename, sal from emp where sal > 2000;

-- MATERIALIZED VIEW (stores results on disk)
create materialized view mv_dept_stats as
    select deptno, avg(sal), count(*) from emp group by deptno;

refresh materialized view mv_dept_stats;
refresh materialized view concurrently mv_dept_stats;  -- no lock, needs unique index

-- Constraints
alter table emp add constraint chk_sal check (sal > 0);
alter table emp add constraint uq_ename unique (ename);
alter table emp add constraint fk_dept foreign key (deptno) references dept(deptno);

-------------------------------------------------
-- SECTION 13: PL/pgSQL  (Ch15)
-------------------------------------------------

-- Function skeleton
create or replace function function_name(param1 type, param2 type)
returns return_type
language plpgsql
stable  -- or immutable / volatile
as $$
declare
    v_var  type;
begin
    -- logic here
    return result;
exception
    when no_data_found then
        -- handle
    when others then
        raise;
end;
$$;

-- Function returning a table
create or replace function dept_roster(p_deptno int)
returns table(empno int, ename text, sal numeric)
language plpgsql stable as $$
begin
    return query
    select e.empno, e.ename, e.sal from emp e where e.deptno = p_deptno;
end;
$$;

select * from dept_roster(10);

-- Procedure skeleton (no return value, can use COMMIT inside)
create or replace procedure procedure_name(param1 type)
language plpgsql as $$
begin
    -- logic here
end;
$$;
call procedure_name(value);

-- Control flow inside PL/pgSQL
if condition then ... elsif condition then ... else ... end if;
for i in 1..10 loop ... end loop;
while condition loop ... end loop;
foreach v in array arr loop ... end loop;

-------------------------------------------------
-- SECTION 14: Triggers & Dynamic SQL  (Ch16)
-------------------------------------------------

-- Trigger function skeleton
create or replace function trg_fn_name()
returns trigger language plpgsql as $$
begin
    -- NEW = new row (INSERT/UPDATE), OLD = old row (UPDATE/DELETE)
    -- TG_OP = 'INSERT' | 'UPDATE' | 'DELETE'
    -- TG_TABLE_NAME = table name
    return NEW;  -- use NULL to abort the operation (BEFORE triggers)
end;
$$;

-- Attach trigger
create trigger trg_name
before insert or update on emp
for each row
when (NEW.sal < 0)               -- optional WHEN condition
execute function trg_fn_name();

-- AFTER trigger (fires after the statement succeeds)
create trigger trg_audit
after insert or update or delete on emp
for each row execute function trg_fn_name();

-- Dynamic SQL
execute format('select * from %I where %I = %L', table_name, col_name, value);
-- %I = identifier (quoted), %L = literal (quoted), %s = raw string (unsafe for values)

-------------------------------------------------
-- SECTION 15: JSON & JSONB  (Ch17)
-------------------------------------------------

-- Operators
-- json_col -> 'key'         -- returns JSON (preserves type)
-- json_col ->> 'key'        -- returns text
-- json_col -> 2             -- array element by index
-- json_col #> '{a,b}'       -- nested path, returns JSON
-- json_col #>> '{a,b}'      -- nested path, returns text
-- json_col @> '{"key":"val"}'::jsonb  -- containment (JSONB only)
-- json_col ? 'key'          -- key exists (JSONB only)
-- json_col - 'key'          -- delete key (JSONB only)

-- Update a JSONB field
update my_table
set data = jsonb_set(data, '{address,city}', '"London"')
where id = 1;

-- Expand JSONB array into rows
select jsonb_array_elements(data->'items') as item from my_table;

-- Expand JSONB object into key/value rows
select * from jsonb_each(data) from my_table;

-- Build JSON from a row
select row_to_json(emp) from emp limit 1;
select jsonb_agg(row_to_json(emp)) from emp where deptno = 10;

-- GIN index for JSONB (required for @> and ? performance)
create index idx_data_gin on my_table using gin (data);

-- JSONPath (PostgreSQL 12+)
select jsonb_path_query(data, '$.items[*].price') from my_table;

-------------------------------------------------
-- SECTION 16: Partitioning  (Ch18)
-------------------------------------------------

-- RANGE partitioning skeleton
create table orders (
    id          bigint generated always as identity,
    order_date  date not null,
    amount      numeric
) partition by range (order_date);

create table orders_2024 partition of orders
    for values from ('2024-01-01') to ('2025-01-01');    -- upper is exclusive

create table orders_2025 partition of orders
    for values from ('2025-01-01') to ('2026-01-01');

-- LIST partitioning skeleton
create table emp_by_region (deptno int, region text, sal numeric)
    partition by list (region);
create table emp_east partition of emp_by_region for values in ('EAST', 'NORTHEAST');
create table emp_west partition of emp_by_region for values in ('WEST', 'SOUTHWEST');

-- HASH partitioning skeleton (distribute evenly)
create table events (id bigint, payload text) partition by hash (id);
create table events_0 partition of events for values with (modulus 4, remainder 0);
create table events_1 partition of events for values with (modulus 4, remainder 1);
-- ...

-- Detach / attach partitions
alter table orders detach partition orders_2024;
alter table orders attach partition orders_2024 for values from ('2024-01-01') to ('2025-01-01');

-------------------------------------------------
-- SECTION 17: Full-Text Search  (Ch19)
-------------------------------------------------

-- tsvector and tsquery
select to_tsvector('english', 'The quick brown fox jumps over the lazy dog');
select to_tsquery('english', 'quick & fox');
select plainto_tsquery('english', 'quick brown fox');   -- plain text, auto &
select websearch_to_tsquery('english', '"quick brown" OR lazy');  -- Google-style

-- @@ operator — does the document match the query?
select 'quick brown fox'::tsvector @@ 'quick & fox'::tsquery;   -- true

-- On a table
select ename from emp where to_tsvector('english', ename || ' ' || job) @@ to_tsquery('manager');

-- GIN index for fast FTS (essential for production)
create index idx_emp_fts on emp using gin (to_tsvector('english', ename || ' ' || job));

-- Ranking results
select ename, ts_rank(to_tsvector('english', ename), to_tsquery('smith')) as rank
from emp
where to_tsvector('english', ename) @@ to_tsquery('smith');

-- Highlight matching terms
select ts_headline('english', 'The quick brown fox', to_tsquery('fox'),
                   'StartSel=<b>, StopSel=</b>');

-------------------------------------------------
-- SECTION 18: Security — Roles & RLS  (Ch20)
-------------------------------------------------

-- Roles
create role readonly_role;
create role app_user login password 'secret';
grant readonly_role to app_user;     -- app_user inherits readonly_role privileges

-- GRANT
grant select on emp to readonly_role;
grant select, insert, update on emp to app_role;
grant all on all tables in schema public to admin_role;
grant usage on schema public to readonly_role;

-- REVOKE
revoke insert on emp from app_role;
revoke all on emp from public;

-- Column-level grant
grant select (empno, ename) on emp to restricted_role;   -- hide sal column

-- Row-Level Security
alter table emp enable row level security;

create policy emp_own_dept
on emp
for select
using (deptno = current_setting('app.current_deptno')::int);

-- Test RLS as another user
set role app_user;
set app.current_deptno = '10';
select * from emp;    -- only sees dept 10 rows
reset role;

-- Bypass RLS (for admin)
alter table emp force row level security;   -- applies to table owner too
create role dba_role bypassrls;

-------------------------------------------------
-- SECTION 19: Performance & EXPLAIN  (Ch21)
-------------------------------------------------

-- EXPLAIN anatomy
explain (analyze, buffers, format text) select * from emp where sal > 2000;
-- Key fields:
--   cost=start..total    — estimated cost (not milliseconds)
--   actual time=...      — real execution time (ms)
--   rows=N               — actual rows returned
--   Seq Scan             — full table scan (no index used)
--   Index Scan           — index used + heap fetch
--   Index Only Scan      — index-only, no heap fetch (covering index)
--   Hash Join            — build hash table of inner, probe with outer
--   Nested Loop          — for each outer row, scan inner (good for small sets)
--   Merge Join           — both sides pre-sorted (efficient for large sorted sets)

-- VACUUM — reclaim dead tuples, update statistics
vacuum verbose emp;
vacuum analyze emp;   -- analyze updates planner statistics
analyze emp;          -- just update statistics, no vacuum

-- Statistics target (default 100; increase for skewed distributions)
alter table emp alter column sal set statistics 500;

-- pg_stat_statements — track slow queries (enable in postgresql.conf)
select query, calls, mean_exec_time, total_exec_time
from pg_stat_statements
order by mean_exec_time desc
limit 10;

-- Reset stats
select pg_stat_reset();

-------------------------------------------------
-- SECTION 20: Custom Types & Advanced Constraints  (Ch23)
-------------------------------------------------

-- ENUM
create type status_t as enum ('ACTIVE', 'INACTIVE', 'PENDING');
alter type status_t add value 'ARCHIVED' after 'INACTIVE';

-- Array
select array[1,2,3], '{a,b,c}'::text[];
select array_agg(ename) from emp;
select unnest(array[1,2,3]);
where skills @> array['SQL'];   -- contains

-- Composite type
create type addr_t as (street text, city text, zip text);
select (home_addr).city from emp_contacts;

-- Range types
select int4range(1, 10), daterange('2024-01-01', '2024-12-31', '[]');
select int4range(1,5) && int4range(3,8);   -- overlaps: true
select int4range(1,5) @> 3;               -- contains point: true

-- Exclusion constraint (requires btree_gist extension)
create extension if not exists btree_gist;
-- exclude using gist (room_no with =, stay with &&)

-- GENERATED column
-- sal_year numeric generated always as (sal * 12) stored

-- IDENTITY column (preferred over SERIAL)
-- id bigint generated always as identity primary key

-- Deferrable constraint
-- unique (rank) deferrable initially deferred

-------------------------------------------------
-- SECTION 21: Bulk I/O, Locks, Sampling  (Ch24)
-------------------------------------------------

-- COPY export (server-side — file on the server)
copy emp to '/tmp/emp.csv' with (format csv, header true);

-- COPY import
copy emp_staging from '/tmp/emp.csv' with (format csv, header true);

-- psql client-side (no superuser needed, works with Docker)
-- \copy emp to '/local/path/emp.csv' with (format csv, header true)
-- \copy emp from '/local/path/emp.csv' with (format csv, header true)

-- LISTEN / NOTIFY
listen my_channel;
notify my_channel, 'hello payload';
select pg_notify('my_channel', 'payload from function');

-- Advisory locks
select pg_advisory_lock(42);        -- session-level, blocks
select pg_advisory_try_lock(42);    -- non-blocking, returns bool
select pg_advisory_unlock(42);
select pg_advisory_xact_lock(42);   -- transaction-level, auto-released at commit

-- TABLESAMPLE
select * from emp tablesample bernoulli(50);              -- 50% of rows (random)
select * from emp tablesample system(50) repeatable(1);   -- block-level, deterministic

-------------------------------------------------
-- SECTION 22: Interview Patterns  (Ch25)
-------------------------------------------------

-- Gaps and Islands (value - row_number = constant for consecutive values)
select val - row_number() over (order by val) as island_id, val
from my_table;

-- Find missing values in a sequence
select gs.n as missing
from generate_series(1, 100) gs(n)
left join my_table t on t.id = gs.n
where t.id is null;

-- Deduplication — keep lowest id per group
delete from dupes
where id not in (select min(id) from dupes group by name);

-- Deduplication — using ROW_NUMBER() (preferred)
with ranked as (select ctid, row_number() over (partition by name order by id) as rn from dupes)
delete from dupes where ctid in (select ctid from ranked where rn > 1);

-- Nth highest value (DENSE_RANK approach)
select val from (select val, dense_rank() over (order by val desc) as rnk from t) x where rnk = 3;

-- Top-N per group
select * from (
    select *, row_number() over (partition by group_col order by val desc) as rn from t
) x where rn <= 2;

-- Consecutive streak length (date - row_number = constant for consecutive dates)
with numbered as (
    select id, date_col,
           date_col - row_number() over (partition by id order by date_col) * interval '1 day'
           as island_id
    from logins
)
select id, count(*) as streak from numbered group by id, island_id order by streak desc;

-------------------------------------------------
-- END OF CHEATSHEET
-- For full explanations and runnable examples, open the chapter files.
-------------------------------------------------
