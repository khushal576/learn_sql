-------------------------------------------------
-- CHAPTER 17
-- JSON and JSONB Deep Dive
-------------------------------------------------
-- PostgreSQL has first-class support for JSON documents stored directly
-- in relational tables. Two types:
--   JSON  — stored as-is (preserves whitespace, duplicate keys)
--   JSONB — stored as parsed binary (indexed, operators, faster querying)
--
-- In practice: always use JSONB unless you need exact text preservation.
--
-- This chapter covers: creating JSONB columns, operators (->, ->>, #>),
-- construction functions, update/delete within JSONB, array handling,
-- JSONPath queries, GIN indexing, and aggregation to JSON.

-------------------------------------------------

-- Setup: employee profile table with JSONB column
create table if not exists emp_profile (
    empno    integer primary key,
    ename    text    not null,
    profile  jsonb
);

insert into emp_profile (empno, ename, profile) values
(7369, 'SMITH',  '{"skills": ["SQL","Python"], "level": "junior",  "location": {"city": "Dallas",    "country": "US"}, "active": true}'),
(7499, 'ALLEN',  '{"skills": ["Sales","CRM"],   "level": "mid",    "location": {"city": "Chicago",   "country": "US"}, "active": true}'),
(7698, 'BLAKE',  '{"skills": ["Management","SQL"], "level": "senior","location": {"city": "Chicago", "country": "US"}, "active": true}'),
(7788, 'SCOTT',  '{"skills": ["SQL","Java","Python"], "level": "senior","location": {"city": "Dallas","country": "US"}, "active": false}'),
(7839, 'KING',   '{"skills": ["Leadership","Strategy"], "level": "exec","location": {"city": "New York","country": "US"}, "active": true}');

-------------------------------------------------

-- -> operator — extract a JSON object field (returns JSONB)
-- ->> operator — extract as TEXT (loses JSON type)

select ename,
       profile -> 'level'              as level_jsonb,    -- "senior" (with quotes)
       profile ->> 'level'             as level_text,     -- senior  (plain text)
       profile -> 'location'           as location_obj,   -- {"city":"Dallas","country":"US"}
       profile -> 'location' ->> 'city' as city           -- Dallas
from emp_profile;

-- Use ->> when you need to compare or display the value as text.
-- Use -> when you need to keep it as JSONB for further navigation.

-------------------------------------------------

-- #> and #>> — path navigation with an array of keys

select ename,
       profile #> '{location, city}'   as city_jsonb,
       profile #>> '{location, city}'  as city_text,
       profile #>> '{skills, 0}'       as first_skill   -- first element of array
from emp_profile;

-- '{location, city}' navigates: profile → location → city
-- Array elements use numeric index (0-based).

-------------------------------------------------

-- Checking key existence — ? operator

select ename, profile
from emp_profile
where profile ? 'skills';           -- has the key "skills"

-- ?| — any of the keys exist
select ename from emp_profile
where profile ?| array['level', 'salary'];

-- ?& — all of the keys must exist
select ename from emp_profile
where profile ?& array['skills', 'level', 'active'];

-------------------------------------------------

-- @> containment operator — does the left JSONB contain the right?

-- Find all senior employees
select ename, profile ->> 'level' as level
from emp_profile
where profile @> '{"level": "senior"}';

-- Find employees in Chicago
select ename
from emp_profile
where profile @> '{"location": {"city": "Chicago"}}';

-- Find employees who have Python as a skill
select ename
from emp_profile
where profile @> '{"skills": ["Python"]}';

-- @> is the operator a GIN index can accelerate (see indexing section below).

-------------------------------------------------

-- Filtering on nested values using ->>

select ename
from emp_profile
where profile ->> 'level' in ('senior', 'exec');

select ename
from emp_profile
where (profile -> 'location' ->> 'city') = 'Dallas';

select ename
from emp_profile
where (profile ->> 'active')::boolean = false;

-------------------------------------------------

-- jsonb_array_length — count elements in a JSON array

select ename,
       jsonb_array_length(profile -> 'skills') as skill_count
from emp_profile
order by skill_count desc;

-------------------------------------------------

-- jsonb_array_elements — expand a JSON array into rows (unnest)

select ep.ename,
       skill.value ->> 0 as skill
from emp_profile ep,
     jsonb_array_elements_text(ep.profile -> 'skills') as skill(value)
order by ep.ename;

-- Each skill becomes its own row — great for filtering/joining.

-- Find all employees who know Python:
select distinct ep.ename
from emp_profile ep,
     jsonb_array_elements_text(ep.profile -> 'skills') as s
where s = 'Python';

-------------------------------------------------

-- jsonb_each — expand top-level key/value pairs into rows

select ename, key, value
from emp_profile,
     jsonb_each(profile) as kv(key, value)
where ename = 'KING'
order by key;

-------------------------------------------------

-- jsonb_keys — list all top-level keys

select ename,
       array_agg(key order by key) as keys
from emp_profile,
     jsonb_object_keys(profile) as key
group by ename;

-------------------------------------------------

-- Building JSON objects and arrays from scratch

-- json_build_object / jsonb_build_object
select json_build_object(
    'empno', empno,
    'name',  ename,
    'dept',  deptno
) as employee_json
from emp
limit 5;

-- json_build_array
select json_build_array(1, 'hello', true, null) as arr;

-- Row to JSON
select row_to_json(e) as full_row
from emp e
limit 3;

-- Select specific columns as JSON:
select row_to_json(t) as obj
from (select empno, ename, sal from emp limit 3) t;

-------------------------------------------------

-- jsonb_set — update a value inside JSONB without replacing the whole document
-- jsonb_set(target, path, new_value, create_missing)

update emp_profile
set profile = jsonb_set(profile, '{level}', '"lead"')
where ename = 'SMITH';

-- Nested update:
update emp_profile
set profile = jsonb_set(profile, '{location, city}', '"Austin"')
where ename = 'SMITH';

-- Add a new key:
update emp_profile
set profile = jsonb_set(profile, '{salary}', '95000', true)
where ename = 'KING';

select ename, profile from emp_profile where ename in ('SMITH','KING');

-------------------------------------------------

-- || operator — merge / concatenate two JSONB objects
-- Overwrites matching keys from the right side.

update emp_profile
set profile = profile || '{"verified": true, "active": true}'
where ename = 'SCOTT';

select ename, profile ->> 'verified', profile ->> 'active'
from emp_profile where ename = 'SCOTT';

-------------------------------------------------

-- - operator — remove a key from JSONB

update emp_profile
set profile = profile - 'salary'
where ename = 'KING';

-- Remove nested key using #- operator:
update emp_profile
set profile = profile #- '{location, country}'
where ename = 'SMITH';

select ename, profile from emp_profile where ename in ('SMITH','KING');

-------------------------------------------------

-- jsonb_insert — insert a value into a JSONB array at a specific position

update emp_profile
set profile = jsonb_insert(profile, '{skills, 0}', '"PostgreSQL"')
where ename = 'SMITH';

select ename, profile -> 'skills' from emp_profile where ename = 'SMITH';

-------------------------------------------------

-- GIN index — makes @>, ?, ?|, ?&, jsonb_path_exists fast on large tables

create index idx_emp_profile_gin on emp_profile using gin (profile);

-- Now this query uses the GIN index:
explain select ename from emp_profile where profile @> '{"level": "senior"}';

-- jsonb_path_ops operator class — smaller index, only supports @>:
-- create index idx_emp_profile_gin2 on emp_profile using gin (profile jsonb_path_ops);

drop index if exists idx_emp_profile_gin;

-------------------------------------------------

-- JSONPath — SQL/JSON path language (PostgreSQL 12+)
-- More expressive than nested -> operators.

-- jsonb_path_exists: does the path match?
select ename
from emp_profile
where jsonb_path_exists(profile, '$.skills[*] ? (@ == "SQL")');

-- jsonb_path_query: extract matching values
select ename,
       jsonb_path_query_array(profile, '$.skills[*]') as skills
from emp_profile;

-- Filter employees where any skill starts with 'P':
select ename
from emp_profile
where jsonb_path_exists(profile, '$.skills[*] ? (@ starts with "P")');

-------------------------------------------------

-- Aggregating rows into JSON (see also Ch11)

-- One JSON object per department with employee array:
select d.dname,
       jsonb_agg(
           jsonb_build_object('name', e.ename, 'sal', e.sal)
           order by e.sal desc
       ) as employees
from dept d
join emp e on d.deptno = e.deptno
group by d.dname
order by d.dname;

-------------------------------------------------

-- JSON vs JSONB — quick comparison

-- JSON:  stores text as-is, preserves key order and duplicate keys,
--        slower for repeated access, no GIN index support for operators.
-- JSONB: parsed binary format, deduplicates keys (last wins),
--        faster for reads and operator queries, supports GIN indexing.
--        Use JSONB in almost all real-world cases.

-------------------------------------------------

-- Clean up
drop table if exists emp_profile;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Always use JSONB over JSON in new tables.
--    JSONB is indexed, faster to query, and supports all operators.

-- 2. Use ->> (not ->) when comparing values in WHERE clauses.
--    -> returns JSONB; ->> returns text — most comparisons need text.

-- 3. Create a GIN index on JSONB columns you query with @>, ?, ?|, ?&.
--    Without it, every query does a full table scan.

-- 4. Use @> for containment checks — it is index-friendly.
--    Avoid profile->>'key' = 'value' patterns in large tables
--    (requires a functional index to avoid a seq scan).

-- 5. Use jsonb_set for surgical updates inside a document.
--    Avoid replacing the entire column for single-key changes.

-- 6. Use jsonb_array_elements_text to turn JSON arrays into rows
--    for joining, filtering, and aggregation.

-- 7. Don't overuse JSONB — relational columns are better for fields
--    you filter, join, or sort on frequently.
--    JSONB is ideal for semi-structured, variable-schema data.
