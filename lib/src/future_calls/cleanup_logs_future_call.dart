import 'package:serverpod/server.dart';

import '../schedule/schedule_helpers.dart';

/// Vacuum behavior after trimming.
enum VacuumMode {
  /// Only delete rows; no vacuum.
  none,

  /// VACUUM ANALYZE (recommended as the daily default).
  analyze,

  /// VACUUM FULL ANALYZE (locks the table; reclaims disk immediately).
  fullAnalyze,
}

/// Which Serverpod internal tables to maintain.
enum CleanupTable {
  serverpod_query_log,
  serverpod_log,
  serverpod_message_log,
  serverpod_session_log,
  serverpod_health_metric,
  serverpod_health_connection_info,
}

extension CleanupTableSql on CleanupTable {
  String get sqlName => 'public.$name';
}

/// Per-table override.
class TableCleanupConfig {
  const TableCleanupConfig({
    this.keepRows,
    this.vacuum,
    this.batchSize,
    this.maxBatches,
    this.enabled,
  });

  /// If false, this table is skipped (even if present in order list).
  /// If null, treated as enabled.
  final bool? enabled;

  /// Keep last N rows by id (descending). If null, uses defaultKeepRows.
  final int? keepRows;

  /// Vacuum behavior after delete. If null, uses defaultVacuum.
  final VacuumMode? vacuum;

  /// Delete in batches of this size. If null, uses defaultBatchSize.
  final int? batchSize;

  /// Safety limit: maximum number of delete batches per run.
  /// If null, uses defaultMaxBatches.
  final int? maxBatches;

  bool get isEnabled => enabled != false;
}

/// Global cleanup configuration with per-table overrides.
class CleanupLogsConfig {
  const CleanupLogsConfig({
    this.timeUtc = const UtcTime(19, 0),
    this.defaultKeepRows = 10000,
    this.defaultVacuum = VacuumMode.analyze,
    this.defaultBatchSize = 50000,
    this.defaultMaxBatches = 200,
    this.order = const [
      // Recommended order: dependents first, parents later.
      CleanupTable.serverpod_message_log,
      CleanupTable.serverpod_log,
      CleanupTable.serverpod_query_log,
      CleanupTable.serverpod_session_log,
      CleanupTable.serverpod_health_metric,
      CleanupTable.serverpod_health_connection_info,
    ],
    this.tables = const {},
  });

  /// When to run daily (UTC).
  final UtcTime timeUtc;

  /// Default keep-last-N for tables without overrides.
  final int defaultKeepRows;

  /// Default vacuum behavior for tables without overrides.
  final VacuumMode defaultVacuum;

  /// Default delete batch size.
  final int defaultBatchSize;

  /// Default safety limit on batches.
  final int defaultMaxBatches;

  /// Which tables to process, and in what order.
  ///
  /// This is also how you can “cleanup each table separately” (skip/remove).
  final List<CleanupTable> order;

  /// Per-table overrides.
  final Map<CleanupTable, TableCleanupConfig> tables;

  TableCleanupConfig effective(CleanupTable t) =>
      tables[t] ?? const TableCleanupConfig();
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

    for (final t in config.order) {
      final eff = config.effective(t);
      if (!eff.isEnabled) {
        session.log('Skipping ${t.sqlName}: disabled');
        continue;
      }

      final keepRows = eff.keepRows ?? config.defaultKeepRows;
      final vacuum = eff.vacuum ?? config.defaultVacuum;
      final batchSize = eff.batchSize ?? config.defaultBatchSize;
      final maxBatches = eff.maxBatches ?? config.defaultMaxBatches;

      await _trimAndVacuum(
        session,
        tableSql: t.sqlName,
        keepRows: keepRows,
        vacuum: vacuum,
        batchSize: batchSize,
        maxBatches: maxBatches,
      );
    }

    session.log('CleanupLogsFutureCall completed; rescheduling');
    await schedule(session, config: config);
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

  /// Trims a table to keep the most recent [keepRows] by id,
  /// deleting older rows in batches.
  ///
  /// Notes:
  /// - Batching is beneficial for *all* tables (shorter transactions).
  /// - VACUUM FULL locks the table; use sparingly.
  static Future<void> _trimAndVacuum(
    Session session, {
    required String tableSql,
    required int keepRows,
    required VacuumMode vacuum,
    required int batchSize,
    required int maxBatches,
  }) async {
    if (keepRows <= 0) {
      session.log('Skip trim for $tableSql because keepRows=$keepRows');
      return;
    }
    if (batchSize <= 0) {
      session.log('Skip trim for $tableSql because batchSize=$batchSize');
      return;
    }
    if (maxBatches <= 0) {
      session.log('Skip trim for $tableSql because maxBatches=$maxBatches');
      return;
    }

    final minKeepId = await _computeMinKeepId(
      session,
      tableSql: tableSql,
      keepRows: keepRows,
    );

    if (minKeepId == null) {
      session.log('Skip trim for $tableSql: table has < $keepRows rows');
      return;
    }

    session.log(
      'Trimming $tableSql: keepRows=$keepRows (minKeepId=$minKeepId), '
      'batchSize=$batchSize, maxBatches=$maxBatches, vacuum=$vacuum',
    );

    var totalDeleted = 0;
    for (var i = 0; i < maxBatches; i++) {
      final deleted = await _deleteBatch(
        session,
        tableSql: tableSql,
        minKeepId: minKeepId,
        batchSize: batchSize,
      );

      if (deleted <= 0) break;

      totalDeleted += deleted;

      // small yield so we don't hog the DB in one tight loop.
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    session.log('Trimmed $tableSql: deleted=$totalDeleted');

    switch (vacuum) {
      case VacuumMode.none:
        break;
      case VacuumMode.analyze:
        await session.db.unsafeExecute('VACUUM ANALYZE $tableSql;');
        break;
      case VacuumMode.fullAnalyze:
        await session.db.unsafeExecute('VACUUM FULL ANALYZE $tableSql;');
        break;
    }
  }

  /// Deletes up to [batchSize] rows older than the cutoff that keeps
  /// the newest [keepRows] rows. Returns number of rows deleted.
  ///
  /// We avoid "DELETE ... RETURNING 1" for every row (huge),
  /// and instead count in SQL: SELECT count(*) FROM del.
static Future<int> _deleteBatch(
  Session session, {
  required String tableSql,
  required int minKeepId,
  required int batchSize,
}) async {
  final sql = '''
    WITH del AS (
      DELETE FROM $tableSql t
      WHERE t.id < $minKeepId
        AND t.ctid IN (
          SELECT s.ctid
          FROM $tableSql s
          WHERE s.id < $minKeepId
          ORDER BY s.id ASC
          LIMIT $batchSize
        )
      RETURNING 1
    )
    SELECT count(*)::int AS n FROM del;
    ''';

  final rows = await session.db.unsafeQuery(sql);

  if (rows.isEmpty || rows.first.isEmpty) return 0;

  final v = rows.first.first;
  if (v is int) return v;
  if (v is BigInt) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;

  return 0;
}

  static Future<int?> _computeMinKeepId(
    Session session, {
    required String tableSql,
    required int keepRows,
  }) async {
    final sql = '''
      WITH last_rows AS (
        SELECT id
        FROM $tableSql
        ORDER BY id DESC
        LIMIT $keepRows
      )
      SELECT MIN(id)::int AS min_keep_id
      FROM last_rows;
      ''';

    final rows = await session.db.unsafeQuery(sql);
    if (rows.isEmpty || rows.first.isEmpty) return null;

    final v = rows.first.first;
    if (v == null) return null;
    if (v is int) return v;
    if (v is BigInt) return v.toInt();
    if (v is String) return int.tryParse(v);

    return null;
  }
}