/// Время Еревана (UTC+4, без перехода на летнее время).
///
/// Сервер хранит время в UTC, а расписание пассажир и водитель видят по ереванским часам — даже если
/// в телефоне выбран другой часовой пояс. Внутри приложений время Еревана хранится как «местное» DateTime.
library;

const _yerevanOffset = Duration(hours: 4);

/// Момент времени (любой пояс) → часы и минуты по Еревану.
DateTime toYerevan(DateTime moment) {
  final y = moment.toUtc().add(_yerevanOffset);
  return DateTime(y.year, y.month, y.day, y.hour, y.minute, y.second);
}

/// Часы по Еревану → момент времени в UTC (для запросов к серверу).
DateTime fromYerevan(DateTime yerevan) =>
    DateTime.utc(yerevan.year, yerevan.month, yerevan.day, yerevan.hour, yerevan.minute, yerevan.second).subtract(_yerevanOffset);

/// Сейчас по Еревану.
DateTime yerevanNow() => toYerevan(DateTime.now());
