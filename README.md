# ChronoRel

**Automatic Temporal Versioning and Time Travel for PostgreSQL**

ChronoRel is a PostgreSQL extension that automatically tracks changes to supported database tables and preserves their historical versions. It enables developers to inspect past states, examine data changes, retain deleted records, and restore historical versions using SQL.

Instead of manually creating history tables and triggers for every application table, ChronoRel uses PostgreSQL event triggers to detect supported table creation and provision temporal tracking automatically.

## Features

- **Automatic table registration** — detects supported `CREATE TABLE` statements.
- **Automatic history tables** — creates a dedicated history table for each supported table.
- **Automatic versioning** — captures `INSERT`, `UPDATE`, and `DELETE` operations.
- **Full snapshots** — preserves row snapshots for historical inspection.
- **JSONB change deltas** — records changed values between successive snapshots.
- **Historical queries** — retrieves the recorded history of an individual record.
- **Time-travel queries** — retrieves a record's historical state at a specified timestamp.
- **Non-destructive restoration** — restores an earlier snapshot as a new version instead of deleting later history.
- **Audit logging** — records operations, versions, timestamps, and database users.
- **Tracking controls** — enables or disables temporal tracking for registered tables.

## How It Works

```text
                 Application / SQL Client
                          |
                          v
                   PostgreSQL
                          |
                  CREATE TABLE event
                          |
                          v
                ChronoRel Schema Monitor
                          |
             +------------+------------+
             |            |            |
             v            v            v
          Register     Create       Install row
           table       history        trigger
                          table
                          |
                          v
                INSERT / UPDATE / DELETE
                          |
                          v
                 Versioning Engine
                          |
              +-----------+-----------+
              |           |           |
              v           v           v
          Snapshots     Deltas     Audit Log
              |
              v
       History / AS-OF / RESTORE
```

ChronoRel uses two distinct PostgreSQL mechanisms:

- **Event triggers** detect supported schema-level DDL operations, such as `CREATE TABLE`.
- **Row-level triggers** capture row changes made by `INSERT`, `UPDATE`, and `DELETE`.

## Requirements

- PostgreSQL 18 (the version used during development and testing)
- A PostgreSQL installation that supports extension installation and event triggers
- Sufficient database and server privileges to install the extension and create event triggers
- A table with a single-column primary key for automatic temporal tracking

Other PostgreSQL versions have not yet been established as supported.

## Project Structure

```text
chronorel-v1.0/
├── README.md
├── LICENSE
├── .gitignore
├── chronorel.control
├── sql/
│   └── chronorel--1.0.sql
└── demo/
    └── chronorel_demo.sql
```

## Installation

ChronoRel v1.0 uses PostgreSQL's SQL-based extension packaging mechanism.

### 1. Copy the extension files

Copy `chronorel.control` into PostgreSQL's `share/extension` directory.

Copy `sql/chronorel--1.0.sql` into the same extension directory, renaming it to:

```text
chronorel--1.0.sql
```

For example, on a standard Windows PostgreSQL 18 installation:

```text
C:\Program Files\PostgreSQL\18\share\extension\
```

The directory may differ depending on your PostgreSQL installation.

### 2. Create a database

Connect to PostgreSQL and create a database if you do not already have one:

```sql
CREATE DATABASE chronorel_demo;
```

Connect to it using your PostgreSQL client:

```text
\c chronorel_demo
```

### 3. Install ChronoRel

Run:

```sql
CREATE EXTENSION chronorel;
```

Verify the installed version:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'chronorel';
```

Expected version:

```text
chronorel | 1.0
```

## Quick Start

Once installed, create a normal PostgreSQL table.

```sql
CREATE TABLE employees (
    employee_id INTEGER PRIMARY KEY,
    employee_name VARCHAR(100),
    salary NUMERIC(10, 2)
);
```

ChronoRel should automatically register this supported table, create its history table, and install the versioning trigger.

Verify registration:

```sql
SELECT
    table_name,
    primary_key_column,
    history_table_name,
    temporal_enabled
FROM chrono_registry
WHERE table_name = 'employees';
```

Inspect the automatically created history table:

```sql
SELECT to_regclass('public.employees_history');
```

No manual call to `chrono_enable_temporal()` should be required for a newly created supported table.

### Insert a record

```sql
INSERT INTO employees (employee_id, employee_name, salary)
VALUES (1, 'Employee One', 50000);
```

### Update the record

```sql
UPDATE employees
SET salary = 60000
WHERE employee_id = 1;
```

### Inspect its history

```sql
SELECT
    chrono_version,
    chrono_operation,
    chrono_valid_from,
    chrono_valid_to,
    chrono_snapshot,
    chrono_delta
FROM employees_history
WHERE chrono_record_key ->> 'employee_id' = '1'
ORDER BY chrono_version;
```

The history should contain the original snapshot and the subsequent update, with a delta describing the salary change.

### Delete a record

```sql
DELETE FROM employees
WHERE employee_id = 1;
```

The deletion is recorded as a historical operation rather than erasing the record's earlier history.

## Temporal APIs

### `chrono_history()`

Retrieve the historical versions of a record:

```sql
SELECT *
FROM chrono_history('employees', '1');
```

### `chrono_as_of()`

Retrieve the recorded state of a record at a particular timestamp:

```sql
SELECT chrono_as_of(
    'employees',
    '1',
    '2026-10-11 10:00:00+05:30'::timestamptz
);
```

Replace the example timestamp with the point in time you want to inspect. The function returns the historical snapshot as JSONB when a matching version is found.

### `chrono_restore()`

Restore a historical version as a new version:

```sql
CALL chrono_restore('employees', '1', 1);
```

The example restores version 1. The live record is updated or re-created as appropriate, while the subsequent history is preserved.

Inspect the history after restoration:

```sql
SELECT
    chrono_version,
    chrono_operation,
    chrono_snapshot
FROM employees_history
WHERE chrono_record_key ->> 'employee_id' = '1'
ORDER BY chrono_version;
```

### `chrono_disable_temporal()`

Disable tracking for a registered table:

```sql
SELECT chrono_disable_temporal('employees');
```

Existing history is preserved. Future row changes are no longer captured while temporal tracking is disabled.

### `chrono_enable_temporal()`

Re-enable tracking:

```sql
SELECT chrono_enable_temporal('employees');
```

## Internal Tables

| Object | Purpose |
|---|---|
| `chrono_registry` | Stores registered tables, primary-key columns, history-table names, and tracking status. |
| `chrono_config` | Stores ChronoRel configuration entries. |
| `chrono_audit_log` | Records audited temporal operations. |
| `<table>_history` | Stores snapshots, deltas, versions, validity timestamps, and operation metadata for a tracked table. |

ChronoRel also adds temporal metadata columns to supported live tables.

## Current Limitations

ChronoRel v1.0 is an MVP with the following limitations:

- **Single-column primary keys only.** Tables with composite primary keys are skipped.
- Tables without primary keys are skipped.
- The extension is currently packaged as a SQL-based PostgreSQL extension.
- A custom temporal SQL syntax such as `CHRONO AS OF` is not implemented; use `chrono_as_of()`.
- Advanced indexing, retention policies, and performance optimizations are not yet implemented.
- Compatibility beyond the tested PostgreSQL version has not been established.

Review these limitations before using ChronoRel with production data.

## Development and Testing

Recommended test sequence:

1. Install the extension in a clean database.
2. Create a table with a single-column primary key.
3. Verify automatic registration, history-table creation, and trigger creation.
4. Insert multiple records and verify that each starts at version 1.
5. Update a record and inspect its snapshot and JSONB delta.
6. Delete a record and verify that the prior snapshots remain available.
7. Test `chrono_history()` and `chrono_as_of()`.
8. Restore a historical version and verify that restoration creates a new version.
9. Disable tracking and confirm that existing history is preserved.
10. Verify that tables without primary keys and tables with composite primary keys are skipped.

A runnable SQL demonstration can be maintained in `demo/chronorel_demo.sql`.

## Contributing

Contributions, bug reports, test cases, and design suggestions are welcome.

When reporting a bug, include:

- PostgreSQL version
- The SQL statements needed to reproduce the issue
- The complete error message
- The observed result and expected behavior

## Roadmap

Potential future improvements include:

- Composite primary-key support
- A custom temporal query syntax
- Configurable history retention
- Better indexing and query performance
- Expanded automated regression tests
- Packaging and compatibility testing for additional PostgreSQL versions

## License

The project license will be specified in the `LICENSE` file. Review the chosen license before redistributing or accepting external contributions.
