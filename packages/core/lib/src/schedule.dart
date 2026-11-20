/// Расписание рейсов, места в салоне и время посадки.
/// Демо-расписание детерминированное: одинаковое на всех устройствах и совпадает с веб-прототипом.
library;

import 'demo_data.dart';
import 'format.dart';
import 'geo.dart';
import 'models.dart';
import 'store.dart';

/// Хеш djb2 — как в веб-прототипе, чтобы демо-рейсы совпадали.
int djb2(String s) {
  var h = 5381;
  for (final c in s.codeUnits) {
    h = ((h << 5) + h + c) & 0xFFFFFFFF;
  }
  return h;
}

/// Пассажирские места легковой машины: переднее и два сзади (сзади — не больше двух пассажиров).
const carSeatIds = ['front', 'rl', 'rr'];

/// Название места.
String seatLabel(String id) => switch (id) { 'front' => 'Переднее', 'rl' => 'Сзади слева', 'rr' => 'Сзади справа', _ => id };

/// Места в салоне [ids] (по умолчанию все три) по порядку, с ценами от базовой цены маршрута.
List<Seat> seatsFor(RouteDef route, [Iterable<String> ids = carSeatIds]) => [
      for (final id in carSeatIds)
        if (ids.contains(id))
          Seat(id: id, label: seatLabel(id), price: route.price + (id == 'front' ? Demo.seatFrontExtra : Demo.seatWindowExtra)),
    ];

class TripService {
  TripService(this.data, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DataStore data;
  final DateTime Function() _clock;

  DateTime get now => _clock();

  Trip _finish(Trip t, Set<String> demoTaken, List<Booking> bookings) {
    final mine = bookings.where((b) => b.tripId == t.id && b.status != BookingStatus.cancelled).toList();
    for (final s in t.seats) {
      Booking? b;
      for (final x in mine) {
        if (x.seatIds.contains(s.id)) b = x;
      }
      s.taken = b != null || demoTaken.contains(s.id);
      s.bookingId = b?.id;
      s.passenger = b != null
          ? 'Пассажир из приложения'
          : (s.taken ? Demo.demoPassengers[djb2(t.id + s.id) % Demo.demoPassengers.length] : null);
    }
    return t;
  }

  /// Все рейсы маршрута на день (0 — сегодня, 1 — завтра, …).
  List<Trip> tripsFor(RouteDef route, int dayOffset) {
    final day = dayStart(dayOffset, now: now);
    final bookings = data.bookings();
    final list = <Trip>[];
    for (final t in Demo.departures) {
      final parts = t.split(':');
      final dep = DateTime(day.year, day.month, day.day, int.parse(parts[0]), int.parse(parts[1]));
      final id = '${route.id}-${ymd(dep)}-$t';
      final seed = djb2(id);
      // Часть демо-водителей продаёт только задние места.
      final seats = seatsFor(route, (seed >> 4) % 3 == 0 ? const ['rl', 'rr'] : carSeatIds);
      final total = seats.length;
      final takenDemo = (seed >> 7) % total;
      final order = seats.map((s) => s.id).toList()..sort((a, b) => djb2(id + a).compareTo(djb2(id + b)));
      list.add(_finish(
        Trip(
          id: id,
          route: route,
          departure: dep,
          driver: Demo.drivers[seed % Demo.drivers.length],
          seats: seats,
          meetAlong: Demo.meetSpots[(seed >> 9) % Demo.meetSpots.length],
        ),
        order.take(takenDemo).toSet(),
        bookings,
      ));
    }
    for (final c in data.customTrips()) {
      if (c.routeId != route.id || c.date != ymd(day)) continue;
      final parts = c.time.split(':');
      final dep = DateTime(day.year, day.month, day.day, int.parse(parts[0]), int.parse(parts[1]));
      list.add(_finish(
        Trip(
          id: c.id,
          route: route,
          departure: dep,
          driver: Demo.drivers[c.driverIndex],
          seats: c.seats.map((s) => s.copy()).toList(),
          meetAlong: c.meetAlong,
          dropAlong: c.dropAlong,
          custom: true,
        ),
        const {},
        bookings,
      ));
    }
    list.sort((a, b) => a.departure.compareTo(b.departure));
    return list;
  }

  Trip? tripById(String id) {
    final route = Demo.routeById(id.split('-').first);
    if (route == null) return null;
    for (var d = -14; d < 3; d++) {
      for (final t in tripsFor(route, d)) {
        if (t.id == id) return t;
      }
    }
    return null;
  }

  /// Рейсы водителя на день по всем маршрутам.
  List<Trip> driverTrips(Driver driver, int dayOffset) => [
        for (final r in Demo.routes)
          for (final t in tripsFor(r, dayOffset))
            if (t.driver.name == driver.name) t,
      ]..sort((a, b) => a.departure.compareTo(b.departure));

  /// Когда машина будет в точке маршрута (метры от начала). Отправление — от места посадки.
  DateTime timeAt(Trip t, double along, RouteGeometry? g) {
    final dur = g?.durationSec ?? t.route.minutes * 60.0;
    final share = g == null ? 0.0 : ((along - t.meetAlong) / g.length).clamp(0.0, 1.0);
    return t.departure.add(Duration(milliseconds: (dur * share * 1000).round()));
  }

  DateTime endOf(Trip t, RouteGeometry? g) => t.departure.add(Duration(seconds: (g?.durationSec ?? t.route.minutes * 60.0).round()));

  TripStatus statusOf(Trip t, RouteGeometry? g) {
    final s = data.tripStatus(t.id);
    if (s == TripStatus.finished || (s == null && endOf(t, g).isBefore(now))) return TripStatus.finished;
    return s ?? TripStatus.planned;
  }
}
