// lib/src/serverpod_housekeeping.dart
import 'package:serverpod/server.dart';

/// Register + schedule housekeeping jobs for a Serverpod backend.
///
/// Call once during startup.
///
/// Example:
/// ```dart
/// await ServerpodHousekeeping.ensureScheduled(pod);
/// ```
import 'future_calls/backup_future_call.dart';
import 'future_calls/cleanup_logs_future_call.dart';

class ServerpodHousekeeping {
  static Future<void> ensureScheduled(
    Serverpod pod, {
    BackupJobConfig? backup,
    CleanupLogsConfig? cleanup,
  }) async {
    if (backup != null) {
      await BackupDailyFutureCall.ensureScheduled(pod, config: backup);
      await BackupWeeklyFutureCall.ensureScheduled(pod, config: backup);
      await BackupMonthlyFutureCall.ensureScheduled(pod, config: backup);
      BackupAdhocFutureCall.register(pod, config: backup);
    }
    if (cleanup != null) {
      await CleanupLogsFutureCall.ensureScheduled(pod, config: cleanup);
    }
  }
}
