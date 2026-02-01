# serverpod_housekeeping

A small helper package for Serverpod backends that registers and schedules
operational “housekeeping” FutureCalls:

- **BackupFutureCall**: calls your HTTP backup agent (I use https://github.com/Alexqwesa/postgres-image-with-backup-agent ) 
and reschedules itself using daily/weekly/monthly policies.
- **CleanupLogsFutureCall**: trims Serverpod internal tables and runs VACUUM / ANALYZE daily.

Schedules are computed in **UTC** for predictability.

---

## Why “housekeeping”

Backups are a must-have. Log cleanup is useful for staging, or for production if you want detailed
Serverpod logs but don’t want to store gigabytes of data in Postgres.

If you want your backups to include logs, schedule cleanup **after** the backup job.

I also clean up health/metrics logs aggressively: if I ever need historical data for a specific
date, I’ll restore it from a backup.

---

## Install

In your Serverpod server `pubspec.yaml`:

```yaml
dependencies:
  serverpod_housekeeping:
    git:
      url: https://github.com/Alexqwesa/serverpod_housekeeping.git
      ref: master

# soon it will be:
dependencies:
  serverpod_housekeeping:
```

```dart

import 'package:serverpod/server.dart';
import 'package:serverpod_housekeeping/serverpod_housekeeping.dart';

Future<void> main(List<String> args) async {
  final pod = Serverpod(
    args,
    Protocol(),
    Endpoints(),
  );

  await ServerpodHousekeeping.ensureScheduled(
    pod,
    backup: const BackupJobConfig(
      agentUrl: envStr('BACKUP_AGENT_URL', 'http://postgres:1804/backup'),
      // you postgres docker container's default name
      agentToken: envStr('BACKUP_AGENT_TOKEN', ''),
      httpTimeout: Duration(seconds: 1000),
      sendDbHostPortHeaders: false,
      dailyTimeUtc: UtcTime(20, 30),
      monthlyTimeUtc: UtcTime(20, 15),
      weeklyTimeUtc: UtcTime(20, 0),
      weeklyWeekday: DateTime.sunday,
      monthlyDay: 1,
    ),
    cleanup: const CleanupLogsConfig(
      timeUtc: UtcTime(19, 0),
      // UTC
      defaultKeepRows: 10_000,
      defaultBatchSize: 50_000,
      defaultVacuum: VacuumMode.analyze,
      order: [
        CleanupTable.serverpod_message_log,
        CleanupTable.serverpod_log,
        CleanupTable.serverpod_query_log,
        CleanupTable.serverpod_session_log,
        CleanupTable.serverpod_health_metric,
        CleanupTable.serverpod_health_connection_info,
      ],
      tables: {
        CleanupTable.serverpod_query_log: TableCleanupConfig(
          keepRows: 50_000,
          vacuum: VacuumMode.fullAnalyze, // locks table; use sparingly
        ),

        CleanupTable.serverpod_session_log: TableCleanupConfig(
          keepRows: 15_000,
          vacuum: VacuumMode.fullAnalyze,
        ),

        CleanupTable.serverpod_health_metric: TableCleanupConfig(
          keepRows: 20_000,
        ),
        CleanupTable.serverpod_health_connection_info: TableCleanupConfig(
          keepRows: 20_000,
        ),
      },
    ),
  );

  await pod.start();
}

```

## TODO:

- move here check_health too
- any backend

