/// Форматирование для интерфейса на русском.
library;

String amd(num n) {
  final s = n.round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return '$buf ֏';
}

String hhmm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String meters(double m) => m < 1000 ? '${(m / 10).round() * 10} м' : '${(m / 1000).toStringAsFixed(1)} км';

String minutesText(double seconds) {
  final m = (seconds / 60).round();
  return '${m < 1 ? 1 : m} мин';
}

String plural(int n, String one, String few, String many) {
  final n10 = n % 10, n100 = n % 100;
  if (n10 == 1 && n100 != 11) return one;
  if (n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14)) return few;
  return many;
}

const _weekdays = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
const _months = ['янв.', 'февр.', 'мар.', 'апр.', 'мая', 'июн.', 'июл.', 'авг.', 'сент.', 'окт.', 'нояб.', 'дек.'];
const _monthsFull = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];

DateTime dayStart(int offset, {DateTime? now}) {
  final n = now ?? DateTime.now();
  return DateTime(n.year, n.month, n.day + offset);
}

String dayLabel(int offset, {DateTime? now}) {
  if (offset == 0) return 'Сегодня';
  if (offset == 1) return 'Завтра';
  final d = dayStart(offset, now: now);
  return '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';
}

String dateLong(DateTime d) => '${d.day} ${_monthsFull[d.month - 1]}';

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

int dayOffsetOf(DateTime d, {DateTime? now}) =>
    DateTime(d.year, d.month, d.day).difference(dayStart(0, now: now)).inDays;
