import 'package:flutter/foundation.dart';
import 'package:transport_core/transport_core.dart';
import 'package:transport_server/transport_server.dart';

/// Данные пассажира с сервера: маршруты, рейсы на 3 дня, водители, карты и свои брони.
/// Экраны берут данные отсюда; после любого изменения на сервере данные перечитываются.
class PassengerRepo extends ChangeNotifier {
  PassengerRepo({ServerApi? api}) : api = api ?? ServerApi.instance;
  final ServerApi api;

  Profile? profile;
  List<RouteInfo> routeInfos = [];
  List<RouteDef> routes = [];
  Map<String, Driver> drivers = {};
  List<Trip> _trips = [];
  List<CardInfo> cards = [];
  List<MyBooking> mine = [];

  /// Маршруты и рейсы загружены хотя бы раз.
  bool loaded = false;

  /// Последняя ошибка загрузки (нет связи и т. п.); null — всё загрузилось.
  String? error;

  /// Сейчас по Еревану: расписание всегда по ереванским часам.
  DateTime get now => yerevanNow();

  Map<String, RouteInfo> get _infoById => {for (final r in routeInfos) r.def.id: r};

  RouteDef? routeById(String id) => _infoById[id]?.def;

  /// Всё сразу: профиль, маршруты, водители, рейсы, карты, брони.
  Future<void> loadAll() async {
    try {
      profile = await api.myProfile();
      routeInfos = await api.routes();
      routes = [for (final r in routeInfos) r.def];
      drivers = await api.drivers();
      await _loadTrips();
      cards = await api.cards();
      mine = await api.myBookings(routes: _infoById, drivers: drivers);
      loaded = true;
      error = null;
    } on ServerError catch (e) {
      error = e.text;
    }
    notifyListeners();
  }

  Future<void> _loadTrips() async {
    final from = now;
    final to = dayStart(3, now: from);
    _trips = await api.trips(
      routes: {for (final r in routes) r.id: r},
      drivers: drivers,
      fromUtc: fromYerevan(from),
      toUtc: fromYerevan(to),
    );
  }

  /// Перечитать рейсы (свободные места меняются: их покупают другие пассажиры).
  Future<void> refreshTrips() async {
    if (!loaded) return loadAll();
    try {
      drivers = await api.drivers();
      await _loadTrips();
      error = null;
    } on ServerError catch (e) {
      error = e.text;
    }
    notifyListeners();
  }

  Future<void> refreshMine() async {
    try {
      mine = await api.myBookings(routes: _infoById, drivers: drivers);
      cards = await api.cards();
    } on ServerError catch (e) {
      error = e.text;
    }
    notifyListeners();
  }

  /// Рейсы маршрута на день (0 — сегодня, 1 — завтра, 2 — послезавтра), по времени отправления.
  List<Trip> tripsFor(RouteDef route, int dayOffset) {
    final day = dayStart(dayOffset, now: now);
    final next = dayStart(dayOffset + 1, now: now);
    return [
      for (final t in _trips)
        if (t.route.id == route.id && !t.departure.isBefore(day) && t.departure.isBefore(next)) t,
    ];
  }

  Trip? tripById(String id) {
    for (final t in _trips) {
      if (t.id == id) return t;
    }
    for (final m in mine) {
      if (m.trip.id == id) return m.trip;
    }
    return null;
  }

  MyBooking? bookingById(String id) {
    for (final m in mine) {
      if (m.booking.id == id) return m;
    }
    return null;
  }

  /// Когда машина будет в точке маршрута (метры от начала). Отправление — от места посадки.
  DateTime timeAt(Trip t, double along, RouteGeometry? g) {
    final dur = g?.durationSec ?? t.route.minutes * 60.0;
    final share = g == null ? 0.0 : ((along - t.meetAlong) / g.length).clamp(0.0, 1.0);
    return t.departure.add(Duration(milliseconds: (dur * share * 1000).round()));
  }

  // ---------- действия ----------

  Future<String> bindCard(String number) async {
    final id = await api.bindCard(number);
    cards = await api.cards();
    notifyListeners();
    return id;
  }

  Future<BookResult> book({required Trip trip, required List<String> seats, required String cardId, required String key}) async {
    final r = await api.book(tripId: trip.id, seats: seats, cardId: cardId, key: key);
    await refreshTrips();
    await refreshMine();
    return r;
  }

  Future<int> cancel(String bookingId) async {
    final refund = await api.cancel(bookingId);
    await refreshMine();
    await refreshTrips();
    return refund;
  }

  Future<void> rate(String bookingId, int stars) async {
    await api.rate(bookingId, stars);
    await refreshMine();
  }

  Future<void> signOut() async {
    await api.signOut();
    profile = null;
    mine = [];
    cards = [];
    notifyListeners();
  }
}
