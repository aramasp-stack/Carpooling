// Доступы: каждый видит только своё, изменить что-либо в обход серверных функций нельзя.
import 'package:postgres/postgres.dart';
import 'package:server_tests/harness.dart';
import 'package:test/test.dart';

/// Код ошибки базы «нет прав».
const denied = '42501';

void main() {
  late World w;
  late Actor driver, otherDriver, ani, intruder;
  late String route, trip, booking;

  setUpAll(() async {
    w = await World.create('tt_access');
    route = await w.newRoute('M1');
    driver = await w.newDriver('Арам');
    otherDriver = await w.newDriver('Гаяне');
    ani = await w.newPassenger('Ани');
    intruder = await w.newPassenger('Любопытный');
    trip = await driver.createTrip(route, (await w.now()).add(const Duration(minutes: 200)));
    booking = (await ani.book(trip, ['front']))['booking_id'] as String;
    await w.newRoute('DRAFT', publish: false);
  });

  tearDownAll(() => w.close());

  Future<int> count(Actor a, String from) async => await a.one('select count(*)::int from $from') as int;

  group('пассажир', () {
    test('видит только свой профиль; телефон водителя и других пассажиров недоступен', () async {
      expect(await count(intruder, 'profiles'), 1);
      expect(await intruder.one('select id::text from profiles'), intruder.id);
      expect(await count(intruder, "profiles where phone is not null and id <> '${intruder.id}'"), 0);
    });

    test('не видит анкеты водителей (ИНН), но видит витрину без личных данных', () async {
      expect(await count(intruder, 'drivers'), 0);
      final card = await intruder.q('select * from driver_public where user_id = @d::uuid', {'d': driver.id});
      expect(card, hasLength(1));
      final cols = card.first.toColumnMap().keys.toSet();
      expect(cols, containsAll(['name', 'rating', 'car', 'car_color', 'plate']));
      expect(cols.intersection({'phone', 'tax_id', 'status', 'reject_reason'}), isEmpty);
    });

    test('видит только свои брони и карты; токен карты не отдаётся никому', () async {
      expect(await count(intruder, 'bookings'), 0);
      expect(await count(ani, 'bookings'), 1);
      expect(await count(intruder, 'cards'), 1);
      expect(await ani.refusal('select token from cards'), denied);
      expect(await ani.refusal('select * from cards'), denied, reason: 'все столбцы разом тоже нельзя');
      expect(await ani.refusal('select card_id from bookings'), denied);
      expect(await ani.refusal('select idem_key from bookings'), denied);
    });

    test('не видит деньги, журналы, сотрудников и чужие отметки посадки', () async {
      for (final t in ['ledger', 'payments', 'payouts', 'audit_log', 'staff']) {
        expect(await count(intruder, t), 0, reason: t);
      }
      expect(await intruder.refusal('select boarding from trip_seats'), denied);
    });

    test('видит опубликованные маршруты, но не черновики', () async {
      expect(await count(intruder, 'routes'), 1);
      expect(await count(w.moderator, 'routes'), 2);
    });

    test('не может действовать с чужой бронью, картой и рейсом', () async {
      expect(await intruder.refusal('select cancel_booking(@b::uuid)', {'b': booking}), 'BOOKING_NOT_FOUND');
      expect(await intruder.refusal('select rate_booking(@b::uuid, 1)', {'b': booking}), 'BOOKING_NOT_FOUND');
      expect(await intruder.refusal('select remove_card(@c::uuid)', {'c': ani.cardId}), 'CARD_NOT_FOUND');
      expect(await intruder.refusal('select * from trip_passengers(@t::uuid)', {'t': trip}), 'FORBIDDEN');
      expect(await intruder.refusal('select driver_start_trip(@t::uuid)', {'t': trip}), 'FORBIDDEN');
      expect(await intruder.refusal('select driver_cancel_trip(@t::uuid)', {'t': trip}), 'FORBIDDEN');
      expect(await intruder.refusal("select driver_mark_boarding(@t::uuid, 'front', 'no_show')", {'t': trip}), 'FORBIDDEN');
    });
  });

  group('в обход серверных функций', () {
    test('ни одну таблицу нельзя изменить напрямую', () async {
      final attempts = <String>[
        'update trip_seats set booking_id = null',
        "update trip_seats set price = 1",
        "insert into bookings (trip_id, passenger_id, seat_ids, amount, status, idem_key) values ('$trip', '${intruder.id}', '{rl}', 1, 'paid', 'x')",
        "update bookings set status = 'paid'",
        'delete from bookings',
        "update profiles set name = 'Взломщик'",
        "update profiles set blocked = false",
        "insert into staff (user_id, roles) values ('${intruder.id}', '{owner}')",
        "update drivers set status = 'approved'",
        'update routes set base_price = 1',
        "insert into routes (code, from_name, from_lat, from_lon, to_name, to_lat, to_lon, base_price, minutes, length_m) values ('X', 'a', 0, 0, 'b', 0, 0, 1, 1, 1)",
        "update trips set status = 'cancelled'",
        "insert into ledger (kind, amount, driver_id) values ('driver_accrual', 1000000, '${driver.id}')",
        "insert into payouts (driver_id, amount) values ('${driver.id}', 1000000)",
        'delete from ledger',
        'delete from audit_log',
        "update app_settings set value = '0' where key = 'commission_percent'",
        "update cards set user_id = '${intruder.id}'",
        "insert into cards (user_id, token, brand, last4) values ('${intruder.id}', 't', 'Visa', '1111')",
      ];
      for (final sql in attempts) {
        expect(await intruder.refusal(sql), denied, reason: sql);
        expect(await driver.refusal(sql), denied, reason: 'водитель: $sql');
        expect(await w.moderator.refusal(sql), denied, reason: 'модератор: $sql');
      }
    });

    test('служебные функции сервера вызвать нельзя', () async {
      for (final sql in [
        "select _bank_charge('1111', 1)",
        "select _refund('$booking', 600)",
        "select _finish_trip('$trip', now())",
        "select _audit('x', 'y', 'z')",
        'select _uid()',
        "select _require_role('owner')",
      ]) {
        expect(await intruder.refusal(sql), denied, reason: sql);
      }
    });

    test('функции сотрудников закрыты для пассажира и водителя', () async {
      for (final a in [intruder, driver]) {
        for (final sql in [
          "select staff_set_roles('${a.id}', '{owner}')",
          "select staff_block_user('${ani.id}', true)",
          "select staff_save_route(null, 'HACK', 'a', 0, 0, 'b', 0, 0, 1, 1, 1)",
          "select staff_set_route_status('$route', 'archived')",
          "select staff_review_driver('${a.id}', true)",
          'select finance_create_payouts()',
          'select accrue_due()',
        ]) {
          expect(await a.refusal(sql), 'FORBIDDEN', reason: '${a.name}: $sql');
        }
      }
    });

    test('без входа не видно и не доступно ничего', () async {
      final conn = await Connection.open(
        Endpoint(host: 'localhost', port: pgPort, database: w.database, username: 'postgres'),
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      );
      for (final sql in [
        'select * from routes',
        'select * from trips',
        'select * from driver_public',
        'select * from profiles',
        "select register_profile('x')",
        "select book_seats('$trip', '{rl}', null, 'k')",
      ]) {
        await expectLater(
          conn.runTx((s) async {
            await s.execute('set local role anon');
            await s.execute(sql);
          }),
          throwsA(isA<ServerException>().having((e) => e.code, 'код', denied)),
          reason: sql,
        );
      }
      await conn.close();
    });
  });

  group('водитель', () {
    test('видит брони только своих рейсов и не видит телефоны пассажиров', () async {
      expect(await count(driver, 'bookings'), 1);
      expect(await count(otherDriver, 'bookings'), 0);
      expect(await count(driver, "profiles where id = '${ani.id}'"), 0);
      final list = await driver.q('select * from trip_passengers(@t::uuid)', {'t': trip});
      expect(list.single.toColumnMap()['passenger_name'], 'Ани');
      expect(await otherDriver.refusal('select * from trip_passengers(@t::uuid)', {'t': trip}), 'FORBIDDEN');
    });

    test('видит только свою анкету и свой заработок', () async {
      expect(await count(driver, 'drivers'), 1);
      expect(await count(driver, 'ledger'), 0);
      expect((await driver.one('select driver_earnings()') as Map)['accrued'], 0);
    });
  });

  group('сотрудники', () {
    test('у каждой роли свой участок', () async {
      // модератор: маршруты — да; деньги, анкеты, профили — нет
      expect(await count(w.moderator, 'ledger'), 0);
      expect(await count(w.moderator, 'drivers'), 0);
      expect(await count(w.moderator, 'profiles'), 1);
      expect(await w.moderator.refusal("select staff_review_driver('${driver.id}', true)"), 'FORBIDDEN');
      expect(await w.moderator.refusal('select finance_create_payouts()'), 'FORBIDDEN');
      // проверяющий: анкеты — да; деньги и маршруты — нет
      expect(await count(w.verifier, 'drivers'), 2);
      expect(await count(w.verifier, 'ledger'), 0);
      expect(await w.verifier.refusal("select staff_set_route_status('$route', 'archived')"), 'FORBIDDEN');
      // финансы: журнал денег — да; анкеты и роли — нет
      expect(await count(w.finance, 'ledger'), greaterThan(0));
      expect(await count(w.finance, 'drivers'), 0);
      expect(await w.finance.refusal("select staff_set_roles('${w.finance.id}', '{owner}')"), 'FORBIDDEN');
      // поддержка: профили и брони — да; журнал денег и роли — нет
      expect(await count(w.support, 'profiles'), greaterThan(5));
      expect(await count(w.support, 'bookings'), 1);
      expect(await count(w.support, 'ledger'), 0);
      expect(await w.support.refusal("select staff_set_roles('${w.support.id}', '{owner}')"), 'FORBIDDEN');
      // журнал действий — только владелец
      expect(await count(w.support, 'audit_log'), 0);
      expect(await count(w.owner, 'audit_log'), greaterThan(0));
    });

    test('заблокированный пользователь не может ничего', () async {
      final bad = await w.newPassenger('Нарушитель');
      await w.support.q('select staff_block_user(@u::uuid, true)', {'u': bad.id});
      expect(await bad.refusal('select bind_card_sim(@n)', {'n': '4111111111111111'}), 'BLOCKED');
      expect(await bad.refusal('select book_seats(@t::uuid, @s::text[], @c::uuid, @k)',
          {'t': trip, 's': '{rl}', 'c': bad.cardId, 'k': 'k'}), 'BLOCKED');
      await w.support.q('select staff_block_user(@u::uuid, false)', {'u': bad.id});
      expect(await bad.refusal('select bind_card_sim(@n)', {'n': '4111111111111111'}), isNull);
    });

    test('человек без профиля не может ничего, кроме регистрации', () async {
      final r = await w.admin.execute("insert into auth.users (phone) values ('+37400000001') returning id");
      final ghost = Actor(w, r.first.first as String, '+37400000001', 'Без профиля');
      expect(await ghost.refusal('select bind_card_sim(@n)', {'n': '4111111111111111'}), 'NO_PROFILE');
      expect(await count(ghost, 'routes'), 1, reason: 'читать расписание может любой вошедший');
      await ghost.close();
    });
  });
}
