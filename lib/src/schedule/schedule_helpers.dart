/// UTC scheduling helpers (predictable across hosts).

DateTime nextDaily({required int hour, required int minute}) {
  final now = DateTime.now().toUtc();
  var next = DateTime.utc(now.year, now.month, now.day, hour, minute);
  if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
  return next;
}

DateTime nextWeekly({
  required int weekday, // DateTime.monday..DateTime.sunday
  required int hour,
  required int minute,
}) {
  final now = DateTime.now().toUtc();
  var next = DateTime.utc(now.year, now.month, now.day, hour, minute);

  final delta = (weekday - next.weekday) % 7;
  next = next.add(Duration(days: delta));

  if (!next.isAfter(now)) next = next.add(const Duration(days: 7));
  return next;
}

DateTime nextMonthly({
  required int hour,
  required int minute,
  int day = 1,
}) {
  final now = DateTime.now().toUtc();
  var next = DateTime.utc(now.year, now.month, day, hour, minute);

  if (!next.isAfter(now)) {
    final y = (now.month == 12) ? now.year + 1 : now.year;
    final m = (now.month == 12) ? 1 : now.month + 1;
    next = DateTime.utc(y, m, day, hour, minute);
  }

  return next;
}


class UtcTime {
  const UtcTime(this.hour, this.minute);

  final int hour;
  final int minute;

  @override
  String toString() => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}