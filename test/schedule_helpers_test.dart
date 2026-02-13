import 'package:serverpod_housekeeping/src/schedule/schedule_helpers.dart';
import 'package:test/test.dart';

void main() {
  group('UtcTime', () {
    test('toString formats correctly', () {
      expect(const UtcTime(5, 9).toString(), '05:09');
      expect(const UtcTime(15, 30).toString(), '15:30');
    });
  });

  group('nextDaily', () {
    test('returns time today if not yet passed', () {
      // This test is tricky because it depends on "now".
      // Ideally we'd inject "now", but the helper calls DateTime.now() internally.
      // We can check if the result is either today or tomorrow with correct hour/minute.
      final targetHour = (DateTime.now().toUtc().hour + 2) % 24;
      final result = nextDaily(hour: targetHour, minute: 30);

      expect(result.hour, targetHour);
      expect(result.minute, 30);
      expect(result.isAfter(DateTime.now().toUtc()), isTrue);
    });

    test('returns time tomorrow if already passed', () {
      final now = DateTime.now().toUtc();
      // Pick a time definitely in the past for today (e.g. 1 hour ago)
      // or if it's start of day, wrap around.
      // Easiest is to pick now.hour - 1 if possible, else now.hour + 23 (which implies yesterday effectively but we want to simulate "today passed")
      // Actually, if we pass an hour that is current hour - 1, it must return tomorrow.

      // Edge case: if now is 00:00, we can't subtract.
      // Let's use logic:

      final pastHour = (now.hour - 1);
      if (pastHour >= 0) {
        final result = nextDaily(hour: pastHour, minute: now.minute);
        expect(result.day, isNot(now.day)); // Should be tomorrow
        expect(result.hour, pastHour);
      }
    });
  });

  // Note: Detailed testing of these helpers is hard without dependency injection of "clock".
  // However, I will write checking logic that asserts the contract.

  group('nextWeekly', () {
    test('returns next occurrence of weekday', () {
      final now = DateTime.now().toUtc();
      // Target next Monday
      final result = nextWeekly(weekday: DateTime.monday, hour: 10, minute: 0);

      expect(result.weekday, DateTime.monday);
      expect(result.hour, 10);
      expect(result.minute, 0);
      expect(result.isAfter(now), isTrue);
      // It should be within 7 days
      expect(result.difference(now).inDays, lessThanOrEqualTo(7));
    });
  });

  group('nextMonthly', () {
    test('returns next occurrence of day', () {
      final now = DateTime.now().toUtc();
      // Target 1st of month
      final result = nextMonthly(hour: 12, minute: 0, day: 1);

      expect(result.day, 1);
      expect(result.hour, 12);
      expect(result.isAfter(now), isTrue);
      // It should be within ~32 days
      expect(result.difference(now).inDays, lessThanOrEqualTo(32));
    });
  });
}
