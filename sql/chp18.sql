-------------------------------------------------
-- CHAPTER 18
-- Table Partitioning
-------------------------------------------------
-- Partitioning splits a large table into smaller physical pieces (partitions)
-- while presenting a single logical table to queries.
-- PostgreSQL supports declarative partitioning (PG 10+).
--
-- Benefits: faster queries (partition pruning), easier archival (detach old parts),
-- faster bulk deletes (drop a partition instead of DELETE).
--
-- Three strategies:
--   RANGE  — by value range (e.g., dates, IDs)
--   LIST   — by specific value categories (e.g., region, status)
--   HASH   — by hash of a column (even data distribution)
--
-- This chapter uses a sales_data table to demonstrate all three strategies.

-------------------------------------------------
-- PART 1: RANGE PARTITIONING (most common — by date)
-------------------------------------------------

-- Parent table: PARTITION BY RANGE defines the strategy and key column.
-- The parent itself holds no rows — all rows go into a partition.

create table sales_range (
    sale_id     serial,
    sale_date   date          not null,
    region      text          not null,
    amount      numeric(10,2) not null,
    product     text
) partition by range (sale_date);

-- Create partitions — each covers a specific date range [inclusive, exclusive)
create table sales_range_2022
    partition of sales_range
    for values from ('2022-01-01') to ('2023-01-01');

create table sales_range_2023
    partition of sales_range
    for values from ('2023-01-01') to ('2024-01-01');

create table sales_range_2024
    partition of sales_range
    for values from ('2024-01-01') to ('2025-01-01');

-- DEFAULT partition — catches any rows that don't fit other partitions
create table sales_range_default
    partition of sales_range default;

-------------------------------------------------

-- Insert rows — automatically routed to the correct partition

insert into sales_range (sale_date, region, amount, product) values
('2022-03-15', 'NORTH', 1500.00, 'Widget'),
('2022-11-20', 'SOUTH', 2200.50, 'Gadget'),
('2023-01-05', 'EAST',   980.00, 'Widget'),
('2023-06-30', 'WEST',  3100.75, 'Gizmo'),
('2024-02-14', 'NORTH', 4000.00, 'Gadget'),
('2024-09-01', 'SOUTH', 1800.25, 'Widget');

-- Query the parent — returns all rows from all partitions
select * from sales_range order by sale_date;

-- Query a specific partition directly
select * from sales_range_2023;

-------------------------------------------------

-- Partition pruning — the planner skips irrelevant partitions
-- When a WHERE clause matches the partition key, PostgreSQL only scans
-- the partitions that could contain matching rows.

explain select * from sales_range where sale_date >= '2023-01-01' and sale_date < '2024-01-01';
-- Notice: only sales_range_2023 is scanned (Seq Scan on sales_range_2023).
-- sales_range_2022 and sales_range_2024 are excluded automatically.

explain select * from sales_range where sale_date = '2022-03-15';
-- Only sales_range_2022 is scanned.

-------------------------------------------------

-- Indexes on partitioned tables
-- Creating an index on the parent automatically creates it on all partitions.

create index idx_sales_range_date on sales_range (sale_date);
create index idx_sales_range_region on sales_range (region);

-- Check indexes were created on all partitions:
select tablename, indexname
from pg_indexes
where tablename like 'sales_range%'
order by tablename, indexname;

-------------------------------------------------

-- Adding a new partition for future data

create table sales_range_2025
    partition of sales_range
    for values from ('2025-01-01') to ('2026-01-01');

-- Detach old partition (stops new rows going in, keeps the data accessible)
alter table sales_range detach partition sales_range_2022;

-- Now sales_range_2022 is a standalone table:
select * from sales_range_2022;

-- Re-attach it:
alter table sales_range attach partition sales_range_2022
    for values from ('2022-01-01') to ('2023-01-01');

-------------------------------------------------

-- Archival pattern: archive old data by detaching the partition
-- Much faster than DELETE — just a metadata change, not row-by-row deletion.

-- Step 1: Detach
alter table sales_range detach partition sales_range_2022;

-- Step 2: Archive (rename or move to archive schema)
alter table sales_range_2022 rename to sales_archive_2022;

-- Step 3: Drop if no longer needed (instant, no row scanning)
-- drop table sales_archive_2022;

-------------------------------------------------
-- PART 2: LIST PARTITIONING (by discrete category values)
-------------------------------------------------

create table sales_list (
    sale_id   serial,
    region    text          not null,
    amount    numeric(10,2) not null,
    sale_date date
) partition by list (region);

create table sales_list_north partition of sales_list for values in ('NORTH', 'NORTHEAST');
create table sales_list_south partition of sales_list for values in ('SOUTH', 'SOUTHEAST');
create table sales_list_west  partition of sales_list for values in ('WEST',  'NORTHWEST');
create table sales_list_other partition of sales_list default;

insert into sales_list (region, amount, sale_date) values
('NORTH',     1200.00, '2024-01-10'),
('SOUTH',      800.50, '2024-01-11'),
('WEST',      2200.00, '2024-01-12'),
('NORTHEAST',  950.75, '2024-01-13'),
('CENTRAL',   1100.00, '2024-01-14');  -- goes to default partition

-- CENTRAL has no matching partition → goes to default
select * from sales_list_other;

-- Pruning on list partition:
explain select * from sales_list where region = 'NORTH';
-- Only sales_list_north is scanned.

-------------------------------------------------
-- PART 3: HASH PARTITIONING (even distribution by hash)
-------------------------------------------------

-- Use when no natural range or category — just want even spread.
-- MODULUS = total number of partitions, REMAINDER = which shard (0 to modulus-1).

create table sales_hash (
    sale_id   serial,
    customer  text not null,
    amount    numeric(10,2)
) partition by hash (customer);

create table sales_hash_0 partition of sales_hash for values with (modulus 4, remainder 0);
create table sales_hash_1 partition of sales_hash for values with (modulus 4, remainder 1);
create table sales_hash_2 partition of sales_hash for values with (modulus 4, remainder 2);
create table sales_hash_3 partition of sales_hash for values with (modulus 4, remainder 3);

insert into sales_hash (customer, amount) values
('Alice', 100), ('Bob', 200), ('Carol', 300),
('Dave', 400), ('Eve', 500), ('Frank', 600),
('Grace', 700), ('Hank', 800);

-- Check how rows are distributed across shards:
select 'sales_hash_0', count(*) from sales_hash_0
union all
select 'sales_hash_1', count(*) from sales_hash_1
union all
select 'sales_hash_2', count(*) from sales_hash_2
union all
select 'sales_hash_3', count(*) from sales_hash_3;

-------------------------------------------------
-- PART 4: SUBPARTITIONING (partitions within partitions)
-------------------------------------------------

-- Range by year, then list by region within each year.
create table sales_sub (
    sale_date date   not null,
    region    text   not null,
    amount    numeric(10,2)
) partition by range (sale_date);

create table sales_sub_2024
    partition of sales_sub
    for values from ('2024-01-01') to ('2025-01-01')
    partition by list (region);     -- subpartition by region

create table sales_sub_2024_north
    partition of sales_sub_2024 for values in ('NORTH');
create table sales_sub_2024_south
    partition of sales_sub_2024 for values in ('SOUTH');
create table sales_sub_2024_other
    partition of sales_sub_2024 default;

insert into sales_sub values ('2024-03-01', 'NORTH', 500);
insert into sales_sub values ('2024-07-15', 'SOUTH', 800);

select tableoid::regclass as partition, * from sales_sub;

-------------------------------------------------

-- Useful: see which partition a row belongs to

select tableoid::regclass as partition, sale_date, region, amount
from sales_range
order by sale_date;

-------------------------------------------------

-- List all partitions of a table

select inhrelid::regclass  as partition_name,
       pg_get_expr(c.relpartbound, c.oid) as partition_bound
from pg_inherits i
join pg_class c on c.oid = i.inhrelid
where inhparent = 'sales_range'::regclass;

-------------------------------------------------

-- Key constraints on partitioned tables
-- PRIMARY KEY and UNIQUE must include the partition key column.

create table orders_part (
    order_id    bigint       not null,
    order_date  date         not null,
    customer    text,
    amount      numeric,
    primary key (order_id, order_date)  -- order_date (partition key) must be included
) partition by range (order_date);

create table orders_part_2024
    partition of orders_part
    for values from ('2024-01-01') to ('2025-01-01');

-- FOREIGN KEY pointing TO a partitioned table is not supported in PostgreSQL.
-- FK FROM a partitioned table to another table IS supported.

-------------------------------------------------

-- Clean up
drop table if exists sales_sub_2024_north;
drop table if exists sales_sub_2024_south;
drop table if exists sales_sub_2024_other;
drop table if exists sales_sub_2024;
drop table if exists sales_sub;
drop table if exists sales_range_2025;
drop table if exists sales_archive_2022;
drop table if exists sales_range_2023;
drop table if exists sales_range_2024;
drop table if exists sales_range_default;
drop table if exists sales_range;
drop table if exists sales_list_north;
drop table if exists sales_list_south;
drop table if exists sales_list_west;
drop table if exists sales_list_other;
drop table if exists sales_list;
drop table if exists sales_hash_0;
drop table if exists sales_hash_1;
drop table if exists sales_hash_2;
drop table if exists sales_hash_3;
drop table if exists sales_hash;
drop table if exists orders_part_2024;
drop table if exists orders_part;

-------------------------------------------------
-- Best Practice Notes
-------------------------------------------------

-- 1. Use RANGE partitioning on time-series data (logs, events, transactions).
--    It is the most common use case and enables easy archival of old partitions.

-- 2. Always create a DEFAULT partition to catch rows that don't match
--    any explicit partition — prevents insert failures.

-- 3. Partition pruning requires the WHERE clause to directly reference
--    the partition key column. Applying a function (e.g., DATE_TRUNC) to
--    the key may prevent pruning.

-- 4. Indexes on the parent table propagate to all partitions automatically.
--    But each partition also has its own physical index — plan storage accordingly.

-- 5. For archival: DETACH the old partition (instant metadata operation),
--    then DROP it or rename it. Far faster than a DELETE statement.

-- 6. PRIMARY KEY and UNIQUE constraints on partitioned tables must include
--    the partition key column — PostgreSQL enforces this requirement.

-- 7. Hash partitioning is best when you want even distribution with no
--    natural range or list grouping (e.g., sharding by customer ID or UUID).

-- 8. Partitioning adds overhead for small tables — only worthwhile when
--    tables exceed tens of millions of rows or need time-based archival.
