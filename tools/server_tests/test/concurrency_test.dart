// Одновременные действия: много пользователей делают одно и то же в один момент.
import 'dart:math';

import 'package:server_tests/harness.dart';
import 'package:server_tests/invariants.dart';
import 'package:test/test.dart';

/// Запускает действия одновременно. Возвращает ответы и коды отказов по порядку.
Future<List<Object?>> together(Iterable<Future<Object?> Function()> actions) => Future.wait(actions.map((a) async {
      try {
        return await a();
      } on Refused catch (e) {
        return e;
      }
    }));

void main() {
  late World w;
  late String route;
  late List<Actor> crowd;

  setUpAll(() async {
    w = await World.create('tt_concurrency');
    route = await w.newRoute('M1');
    crowd = [for (var i = 0; i < 60; i++) await w.newPassenger('Пассажир $i')];
  });

  tearDown(() async => expect(await violations(w), isEmpty, reason: 'целостность данных после теста'));
  tearDownAll(() => w.close());

  Future<DateTime> inMinutes(int m) async => (await w.now()).add(Duration(minutes: m));

  test('60 человек одновременно покупают одно место: продано ровно одному', () async {
    final driver = await w.newDriver('Арам');
    final trip = await driver.createTrip(route, await inMinutes(200));
    final res = await together(crowd.map((p) => () => p.book(trip, ['front'])));
    final paid = res.whereType<Map>().where((r) => r['status'] == 'paid').length;
    final refused = res.whereType<Refused>().map((e) => e.code).toSet();
    expect(paid, 1);
    expect(refused, {'SEAT_TAKEN'});
    expect(await w.scalar("select count(*)::int from ledger where trip_id = @t::uuid and kind = 'charge'", {'t': trip}), 1);
  });

  test('60 человек одновременно разбирают 4 места: каждое продано один раз', () async {
    final driver = await w.newDriver('Гаяне');
    final trip = await driver.createTrip(route, await inMinutes(200), seats: {'front': 600, 'rl': 500, 'rm': 400, 'rr': 500});
    final rnd = Random(7);
    const all = ['front', 'rl', 'rm', 'rr'];
    final res = await together(crowd.map((p) {
      final seats = (List.of(all)..shuffle(rnd)).take(1 + rnd.nextInt(2)).toList();
      return () => p.book(trip, seats);
    }));
    final paid = res.whereType<Map>().where((r) => r['status'] == 'paid').toList();
    final soldSeats = await w.scalar('select count(*)::int from trip_seats where trip_id = @t::uuid and booking_id is not null', {'t': trip});
    final charged = await w.scalar("select coalesce(sum(amount), 0)::int from ledger where trip_id = @t::uuid and kind = 'charge'", {'t': trip});
    final soldValue = await w.scalar('select coalesce(sum(price), 0)::int from trip_seats where trip_id = @t::uuid and booking_id is not null', {'t': trip});
    expect(soldSeats, 4, reason: 'при 60 желающих должны уйти все места');
    expect(charged, soldValue, reason: 'списано ровно за проданные места');
    expect(paid.fold<int>(0, (s, r) => s + (r['amount'] as int)), charged);
  });

  test('одна и та же операция, отправленная 20 раз одновременно, списывает один раз', () async {
    final driver = await w.newDriver('Давид');
    final trip = await driver.createTrip(route, await inMinutes(200));
    final p = crowd.first;
    // Одно приложение — одно подключение, поэтому «дубли» шлём с разных подключений того же пользователя.
    final clones = [for (var i = 0; i < 20; i++) Actor(w, p.id, p.phone, p.name)..cardId = p.cardId];
    final res = await together(clones.map((c) => () => c.book(trip, ['rl'], idem: 'same-op')));
    for (final c in clones) {
      await c.close();
    }
    expect(res.whereType<Refused>(), isEmpty);
    expect(res.whereType<Map>().map((r) => r['booking_id']).toSet(), hasLength(1));
    expect(await w.scalar("select count(*)::int from ledger where trip_id = @t::uuid and kind = 'charge'", {'t': trip}), 1);
  });

  test('водитель одновременно ставит 12 пересекающихся рейсов: проходит один', () async {
    final driver = await w.newDriver('Нарек');
    final dep = await inMinutes(300);
    final clones = [for (var i = 0; i < 12; i++) Actor(w, driver.id, driver.phone, driver.name)];
    final res = await together([
      for (var i = 0; i < clones.length; i++) () => clones[i].createTrip(route, dep.add(Duration(minutes: i))),
    ]);
    for (final c in clones) {
      await c.close();
    }
    expect(res.whereType<String>(), hasLength(1));
    expect(res.whereType<Refused>().map((e) => e.code).toSet(), {'TRIP_OVERLAP'});
  });

  test('покупки, отмены пассажиров и отмена рейса водителем вперемешку: деньги сходятся', () async {
    final rnd = Random(11);
    for (var round = 0; round < 25; round++) {
      final driver = await w.newDriver('Водитель $round');
      final trip = await driver.createTrip(route, await inMinutes(200), seats: {'front': 600, 'rl': 500, 'rm': 400, 'rr': 500});
      final buyers = (List.of(crowd)..shuffle(rnd)).take(8).toList();
      final first = await together(buyers.map((p) => () => p.book(trip, [const ['front', 'rl', 'rm', 'rr'][rnd.nextInt(4)]])));
      final mine = <Actor, String>{
        for (var i = 0; i < buyers.length; i++)
          if (first[i] is Map && (first[i] as Map)['status'] == 'paid') buyers[i]: (first[i] as Map)['booking_id'] as String,
      };
      await together([
        for (final e in mine.entries) () => e.key.cancel(e.value),
        for (final p in buyers) () => p.book(trip, [const ['front', 'rl', 'rm', 'rr'][rnd.nextInt(4)]]),
        if (round.isOdd) () => driver.q('select driver_cancel_trip(@t::uuid)', {'t': trip}),
      ]);
    }
  });

  test('два финансиста одновременно формируют выплаты: каждая сумма выплачена один раз', () async {
    final driver = await w.newDriver('Тигран');
    final trip = await driver.createTrip(route, await inMinutes(60));
    await crowd[1].book(trip, ['front']);
    await w.advance(const Duration(minutes: 55));
    await driver.q('select driver_start_trip(@t::uuid)', {'t': trip});
    await w.advance(const Duration(hours: 30));
    await w.scalar('select accrue_due()');
    final f2 = await w.newStaff('Финансист 2', ['finance']);
    await together([
      () => w.finance.one('select finance_create_payouts()'),
      () => f2.one('select finance_create_payouts()'),
    ]);
    expect(await w.scalar('select count(*)::int from payouts where driver_id = @d::uuid', {'d': driver.id}), 1);
  });
}
