# Chapter 5 — Normalization

Normalization is the process of organizing a database to **reduce redundancy** and **prevent update anomalies**. It is one of the most critical skills in database design.

---

## 5.1 Why Normalization?

Consider this un-normalized table:

```
orders_flat
┌──────────┬──────────────┬───────────┬─────────────────────┬──────────┬───────────┬──────────────┐
│ order_id │ customer_name│ customer_ │ product_name        │ category │ qty       │ unit_price   │
│          │              │ email     │                     │          │           │              │
├──────────┼──────────────┼───────────┼─────────────────────┼──────────┼───────────┼──────────────┤
│ 1001     │ Alice        │ a@x.com   │ Laptop              │ Electronics │ 1      │ 999.00       │
│ 1001     │ Alice        │ a@x.com   │ Mouse               │ Electronics │ 2      │ 25.00        │
│ 1002     │ Bob          │ b@x.com   │ Desk                │ Furniture   │ 1      │ 350.00       │
└──────────┴──────────────┴───────────┴─────────────────────┴──────────┴───────────┴──────────────┘
```

Problems (called **anomalies**):

| Anomaly | Problem |
|---------|---------|
| **Insert anomaly** | Can't add a product without an order |
| **Update anomaly** | Alice changes her email → must update every row |
| **Delete anomaly** | Delete order 1002 → lose all info about "Desk" and "Bob" |

Normalization eliminates these by splitting data into proper tables.

---

## 5.2 Functional Dependency — The Foundation

Before learning normal forms, understand **functional dependency (FD)**:

> Column B is **functionally dependent** on column A if each value of A determines exactly one value of B.
> Written: **A → B** ("A determines B")

Examples:
- `employee_id → name` — knowing the ID tells you exactly one name ✅
- `dept_id → dept_name` — knowing the dept ID tells you the name ✅
- `name → salary` — knowing the name does NOT uniquely determine salary ❌ (two employees can share a name)

**Partial dependency**: B depends on part of a composite key.  
**Transitive dependency**: A → B → C (A determines B, B determines C, but A doesn't directly determine C).

---

## 5.3 First Normal Form (1NF)

**Rule**: Every column must contain **atomic (indivisible) values** and every row must be unique.

### Violations of 1NF:

**Multi-valued columns:**
```
❌ employees
┌────┬───────┬──────────────────────┐
│ id │ name  │ phone_numbers        │
├────┼───────┼──────────────────────┤
│  1 │ Alice │ 555-1234, 555-5678   │ ← two values in one cell
└────┴───────┴──────────────────────┘
```

**Fix**: Create a separate table.
```sql
✅
employee_phones (emp_id FK, phone_number, phone_type)
```

**Repeating groups:**
```
❌
┌────┬───────┬──────────┬──────────┬──────────┐
│ id │ name  │ skill_1  │ skill_2  │ skill_3  │
└────┴───────┴──────────┴──────────┴──────────┘
```

**Fix**: 
```sql
✅
employee_skills (emp_id FK, skill)
```

**After 1NF**: All values are atomic, no repeating columns, no sets in cells.

---

## 5.4 Second Normal Form (2NF)

**Rule**: Must be in 1NF AND every non-key attribute must be **fully functionally dependent on the entire primary key** (no partial dependencies).

This only applies when the PK is **composite**.

### Example:

```
order_items
PK: (order_id, product_id)

┌──────────┬────────────┬──────────────────┬───────────┐
│ order_id │ product_id │ product_name     │ quantity  │
├──────────┼────────────┼──────────────────┼───────────┤
│ 1001     │ 55         │ Laptop           │ 1         │
│ 1001     │ 66         │ Mouse            │ 2         │
└──────────┴────────────┴──────────────────┴───────────┘
```

- `quantity` depends on `(order_id, product_id)` — full dependency ✅
- `product_name` depends on `product_id` alone — **partial dependency** ❌

### Fix — Remove partial dependency:

```sql
-- products table owns product_name
products    (product_id PK, product_name, price, ...)

-- order_items only stores what's specific to the order
order_items (order_id FK, product_id FK, quantity, unit_price)
```

**After 2NF**: No non-key column depends on only part of the primary key.

---

## 5.5 Third Normal Form (3NF)

**Rule**: Must be in 2NF AND no non-key attribute is **transitively dependent** on the primary key.

Transitive dependency: PK → A → B (B depends on A, not directly on PK)

### Example:

```
employees
PK: employee_id

┌─────────────┬──────────┬─────────┬──────────────┐
│ employee_id │ name     │ dept_id │ dept_name    │
├─────────────┼──────────┼─────────┼──────────────┤
│ 1           │ Alice    │ 10      │ Engineering  │
│ 2           │ Bob      │ 20      │ Marketing    │
└─────────────┴──────────┴─────────┴──────────────┘
```

- `employee_id → dept_id` ✅ (direct)
- `dept_id → dept_name` — **transitive!** `dept_name` depends on `dept_id`, not `employee_id` ❌

Update anomaly: If Engineering changes its name, you update every employee in that dept.

### Fix — Extract transitive dependency:

```sql
departments (dept_id PK, dept_name)
employees   (employee_id PK, name, dept_id FK)
```

**After 3NF**: Every non-key column depends on the key, the whole key, and nothing but the key.

> Mnemonic: "The key, the whole key, and nothing but the key."

---

## 5.6 Boyce-Codd Normal Form (BCNF)

**Rule**: For every functional dependency A → B, A must be a **superkey**.

BCNF is a stricter version of 3NF. Most tables in 3NF are also in BCNF — violations only appear with multiple overlapping candidate keys.

### Example (rare but real):

```
course_teacher
┌──────────┬───────────────┬───────────┐
│ student  │ course        │ teacher   │
├──────────┼───────────────┼───────────┤
│ Alice    │ Math          │ Dr. Smith │
│ Bob      │ Math          │ Dr. Smith │
│ Alice    │ Physics       │ Dr. Jones │
└──────────┴───────────────┴───────────┘
```

Candidate keys: `(student, course)` and `(student, teacher)`  
FD: `teacher → course` (each teacher teaches only one course)

`teacher` is not a superkey but determines `course` → BCNF violation.

### Fix:
```sql
teacher_courses (teacher PK, course)
student_teachers (student, teacher, PRIMARY KEY(student, teacher))
```

BCNF violations are uncommon and sometimes acceptable if decomposition makes queries harder.

---

## 5.7 Higher Normal Forms (Brief Overview)

| Form | What it removes |
|------|----------------|
| 4NF | Multi-valued dependencies |
| 5NF | Join dependencies |
| 6NF | Temporal data redundancy |

In practice, **3NF or BCNF is the target** for most production databases. Going beyond is academic.

---

## 5.8 Step-by-Step Normalization Example

Start with a messy table and normalize it fully.

**Un-normalized:**
```
student_courses (student_id, student_name, advisor_id, advisor_name, course_id, course_name, grade)
PK: (student_id, course_id)
```

**Step 1 — Check 1NF**: All values atomic, no repeating groups → ✅ Already 1NF.

**Step 2 — Check 2NF**: 
- `student_name` depends on `student_id` alone → partial dependency ❌
- `advisor_id` depends on `student_id` alone → partial dependency ❌  
- `advisor_name` depends on `student_id` alone → partial dependency ❌
- `course_name` depends on `course_id` alone → partial dependency ❌
- `grade` depends on `(student_id, course_id)` → full dependency ✅

**Fix for 2NF:**
```
students  (student_id PK, student_name, advisor_id)
courses   (course_id PK, course_name)
enrollments (student_id FK, course_id FK, grade)
```

**Step 3 — Check 3NF on `students`**:
- `student_id → advisor_id` ✅ direct
- `advisor_id → advisor_name` ← transitive! ❌

**Fix for 3NF:**
```
advisors    (advisor_id PK, advisor_name)
students    (student_id PK, student_name, advisor_id FK)
courses     (course_id PK, course_name)
enrollments (student_id FK, course_id FK, grade)
```

**Final result: 4 clean tables in 3NF.**

---

## 5.9 Denormalization — When to Break the Rules

Normalization is not always the right answer. Sometimes you **intentionally** add redundancy for performance.

### When to denormalize:
- Read-heavy systems where joins are too slow
- Analytics / data warehouses (OLAP) — star/snowflake schemas are deliberately denormalized
- Caching computed values (e.g., store `total_amount` on `orders` instead of summing `order_items`)
- Reporting tables that need to be queried quickly without joins

### Tradeoffs:
| | Normalized | Denormalized |
|-|------------|-------------|
| Data integrity | ✅ Enforced | ❌ Must maintain manually |
| Storage | ✅ Less | ❌ More |
| Write performance | ✅ Write once | ❌ Update multiple places |
| Read performance | ❌ Joins needed | ✅ Fewer joins |

**Rule of thumb**: Start normalized. Denormalize only when you have a measured performance problem.

---

## Summary of Normal Forms

| Form | Requirement | Removes |
|------|-------------|---------|
| 1NF | Atomic values, unique rows | Multi-valued cells, repeating groups |
| 2NF | 1NF + no partial dependencies | Partial dependencies on composite PK |
| 3NF | 2NF + no transitive dependencies | Transitive dependencies via non-key columns |
| BCNF | Every determinant is a superkey | Anomalies with overlapping candidate keys |

---

## Practice Questions

1. A table has `(order_id, product_id, product_description, quantity)`. What normal form is violated and how do you fix it?
2. Normalize this: `employee(emp_id, emp_name, dept_id, dept_name, project_id, project_name, hours_worked)`
3. What is a transitive dependency? Give an example from your daily work.
4. Why is BCNF stricter than 3NF?
5. You're building a reporting dashboard that runs queries 10,000 times per day. Should you normalize or denormalize? Why?

---

**← Previous:** [04_relational_model.md](04_relational_model.md)  
**Next →** [06_schema_design.md](06_schema_design.md)
