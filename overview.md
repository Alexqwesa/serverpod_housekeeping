## Technical overview

This package adds two operational jobs to a Serverpod backend using Serverpod’s built-in
**FutureCall** scheduler. Both jobs are designed to be deterministic and ops-friendly:
schedules are computed in **UTC**, and maintenance work is executed in bounded steps to avoid
long database locks or runaway jobs.

### Components

#### 1) Backup FutureCalls

Backups are implemented as three independent FutureCalls:

- `BackupDailyFutureCall`
- `BackupWeeklyFutureCall`
- `BackupMonthlyFutureCall`

Each FutureCall:

1. Sends an HTTP request to your backup agent (`agentUrl`) with a `reason` query parameter
   (`daily|weekly|monthly`).
2. Optionally adds a bearer token (`Authorization: Bearer ...`).
3. Optionally sends database connection hints via headers (`POSTGRES_HOST` and
   `POSTGRES_PORT`) so the backup agent can connect to the same DB Serverpod is using.
4. Reschedules itself for the next run using a stable identifier (e.g. `housekeeping:backup:daily`).

Design notes:

- Uses `HttpClient` with configurable timeouts and defensive error handling
  (`TimeoutException`, non-2xx status codes).
- Scheduling helpers (`nextDaily / nextWeekly / nextMonthly`) compute the next execution time
  in UTC, avoiding local timezone drift.
- Recurring jobs should reschedule even after failures (so a temporary outage does not stop future backups).

##### Adhoc backup (`BackupAdhocFutureCall`)

In addition to recurring backups, the package provides an **adhoc** (one-shot) backup trigger:

- `BackupAdhocFutureCall` is registered once at startup (no schedule).
- `BackupAdhocFutureCall.runNow(pod)` schedules a FutureCall **immediately** and executes the
  same HTTP backup logic with `reason=adhoc`.
- Adhoc does **not** reschedule itself.

Operational notes:

- Adhoc runs via the FutureCall worker (recommended for admin UI buttons), so it does not block
  the request that triggered it.


#### 2) `CleanupLogsFutureCall`

Log/metric cleanup is implemented as a single daily FutureCall: `CleanupLogsFutureCall`.

The cleanup job is configurable on a **per-table** basis:

- `CleanupTable` enumerates supported Serverpod internal tables.
- `CleanupLogsConfig` defines global defaults (keep rows, batch size, vacuum mode, max
  batches) and an explicit processing order.
- `TableCleanupConfig` overrides behavior per table (including disabling a table entirely).

This makes it easy to keep more history for some tables (e.g. `serverpod_session_log`) while
aggressively trimming others (e.g. health metrics).

### Cleanup algorithm

For each enabled table in `config.order`:

1. **Compute cutoff once**  
   `_computeMinKeepId()` finds the minimum `id` among the newest `keepRows` rows.

   - If the table has fewer than `keepRows` rows, the cutoff is `null` and the table is
     skipped.

2. **Delete old rows in batches**  
   `_deleteBatch()` removes up to `batchSize` rows where `id < cutoff`.

   Since Postgres doesn’t support `DELETE … LIMIT`, the batch limit is enforced using
   `ctid`:

   - select `ctid` for the oldest rows to delete (`ORDER BY id ASC LIMIT batchSize`)
   - delete exactly those physical rows
   - return only a count (not the deleted rows)

   The job repeats this up to `maxBatches` times, with a small delay between batches to avoid
   monopolizing the database.

3. **Vacuum strategy**  
   After deletes, the job applies a per-table vacuum mode:

   - `VacuumMode.analyze` → `VACUUM ANALYZE`
   - `VacuumMode.fullAnalyze` → `VACUUM FULL ANALYZE` (reclaims disk but locks the table; use
     sparingly)
   - `VacuumMode.none` → no vacuum

### Why batching matters

A single “delete everything older than N” statement can become a massive transaction on large
tables. Batching:

- keeps transactions short,
- reduces long lock holds,
- smooths WAL generation,
- lowers the risk of timeouts.

`VACUUM FULL` is still a blocking operation (table rewrite + locks), so it should be reserved
for exceptional cases (typically large query logs that must reclaim disk immediately).

### Table ordering and safety

The default cleanup order is chosen to reduce foreign key issues if your schema links log
tables to sessions:

1. `serverpod_message_log`
2. `serverpod_log`
3. `serverpod_query_log`
4. `serverpod_session_log`
5. `serverpod_health_metric`
6. `serverpod_health_connection_info`

If you customize your Serverpod schema or add constraints, adjust `CleanupLogsConfig.order`
accordingly.

### Configuration model

Global defaults apply to all tables. Any table can override:

- `keepRows`
- `batchSize`
- `maxBatches`
- `vacuum`
- `enabled`

This gives fine-grained control while keeping the default setup simple.

### Operational behavior

- Jobs are registered and scheduled via `ensureScheduled(...)`.
- FutureCalls use stable identifiers so re-deploying or re-running setup replaces the previous
  schedule cleanly (`cancelFutureCall` + schedule).
- The jobs write progress to `session.log(...)` so behavior is visible in production logs.
