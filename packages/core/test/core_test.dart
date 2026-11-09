import 'package:test/test.dart';
import 'package:transport_core/transport_core.dart';

void main() {
  group('деньги', () {
    test('водителю — оплата минус 10% комиссии и 4% госпошлины', () {
      final m = MoneySplit.of(1000);
      expect(m.commission, 100);
      expect(m.duty, 40);
      expect(m.driver, 860);
    });

    test('отмена: раньше чем за 60 минут — полный возврат, позже — без возврата', () {
      final pickup = DateTime(2026, 11, 10, 8, 0);
      expect(refundFor(amount: 900, pickupTime: pickup, now: DateTime(2026, 11, 10, 6, 59)), 900);
      expect(refundFor(amount: 900, pickupTime: pickup, now: DateTime(2026, 11, 10, 7, 30)), 0);
    });
  });

  group('расписание', () {
    final service = TripService(DataStore(MemoryStore()), clock: () => DateTime(2026, 11, 9, 12));

    test('совпадает с веб-прототипом: водители маршрута M1 на 10 ноября', () {
      final trips = service.tripsFor(Demo.routeById('M1')!, 1);
      expect(
        trips.map((t) => '${t.driver.name} ${hhmm(t.departure)}').toList(),
        ['Арам 07:30', 'Арам 08:00', 'Нарек 08:30', 'Нарек 09:00', 'Арам 13:00', 'Нарек 17:30', 'Нарек 18:00', 'Арам 18:30', 'Нарек 19:30'],
      );
    });

    test('бронь занимает места, отмена освобождает', () async {
      final data = DataStore(MemoryStore());
      final s = TripService(data, clock: () => DateTime(2026, 11, 9, 12));
      final trip = s.tripsFor(Demo.routeById('M2')!, 1).firstWhere((t) => t.freeCount > 0);
      final seat = trip.freeSeats.first;
      final b = Booking(
        id: 'B1', tripId: trip.id, routeId: 'M2', pickAlong: 0, dropAlong: 100,
        fromName: 'Нор Норк', toName: 'Площадь Республики',
        seatIds: [seat.id], seatLabels: [seat.label], amount: seat.price,
      );
      await data.addBooking(b);
      expect(s.tripById(trip.id)!.seats.firstWhere((x) => x.id == seat.id).taken, isTrue);
      b.status = BookingStatus.cancelled;
      await data.updateBooking(b);
      expect(s.tripById(trip.id)!.seats.firstWhere((x) => x.id == seat.id).taken, isFalse);
    });

    test('рейс, созданный водителем, виден в расписании', () async {
      final data = DataStore(MemoryStore());
      final s = TripService(data, clock: () => DateTime(2026, 11, 9, 12));
      final route = Demo.routeById('M1')!;
      await data.addCustomTrip(CustomTrip(
        id: 'M1-2026-11-10-10:15-c1', routeId: 'M1', date: '2026-11-10', time: '10:15', driverIndex: 0,
        seats: seatsFor(route, 4),
      ));
      final t = s.tripsFor(route, 1).firstWhere((t) => t.custom);
      expect(hhmm(t.departure), '10:15');
      expect(t.driver.name, 'Арам');
      expect(s.tripById(t.id), isNotNull);
    });
  });

  group('поиск маршрутов', () {
    final geos = {for (final r in Demo.routes) r.id: RouteGeometry.straight(r)};

    test('только «откуда»: все маршруты из этого места', () {
      final m = matchRoutes(geometries: geos, routes: Demo.routes, from: const GeoPoint(40.2264, 44.4930));
      expect(m.map((x) => x.route.id).toSet(), {'M1', 'M5'});
    });

    test('«откуда» и «куда»: остаётся подходящий маршрут', () {
      final m = matchRoutes(
        geometries: geos, routes: Demo.routes,
        from: const GeoPoint(40.2264, 44.4930), to: const GeoPoint(40.1777, 44.5126),
      );
      expect(m.first.route.id, 'M1');
    });

    test('в обратную сторону маршрут не подходит', () {
      final m = matchRoutes(
        geometries: geos, routes: Demo.routes,
        from: const GeoPoint(40.1777, 44.5126), to: const GeoPoint(40.2264, 44.4930),
      );
      expect(m.where((x) => x.route.id == 'M1'), isEmpty);
    });
  });

  test('форматирование', () {
    expect(amd(1200), '1 200 ֏');
    expect(plural(2, 'место', 'места', 'мест'), 'места');
    expect(plural(5, 'место', 'места', 'мест'), 'мест');
  });
}
