import 'package:serverpod/server.dart';

import '../schedule/schedule_helpers.dart';

class CleanupLogsConfig {
  const CleanupLogsConfig({
    this.timeUtc = const UtcTime(19, 0),
    this.keepRows = 10000,
    this.fullVacuumQueryLog = true,
  });

  final UtcTime timeUtc;
  final int keepRows;

  /// Uses VACUUM FULL for serverpod_query_log (locks table but reclaims disk space).
  final bool fullVacuumQueryLog;
}

/// Daily housekeeping for Serverpod internal tables.
class CleanupLogsFutureCall extends FutureCall {
  CleanupLogsFutureCall(this.config);

  final CleanupLogsConfig config;

  static const futureCallName = 'housekeeping.logs.cleanup';
  static const futureCallId = 'housekeeping:logs:cleanup:daily';

  @override
  Future<void> invoke(Session session, void parameter) async {
    session.log('CleanupLogsFutureCall started');

    await _trimAndVacuum(
      session,
      table: 'public.serverpod_query_log',
      keepRows: config.keepRows,
      fullVacuum: config.fullVacuumQueryLog,
    );

    await _trimAndVacuum(
      session,
      table: 'public.serverpod_health_metric',
      keepRows: config.keepRows,
      fullVacuum: config.fullVacuumQueryLog,
    );
    await _trimAndVacuum(
      session,
      table: 'public.serverpod_health_connection_info',
      keepRows: config.keepRows,
      fullVacuum: config.fullVacuumQueryLog,
    );
    await _trimAndVacuum(
      session,
      table: 'public.serverpod_session_log',
      keepRows: config.keepRows,
      fullVacuum: config.fullVacuumQueryLog,
    );

    session.log('CleanupLogsFutureCall completed; rescheduling');

    await schedule(session);
  }

  static Future<void> ensureScheduled(
    Serverpod pod, {
    required CleanupLogsConfig config,
  }) async {
    final session = await pod.createSession();
    try {
      pod.registerFutureCall(CleanupLogsFutureCall(config), futureCallName);
      await schedule(session, config: config);
    } finally {
      await session.close();
    }
  }

  static Future<void> schedule(
    Session session, {
    CleanupLogsConfig? config,
  }) async {
    final c = config ?? const CleanupLogsConfig();
    final next = nextDaily(hour: c.timeUtc.hour, minute: c.timeUtc.minute);

    await session.serverpod.cancelFutureCall(futureCallId);
    await session.serverpod.futureCallAtTime(
      futureCallName,
      null,
      next,
      identifier: futureCallId,
    );

    session.log('CleanupLogsFutureCall scheduled at $next (UTC)');
  }

  static Future<void> _trimAndVacuum(
    Session session, {
    required String table,
    required int keepRows,
    required bool fullVacuum,
  }) async {
    final sqlDelete = '''
WITH cutoff AS (
  SELECT MIN(id) AS min_keep_id
  FROM (
    SELECT id
    FROM $table
    ORDER BY id DESC
    LIMIT $keepRows
  ) AS last_rows
)
DELETE FROM $table l
USING cutoff
WHERE l.id < cutoff.min_keep_id;
''';

    await session.db.unsafeExecute(sqlDelete);
    await session.db.unsafeExecute('VACUUM ANALYZE $table;');

    if (fullVacuum) {
      await session.db.unsafeExecute('VACUUM FULL ANALYZE $table;');
    }
  }
}
