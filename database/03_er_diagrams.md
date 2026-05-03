# Chapter 3 — Entity-Relationship Diagrams

An **ER Diagram** is the blueprint of your database. You draw it before you write a single line of SQL. It captures *what* your system needs to store and *how* pieces relate to each other.

---

## 3.1 Why ER Diagrams?

Without design, you end up with:
- Duplicated data everywhere
- Tables that are impossible to query without pain
- Schema changes that break everything

An ER diagram forces you to think about the problem domain first.

---

## 3.2 The Three Building Blocks

### Entities
An **entity** is a real-world object or concept you want to store data about.

Examples: `Customer`, `Order`, `Product`, `Employee`, `Department`

In SQL → becomes a **table**.

### Attributes
An **attribute** is a property of an entity.

- `Customer` has: `customer_id`, `name`, `email`, `phone`
- `Product` has: `product_id`, `name`, `price`, `stock_qty`

In SQL → becomes a **column**.

### Relationships
A **relationship** connects two entities.

- A `Customer` **places** an `Order`
- An `Order` **contains** `Products`
- An `Employee` **works in** a `Department`

In SQL → becomes a **foreign key** (or a junction table for many-to-many).

---

## 3.3 Cardinality — The Most Important Concept

Cardinality describes **how many** of one entity relates to **how many** of another.

### One-to-One (1:1)
Each record on side A relates to exactly one record on side B.

```
Employee (1) ──── (1) Passport
```
One employee has one passport. One passport belongs to one employee.

SQL: Add `passport_id FK` in the `employees` table (or vice versa).

---

### One-to-Many (1:N) — Most Common
One record on side A relates to many records on side B.

```
Department (1) ──── (N) Employee
```
One department has many employees. Each employee belongs to one department.

SQL: Add `dept_id FK` in the `employees` table (the "many" side always holds the FK).

---

### Many-to-Many (M:N)
Many records on side A relate to many records on side B.

```
Student (M) ──── (N) Course
```
A student enrolls in many courses. A course has many students.

SQL: You **cannot** store this directly — you need a **junction table** (also called bridge table, associative table).

```
students          enrollments          courses
┌────┬──────┐    ┌────┬──────────┬──────────┐    ┌────┬────────┐
│ id │ name │    │ id │student_id│course_id │    │ id │ name   │
└────┴──────┘    └────┴──────────┴──────────┘    └────┴────────┘
```

The `enrollments` table holds the M:N relationship. It can also carry extra attributes like `enrolled_at`, `grade`.

---

## 3.4 Types of Attributes

| Type | Description | Example |
|------|-------------|---------|
| **Simple** | Single atomic value | `age`, `salary` |
| **Composite** | Made of sub-parts | `full_name` = `first_name` + `last_name` |
| **Multi-valued** | Can have multiple values | `phone_numbers` (a person can have many) |
| **Derived** | Computed from other data | `age` derived from `birth_date` |
| **Key** | Uniquely identifies the entity | `employee_id` |

In practice: store composite attributes as separate columns. Store multi-valued as a separate table.

---

## 3.5 ER Notation (Chen vs Crow's Foot)

You'll see two notations in the wild:

### Chen Notation (academic)
```
[Employee] ----<works_in>---- [Department]
```
Rectangles = entities, diamonds = relationships, ovals = attributes.

### Crow's Foot Notation (industry standard)

```
Department  ||──o{  Employee
             ^         ^
         exactly one   zero or many
```

Symbols on the line ends:
```
||   = exactly one
|o   = zero or one
|{   = one or many
o{   = zero or many
```

Most tools (dbdiagram.io, Lucidchart, ERDPlus) use Crow's Foot.

---

## 3.6 Full Example — E-Commerce System

Let's design a simple e-commerce database.

**Entities**: `Customer`, `Order`, `Product`, `Category`

**Relationships**:
- A customer **places** many orders (1:N)
- An order **contains** many products, a product appears in many orders (M:N)
- A product **belongs to** one category, a category **has** many products (1:N)

**ER Diagram (text representation)**:

```
Customer (1) ──────────── (N) Order
                                │
                                │ (N)
                          OrderItem  ← junction table
                                │
                                │ (N)
Product (N) ──────────── (M) OrderItem
   │
   │ (N)
Category (1) ──────────── (N) Product
```

**Resulting tables**:

```sql
customers    (customer_id PK, name, email, created_at)
orders       (order_id PK, customer_id FK, order_date, total)
products     (product_id PK, name, price, category_id FK)
categories   (category_id PK, name)
order_items  (order_id FK, product_id FK, qty, unit_price)
              └── composite PK: (order_id, product_id)
```

---

## 3.7 Participation Constraints

Along with cardinality, you must decide if participation is **total** or **partial**.

- **Total participation**: every instance must participate  
  e.g., every employee *must* belong to a department
- **Partial participation**: participation is optional  
  e.g., a department *may* have employees (a new dept with no staff yet)

In SQL:
- Total = `NOT NULL` constraint on the FK
- Partial = FK is nullable

---

## 3.8 Weak Entities

A **weak entity** cannot be uniquely identified by its own attributes alone — it depends on another entity.

Example: `OrderItem` has no meaning without an `Order`. Its identity is `(order_id, line_number)`.

Weak entities:
- Have no primary key of their own
- Identified by their **owner entity** + a **partial key**
- Always have total participation with their owner

---

## 3.9 ER to SQL — The Translation Rules

| ER Concept | SQL Translation |
|------------|----------------|
| Entity | Table |
| Simple attribute | Column |
| Composite attribute | Multiple columns |
| Multi-valued attribute | Separate table with FK |
| 1:1 relationship | FK in either table (usually the optional side) |
| 1:N relationship | FK on the "many" side |
| M:N relationship | Junction table with two FKs |
| Weak entity | Table whose PK includes owner's PK |

---

## 3.10 Common Design Mistakes

1. **Storing multi-valued data in one column** — `"Python,SQL,Docker"` in a skills column. Make a separate `employee_skills` table.
2. **Skipping the junction table** — trying to store M:N by listing IDs in an array column. Use a proper junction table.
3. **Making everything one giant table** — cramming customer + order + product into one row. Split by entity.
4. **Ignoring cardinality** — not deciding 1:N vs M:N before writing SQL leads to incorrect schemas.

---

## Key Terms

| Term | Meaning |
|------|---------|
| Entity | A real-world thing you store data about |
| Attribute | A property of an entity |
| Relationship | A connection between two entities |
| Cardinality | How many of A relates to how many of B |
| Junction Table | A table that resolves M:N relationships |
| Weak Entity | An entity that depends on another for identity |
| Participation | Whether every instance must be in a relationship |

---

## Practice Questions

1. Draw an ER diagram for a library system: books, authors, members, loans.
2. Is the relationship between a doctor and patients 1:N or M:N? Why?
3. What SQL structure do you create for a M:N relationship?
4. An `Invoice` has `InvoiceLines`. Is `InvoiceLine` a weak entity? Why?
5. Convert this: a `Blog` has many `Posts`, each `Post` has many `Tags`, and `Tags` can apply to many `Posts`.

---

**← Previous:** [02_data_models.md](02_data_models.md)  
**Next →** [04_relational_model.md](04_relational_model.md)
