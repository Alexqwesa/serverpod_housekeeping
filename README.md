# serverpod_housekeeping

A small helper package for Serverpod backends that registers and schedules
operational “housekeeping” FutureCalls:

- **BackupFutureCall**: calls your HTTP backup agent (pg_dump trigger)
  and reschedules itself for daily/weekly/monthly policies.
- **CleanupLogsFutureCall**: trims Serverpod internal tables and runs
  VACUUM / ANALYZE daily.

Schedules are computed in **UTC** for predictability.

---

## Why “housekeeping”

Backups are a must. Log cleanup is useful for staging, or for production if you want detailed
Serverpod logs but don’t want to store gigabytes of data in Postgres.


---

## Install

In your Serverpod server `pubspec.yaml`:

```yaml
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
        agentUrl: 'http://postgres:1804/backup', // you postgres docker container's default name
        agentToken: 'secret',
        httpTimeout: Duration(seconds: 1000),
        sendDbHostPortHeaders: false, 
        dailyTimeUtc: UtcTime(20, 30),
        monthlyTimeUtc: UtcTime(20, 15),
        weeklyTimeUtc: UtcTime(20, 0),
        weeklyWeekday: DateTime.sunday,
        monthlyDay: 1,
      ),
      cleanup: const CleanupLogsConfig( // don't need if you do not logs in production
        timeUtc: UtcTime(19, 0), // before backup
        keepRows: 10000,  // delete all except last 10000
        fullVacuumQueryLog: true,
      ),
    );

  await pod.start();
}

```

