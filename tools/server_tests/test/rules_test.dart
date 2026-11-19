// Правила сервера: полный путь поездки и отказы.
import 'package:server_tests/harness.dart';
import 'package:server_tests/invariants.dart';
import 'package:test/test.dart';
import 'package:transport_core/transport_core.dart';

void main() {
  late World w;
  late String route;

  setUpAll(() async {
    w = await World.create('tt_rules');
    route = await w.newRoute('M1');
  });

  tearDown(() async => expect(await violations(w), isEmpty, reason: 'целостность данных после теста'));
  tearDownAll(() => w.close());

  Future<DateTime> inMinutes(int m) async => (await w.now()).add(Duration(minutes: m));

  test('полный путь: рейс → бронь → поездка → начисление → выплата', () async {
    final driver = await w.newDriver('Арам');
    final pass = await w.newPassenger('Ани');
    final trip = await driver.createTrip(route, await inMinutes(180), meet: 400, seats: {'front': 600, 'rl': 500, 'rr': 500});

    final r = await pass.book(trip, ['front', 'rl']);
    expect(r['status'], 'paid');
    expect(r['amount'], 1100);

    // Водитель видит пассажира по имени, без телефона.
    final list = await driver.q('select * from trip_passengers(@t::uuid)', {'t': trip});
    expect(list.map((x) => x.toColumnMap()['passenger_name']).toSet(), {'Ани'});
    expect(list.first.toColumnMap().keys, isNot(contains('phone')));

    // Начать рейс можно не раньше чем за 15 минут до отправления.
    expect(await driver.refusal('select driver_start_trip(@t::uuid)', {'t': trip}), 'TOO_EARLY');
    await w.advance(const Duration(minutes: 170));
    await driver.q('select driver_start_trip(@t::uuid)', {'t': trip});
    await driver.q("select driver_mark_boarding(@t::uuid, 'front', 'boarded')", {'t': trip});
    await driver.q("select driver_mark_boarding(@t::uuid, 'rl', 'boarded')", {'t': trip});
    expect(await driver.refusal("select driver_mark_boarding(@t::uuid, 'rr', 'boarded')", {'t': trip}), 'SEAT_NOT_BOOKED');
    // Завершить рейс до времени отправления нельзя: пассажиры ещё вправе ждать выезда.
    expect(await driver.refusal('select driver_finish_trip(@t::uuid)', {'t': trip}), 'TOO_EARLY');
    await w.advance(const Duration(minutes: 15));
    await driver.q('select driver_finish_trip(@t::uuid)', {'t': trip});
    expect(await pass.one('select status::text from bookings where id = @b::uuid', {'b': r['booking_id']}), 'done');

    await pass.q('select rate_booking(@b::uuid, 4)', {'b': r['booking_id']});
    expect(await pass.refusal('select rate_booking(@b::uuid, 5)', {'b': r['booking_id']}), 'ALREADY_RATED');

    // Раньше 24 часов доля не начисляется.
    await w.scalar('select accrue_due()');
    expect((await driver.one('select driver_earnings()') as Map)['accrued'], 0);

    await w.advance(const Duration(hours: 25));
    expect(await w.scalar('select accrue_due()'), 1);
    final split = MoneySplit.of(1100); // тот же расчёт, что в приложении
    final earn = await driver.one('select driver_earnings()') as Map;
    expect(earn['accrued'], split.driver);
    expect(earn['to_pay'], split.driver);
    expect(await w.scalar("select sum(amount)::int from ledger where booking_id = @b::uuid and kind = 'commission'", {'b': r['booking_id']}), split.commission);
    expect(await w.scalar("select sum(amount)::int from ledger where booking_id = @b::uuid and kind = 'state_duty'", {'b': r['booking_id']}), split.duty);

    // Повторный запуск не начисляет второй раз.
    expect(await w.scalar('select accrue_due()'), 0);

    expect(await w.finance.one('select finance_create_payouts()'), 1);
    expect(await w.finance.one('select finance_create_payouts()'), 0);
    final after = await driver.one('select driver_earnings()') as Map;
    expect(after['paid_out'], split.driver);
    expect(after['to_pay'], 0);
  });

  test('отмена: за 61 минуту — полный возврат и место снова в продаже; за 59 — без возврата', () async {
    final driver = await w.newDriver('Гаяне');
    final early = await w.newPassenger('Сурен');
    final late = await w.newPassenger('Мари');
    final third = await w.newPassenger('Карен');
    final trip = await driver.createTrip(route, await inMinutes(121));
    final b1 = await early.book(trip, ['front']);
    final b2 = await late.book(trip, ['rl']);

    await w.advance(const Duration(minutes: 60)); // до отправления ~61 минута
    expect((await early.cancel(b1['booking_id'] as String))['refund'], 600);
    expect((await third.book(trip, ['front']))['status'], 'paid', reason: 'освободившееся место можно купить');

    await w.advance(const Duration(minutes: 2)); // до отправления ~59 минут
    expect((await late.cancel(b2['booking_id'] as String))['refund'], 0);
    expect(await third.refusal('select book_seats(@t::uuid, @s::text[], @c::uuid, @k)',
        {'t': trip, 's': '{rl}', 'c': third.cardId, 'k': w.nextKey()}), 'SEAT_TAKEN', reason: 'место без возврата остаётся за пассажиром');
    expect(await late.refusal('select cancel_booking(@b::uuid)', {'b': b2['booking_id']}), 'NOT_CANCELLABLE');
  });

  test('отказ банка: место не занято и ничего не списано; банк недоступен — брони нет', () async {
    final driver = await w.newDriver('Давид');
    final declined = await w.newPassenger('Лилит', card: '4111111111110002');
    final down = await w.newPassenger('Артур', card: '4111111111110119');
    final ok = await w.newPassenger('Нарине');
    final trip = await driver.createTrip(route, await inMinutes(200));

    final r = await declined.book(trip, ['front']);
    expect(r['status'], 'failed');
    expect(r['reason'], 'CARD_DECLINED');
    expect(await w.scalar("select count(*)::int from ledger where booking_id = @b::uuid", {'b': r['booking_id']}), 0);

    expect(await down.refusal('select book_seats(@t::uuid, @s::text[], @c::uuid, @k)',
        {'t': trip, 's': '{front}', 'c': down.cardId, 'k': w.nextKey()}), 'BANK_UNAVAILABLE');
    expect(await w.scalar('select count(*)::int from bookings where passenger_id = @u::uuid', {'u': down.id}), 0);

    expect((await ok.book(trip, ['front']))['status'], 'paid');
  });

  test('повтор той же операции не списывает деньги дважды', () async {
    final driver = await w.newDriver('Нарек');
    final pass = await w.newPassenger('Гор');
    final trip = await driver.createTrip(route, await inMinutes(200));
    final a = await pass.book(trip, ['rl'], idem: 'op-1');
    final b = await pass.book(trip, ['rl'], idem: 'op-1');
    expect(b['booking_id'], a['booking_id']);
    expect(b['repeat'], true);
    expect(await w.scalar("select count(*)::int from ledger where booking_id = @b::uuid and kind = 'charge'", {'b': a['booking_id']}), 1);
  });

  test('водитель отменил рейс: всем полный возврат, даже после поздней отмены', () async {
    final driver = await w.newDriver('Тигран');
    final p1 = await w.newPassenger('П1');
    final p2 = await w.newPassenger('П2');
    final trip = await driver.createTrip(route, await inMinutes(90));
    final b1 = await p1.book(trip, ['front']);
    final b2 = await p2.book(trip, ['rl', 'rr']);
    await w.advance(const Duration(minutes: 40)); // до отправления ~50 минут: поздняя отмена
    expect((await p1.cancel(b1['booking_id'] as String))['refund'], 0);

    await driver.q('select driver_cancel_trip(@t::uuid)', {'t': trip});
    expect(await w.scalar('select refund from bookings where id = @b::uuid', {'b': b1['booking_id']}), 600);
    expect(await w.scalar('select refund from bookings where id = @b::uuid', {'b': b2['booking_id']}), 1000);
    expect(await p2.refusal('select book_seats(@t::uuid, @s::text[], @c::uuid, @k)',
        {'t': trip, 's': '{front}', 'c': p2.cardId, 'k': w.nextKey()}), 'TRIP_CLOSED');
  });

  test('рейс нельзя поставить с нарушением правил', () async {
    final driver = await w.newDriver('Сос', seats: 3);
    final pending = await w.newDriver('Новичок', approve: false);
    final draft = await w.newRoute('D1', publish: false);
    final dep = await inMinutes(300);
    const fn = 'select driver_create_trip(@r::uuid, @d::timestamptz, @m::int, @s::jsonb)';
    Map<String, Object?> args({String? r, DateTime? d, int m = 0, String s = '[{"id":"front","price":600}]'}) =>
        {'r': r ?? route, 'd': (d ?? dep).toUtc().toIso8601String(), 'm': '$m', 's': s};

    expect(await pending.refusal(fn, args()), 'DRIVER_NOT_APPROVED');
    expect(await driver.refusal(fn, args(r: draft)), 'ROUTE_NOT_AVAILABLE');
    expect(await driver.refusal(fn, args(d: await inMinutes(5))), 'DEPARTURE_TOO_SOON');
    expect(await driver.refusal(fn, args(d: await inMinutes(60 * 24 * 8))), 'DEPARTURE_TOO_FAR');
    expect(await driver.refusal(fn, args(m: 1600)), 'MEET_POINT_OUTSIDE_DISTRICT', reason: 'место посадки вне начального района');
    expect(await driver.refusal(fn, args(m: -1)), 'MEET_POINT_OUTSIDE_DISTRICT');
    expect(await driver.refusal(fn, args(s: '[{"id":"rm","price":400}]')), 'BAD_SEATS', reason: 'в трёхместной машине нет среднего места');
    expect(await driver.refusal(fn, args(s: '[{"id":"front","price":600},{"id":"front","price":600}]')), 'BAD_SEATS');
    expect(await driver.refusal(fn, args(s: '[{"id":"trunk","price":600}]')), 'BAD_SEATS');
    expect(await driver.refusal(fn, args(s: '[]')), 'BAD_SEATS');
    expect(await driver.refusal(fn, args(s: '[{"id":"front","price":0}]')), 'BAD_PRICE');
    expect(await driver.refusal(fn, args(s: '[{"id":"front","price":1501}]')), 'BAD_PRICE', reason: 'дороже трёх базовых цен');
    expect(await driver.refusal(fn, args(s: '[{"id":"front","price":"abc"}]')), 'BAD_PRICE');

    await driver.q(fn, args());
    expect(await driver.refusal(fn, args(d: dep.add(const Duration(minutes: 10)))), 'TRIP_OVERLAP', reason: 'водитель уже в рейсе в это время');
    expect(await driver.refusal(fn, args(d: dep.add(const Duration(minutes: 30)))), isNull);
  });

  test('бронь нельзя купить с нарушением правил', () async {
    final driver = await w.newDriver('Вардан');
    final other = await w.newPassenger('Чужой');
    final pass = await w.newPassenger('Свой');
    await driver.bindCard('5555555555554444');
    final trip = await driver.createTrip(route, await inMinutes(30));
    const fn = 'select book_seats(@t::uuid, @s::text[], @c::uuid, @k)';
    Map<String, Object?> args(Actor a, String seats, {String? card}) => {'t': trip, 's': seats, 'c': card ?? a.cardId, 'k': w.nextKey()};

    expect(await driver.refusal(fn, args(driver, '{front}')), 'OWN_TRIP');
    expect(await pass.refusal(fn, args(pass, '{trunk}')), 'BAD_SEATS');
    expect(await pass.refusal(fn, args(pass, '{front,front}')), 'BAD_SEATS');
    expect(await pass.refusal(fn, args(pass, '{}')), 'BAD_SEATS');
    expect(await pass.refusal(fn, args(pass, '{front}', card: other.cardId)), 'CARD_NOT_FOUND', reason: 'чужой картой платить нельзя');
    expect(await pass.refusal(fn, {'t': trip, 's': '{front}', 'c': pass.cardId, 'k': ' '}), 'IDEM_KEY_REQUIRED');

    await pass.q('select remove_card(@c::uuid)', {'c': pass.cardId});
    expect(await pass.refusal(fn, args(pass, '{front}')), 'CARD_NOT_FOUND', reason: 'удалённой картой платить нельзя');
    await pass.bindCard('4111111111111111');

    await w.advance(const Duration(minutes: 26)); // до отправления ~4 минуты: продажа закрыта
    expect(await pass.refusal(fn, args(pass, '{front}')), 'TRIP_CLOSED');
  });

  test('маршрут нельзя снять, пока на нём есть рейсы', () async {
    final r2 = await w.newRoute('M2');
    final driver = await w.newDriver('Рубен');
    final trip = await driver.createTrip(r2, await inMinutes(120));
    expect(await w.moderator.refusal("select staff_set_route_status(@r::uuid, 'archived')", {'r': r2}), 'ROUTE_HAS_ACTIVE_TRIPS');
    await driver.q('select driver_cancel_trip(@t::uuid)', {'t': trip});
    expect(await w.moderator.refusal("select staff_set_route_status(@r::uuid, 'archived')", {'r': r2}), isNull);
    expect(await driver.refusal('select driver_create_trip(@r::uuid, @d::timestamptz, 0, @s::jsonb)',
        {'r': r2, 'd': (await inMinutes(120)).toUtc().toIso8601String(), 's': '[{"id":"front","price":600}]'}), 'ROUTE_NOT_AVAILABLE');
  });

  test('рейс начат, но водитель забыл его завершить: закрывается сам и начисляется', () async {
    final driver = await w.newDriver('Ашот');
    final pass = await w.newPassenger('Забытый');
    final trip = await driver.createTrip(route, await inMinutes(60));
    final b = await pass.book(trip, ['front']);
    await w.advance(const Duration(minutes: 55));
    await driver.q('select driver_start_trip(@t::uuid)', {'t': trip});
    await w.advance(const Duration(hours: 30));
    await w.scalar('select accrue_due()');
    expect(await w.scalar('select status::text from trips where id = @t::uuid', {'t': trip}), 'finished');
    expect(await w.scalar('select status::text from bookings where id = @b::uuid', {'b': b['booking_id']}), 'done');
    expect((await driver.one('select driver_earnings()') as Map)['accrued'], MoneySplit.of(600).driver);
  });

  test('рейс так и не начался: отменяется сам, пассажирам полный возврат, водителю ничего', () async {
    final driver = await w.newDriver('Непришедший');
    final pass = await w.newPassenger('Ждавший');
    final late = await w.newPassenger('Отменивший поздно');
    final trip = await driver.createTrip(route, await inMinutes(50));
    final b1 = await pass.book(trip, ['front']);
    final b2 = await late.book(trip, ['rl']);
    expect((await late.cancel(b2['booking_id'] as String))['refund'], 0);
    await w.advance(const Duration(hours: 30));
    await w.scalar('select accrue_due()');
    expect(await w.scalar('select status::text from trips where id = @t::uuid', {'t': trip}), 'cancelled');
    expect(await w.scalar('select refund from bookings where id = @b::uuid', {'b': b1['booking_id']}), 600);
    expect(await w.scalar('select refund from bookings where id = @b::uuid', {'b': b2['booking_id']}), 500);
    expect((await driver.one('select driver_earnings()') as Map)['accrued'], 0);
  });

  test('цены мест ставит водитель, но не ниже минимальной цены маршрута', () async {
    const save = 'select staff_save_route(@id::uuid, @c, @fn, 40.2264, 44.4930, @tn, 40.1777, 44.5126, @p::int, 25, 9000, 4283388645, @mn::int)';
    Map<String, Object?> a(String? id, String code, int price, int? min) =>
        {'id': id, 'c': code, 'fn': 'Аван', 'tn': 'Опера', 'p': '$price', 'mn': min == null ? null : '$min'};
    Future<int> minOf(String r) async => await w.scalar('select min_price from routes where id = @r::uuid', {'r': r}) as int;

    // Модератор: минимум — от 1 до базовой цены; не указан — равен базовой цене.
    expect(await w.moderator.refusal(save, a(null, 'MIN0', 500, 0)), 'BAD_ARGUMENT');
    expect(await w.moderator.refusal(save, a(null, 'MIN0', 500, 501)), 'BAD_ARGUMENT', reason: 'минимум выше базовой цены');
    final plain = await w.moderator.one(save, a(null, 'MIN1', 700, null)) as String;
    expect(await minOf(plain), 700);
    final r = await w.newRoute('MIN2', price: 500, minPrice: 400);
    expect(await minOf(r), 400);

    // Водитель: ниже минимума нельзя ни одно место; ровно минимум и выше (до трёх базовых цен) — можно.
    final driver = await w.newDriver('Щедрый');
    Future<String?> refused(Map<String, int> seats, {int inMin = 60}) async {
      try {
        await driver.createTrip(r, await inMinutes(inMin), seats: seats);
        return null;
      } on Refused catch (e) {
        return e.code;
      }
    }

    expect(await refused({'front': 399}), 'PRICE_BELOW_MINIMUM');
    expect(await refused({'front': 600, 'rl': 500, 'rr': 1}), 'PRICE_BELOW_MINIMUM', reason: 'хватает одного дешёвого места');
    expect(await refused({'front': 1501}), 'BAD_PRICE', reason: 'дороже трёх базовых цен');
    final trip = await driver.createTrip(r, await inMinutes(60), seats: {'front': 1500, 'rl': 400});
    final pass = await w.newPassenger('За минимум');
    expect((await pass.book(trip, ['rl']))['amount'], 400);

    // Модератор поднял минимум: уже выставленные места не меняются, новые рейсы — по новому минимуму.
    await w.moderator.q(save, a(r, 'MIN2', 500, 500));
    expect(await w.scalar("select price from trip_seats where trip_id = @t::uuid and seat_id = 'rl'", {'t': trip}), 400);
    expect(await refused({'front': 450}, inMin: 300), 'PRICE_BELOW_MINIMUM');
    expect(await refused({'front': 500}, inMin: 300), isNull);
    // Базовую цену опустили ниже минимума, не указав новый минимум: минимум опускается вместе с ней.
    await w.moderator.q(save, a(r, 'MIN2', 450, null));
    expect(await minOf(r), 450);
    // Изменения минимума записаны в журнал действий.
    expect(await w.scalar("select count(*)::int from audit_log where action = 'save_route' and entity_id = @r", {'r': r}), 3);
  });

  test('жалоба: поддержка возвращает деньги после рейса, пока доля водителя не начислена', () async {
    final driver = await w.newDriver('Спорный');
    final pass = await w.newPassenger('Недовольный');
    final trip = await driver.createTrip(route, await inMinutes(60));
    final b = await pass.book(trip, ['front']);
    await w.advance(const Duration(minutes: 55));
    await driver.q('select driver_start_trip(@t::uuid)', {'t': trip});
    await w.advance(const Duration(minutes: 30));
    await driver.q('select driver_finish_trip(@t::uuid)', {'t': trip});
    const fn = 'select staff_refund_booking(@b::uuid, @r)';
    expect(await pass.refusal(fn, {'b': b['booking_id'], 'r': 'хочу'}), 'FORBIDDEN');
    expect(await w.support.refusal(fn, {'b': b['booking_id'], 'r': ' '}), 'REASON_REQUIRED');
    expect(await w.support.one(fn, {'b': b['booking_id'], 'r': 'водитель не довёз'}), 600);
    expect(await w.support.refusal(fn, {'b': b['booking_id'], 'r': 'ещё раз'}), 'NOTHING_TO_REFUND');
    await w.advance(const Duration(hours: 25));
    await w.scalar('select accrue_due()');
    expect((await driver.one('select driver_earnings()') as Map)['accrued'], 0);

    // После начисления возврат через эту функцию уже невозможен.
    final trip2 = await driver.createTrip(route, await inMinutes(60));
    final b2 = await pass.book(trip2, ['front']);
    await w.advance(const Duration(minutes: 55));
    await driver.q('select driver_start_trip(@t::uuid)', {'t': trip2});
    await w.advance(const Duration(hours: 30));
    await w.scalar('select accrue_due()');
    expect(await w.support.refusal(fn, {'b': b2['booking_id'], 'r': 'поздно'}), 'ALREADY_ACCRUED');
  });

  test('журнал денег и журнал действий нельзя править даже серверу', () async {
    for (final sql in [
      'update ledger set amount = 1',
      'delete from ledger',
      'truncate ledger',
      "update audit_log set action = 'x'",
      'delete from audit_log',
    ]) {
      await expectLater(w.admin.execute(sql), throwsA(isA<Exception>()), reason: sql);
    }
    expect(await w.scalar('select count(*)::int from ledger'), greaterThan(0));
  });
}
