import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:serverpod/serverpod.dart';

import '../schedule/schedule_helpers.dart';

/// Backup job config passed by the host project (no env magic).
class BackupJobConfig {
  const BackupJobConfig({
    required this.agentUrl, // e.g. http://postgres:1804/backup
    this.agentToken = '',
    this.httpTimeout = const Duration(seconds: 300),
    this.sendDbHostPortHeaders = false,
    this.dbHostOverride,
    this.dbPortOverride,
    this.dailyTimeUtc = const UtcTime(20, 30),
    this.weeklyTimeUtc = const UtcTime(20, 0),
    this.weeklyWeekday = DateTime.sunday,
    this.monthlyTimeUtc = const UtcTime(20, 15),
    this.monthlyDay = 1,
    this.callBack,
  });

  final String agentUrl;
  final String agentToken;
  final Duration httpTimeout;

  /// If true, send POSTGRES_HOST/POSTGRES_PORT headers to the agent.
  final bool sendDbHostPortHeaders;

  /// Optional overrides; if null, values are derived from Serverpod db config.
  final String? dbHostOverride;
  final String? dbPortOverride;

  final UtcTime dailyTimeUtc;
  final UtcTime weeklyTimeUtc;
  final int weeklyWeekday; // DateTime.monday..DateTime.sunday
  final UtcTime monthlyTimeUtc;
  final int monthlyDay;

  final void Function(bool success, String policy)? callBack;
}

/// Base class implementing the actual HTTP call logic.
/// Uses `FutureCall<void>` for maximum Serverpod 2+/3+ compatibility.
abstract class _BackupBaseFutureCall extends FutureCall {
  _BackupBaseFutureCall(this.config);

  final BackupJobConfig config;

  /// 'daily' | 'weekly' | 'monthly' | 'adhoc'
  String get policy;

  @override
  Future<void> invoke(Session session, void parameter) async {
    session.log('BackupFutureCall started; policy=$policy');
    var success = false;
    HttpClient? client;

    try {
      final rawUrl = _sanitizeUrl(config.agentUrl);
      final uri = Uri.parse(rawUrl).replace(queryParameters: {'reason': policy});

      client = HttpClient()..connectionTimeout = config.httpTimeout;

      final req = await client.postUrl(uri);

      if (config.agentToken.isNotEmpty) {
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${config.agentToken}',
        );
      }

      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');

      if (config.sendDbHostPortHeaders) {
        final cfg = session.serverpod.config.database;

        final dbHost = config.dbHostOverride ??
            (session.serverpod.runMode == ServerpodRunMode.development
                ? 'host.docker.internal'
                : (cfg?.host ?? 'postgres'));

        final dbPort = config.dbPortOverride ?? (cfg?.port?.toString() ?? '5432');

        req.headers.set('POSTGRES_HOST', dbHost);
        req.headers.set('POSTGRES_PORT', dbPort);
      }

      req.add(utf8.encode('{}'));

      final res = await req.close().timeout(config.httpTimeout);
      final status = res.statusCode;
      final bodyText = await res.transform(utf8.decoder).join();

      success = status >= 200 && status < 300;
      if (!success) {
        session.log(
          'Backup agent failed; status=$status body=$bodyText',
          level: LogLevel.error,
        );
        return;
      }

      session.log('Backup agent success; status=$status body=$bodyText');
    } on TimeoutException {
      session.log(
        'Backup agent timeout after ${config.httpTimeout.inSeconds}s',
        level: LogLevel.error,
      );
    } catch (e, st) {
      session.log(
        'Backup agent exception: $e\n$st',
        level: LogLevel.error,
      );
    } finally {
      client?.close(force: true);
      // Always reschedule recurring jobs even after failure

      // Precompute recurring reschedule info (so it works even if we fail early).
      final nextTime = switch (policy) {
        'daily' => nextDaily(
            hour: config.dailyTimeUtc.hour,
            minute: config.dailyTimeUtc.minute,
          ),
        'weekly' => nextWeekly(
            weekday: config.weeklyWeekday,
            hour: config.weeklyTimeUtc.hour,
            minute: config.weeklyTimeUtc.minute,
          ),
        'monthly' => nextMonthly(
            hour: config.monthlyTimeUtc.hour,
            minute: config.monthlyTimeUtc.minute,
            day: config.monthlyDay,
          ),
        _ => null,
      };

      final id = switch (policy) {
        'daily' => BackupDailyFutureCall.futureCallId,
        'weekly' => BackupWeeklyFutureCall.futureCallId,
        'monthly' => BackupMonthlyFutureCall.futureCallId,
        _ => null,
      };

      final name = switch (policy) {
        'daily' => BackupDailyFutureCall.futureCallName,
        'weekly' => BackupWeeklyFutureCall.futureCallName,
        'monthly' => BackupMonthlyFutureCall.futureCallName,
        _ => null,
      };

      if (!(policy == 'adhoc') && nextTime != null && id != null && name != null) {
        try {
          await session.serverpod.futureCallAtTime(
            name,
            null,
            nextTime,
            identifier: id,
          );
          session.log('Rescheduled $policy backup at $nextTime (id=$id)');
        } catch (e, st) {
          session.log(
            'Failed to reschedule $policy backup: $e\n$st',
            level: LogLevel.error,
          );
        }
      }

      config.callBack?.call(success, policy);
    }
  }
}

/// Trim accidental wrapping quotes in config values.
String _sanitizeUrl(String s) {
  var v = s.trim();
  if (v.length >= 2) {
    final first = v.codeUnitAt(0);
    final last = v.codeUnitAt(v.length - 1);
    final quoted = (first == 0x27 && last == 0x27) || (first == 0x22 && last == 0x22); // ' or "
    if (quoted) v = v.substring(1, v.length - 1).trim();
  }
  return v;
}

/// Daily backup: `backup.daily`
class BackupDailyFutureCall extends _BackupBaseFutureCall {
  BackupDailyFutureCall(super.config);

  static const futureCallName = 'housekeeping.backup.daily';
  static const futureCallId = 'housekeeping:backup:daily';

  @override
  String get policy => 'daily';

  static Future<void> ensureScheduled(
    Serverpod pod, {
    required BackupJobConfig config,
  }) async {
    final session = await pod.createSession();
    try {
      pod.registerFutureCall(BackupDailyFutureCall(config), futureCallName);

      await session.serverpod.cancelFutureCall(futureCallId);

      await session.serverpod.futureCallAtTime(
        futureCallName,
        null,
        nextDaily(
          hour: config.dailyTimeUtc.hour,
          minute: config.dailyTimeUtc.minute,
        ),
        identifier: futureCallId,
      );

      session.log('Daily backup scheduled (UTC) at ${config.dailyTimeUtc}');
    } finally {
      await session.close();
    }
  }
}

/// Weekly backup: `backup.weekly`
class BackupWeeklyFutureCall extends _BackupBaseFutureCall {
  BackupWeeklyFutureCall(super.config);

  static const futureCallName = 'housekeeping.backup.weekly';
  static const futureCallId = 'housekeeping:backup:weekly';

  @override
  String get policy => 'weekly';

  static Future<void> ensureScheduled(
    Serverpod pod, {
    required BackupJobConfig config,
  }) async {
    final session = await pod.createSession();
    try {
      pod.registerFutureCall(BackupWeeklyFutureCall(config), futureCallName);

      await session.serverpod.cancelFutureCall(futureCallId);

      await session.serverpod.futureCallAtTime(
        futureCallName,
        null,
        nextWeekly(
          weekday: config.weeklyWeekday,
          hour: config.weeklyTimeUtc.hour,
          minute: config.weeklyTimeUtc.minute,
        ),
        identifier: futureCallId,
      );

      session.log(
        'Weekly backup scheduled (UTC) weekday=${config.weeklyWeekday} at ${config.weeklyTimeUtc}',
      );
    } finally {
      await session.close();
    }
  }
}

/// Monthly backup: `backup.monthly`
class BackupMonthlyFutureCall extends _BackupBaseFutureCall {
  BackupMonthlyFutureCall(super.config);

  static const futureCallName = 'housekeeping.backup.monthly';
  static const futureCallId = 'housekeeping:backup:monthly';

  @override
  String get policy => 'monthly';

  static Future<void> ensureScheduled(
    Serverpod pod, {
    required BackupJobConfig config,
  }) async {
    final session = await pod.createSession();
    try {
      pod.registerFutureCall(BackupMonthlyFutureCall(config), futureCallName);

      await session.serverpod.cancelFutureCall(futureCallId);

      await session.serverpod.futureCallAtTime(
        futureCallName,
        null,
        nextMonthly(
          hour: config.monthlyTimeUtc.hour,
          minute: config.monthlyTimeUtc.minute,
          day: config.monthlyDay,
        ),
        identifier: futureCallId,
      );

      session.log(
        'Monthly backup scheduled (UTC) day=${config.monthlyDay} at ${config.monthlyTimeUtc}',
      );
    } finally {
      await session.close();
    }
  }
}

/// Adhoc backup: one-shot, no reschedule.
class BackupAdhocFutureCall extends _BackupBaseFutureCall {
  BackupAdhocFutureCall(super.config);

  static const futureCallName = 'housekeeping.backup.adhoc';
  static const futureCallId = 'housekeeping:backup:adhoc';

  @override
  String get policy => 'adhoc';

  static BackupJobConfig? _config;

  /// Register the adhoc FutureCall (no scheduling).
  ///
  /// Stores config so `runNow()` can be called without parameters.
  static void register(Serverpod pod, {required BackupJobConfig config}) {
    _config = config;
    pod.registerFutureCall(BackupAdhocFutureCall(config), futureCallName);
  }

  /// Trigger a one-shot backup immediately (runs via FutureCall scheduler).
  ///
  /// - No config parameter (uses config stored during `register()`)
  /// - No reschedule (policy == 'adhoc')
  static Future<void> runNow(Serverpod pod) async {
    if (_config == null) {
      throw StateError(
        'BackupAdhocFutureCall.runNow called before register(). '
        'Register it once during startup.',
      );
    }

    final session = await pod.createSession();
    try {
      // Replace any pending adhoc run.
      await session.serverpod.cancelFutureCall(futureCallId);

      await session.serverpod.futureCallAtTime(
        futureCallName,
        null,
        DateTime.now().toUtc(),
        identifier: futureCallId,
      );

      session.log('Adhoc backup triggered (UTC) now');
    } finally {
      await session.close();
    }
  }
}
