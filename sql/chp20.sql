-------------------------------------------------
-- CHAPTER 20
-- Security — Roles, Grants, and Row-Level Security
-------------------------------------------------
-- PostgreSQL security operates at multiple layers:
--   1. Authentication  — who can connect (pg_hba.conf)
--   2. Roles & Grants  — what objects they can access
--   3. Row-Level Security (RLS) — which rows they can see/modify
--
-- This chapter covers: CREATE ROLE/USER, role inheritance,
-- GRANT/REVOKE at object level, schema permissions, column-level grants,
-- RLS policies (permissive and restrictive), SECURITY DEFINER functions,
-- and auditing who can do what.
--
-- NOTE: Many statements here require superuser or pg_hba access.
--       Read them to understand the concepts; run in a dev environment.

-------------------------------------------------
-- PART 1: ROLES AND USERS
-------------------------------------------------

-- In PostgreSQL, users and roles are the same thing.
-- CREATE USER = CREATE ROLE WITH LOGIN
-- Roles can be granted to other roles (role inheritance).

-- Create a role (no login — used as a group)
create role readonly_role;

-- Create a role with login (a real user)
create role alice with login password 'secret123';
create role bob   with login password 'secret456';

-- Create a superuser (full access — use carefully)
-- create role admin_user with login superuser password 'adminpass';

-- List all roles:
select rolname, rolsuper, rolinherit, rolcreatedb, rolcanlogin
from pg_roles
where rolname not like 'pg_%'
order by rolname;

-------------------------------------------------

-- Role inheritance — grant a role to another role
-- Members of readonly_role get all its privileges automatically.

grant readonly_role to alice;
grant readonly_role to bob;

-- Alice and Bob now inherit all privileges given to readonly_role.
-- Check role membership:
select rolname,
       array_agg(member::regrole::text) as members
from pg_auth_members
join pg_roles on pg_roles.oid = roleid
group by rolname;

-------------------------------------------------

-- SET ROLE — switch to a granted role within a session
-- Useful for testing what a role can see.

-- set role readonly_role;
-- select current_user;   -- still alice
-- select session_user;   -- alice (original login)
-- reset role;            -- switch back

-------------------------------------------------
-- PART 2: GRANT AND REVOKE
-------------------------------------------------

-- GRANT on a table — give specific privileges to a role
-- Privileges: SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER

grant select on emp  to readonly_role;
grant select on dept to readonly_role;

-- Now alice and bob can SELECT on emp and dept (via readonly_role).

-- Grant multiple privileges at once:
grant select, insert on emp_bonus to alice;

-- Grant on ALL tables in a schema:
grant select on all tables in schema public to readonly_role;

-- Grant on future tables (default privileges):
alter default privileges in schema public
    grant select on tables to readonly_role;

-------------------------------------------------

-- REVOKE — remove a privilege

revoke insert on emp_bonus from alice;

-- Revoke everything:
revoke all privileges on emp from readonly_role;

-------------------------------------------------

-- Schema-level permissions
-- Even if a role has SELECT on a table, they also need USAGE on the schema.

grant usage on schema public to readonly_role;

-- Without USAGE on the schema, the role cannot see the tables inside it.
-- This is a common "I can't see the table!" gotcha.

-------------------------------------------------

-- Column-level privileges
-- Restrict access to specific columns only.

-- Create a salary-restricted view of emp:
grant select (empno, ename, job, deptno) on emp to readonly_role;
-- readonly_role can see empno, ename, job, deptno — but NOT sal or comm.

-- Revoke column-level:
-- revoke select (empno, ename, job, deptno) on emp from readonly_role;

-------------------------------------------------

-- Ownership and ALTER TABLE
-- Only the table owner or a superuser can ALTER TABLE, DROP TABLE, etc.
-- Grant ownership transfer:
-- alter table emp owner to alice;

-------------------------------------------------

-- Checking current privileges
-- \dp tablename in psql shows privilege map.
-- SQL alternative:

select grantee,
       table_name,
       privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('emp', 'dept')
order by grantee, table_name, privilege_type;

-------------------------------------------------
-- PART 3: ROW-LEVEL SECURITY (RLS)
-------------------------------------------------

-- RLS restricts which ROWS a role can see or modify.
-- Even with SELECT on the table, a user only sees rows their policy allows.

-- Setup: multi-tenant orders table
create table if not exists tenant_orders (
    order_id  serial primary key,
    tenant    text   not null,
    item      text   not null,
    amount    numeric(10,2)
);

insert into tenant_orders (tenant, item, amount) values
('acme',   'Widget A', 100.00),
('acme',   'Widget B', 200.00),
('globex', 'Gadget X', 150.00),
('globex', 'Gadget Y', 300.00),
('initech','Service Z', 500.00);

-- Step 1: Enable RLS on the table
alter table tenant_orders enable row level security;

-- Without any policy, table owner still sees all rows.
-- Non-owners with SELECT see ZERO rows (default-deny when RLS enabled).

-- Step 2: Create a policy
-- USING clause controls which rows are VISIBLE (SELECT, UPDATE, DELETE).
-- WITH CHECK clause controls which rows can be WRITTEN (INSERT, UPDATE).

create policy tenant_isolation
on tenant_orders
for all                          -- applies to SELECT, INSERT, UPDATE, DELETE
to public                        -- applies to all non-superuser roles
using (tenant = current_user)   -- can only see rows where tenant = their username
with check (tenant = current_user);  -- can only write rows for themselves

-- Test as alice (must first create the tenant row):
-- set role alice;
-- select * from tenant_orders;  -- only sees rows where tenant = 'alice'
-- reset role;

-------------------------------------------------

-- Bypassing RLS — superusers and BYPASSRLS role
-- Superusers and roles with BYPASSRLS ignore RLS policies.
-- Table owners bypass RLS by default — use FORCE ROW LEVEL SECURITY to restrict even owners.

alter table tenant_orders force row level security;
-- Now even the table owner is subject to RLS policies.

-------------------------------------------------

-- Permissive vs Restrictive policies
-- PERMISSIVE (default): multiple policies are OR-ed together.
--   A row is visible if ANY permissive policy allows it.
-- RESTRICTIVE: must pass ALL restrictive policies AND at least one permissive.

-- Add a permissive policy: admins see everything
create policy admin_sees_all
on tenant_orders
as permissive
for select
to readonly_role
using (true);   -- always true → readonly_role sees all rows

-- Add a restrictive policy: only active orders visible
create table if not exists active_tenants (tenant text primary key);
insert into active_tenants values ('acme'), ('globex');

create policy only_active_tenants
on tenant_orders
as restrictive
for select
to public
using (tenant in (select tenant from active_tenants));
-- Even if permissive policy allows the row, this restrictive policy
-- further limits to rows where tenant is in active_tenants.

-------------------------------------------------

-- Separate policies per operation

drop policy if exists tenant_isolation on tenant_orders;

create policy select_own_rows
on tenant_orders for select
using (tenant = current_user);

create policy insert_own_rows
on tenant_orders for insert
with check (tenant = current_user);

create policy update_own_rows
on tenant_orders for update
using (tenant = current_user)
with check (tenant = current_user);

create policy delete_own_rows
on tenant_orders for delete
using (tenant = current_user);

-------------------------------------------------

-- List all RLS policies
select schemaname,
       tablename,
       policyname,
       cmd,
       qual,
       with_check
from pg_policies
where schemaname = 'public'
order by tablename, policyname;

-------------------------------------------------
-- PART 4: SECURITY DEFINER vs SECURITY INVOKER
-------------------------------------------------

-- SECURITY INVOKER (default): function runs with the CALLER's privileges.
-- SECURITY DEFINER: function runs with the OWNER's privileges.
--   Useful for giving restricted users controlled access to privileged operations.

-- Example: allow a low-privilege user to insert into emp via a function,
-- without granting them direct INSERT on emp.

create or replace function hire_employee(
    p_empno integer,
    p_ename text,
    p_job   text,
    p_sal   integer,
    p_deptno integer
)
returns void
language plpgsql
security definer   -- runs as the function owner (e.g., postgres)
set search_path = public  -- security: prevent search_path hijacking
as $$
begin
    -- Validate before inserting
    if p_sal < 0 then
        raise exception 'Salary must be non-negative';
    end if;
    if p_deptno not in (select deptno from dept) then
        raise exception 'Invalid department: %', p_deptno;
    end if;

    insert into emp (empno, ename, job, sal, deptno)
    values (p_empno, p_ename, p_job, p_sal, p_deptno);
end;
$$;

-- Grant alice the right to call the function — not direct INSERT on emp:
grant execute on function hire_employee(integer, text, text, integer, integer) to alice;

-- Alice can now call: select hire_employee(9999, 'ALICE', 'ANALYST', 3000, 20);
-- Even though she has no INSERT privilege on emp.

-- IMPORTANT: always SET search_path in SECURITY DEFINER functions to prevent
-- a malicious user from placing objects in a schema that shadows pg_catalog.

-------------------------------------------------

-- Auditing who has what access

-- Tables a role can SELECT:
select table_schema, table_name
from information_schema.role_table_grants
where grantee = 'readonly_role'
  and privilege_type = 'SELECT'
order by table_schema, table_name;

-- All privileges in the database:
select grantee, table_name, string_agg(privilege_type, ', ' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'public'
group by grantee, table_name
order by grantee, table_name;

-------------------------------------------------

-- Clean up
drop policy if exists select_own_rows      on tenant_orders;
drop policy if exists insert_own_rows      on tenant_orders;
drop policy if exists update_own_rows      on tenant_orders;
drop policy if exists delete_own_rows      on tenant_orders;
drop policy if exists admin_sees_all       on tenant_orders;
drop policy if exists only_active_tenants  on tenant_orders;
drop table if exists tenant_orders;
drop table if exists active_tenants;
drop function if exists hire_employee(integer, text, text, integer, integer);
drop role if exists readonly_role;
drop role if exists alice;
drop role if exists bob;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Never use superuser roles in application connection strings.
--    Create a dedicated application role with only the privileges it needs.

-- 2. Grant privileges to ROLES, not directly to users.
--    Add/remove users from roles — cleaner than managing per-user grants.

-- 3. Always GRANT USAGE ON SCHEMA alongside table privileges.
--    Without schema USAGE, a role cannot even see the tables in it.

-- 4. Use RLS for multi-tenant systems — one table, isolated per tenant.
--    It is enforced at the database layer regardless of application code.

-- 5. Always set FORCE ROW LEVEL SECURITY on RLS tables.
--    Without it, the table owner bypasses all policies silently.

-- 6. Use SECURITY DEFINER functions to give controlled, audited access
--    to privileged operations — safer than broad GRANT statements.

-- 7. Always include SET search_path = public in SECURITY DEFINER functions
--    to prevent search_path injection attacks.

-- 8. Regularly audit privileges with information_schema.role_table_grants
--    and pg_policies to ensure least-privilege is maintained.
