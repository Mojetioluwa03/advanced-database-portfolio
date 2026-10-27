# Advanced Database Systems Portfolio

**Course:** MIT 8103 Advanced Database Systems
**Assessment:** Individual Practical Database Portfolio (40 marks)
**Session:** 2026/2027, First Semester Continuous Assessment
**Student:** `<Your Name>` — `<Student ID>`

---

## 1. Selected case study

**Organisation:** ShopStack — a fictional mid-sized online retailer operating in the
UK, EU and US.

**Nature of the business.** ShopStack sells consumer goods through a web storefront
and mobile app. Products are sourced from third-party suppliers and stocked across
four regional distribution centres. Customers browse a two-level category tree, place
orders, pay by card, wallet or buy-now-pay-later, and receive one or more parcels per
order. The business also handles reviews, returns and promotional discount codes.

**Users of the database.**

| User | What they need from the system |
|---|---|
| Customers | Browse catalogue, manage addresses, place orders, track delivery, review products |
| Warehouse staff | See per-location stock, pick and dispatch parcels, record restocks and damages |
| Merchandising team | Manage products, variants, pricing and promotions |
| Customer service | Look up order history, payments, refunds and returns |
| Finance / analysts | Revenue by month and region, margin, returns rate, stock valuation |

**Major data stored.** Customers and their addresses; brands, categories, products and
sellable variants with their attributes; supplier relationships and costs; per-warehouse
stock levels and a complete stock movement ledger; shopping carts; orders, order lines,
payments, shipments; promotions; reviews; return requests.

**Key operations the database supports.**

1. Register a customer and maintain multiple delivery addresses, one of which is default.
2. Browse and search the catalogue by category tree, brand and variant attributes.
3. Place an order: price each line, apply a promotion, compute tax and shipping, take payment.
4. Reserve and decrement stock at a warehouse, recording a movement for every unit.
5. Dispatch an order, possibly across multiple parcels, and track delivery.
6. Accept returns and issue refunds against specific order lines.
7. Report revenue, stock position, returns rate and category performance.

The case study is used consistently across all five portfolio activities.

---

## 2. Repository structure

```
advanced-database-portfolio/
├── README.md                              ← you are here
├── docker-compose.yml                     ← PostgreSQL 16 for local reproduction
├── portfolio-1-database-design/
│   ├── README.md                          design decisions and normalisation argument
│   ├── schema.sql                         26 tables, keys, constraints, reconciliation view
│   ├── seed.py                            deterministic data generator (stdlib only)
│   ├── verify_seed.py                     offline integrity checks on the generated CSVs
│   ├── load.sql                           bulk COPY loader + sequence resync
│   ├── checks.sql                         post-load verification queries
│   ├── verification/checks-output.txt     captured output of the verification run
│   └── erd/                               exported ER diagrams (Chen + crow's foot) and their generators
├── portfolio-2-query-optimisation/
├── portfolio-3-transactions-concurrency/
├── portfolio-4-nosql/
└── portfolio-5-distributed-cloud/
```

---

## 3. Progress

| # | Component | Status | Evidence |
|---|---|---|---|
| 1 | Database Design and Modelling (7) | Complete | `portfolio-1-database-design/` |
| 2 | Query Processing and Optimisation (7) | Complete | `portfolio-2-query-optimisation/` |
| 3 | Transactions and Concurrency (7) | Complete | `portfolio-3-transactions-concurrency/` |
| 4 | NoSQL and Advanced Data Models (7) | Not started | — |
| 5 | Distributed and Cloud Database Exercise (6) | Not started | — |
| — | Final Documentation (6) | Not started | — |

Each folder's README records what was done, how it was tested, and the evidence
captured. Commits are made progressively as each activity progresses.

---

## 4. Environment and reproduction

Requires Python 3.9+ and PostgreSQL 15+; PostgreSQL 16.15 was used here. Docker is
optional and only needed if you have no local server.

### Route A — local PostgreSQL

```bash
cd portfolio-1-database-design

createdb  -h localhost -p 5432 -U postgres shopstack
psql -h localhost -p 5432 -U postgres -d shopstack -f schema.sql

python seed.py            # ~10k products, 50k customers, 200k orders
python verify_seed.py     # offline integrity checks, no database required

psql -h localhost -p 5432 -U postgres -d shopstack -f load.sql
psql -h localhost -p 5432 -U postgres -d shopstack -f checks.sql
```

### Route B — no server, no admin rights

PostgreSQL also ships a portable binaries zip: no installer, no Windows service, no
elevation. This is how the portfolio was built on a machine with no Docker:

```bash
curl -L -A "Mozilla/5.0" -o postgres.zip \
  https://get.enterprisedb.com/postgresql/postgresql-16.15-1-windows-x64-binaries.zip
unzip -q postgres.zip
pgsql/bin/initdb -D pgdata -U postgres --auth=trust -E UTF8 --locale=C
pgsql/bin/pg_ctl -D pgdata -o "-p 5433" -l pgdata/server.log start
pgsql/bin/createdb -h localhost -p 5433 -U postgres shopstack
```

Then run the five Route A steps against port 5433.

Two traps worth recording. The EDB CDN returns **HTTP 403** to anything that is not a
browser user-agent, so the `-A "Mozilla/5.0"` flag is not optional. And
`winget install PostgreSQL.PostgreSQL.16` installs nothing yet still exits **0** — it
fails on that same 403. Check `psql --version` rather than trusting the exit code.

### Route C — Docker

```bash
docker compose up -d
docker compose exec -T postgres psql -U shopstack -d shopstack < schema.sql
```

`load.sql` uses psql's `\copy`, a client-side meta-command, so it must run through
`psql` rather than a generic SQL client — and from inside
`portfolio-1-database-design`, because the CSV paths are relative.

Measured on the reference machine: `schema.sql` under a second, `load.sql` 3m44s for
1.35M rows (dominated by foreign-key checks), `checks.sql` 1.9s over the loaded data.

The generated CSV files in `seed-data/` are deliberately excluded from version control:
they total roughly 100 MB and are fully reproducible from `seed.py` with a fixed random
seed. The generator, not the data dump, is the artefact.

---

## 5. Query languages used

The brief mandates SQL for the relational components and requires the native interface
of the chosen NoSQL store for Portfolio 4. This portfolio complies as follows.

| Component | Language / interface | Where |
|---|---|---|
| P1 Design and modelling | SQL — DDL, DML and verification | `schema.sql`, `load.sql`, `checks.sql` |
| P2 Query and optimisation | SQL, run through psql | `queries.sql`, `indexes.sql`, captured `EXPLAIN (ANALYZE, BUFFERS)` output |
| P3 Transactions | SQL, two concurrent psql sessions | `BEGIN`/`COMMIT`/`ROLLBACK`/`SAVEPOINT`, isolation levels, `SELECT … FOR UPDATE` |
| P4 NoSQL | MongoDB query language (MQL) via the driver | `portfolio-4-nosql/` |
| P5 Distributed and cloud | SQL plus deployment configuration | `portfolio-5-distributed-cloud/` |

`seed.py` is the one non-SQL component. It fabricates rows and stops: it runs no query
that answers a graded question, produces no analysis and generates no execution plan,
so it cannot substitute for the mandated SQL. Every claim about the database's
behaviour is stated in SQL and reproducible from the scripts committed beside it.

`load.sql` uses psql's `\copy`, a client-side meta-command rather than SQL itself, and
it moves data only. All queries in Portfolios 2, 3 and 5 are plain SQL.

---

## 6. Evidence conventions

Every screenshot committed to this repository is accompanied by a sentence stating
what it demonstrates and against which command or query it was captured. Outputs are
reproducible: the dataset is deterministic, so an execution plan quoted in the
documentation can be regenerated by re-running `seed.py` and `load.sql`.

---

## 7. AI use declaration

| Item | Detail |
|---|---|
| Tool | `<e.g. Qoder>` |
| Used for | `<be specific: schema scaffolding, seed data generation, query drafting, ...>` |
| Review performed | `<how each output was checked: re-read, executed, results compared, modified>` |

The database implementation, analysis, documentation and conclusions submitted here
are my own work. AI assistance is declared above in line with the University's
academic integrity requirements, and I can explain and defend every part of the
submitted work.

---

## 8. References

- Elmasri, R. and Navathe, S. B. *Fundamentals of Database Systems*, 7th ed.
- Connolly, T. and Begg, C. *Database Systems: A Practical Approach to Design,
  Implementation and Management*, 6th ed.
- PostgreSQL Global Development Group, *PostgreSQL 16 Documentation*.
- `<add any datasets, libraries or external resources used>`
