import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:transport_core/transport_core.dart';
import 'package:transport_server/transport_server.dart';

/// Напоминания о поездке: за 30 и за 5 минут до отправления.
///
/// Напоминание ставится в сам телефон (будильник Android), поэтому приходит, даже если приложение закрыто
/// и нет интернета. Список напоминаний пересобирается после любого изменения броней: отменённая бронь —
/// напоминаний нет. Нажатие на напоминание открывает билет.
class TripReminders {
  TripReminders._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// За сколько минут до отправления напоминать.
  static const minutesBefore = [30, 5];

  /// Билет, который открыть после запуска из напоминания.
  static String? launchBookingId;

  /// Пассажир нажал на напоминание, пока приложение открыто.
  static void Function(String bookingId)? onTap;

  static const _channel = AndroidNotificationDetails(
    'trip_reminders',
    'Напоминания о поездке',
    channelDescription: 'За 30 и за 5 минут до отправления',
    importance: Importance.high,
    priority: Priority.high,
  );

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  static Future<void> init() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      tzdata.initializeTimeZones();
      await _plugin.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) {
          final id = r.payload;
          if (id != null && id.isNotEmpty) onTap?.call(id);
        },
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) launchBookingId = launch?.notificationResponse?.payload;
      _ready = true;
    } catch (_) {
      // Без напоминаний приложение работает как обычно.
    }
  }

  /// Попросить разрешение показывать уведомления (Android спросит один раз).
  static Future<void> askNotifications() async {
    if (!_ready) return;
    try {
      await _android?.requestNotificationsPermission();
    } catch (_) {}
  }

  /// Нет разрешения на точное время: без него Android может показать напоминание на несколько минут позже.
  static Future<bool> needsExactPermission() async {
    if (!_ready) return false;
    try {
      return await _android?.canScheduleExactNotifications() == false;
    } catch (_) {
      return false;
    }
  }

  /// Открыть системный экран «Будильники и напоминания» для этого приложения.
  static Future<void> openExactSettings() async {
    try {
      await _android?.requestExactAlarmsPermission();
    } catch (_) {}
  }

  /// Поставить напоминания для предстоящих поездок (старые снимаются).
  static Future<void> sync(List<MyBooking> upcoming) async {
    if (!_ready) return;
    try {
      await _plugin.cancelAllPendingNotifications();
      final exact = await _android?.canScheduleExactNotifications() ?? false;
      final nowUtc = DateTime.now().toUtc();
      for (final m in upcoming) {
        final t = m.trip, d = t.driver;
        final departureUtc = fromYerevan(t.departure);
        for (final (i, mins) in minutesBefore.indexed) {
          final at = departureUtc.subtract(Duration(minutes: mins));
          if (!at.isAfter(nowUtc)) continue;
          await _plugin.zonedSchedule(
            id: _id(m.booking.id, i),
            scheduledDate: tz.TZDateTime.from(at, tz.UTC),
            notificationDetails: const NotificationDetails(android: _channel),
            androidScheduleMode: exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
            title: 'Через $mins ${plural(mins, 'минуту', 'минуты', 'минут')} отправление — ${hhmm(t.departure)}',
            body: '${t.route.from.name} → ${t.route.to.name}. ${d.name}, ${d.car}, ${d.carColor}, ${d.plate}. '
                'Подойдите к месту посадки.',
            payload: m.booking.id,
          );
        }
      }
    } catch (_) {}
  }

  /// Номер напоминания: из номера брони и того, какое это напоминание.
  static int _id(String bookingId, int which) => ((bookingId.hashCode & 0x0FFFFFFF) << 2) | which;
}
