// Проверки безопасности «глазами взломщика»: вошедший пользователь пробует прочитать чужое
// и изменить то, что менять не должен. Каждая проверка утверждает БЕЗОПАСНОЕ поведение сервера.
//
// «ИСПРАВЛЕНО» — дыра была найдена этим файлом и с тех пор закрыта на сервере: тест проверяет новое правило строго —
// точный код отказа и то, что в базе ничего не изменилось.
// «FINDING» — дыра ещё открыта: такой тест сейчас НЕ проходит и оставлен как её описание.
// Этот файл только проверяет сервер и ничего в нём не чинит.
import 'package:postgres/postgres.dart';
import 'package:server_tests/harness.dart';
import 'package:server_tests/invariants.dart';
import 'package:test/test.dart';

/// Коды ошибок базы.
const denied = '42501'; // нет прав
const noColumn = '42703'; // такого столбца нет
// Значение не разобралось как uuid, json, число или статус. Это отказ ещё до вызова серверной функции:
// аргумент не подошёл по типу, сама функция не выполнялась.
const badText = '22P02';

/// Отказ серверной функции — понятный код ЗАГЛАВНЫМИ буквами, а не сырая ошибка базы (23505, 54000 и т. п.).
final cleanCode = matches(RegExp(r'^[A-Z][A-Z0-9_]+$'));

const bookSql = 'select book_seats(@t::uuid, @s::text[], @c::uuid, @k)';
const tripSql = 'select driver_create_trip(@r::uuid, @d::timestamptz, @m::int, @s::jsonb)';
const applySql = 'select apply_driver(@c, @k, @p, @s::int, @t)';
const refundSql = 'select staff_refund_booking(@b::uuid, @r)';
const nobody = '00000000-0000-0000-0000-000000000000';

const injection = "x'); drop table bookings; update staff set roles = '{owner}'; --";

void main() {
  late World w;
  late Actor driver, otherDriver, smallDriver, pendingDriver, rejectedDriver;
  late Actor ani, bob, cara, declined, intruder;
  late String route, draftRoute, trip, booking, bobBooking, doneTrip, doneBooking, failedBooking, payout;
  String? markGarbage, markFreeSeat, markNullSeat, markByStranger;

  setUpAll(() async {
    w = await World.create('tt_agent_security');
    route = await w.newRoute('M1');
    draftRoute = await w.newRoute('DRAFT', publish: false);
    driver = await w.newDriver('Арам');
    otherDriver = await w.newDriver('Гаяне');
    smallDriver = await w.newDriver('Трёхместный', seats: 3);
    pendingDriver = await w.newDriver('Ждёт проверки', approve: false);
    rejectedDriver = await w.newDriver('Отклонённый', approve: false);
    await w.verifier.q("select staff_review_driver(@d::uuid, false, 'нет прав')", {'d': rejectedDriver.id});
    ani = await w.newPassenger('Ани');
    bob = await w.newPassenger('Боб');
    cara = await w.newPassenger('Кара');
    declined = await w.newPassenger('Отказ банка', card: '4111111111110002');
    intruder = await w.newPassenger('Любопытный');

    // Полный круг денег на отдельном рейсе: бронь, отказ банка, поездка, оценка, начисление, выплата.
    doneTrip = await otherDriver.createTrip(route, (await w.now()).add(const Duration(minutes: 30)));
    doneBooking = (await cara.book(doneTrip, ['front']))['booking_id'] as String;
    failedBooking = (await declined.book(doneTrip, ['rl']))['booking_id'] as String;
    await w.advance(const Duration(minutes: 20));
    await otherDriver.q('select driver_start_trip(@t::uuid)', {'t': doneTrip});
    markGarbage = await otherDriver.refusal("select driver_mark_boarding(@t::uuid, 'front', 'hacked')", {'t': doneTrip});
    markFreeSeat = await otherDriver.refusal("select driver_mark_boarding(@t::uuid, 'rr', 'boarded')", {'t': doneTrip});
    markNullSeat = await otherDriver.refusal("select driver_mark_boarding(@t::uuid, null, 'boarded')", {'t': doneTrip});
    markByStranger = await driver.refusal("select driver_mark_boarding(@t::uuid, 'front', 'no_show')", {'t': doneTrip});
    await w.advance(const Duration(minutes: 11)); // завершить можно не раньше времени отправления
    await otherDriver.q('select driver_finish_trip(@t::uuid)', {'t': doneTrip});
    await cara.q('select rate_booking(@b::uuid, 2)', {'b': doneBooking});
    await w.advance(const Duration(hours: 25));
    await w.finance.q('select accrue_due()');
    await w.finance.q('select finance_create_payouts()');
    payout = await w.scalar('select id::text from payouts limit 1') as String;

    // Основной рейс, вокруг которого идут атаки: до отправления 200 минут.
    trip = await driver.createTrip(route, (await w.now()).add(const Duration(minutes: 200)),
        seats: {'front': 600, 'rl': 500, 'rm': 500, 'rr': 500});
    booking = (await ani.book(trip, ['front'], idem: 'ani-key-1'))['booking_id'] as String;
    bobBooking = (await bob.book(trip, ['rl']))['booking_id'] as String;
  });

  tearDownAll(() => w.close());

  Future<int> count(Actor a, String from) async => await a.one('select count(*)::int from $from') as int;
  Future<int> total(String from) async => await w.scalar('select count(*)::int from $from') as int;

  /// Текст отказа целиком (то, что увидит приложение), null — если запрос прошёл.
  Future<String?> message(Actor a, String sql, [Map<String, Object?> params = const {}]) async {
    try {
      await a.q(sql, params);
      return null;
    } on Refused catch (e) {
      return e.message;
    }
  }

  /// Запрос под произвольной ролью базы и с произвольным «токеном».
  Future<String?> rawRefusal(String role, String claims, String sql) async {
    final conn = await Connection.open(
      Endpoint(host: 'localhost', port: pgPort, database: w.database, username: 'postgres'),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    try {
      await conn.runTx((s) async {
        await s.execute('set local role $role');
        await s.execute(Sql.named("select set_config('request.jwt.claims', @c, true)"), parameters: {'c': claims});
        await s.execute(sql);
      });
      return null;
    } on ServerException catch (e) {
      return e.code;
    } finally {
      await conn.close();
    }
  }

  // =====================================================================================================
  group('выданные права (каталог базы)', () {
    test('приложению доступны только перечисленные функции; без входа — ни одной', () async {
      Future<String> executable(String role) async => await w.scalar('''
        select coalesce(string_agg(p.proname, ',' order by p.proname), '')
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and has_function_privilege('$role', p.oid, 'execute')''') as String;
      const allowed = [
        'accrue_due', 'app_now', 'apply_driver', 'bind_card_sim', 'book_seats', 'cancel_booking',
        'driver_cancel_trip', 'driver_create_trip', 'driver_earnings', 'driver_finish_trip', 'driver_mark_boarding',
        'driver_start_trip', 'finance_create_payouts', 'finance_mark_paid', 'has_role', 'rate_booking',
        'register_profile', 'remove_card', 'setting_int', 'staff_block_user', 'staff_refund_booking', 'staff_review_driver',
        'staff_save_route', 'staff_set_roles', 'staff_set_route_status', 'trip_passengers',
        // водитель: документы, карта для выплат, блокировки, заявки на маршруты, оценка пассажиров
        'driver_block_passenger', 'driver_blocked_passengers', 'driver_rate_passenger', 'driver_request_route',
        'driver_save_document', 'driver_set_payout_card_sim', 'driver_unblock_passenger', 'staff_review_route_request',
        // нужна правилу видимости рейсов (заблокированный пассажир не видит рейсов водителя)
        '_can_see_trip',
      ];
      expect((await executable('authenticated')).split(',').toSet(), allowed.toSet());
      expect(await executable('anon'), '', reason: 'без входа нельзя вызвать ни одну функцию');
    });

    test('ни одной таблице не выдано право на изменение; без входа нет и чтения', () async {
      expect(
        await w.scalar('''
          select coalesce(string_agg(c.relname, ','), '')
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relkind in ('r', 'v', 'S')
            and (has_table_privilege('authenticated', c.oid, 'insert, update, delete, truncate, references, trigger')
              or has_any_column_privilege('authenticated', c.oid, 'insert, update, references')
              or has_table_privilege('anon', c.oid, 'select, insert, update, delete, truncate, references, trigger')
              or has_any_column_privilege('anon', c.oid, 'select, insert, update, references'))'''),
        '',
      );
    });

    test('на каждой таблице включены правила строк; секретные столбцы не выданы', () async {
      expect(
        await w.scalar('''
          select coalesce(string_agg(c.relname, ','), '')
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity'''),
        '',
      );
      for (final col in ['cards.token', 'bookings.card_id', 'bookings.idem_key', 'bookings.rating', 'trip_seats.boarding']) {
        final p = col.split('.');
        expect(await w.scalar("select has_column_privilege('authenticated', 'public.${p[0]}', '${p[1]}', 'select')"), isFalse,
            reason: col);
      }
    });

    test('таблица входа (телефоны всех пользователей) приложению недоступна', () async {
      expect(await intruder.refusal('select phone from auth.users'), denied);
      expect(await w.support.refusal('select count(*) from auth.users'), denied);
      expect(await w.owner.refusal('select count(*) from auth.users'), denied);
    });
  });

  // =====================================================================================================
  group('чтение в обход: столбцы, строки целиком, соединения, подсчёты', () {
    test('закрытый столбец не достаётся ни напрямую, ни через строку целиком, ни через фильтр или сортировку', () async {
      for (final sql in [
        'select * from bookings',
        'select b from bookings b',
        'select to_jsonb(b) from bookings b',
        'select row_to_json(b) from bookings b',
        'select count(card_id) from bookings',
        'select id from bookings where card_id is not null',
        'select id from bookings order by idem_key',
        "select count(*) from bookings where idem_key = 'ani-key-1'",
        'select array_agg(idem_key) from bookings',
        'select rating from bookings',
        'select avg(rating) from bookings',
        'select id from bookings where rating = 2',
        'select id from bookings order by rating',
        'select * from trip_seats',
        'select s from trip_seats s',
        'select count(*) from trip_seats where boarding is not null',
        'select seat_id from trip_seats order by boarding',
        'select max(token) from cards',
        "select id from cards where token like 'sim%'",
        'select c from cards c',
        'select to_jsonb(c) from cards c',
      ]) {
        expect(await ani.refusal(sql), denied, reason: sql);
        expect(await driver.refusal(sql), denied, reason: 'водитель: $sql');
        expect(await w.owner.refusal(sql), denied, reason: 'владелец: $sql');
      }
    });

    test('соединения таблиц и подсчёты не открывают чужие строки', () async {
      expect(await count(intruder, 'trip_seats s join bookings b on b.id = s.booking_id'), 0);
      expect(await count(intruder, 'driver_public d join profiles p on p.id = d.user_id'), 0);
      expect(await count(intruder, 'trips t join drivers d on d.user_id = t.driver_id'), 0);
      expect(await count(intruder, 'trips t join profiles p on p.id = t.driver_id'), 0);
      expect(await count(intruder, "profiles where phone like '+374%'"), 1, reason: 'только свой профиль');
      expect(await intruder.one('select max(phone) from profiles'), intruder.phone);
      expect(await count(intruder, 'bookings b join profiles p on p.id = b.passenger_id'), 0);
      expect(await count(intruder, "bookings where trip_id = '$trip'"), 0);
      expect(await intruder.one("select sum(amount) from bookings where trip_id = '$trip'"), isNull);
    });

    test('в витрине водителя нет ни телефона, ни ИНН, ни статуса — даже если спросить по имени столбца', () async {
      for (final col in ['phone', 'tax_id', 'status', 'reject_reason', 'blocked', 'reviewed_by']) {
        expect(await intruder.refusal('select $col from driver_public'), noColumn, reason: col);
      }
      final row = (await intruder.q('select * from driver_public where user_id = @d::uuid', {'d': driver.id})).single;
      expect(row.toColumnMap().keys.toSet(),
          {'user_id', 'name', 'rating', 'rating_count', 'car', 'car_color', 'plate', 'seats_total'});
    });

    test('попутчик не видит чужую бронь того же рейса и не может узнать имена попутчиков', () async {
      expect(await count(bob, "bookings where trip_id = '$trip'"), 1);
      expect(await bob.one("select id::text from bookings where trip_id = '$trip'"), bobBooking);
      expect(await bob.refusal('select * from trip_passengers(@t::uuid)', {'t': trip}), 'FORBIDDEN');
      expect(await count(bob, "profiles where id = '${ani.id}'"), 0);
    });

    test('строки нельзя заблокировать запросом на чтение', () async {
      expect(await intruder.refusal('select id from trips for update'), denied);
      expect(await intruder.refusal('select trip_id from trip_seats for share'), denied);
      expect(await intruder.refusal('lock table trips in access exclusive mode'), denied);
    });
  });

  // =====================================================================================================
  group('витрина водителей и заявки', () {
    test('в витрине нет водителей на проверке, отклонённых и обычных пассажиров', () async {
      for (final a in [pendingDriver, rejectedDriver, ani, w.support]) {
        expect(await count(intruder, "driver_public where user_id = '${a.id}'"), 0, reason: a.name);
      }
      expect(await count(intruder, "driver_public where user_id = '${driver.id}'"), 1);
    });

    test('неодобренный водитель не может поставить рейс', () async {
      final args = {'r': route, 'd': (await w.now()).add(const Duration(minutes: 600)).toIso8601String(), 'm': '0',
        's': '[{"id":"front","price":500}]'};
      expect(await pendingDriver.refusal(tripSql, args), 'DRIVER_NOT_APPROVED');
      expect(await rejectedDriver.refusal(tripSql, args), 'DRIVER_NOT_APPROVED');
      expect(await ani.refusal(tripSql, args), 'DRIVER_NOT_APPROVED');
      expect(await w.owner.refusal(tripSql, args), 'DRIVER_NOT_APPROVED', reason: 'роль владельца не делает водителем');
    });

    test('повторная заявка отклонённого возвращает «на проверке», а не «одобрен»', () async {
      await rejectedDriver.q(applySql, {'c': 'Kia Rio', 'k': 'синяя', 'p': '35 RR 001', 's': '4', 't': '01234567'});
      expect(await w.scalar("select status::text from drivers where user_id = '${rejectedDriver.id}'"), 'pending');
      expect(await count(intruder, "driver_public where user_id = '${rejectedDriver.id}'"), 0);
    });

    test('водителя со статусом «заблокирован» не вернуть ни новой заявкой, ни проверяющим', () async {
      final banned = await w.newDriver('Забанен');
      await w.admin.execute("update drivers set status = 'blocked' where user_id = '${banned.id}'");
      expect(await banned.refusal(applySql, {'c': 'BMW', 'k': 'чёрная', 'p': '35 BB 001', 's': '4', 't': '0999'}), 'DRIVER_BLOCKED');
      expect(await w.verifier.refusal("select staff_review_driver('${banned.id}', true)"), 'DRIVER_BLOCKED');
      expect(await w.verifier.refusal("select staff_review_driver('${banned.id}', false, 'причина')"), 'DRIVER_BLOCKED');
      expect(await w.owner.refusal("select staff_review_driver('${banned.id}', true)"), 'DRIVER_BLOCKED');
      expect(await w.scalar("select status::text || '/' || car from drivers where user_id = '${banned.id}'"), 'blocked/Toyota Camry');
      expect(await count(intruder, "driver_public where user_id = '${banned.id}'"), 0);
      expect(
          await banned.refusal(tripSql, {
            'r': route, 'd': (await w.now()).add(const Duration(minutes: 600)).toIso8601String(), 'm': '0',
            's': '[{"id":"front","price":500}]',
          }),
          'DRIVER_NOT_APPROVED');
    });

    test('заявка с мусором отклоняется целиком', () async {
      final fresh = await w.newUser('Мусорная заявка');
      final good = {'c': 'Toyota', 'k': 'белая', 'p': '35 AA 001', 's': '4', 't': '0123'};
      final cases = <Map<String, Object?>, String>{
        {...good, 's': '99'}: 'BAD_SEATS_TOTAL',
        {...good, 's': '0'}: 'BAD_SEATS_TOTAL',
        {...good, 's': '-4'}: 'BAD_SEATS_TOTAL',
        {...good, 's': '2'}: 'BAD_SEATS_TOTAL',
        {...good, 's': '5'}: 'BAD_SEATS_TOTAL',
        {...good, 's': '2147483647'}: 'BAD_SEATS_TOTAL',
        {...good, 's': null}: 'BAD_SEATS_TOTAL',
        {...good, 'c': null}: 'BAD_ARGUMENT',
        {...good, 'c': ''}: 'BAD_ARGUMENT',
        {...good, 'c': '   '}: 'BAD_ARGUMENT',
        {...good, 'c': 'x' * 61}: 'BAD_ARGUMENT',
        {...good, 'k': null}: 'BAD_ARGUMENT',
        {...good, 'k': 'x' * 31}: 'BAD_ARGUMENT',
        {...good, 'p': null}: 'BAD_ARGUMENT',
        {...good, 'p': 'x' * 21}: 'BAD_ARGUMENT',
        {...good, 't': null}: 'BAD_ARGUMENT',
        {...good, 't': '   '}: 'BAD_ARGUMENT',
        {...good, 't': '1' * 21}: 'BAD_ARGUMENT',
        {...good, 's': 'четыре'}: badText,
      };
      final audit = await total("audit_log where action = 'apply_driver'");
      for (final c in cases.entries) {
        expect(await fresh.refusal(applySql, c.key), c.value, reason: '${c.key}');
      }
      expect(await total("drivers where user_id = '${fresh.id}'"), 0);
      expect(await total("audit_log where action = 'apply_driver'"), audit);
    });

    test('проверяющий: отказ без причины не проходит, чужие заявки без роли не тронуть', () async {
      expect(await w.verifier.refusal("select staff_review_driver('${pendingDriver.id}', false)"), 'REASON_REQUIRED');
      expect(await w.verifier.refusal("select staff_review_driver('${pendingDriver.id}', false, '   ')"), 'REASON_REQUIRED');
      expect(await w.verifier.refusal('select staff_review_driver(null, true)'), 'DRIVER_NOT_FOUND');
      expect(await w.verifier.refusal("select staff_review_driver('${ani.id}', true)"), 'DRIVER_NOT_FOUND',
          reason: 'пассажира без заявки одобрить нельзя');
      expect(await pendingDriver.refusal("select staff_review_driver('${pendingDriver.id}', true)"), 'FORBIDDEN');
      expect(await w.scalar("select status::text from drivers where user_id = '${pendingDriver.id}'"), 'pending');
    });

    // ИСПРАВЛЕНО: p_approve = null больше не обходит обязательную причину отказа — BAD_ARGUMENT.
    test('отказ без причины не проходит и при p_approve = null', () async {
      final target = await w.newDriver('Без причины', approve: false);
      expect(await w.verifier.refusal("select staff_review_driver('${target.id}', null)"), 'BAD_ARGUMENT');
      expect(await w.verifier.refusal("select staff_review_driver('${target.id}', null, 'причина')"), 'BAD_ARGUMENT');
      expect(
          await w.scalar("select status::text || ' / причина: ' || coalesce(reject_reason, 'нет') || ' / проверил: ' "
              "|| coalesce(reviewed_by::text, 'никто') from drivers where user_id = '${target.id}'"),
          'pending / причина: нет / проверил: никто');
    });

    // ИСПРАВЛЕНО: свою заявку проверять нельзя — FORBIDDEN, в том числе владельцу.
    test('проверяющий не может одобрить самого себя', () async {
      await w.verifier.q(applySql, {'c': 'Lada', 'k': 'серая', 'p': '35 VV 001', 's': '4', 't': '0555'});
      expect(await w.verifier.refusal("select staff_review_driver('${w.verifier.id}', true)"), 'FORBIDDEN');
      expect(await w.verifier.refusal("select staff_review_driver('${w.verifier.id}', false, 'сам себе')"), 'FORBIDDEN');
      expect(await w.scalar("select status::text from drivers where user_id = '${w.verifier.id}'"), 'pending');
      await w.owner.q(applySql, {'c': 'Lada', 'k': 'серая', 'p': '35 OW 001', 's': '4', 't': '0556'});
      expect(await w.owner.refusal("select staff_review_driver('${w.owner.id}', true)"), 'FORBIDDEN');
      expect(await w.scalar("select status::text from drivers where user_id = '${w.owner.id}'"), 'pending');
      expect(await count(intruder, "driver_public where user_id in ('${w.verifier.id}', '${w.owner.id}')"), 0);
    });
  });

  // =====================================================================================================
  group('водитель и его пассажиры', () {
    // ПРАВИЛО: номер пассажира (id) и его общий рейтинг нужны водителю, чтобы заблокировать и оценить.
    test('список пассажиров: только место, имя, номер и рейтинг пассажира, номер брони и отметка', () async {
      final list = await driver.q('select * from trip_passengers(@t::uuid)', {'t': trip});
      expect(list, hasLength(2));
      expect(list.first.toColumnMap().keys.toSet(),
          {'seat_id', 'passenger_id', 'passenger_name', 'passenger_rating', 'booking_id', 'boarding'});
      expect(list.map((r) => r.toColumnMap()['passenger_name']).toSet(), {'Ани', 'Боб'});
      expect(await driver.refusal('select phone from trip_passengers(@t::uuid)', {'t': trip}), noColumn);
    });

    test('водитель не достаёт телефон, профиль и карты пассажира ни одним запросом', () async {
      expect(await count(driver, "profiles where id in ('${ani.id}', '${bob.id}')"), 0);
      expect(await count(driver, 'bookings b join profiles p on p.id = b.passenger_id'), 0);
      expect(await count(driver, "cards where user_id <> '${driver.id}'"), 0);
      expect(await count(driver, "driver_public where user_id = '${ani.id}'"), 0);
      expect(await count(driver, 'payments'), 0);
    });

    test('пассажир не достаёт телефон и анкету водителя', () async {
      expect(await count(ani, "profiles where id = '${driver.id}'"), 0);
      expect(await count(ani, "drivers where user_id = '${driver.id}'"), 0);
      expect(await count(ani, "payouts where driver_id = '${otherDriver.id}'"), 0);
    });

    test('водитель не может отменить или оценить бронь пассажира на своём рейсе', () async {
      expect(await driver.refusal('select cancel_booking(@b::uuid)', {'b': booking}), 'BOOKING_NOT_FOUND');
      expect(await otherDriver.refusal('select rate_booking(@b::uuid, 5)', {'b': doneBooking}), 'BOOKING_NOT_FOUND',
          reason: 'водитель не ставит оценку сам себе');
      expect(await w.scalar("select status::text from bookings where id = '$booking'"), 'paid');
      expect(await w.scalar("select rating from bookings where id = '$doneBooking'"), 2);
    });

    test('чужой водитель не видит брони и не управляет чужим рейсом', () async {
      expect(await count(otherDriver, "bookings where trip_id = '$trip'"), 0);
      expect(await count(driver, "bookings where trip_id = '$doneTrip'"), 0);
      for (final sql in [
        'select driver_start_trip(@t::uuid)',
        'select driver_finish_trip(@t::uuid)',
        'select driver_cancel_trip(@t::uuid)',
        "select driver_mark_boarding(@t::uuid, 'front', 'boarded')",
        'select * from trip_passengers(@t::uuid)',
      ]) {
        expect(await otherDriver.refusal(sql, {'t': trip}), 'FORBIDDEN', reason: sql);
      }
      expect(markByStranger, 'FORBIDDEN');
      expect(await w.scalar("select status::text from trips where id = '$trip'"), 'planned');
    });

    test('заработок и выплаты: только свои', () async {
      const zero = {'accrued': 0, 'paid_out': 0, 'to_pay': 0};
      expect(await intruder.one('select driver_earnings()'), zero);
      expect(await driver.one('select driver_earnings()'), zero);
      expect(await w.finance.one('select driver_earnings()'), zero, reason: 'финансист не получает здесь общий итог');
      expect((await otherDriver.one('select driver_earnings()') as Map)['accrued'], greaterThan(0));
      expect(await count(otherDriver, 'payouts'), 1);
      expect(await count(driver, 'payouts'), 0);
      expect(await count(intruder, 'payouts'), 0);
      expect(await otherDriver.refusal('select finance_mark_paid(@p::uuid)', {'p': payout}), 'FORBIDDEN',
          reason: 'водитель не может сам отметить свою выплату выплаченной');
      expect(await w.scalar("select status from payouts where id = '$payout'"), 'created');
      expect(await count(otherDriver, 'ledger'), 0);
    });

    // ИСПРАВЛЕНО: неудачные попытки оплаты водителю не показываются (правило bookings_read смотрит на статус).
    test('водитель не видит неудачные попытки оплаты пассажиров', () async {
      expect(await count(otherDriver, "bookings where id = '$failedBooking'"), 0);
      expect(await count(otherDriver, "bookings where status = 'failed'"), 0);
      expect(await count(otherDriver, "bookings where passenger_id = '${declined.id}'"), 0);
      expect(await count(otherDriver, "bookings where trip_id = '$doneTrip'"), 1, reason: 'оплаченную бронь своего рейса видит');
      final list = await otherDriver.q('select booking_id from trip_passengers(@t::uuid)', {'t': doneTrip});
      expect(list.map((r) => r.first), [doneBooking], reason: 'в списке пассажиров — только оплатившие');
      // сам пассажир и поддержка неудачную попытку видят
      expect(await count(declined, "bookings where id = '$failedBooking'"), 1);
      expect(await count(w.support, "bookings where id = '$failedBooking'"), 1);
    });

    // ИСПРАВЛЕНО: столбец оценки в бронях закрыт для приложений целиком (отказ «нет прав»),
    // свои оценки пассажир читает из my_ratings. Водитель видит бронь, но не оценку в ней.
    test('водитель не видит, кто именно поставил ему оценку', () async {
      for (final sql in [
        "select rating from bookings where id = '$doneBooking'",
        "select id from bookings where id = '$doneBooking' and rating = 2",
        "select id from bookings where trip_id = '$doneTrip' order by rating",
        "select passenger_id, max(rating) from bookings where trip_id = '$doneTrip' group by passenger_id",
      ]) {
        expect(await otherDriver.refusal(sql), denied, reason: sql);
      }
      expect(await count(otherDriver, "bookings where id = '$doneBooking'"), 1, reason: 'саму бронь водитель видит');
      expect(await count(otherDriver, 'my_ratings'), 0);
      expect(await count(otherDriver, "my_ratings where booking_id = '$doneBooking'"), 0);
      expect(await otherDriver.refusal('select rating from trip_passengers(@t::uuid)', {'t': doneTrip}), noColumn);
    });

    // ИСПРАВЛЕНО (средняя, приватность): оценку конкретной брони водитель всё же узнаёт — перебором через my_ratings.
    // Витрина my_ratings создана без security_barrier, поэтому условие из запроса вычисляется по ВСЕМ броням
    // раньше, чем отбор «только свои». Верная догадка об оценке даёт ошибку деления на ноль, неверная — пустой ответ.
    test('оценку чужой брони нельзя подобрать через my_ratings', () async {
      String guess(int stars) => "select count(*) from my_ratings where booking_id = '$doneBooking' and 1 / (rating - $stars) > 0";
      final answers = {for (final stars in [1, 2, 3, 4, 5]) stars: await otherDriver.refusal(guess(stars))};
      expect(answers, {1: null, 2: null, 3: null, 4: null, 5: null},
          reason: 'ответ на верную догадку отличается: водитель узнал, что пассажир поставил ему 2');
    });

    test('свои оценки пассажир читает из my_ratings; чужих там нет ни для кого, изменить их нельзя', () async {
      final mine = await cara.q('select * from my_ratings');
      expect(mine.single.toColumnMap(), {'booking_id': doneBooking, 'rating': 2});
      for (final a in [ani, intruder, driver, otherDriver, w.support, w.finance, w.verifier, w.moderator, w.owner]) {
        expect(await count(a, 'my_ratings'), 0, reason: a.name);
      }
      expect(await rawRefusal('anon', '{"role":"anon"}', 'select * from my_ratings'), denied);
      expect(await rawRefusal('anon', '{"role":"anon","sub":"${cara.id}"}', 'select * from my_ratings'), denied);
      for (final sql in [
        'update my_ratings set rating = 5',
        'delete from my_ratings',
        "insert into my_ratings (booking_id, rating) values ('$booking', 5)",
      ]) {
        expect(await cara.refusal(sql), denied, reason: sql);
        expect(await otherDriver.refusal(sql), denied, reason: 'водитель: $sql');
      }
      expect(await w.scalar("select rating from bookings where id = '$doneBooking'"), 2);
      expect(await total('bookings where rating is not null'), 1);
    });
  });

  // =====================================================================================================
  group('бронь, карты и оценки: враждебные аргументы', () {
    test('чужой картой не заплатить: ни брони, ни списания не появляется', () async {
      final before = await total('bookings');
      final payments = await total('payments');
      expect(await bob.refusal(bookSql, {'t': trip, 's': '{rr}', 'c': ani.cardId, 'k': 'bob-steals-card'}), 'CARD_NOT_FOUND');
      expect(await intruder.refusal(bookSql, {'t': trip, 's': '{rr}', 'c': ani.cardId, 'k': 'x1'}), 'CARD_NOT_FOUND');
      expect(await total('bookings'), before);
      expect(await total('payments'), payments);
      expect(await w.scalar("select booking_id::text from trip_seats where trip_id = '$trip' and seat_id = 'rr'"), isNull);
    });

    test('чужой номер операции не отдаёт чужую бронь', () async {
      // место Ани занято: с её номером операции чужой получает отказ, а не её бронь
      expect(await intruder.refusal(bookSql, {'t': trip, 's': '{front}', 'c': intruder.cardId, 'k': 'ani-key-1'}), 'SEAT_TAKEN');
      // на свободное место с тем же номером создаётся своя, отдельная бронь
      final mine = await intruder.book(trip, ['rr'], idem: 'ani-key-1');
      expect(mine['booking_id'], isNot(booking));
      expect(mine['repeat'], isNull);
      expect((await intruder.cancel(mine['booking_id'] as String))['refund'], 500);
    });

    test('свой номер операции нельзя пустить повторно на другой рейс или другие места', () async {
      final before = await total('bookings');
      final payments = await total('payments');
      expect(await ani.refusal(bookSql, {'t': trip, 's': '{rr}', 'c': ani.cardId, 'k': 'ani-key-1'}), 'IDEM_KEY_REUSED');
      expect(await ani.refusal(bookSql, {'t': trip, 's': '{front,rr}', 'c': ani.cardId, 'k': 'ani-key-1'}), 'IDEM_KEY_REUSED');
      expect(await ani.refusal(bookSql, {'t': doneTrip, 's': '{front}', 'c': ani.cardId, 'k': 'ani-key-1'}), 'IDEM_KEY_REUSED');
      expect(await ani.refusal(bookSql, {'t': null, 's': '{front}', 'c': ani.cardId, 'k': 'ani-key-1'}), 'IDEM_KEY_REUSED');
      // тот же рейс и те же места — та же бронь, без нового списания
      final again = await ani.book(trip, ['front'], idem: 'ani-key-1');
      expect(again['booking_id'], booking);
      expect(again['repeat'], isTrue);
      expect(await total('bookings'), before);
      expect(await total('payments'), payments);
      expect(await w.scalar("select booking_id::text from trip_seats where trip_id = '$trip' and seat_id = 'rr'"), isNull);
    });

    test('удалённой картой не заплатить; чужую и несуществующую карту не удалить', () async {
      final second = await intruder.one('select bind_card_sim(@n)', {'n': '5111111111111111'}) as String;
      await intruder.q('select remove_card(@c::uuid)', {'c': second});
      expect(await intruder.refusal(bookSql, {'t': trip, 's': '{rr}', 'c': second, 'k': 'removed-card'}), 'CARD_NOT_FOUND');
      expect(await intruder.refusal('select remove_card(@c::uuid)', {'c': second}), 'CARD_NOT_FOUND');
      expect(await intruder.refusal('select remove_card(null)'), 'CARD_NOT_FOUND');
      expect(await w.support.refusal('select remove_card(@c::uuid)', {'c': ani.cardId}), 'CARD_NOT_FOUND');
      expect(await w.owner.refusal('select remove_card(@c::uuid)', {'c': ani.cardId}), 'CARD_NOT_FOUND');
      expect(await w.scalar("select removed_at is null from cards where id = '${ani.cardId}'"), isTrue);
    });

    test('мусор в покупке отклоняется и ничего не меняет', () async {
      final before = await total('bookings');
      final good = {'t': trip, 's': '{rr}', 'c': intruder.cardId, 'k': 'garbage'};
      final cases = <Map<String, Object?>, String>{
        {...good, 't': null}: 'TRIP_NOT_FOUND',
        {...good, 't': '00000000-0000-0000-0000-000000000000'}: 'TRIP_NOT_FOUND',
        {...good, 't': 'not-a-uuid'}: badText,
        {...good, 't': booking}: 'TRIP_NOT_FOUND',
        {...good, 's': null}: 'BAD_SEATS',
        {...good, 's': '{}'}: 'BAD_SEATS',
        {...good, 's': '{NULL}'}: 'BAD_SEATS',
        {...good, 's': '{rr,NULL}'}: 'BAD_SEATS',
        {...good, 's': '{rr,rr}'}: 'BAD_SEATS',
        {...good, 's': '{trunk}'}: 'BAD_SEATS',
        {...good, 's': '{rr,rm,front,rl,trunk}'}: 'BAD_SEATS',
        {...good, 's': '{"rr\'; drop table bookings; --"}'}: 'BAD_SEATS',
        {...good, 's': '{RR}'}: 'BAD_SEATS',
        {...good, 'c': null}: 'CARD_NOT_FOUND',
        {...good, 'c': '00000000-0000-0000-0000-000000000000'}: 'CARD_NOT_FOUND',
        {...good, 'c': booking}: 'CARD_NOT_FOUND',
        {...good, 'k': null}: 'IDEM_KEY_REQUIRED',
        {...good, 'k': ''}: 'IDEM_KEY_REQUIRED',
        {...good, 'k': '   '}: 'IDEM_KEY_REQUIRED',
      };
      for (final c in cases.entries) {
        expect(await intruder.refusal(bookSql, c.key), c.value, reason: '${c.key}');
      }
      expect(await total('bookings'), before);
      expect(await total("trip_seats where trip_id = '$trip' and booking_id is not null"), 2);
    });

    // ИСПРАВЛЕНО: вложенный список мест '{{rr,rm}}' отклоняется — BAD_SEATS, бронь не создаётся и деньги не списываются.
    test('места принимаются только простым списком', () async {
      final before = await total('bookings');
      final payments = await total('payments');
      for (final seats in ['{{rr,rm}}', '{{rr},{rm}}', '{{{rr}}}', '{{rr}}']) {
        expect(await bob.refusal(bookSql, {'t': trip, 's': seats, 'c': bob.cardId, 'k': 'two-dim'}), 'BAD_SEATS', reason: seats);
      }
      expect(await total('bookings'), before);
      expect(await total('payments'), payments);
      expect(await total("trip_seats where trip_id = '$trip' and seat_id in ('rr', 'rm') and booking_id is not null"), 0);
    });

    // ИСПРАВЛЕНО (средняя): длина номера операции не ограничена. Длинный номер (несколько тысяч случайных знаков)
    // доходит до записи брони и там падает сырой ошибкой базы 54000 («index row requires … bytes») —
    // уже ПОСЛЕ обращения к банку: с настоящим банком деньги будут списаны, а бронь не появится.
    // book_seats проверяет только, что p_idem не пустой.
    test('слишком длинный номер операции отклоняется понятным отказом и до обращения к банку', () async {
      final before = await total('bookings');
      // 9600 случайных знаков: такая строка не сжимается и не помещается в индекс (passenger_id, idem_key)
      final long = await w.scalar("select string_agg(md5(i::text || 'z'), '') from generate_series(1, 300) i") as String;
      final r = await bob.refusal(bookSql, {'t': trip, 's': '{rr}', 'c': bob.cardId, 'k': long});
      // 100000 одинаковых знаков сжимаются и в индекс помещаются: такой номер сервер сейчас принимает и хранит
      final huge = await bob.refusal(bookSql, {'t': trip, 's': '{rr}', 'c': bob.cardId, 'k': 'x' * 100000});
      // убираем за собой, если бронь всё же создалась: полный возврат, место снова свободно
      for (final row in await w.admin.execute(
          "select id::text from bookings where passenger_id = '${bob.id}' and length(idem_key) > 1000 and status = 'paid'")) {
        await bob.cancel(row.first as String);
      }
      expect(r, cleanCode, reason: 'номер операции из ${long.length} знаков: сырая ошибка базы после обращения к банку');
      expect(huge, cleanCode, reason: 'номер операции из 100000 знаков принят, бронь оплачена и сохранена');
      expect(await total('bookings'), before);
    });

    test('водитель не покупает места на своём рейсе', () async {
      await driver.bindCard('4111111111111111');
      expect(await driver.refusal(bookSql, {'t': trip, 's': '{rr}', 'c': driver.cardId, 'k': 'own'}), 'OWN_TRIP');
    });

    test('чужую бронь не отменить никому, кроме поддержки; отказ не выдаёт, существует ли бронь', () async {
      for (final a in [intruder, bob, driver, w.finance, w.moderator, w.verifier]) {
        expect(await message(a, 'select cancel_booking(@b::uuid)', {'b': booking}), 'BOOKING_NOT_FOUND', reason: a.name);
      }
      expect(await message(intruder, 'select cancel_booking(@b::uuid)', {'b': '00000000-0000-0000-0000-000000000000'}),
          'BOOKING_NOT_FOUND', reason: 'тот же ответ, что и для существующей чужой брони');
      expect(await intruder.refusal('select cancel_booking(null)'), 'BOOKING_NOT_FOUND');
      expect(await intruder.refusal('select cancel_booking(@b::uuid)', {'b': trip}), 'BOOKING_NOT_FOUND');
      expect(await w.scalar("select status::text from bookings where id = '$booking'"), 'paid');
      expect(await total("ledger where booking_id = '$booking' and kind = 'refund'"), 0);
    });

    test('оценка: только своя завершённая поездка, один раз, от 1 до 5', () async {
      expect(await ani.refusal('select rate_booking(@b::uuid, 5)', {'b': booking}), 'TRIP_NOT_FINISHED');
      expect(await declined.refusal('select rate_booking(@b::uuid, 1)', {'b': failedBooking}), 'TRIP_NOT_FINISHED',
          reason: 'неоплаченная бронь не даёт права на оценку');
      expect(await cara.refusal('select rate_booking(@b::uuid, 5)', {'b': doneBooking}), 'ALREADY_RATED');
      for (final stars in ['0', '6', '-1', '2147483647', null]) {
        expect(await cara.refusal('select rate_booking(@b::uuid, @s::int)', {'b': doneBooking, 's': stars}), 'BAD_RATING',
            reason: '$stars');
      }
      expect(await cara.refusal('select rate_booking(null, 5)'), 'BOOKING_NOT_FOUND');
      expect(await w.support.refusal('select rate_booking(@b::uuid, 1)', {'b': doneBooking}), 'BOOKING_NOT_FOUND');
      expect(await w.owner.refusal('select rate_booking(@b::uuid, 1)', {'b': doneBooking}), 'BOOKING_NOT_FOUND');
      expect(await w.scalar("select rating::text || ' / ' || rating_count from drivers where user_id = '${otherDriver.id}'"), '2.0 / 1');
    });

    test('привязка карты: мусор вместо номера и превышение числа карт', () async {
      for (final n in [null, '', 'abcd', '41111111111111111', '411111111111111', '4111 1111 1111 111x', "4111111111111111'; --",
        '-411111111111111', '٤١١١١١١١١١١١١١١١']) {
        expect(await intruder.refusal('select bind_card_sim(@n)', {'n': n}), 'BAD_CARD_NUMBER', reason: '$n');
      }
      final active = await count(intruder, 'cards where removed_at is null');
      for (var i = active; i < 5; i++) {
        await intruder.q('select bind_card_sim(@n)', {'n': '4111111111111111'});
      }
      expect(await intruder.refusal('select bind_card_sim(@n)', {'n': '4111111111111111'}), 'TOO_MANY_CARDS');
      expect(await count(intruder, 'cards where removed_at is null'), 5);
    });
  });

  // =====================================================================================================
  group('рейсы: враждебные аргументы', () {
    test('мусор при постановке рейса отклоняется; рейс не появляется', () async {
      final when = (await w.now()).add(const Duration(minutes: 900)).toIso8601String();
      final good = {'r': route, 'd': when, 'm': '0', 's': '[{"id":"front","price":500}]'};
      final before = await total("trips where driver_id = '${otherDriver.id}'");
      final cases = <Map<String, Object?>, String>{
        {...good, 'r': null}: 'ROUTE_NOT_AVAILABLE',
        {...good, 'r': '00000000-0000-0000-0000-000000000000'}: 'ROUTE_NOT_AVAILABLE',
        {...good, 'r': draftRoute}: 'ROUTE_NOT_AVAILABLE',
        {...good, 'd': null}: 'DEPARTURE_TOO_SOON',
        {...good, 'd': '-infinity'}: 'DEPARTURE_TOO_SOON',
        {...good, 'd': '2000-01-01T00:00:00Z'}: 'DEPARTURE_TOO_SOON',
        {...good, 'd': 'infinity'}: 'DEPARTURE_TOO_FAR',
        {...good, 'd': '2999-01-01T00:00:00Z'}: 'DEPARTURE_TOO_FAR',
        {...good, 'm': null}: 'MEET_POINT_OUTSIDE_DISTRICT',
        {...good, 'm': '-1'}: 'MEET_POINT_OUTSIDE_DISTRICT',
        {...good, 'm': '1501'}: 'MEET_POINT_OUTSIDE_DISTRICT',
        {...good, 'm': '2147483647'}: 'MEET_POINT_OUTSIDE_DISTRICT',
        {...good, 's': null}: 'BAD_SEATS',
        {...good, 's': 'null'}: 'BAD_SEATS',
        {...good, 's': '{}'}: 'BAD_SEATS',
        {...good, 's': '[]'}: 'BAD_SEATS',
        {...good, 's': '"front"'}: 'BAD_SEATS',
        {...good, 's': '[1]'}: 'BAD_SEATS',
        {...good, 's': '["front"]'}: 'BAD_SEATS',
        {...good, 's': '[null]'}: 'BAD_SEATS',
        {...good, 's': '[[{"id":"front","price":500}]]'}: 'BAD_SEATS',
        {...good, 's': '[{"id":"trunk","price":500}]'}: 'BAD_SEATS',
        {...good, 's': '[{"id":null,"price":500}]'}: 'BAD_SEATS',
        {...good, 's': '[{"id":"front","price":500},{"id":"front","price":1}]'}: 'BAD_SEATS',
        {...good, 's': '[{"id":"front"}]'}: 'BAD_PRICE',
        {...good, 's': '[{"id":"front","price":null}]'}: 'BAD_PRICE',
        {...good, 's': '[{"id":"front","price":0}]'}: 'BAD_PRICE',
        {...good, 's': '[{"id":"front","price":-5}]'}: 'BAD_PRICE',
        {...good, 's': '[{"id":"front","price":500.5}]'}: 'BAD_PRICE',
        {...good, 's': '[{"id":"front","price":1501}]'}: 'BAD_PRICE',
        {...good, 's': '[{"id":"front","price":99999999}]'}: 'BAD_PRICE',
        {...good, 's': '[{"id":"front","price":true}]'}: 'BAD_PRICE',
        {...good, 's': '[{"id":"front","price":""}]'}: 'BAD_PRICE',
        {...good, 's': '[{"id":"front","price":"500; drop table trips"}]'}: 'BAD_PRICE',
        {...good, 's': '[{"id":"front","price":{"x":1}}]'}: 'BAD_PRICE',
        {...good, 's': 'не json'}: badText,
      };
      for (final c in cases.entries) {
        expect(await otherDriver.refusal(tripSql, c.key), c.value, reason: '${c.key}');
      }
      expect(await smallDriver.refusal(tripSql, {...good, 's': '[{"id":"rm","price":500}]'}), 'BAD_SEATS',
          reason: 'в трёхместной машине нет среднего места');
      expect(await total("trips where driver_id = '${otherDriver.id}'"), before);
      expect(await total("trips where driver_id = '${smallDriver.id}'"), 0);
    });

    test('действия с рейсом: пустые и несуществующие номера, не то состояние', () async {
      for (final sql in ['select driver_start_trip(null)', 'select driver_finish_trip(null)', 'select driver_cancel_trip(null)',
        "select driver_mark_boarding(null, 'front', 'boarded')"]) {
        expect(await driver.refusal(sql), 'TRIP_NOT_FOUND', reason: sql);
      }
      expect(await driver.refusal('select driver_start_trip(@t::uuid)', {'t': trip}), 'TOO_EARLY');
      expect(await driver.refusal('select driver_finish_trip(@t::uuid)', {'t': trip}), 'TRIP_NOT_STARTED');
      expect(await driver.refusal("select driver_mark_boarding(@t::uuid, 'front', 'boarded')", {'t': trip}), 'TOO_EARLY');
      expect(await otherDriver.refusal('select driver_cancel_trip(@t::uuid)', {'t': doneTrip}), 'TRIP_NOT_PLANNED');
      expect(await otherDriver.refusal('select driver_start_trip(@t::uuid)', {'t': doneTrip}), 'TRIP_NOT_PLANNED');
      expect(await otherDriver.refusal('select driver_finish_trip(@t::uuid)', {'t': doneTrip}), 'TRIP_NOT_STARTED');
      expect(await otherDriver.refusal("select driver_mark_boarding(@t::uuid, 'front', 'no_show')", {'t': doneTrip}), 'TRIP_CLOSED',
          reason: 'после завершения отметки не меняются');
      expect(markGarbage, 'BAD_MARK');
      expect(markFreeSeat, 'SEAT_NOT_BOOKED');
      expect(markNullSeat, 'SEAT_NOT_BOOKED');
    });

    test('список пассажиров: пустой и несуществующий рейс дают тот же отказ, что и чужой', () async {
      expect(await intruder.refusal('select * from trip_passengers(null)'), 'FORBIDDEN');
      expect(await intruder.refusal("select * from trip_passengers('00000000-0000-0000-0000-000000000000')"), 'FORBIDDEN');
      expect(await driver.refusal('select * from trip_passengers(null)'), 'FORBIDDEN');
      expect(await ani.refusal('select * from trip_passengers(@t::uuid)', {'t': trip}), 'FORBIDDEN',
          reason: 'пассажир рейса — не водитель рейса');
    });

    test('завершённую поездку пассажир отменить не может: возврата нет', () async {
      expect(await cara.refusal('select cancel_booking(@b::uuid)', {'b': doneBooking}), 'NOT_CANCELLABLE');
      expect(await declined.refusal('select cancel_booking(@b::uuid)', {'b': failedBooking}), 'NOT_CANCELLABLE');
      expect(await total("ledger where booking_id in ('$doneBooking', '$failedBooking') and kind = 'refund'"), 0);
    });
  });

  // =====================================================================================================
  group('сотрудники: каждый только в своём участке', () {
    test('чтение: роль не открывает чужие участки', () async {
      // поддержка: без анкет, выплат, ролей, черновиков маршрутов
      expect(await count(w.support, 'drivers'), 0);
      expect(await count(w.support, 'payouts'), 0);
      expect(await count(w.support, 'staff'), 1);
      expect(await count(w.support, 'routes'), 1);
      // финансы: без чужих профилей (телефонов), журнала действий, ролей, черновиков
      expect(await count(w.finance, 'profiles'), 1);
      expect(await count(w.finance, 'audit_log'), 0);
      expect(await count(w.finance, 'staff'), 1);
      expect(await count(w.finance, 'routes'), 1);
      // проверяющий: без броней, денег, чужих профилей
      expect(await count(w.verifier, 'profiles'), 1);
      expect(await count(w.verifier, 'bookings'), 0);
      expect(await count(w.verifier, 'payments'), 0);
      expect(await count(w.verifier, 'payouts'), 0);
      expect(await count(w.verifier, 'audit_log'), 0);
      expect(await count(w.verifier, 'routes'), 1);
      // модератор: без броней и денег
      expect(await count(w.moderator, 'bookings'), 0);
      expect(await count(w.moderator, 'payments'), 0);
      expect(await count(w.moderator, 'payouts'), 0);
      expect(await count(w.moderator, 'audit_log'), 0);
      expect(await count(w.moderator, 'staff'), 1);
      // чужие карты не видит никто, даже владелец
      for (final a in [w.support, w.finance, w.verifier, w.moderator, w.owner]) {
        expect(await count(a, 'cards'), 0, reason: a.name);
      }
    });

    test('функции: роль не даёт действовать в чужом участке', () async {
      final attempts = <Actor, List<String>>{
        w.support: [
          "select staff_review_driver('${pendingDriver.id}', true)",
          "select staff_save_route(null, 'HACK', 'a', 0, 0, 'b', 0, 0, 1, 1, 1)",
          "select staff_set_route_status('$route', 'archived')",
          'select finance_create_payouts()',
          "select finance_mark_paid('$payout')",
          'select accrue_due()',
        ],
        w.finance: [
          "select staff_block_user('${ani.id}', true)",
          "select staff_review_driver('${pendingDriver.id}', true)",
          "select staff_save_route(null, 'HACK', 'a', 0, 0, 'b', 0, 0, 1, 1, 1)",
          "select staff_set_route_status('$draftRoute', 'published')",
          "select driver_cancel_trip('$trip')",
          "select * from trip_passengers('$trip')",
        ],
        w.verifier: [
          "select staff_block_user('${ani.id}', true)",
          "select staff_save_route(null, 'HACK', 'a', 0, 0, 'b', 0, 0, 1, 1, 1)",
          "select staff_set_route_status('$draftRoute', 'published')",
          'select finance_create_payouts()',
          "select finance_mark_paid('$payout')",
          'select accrue_due()',
          "select driver_cancel_trip('$trip')",
          "select * from trip_passengers('$trip')",
          "select staff_set_roles('${w.verifier.id}', '{verifier,finance}')",
        ],
        w.moderator: [
          "select staff_block_user('${ani.id}', true)",
          "select finance_mark_paid('$payout')",
          'select accrue_due()',
          "select driver_cancel_trip('$trip')",
          "select * from trip_passengers('$trip')",
          "select staff_set_roles('${w.moderator.id}', '{moderator,owner}')",
          "select staff_set_roles('${w.owner.id}', '{}')",
        ],
      };
      for (final e in attempts.entries) {
        for (final sql in e.value) {
          expect(await e.key.refusal(sql), 'FORBIDDEN', reason: '${e.key.name}: $sql');
        }
      }
      expect(await w.scalar("select status::text from trips where id = '$trip'"), 'planned');
      expect(await w.scalar("select status from payouts where id = '$payout'"), 'created');
      expect(await w.scalar("select blocked from profiles where id = '${ani.id}'"), isFalse);
      expect(await total("routes where code = 'HACK'"), 0);
      expect(await w.scalar("select status::text from routes where id = '$draftRoute'"), 'draft');
    });

    test('проверка ролей отвечает только про себя и не поддаётся на мусор', () async {
      for (final r in ['owner', 'support', 'finance', 'verifier', 'moderator', '', "owner' or '1'='1", '%', null]) {
        expect(await intruder.one('select has_role(@r)', {'r': r}), isNot(true), reason: '$r');
      }
      expect(await w.finance.one("select has_role('finance')"), isTrue);
      for (final r in ['owner', 'support', 'verifier', 'moderator']) {
        expect(await w.finance.one('select has_role(@r)', {'r': r}), isFalse, reason: r);
      }
    });

    test('назначение ролей: мусор отклоняется, состав сотрудников не меняется', () async {
      final before = await w.scalar("select string_agg(user_id::text || roles::text, ',' order by user_id) from staff");
      final audit = await total("audit_log where action = 'staff_set_roles'");
      final cases = <String, String>{
        "select staff_set_roles('${ani.id}', '{superadmin}')": 'BAD_ROLES',
        "select staff_set_roles('${ani.id}', '{owner,root}')": 'BAD_ROLES',
        "select staff_set_roles('${ani.id}', '{NULL}')": 'BAD_ROLES',
        "select staff_set_roles('${ani.id}', '{support,NULL}')": 'BAD_ROLES',
        "select staff_set_roles('${ani.id}', '{OWNER}')": 'BAD_ROLES',
        "select staff_set_roles('${ani.id}', '{\"\"}')": 'BAD_ROLES',
        "select staff_set_roles('${ani.id}', '{{owner}}')": 'BAD_ROLES',
        "select staff_set_roles('${ani.id}', '{{support,finance}}')": 'BAD_ROLES',
        "select staff_set_roles('${w.support.id}', '{support,hacker}')": 'BAD_ROLES',
        "select staff_set_roles(null, '{support}')": 'USER_NOT_FOUND',
        "select staff_set_roles(null, null)": 'USER_NOT_FOUND',
        "select staff_set_roles('$nobody', '{support}')": 'USER_NOT_FOUND',
        "select staff_set_roles('$nobody', '{}')": 'USER_NOT_FOUND',
        "select staff_set_roles('$trip', '{support}')": 'USER_NOT_FOUND',
      };
      for (final c in cases.entries) {
        expect(await w.owner.refusal(c.key), c.value, reason: c.key);
      }
      expect(await w.scalar("select string_agg(user_id::text || roles::text, ',' order by user_id) from staff"), before);
      expect(await total("audit_log where action = 'staff_set_roles'"), audit);
      expect(await ani.one("select has_role('support')"), isFalse);
    });

    test('маршруты: мусор от модератора отклоняется; несуществующий маршрут не создаётся', () async {
      // В каждой строке испорчен ровно один аргумент; остальные — как у настоящего маршрута.
      String save({String id = 'null', String code = "'NEW1'", String from = "'Давташен'", String fromLat = '40.2264',
              String fromLon = '44.4930', String to = "'Площадь Республики'", String toLat = '40.1777', String toLon = '44.5126',
              String price = '500', String minutes = '25', String length = '9000', String? color}) =>
          'select staff_save_route($id, $code, $from, $fromLat, $fromLon, $to, $toLat, $toLon, $price, $minutes, $length'
          '${color == null ? '' : ', $color'})';
      final cases = <String, String>{
        save(code: "'lower'"): 'BAD_ARGUMENT',
        save(code: "'A; DROP'"): 'BAD_ARGUMENT',
        save(code: "'TOOLONG99'"): 'BAD_ARGUMENT',
        save(code: "''"): 'BAD_ARGUMENT',
        save(code: 'null'): 'BAD_ARGUMENT',
        save(from: 'null'): 'BAD_ARGUMENT',
        save(from: "'   '"): 'BAD_ARGUMENT',
        save(to: 'null'): 'BAD_ARGUMENT',
        save(to: "''"): 'BAD_ARGUMENT',
        save(fromLat: 'null'): 'BAD_ARGUMENT',
        save(fromLat: '90.1'): 'BAD_ARGUMENT',
        save(fromLat: "'NaN'"): 'BAD_ARGUMENT',
        save(fromLon: '-180.5'): 'BAD_ARGUMENT',
        save(toLat: '-91'): 'BAD_ARGUMENT',
        save(toLat: "'Infinity'"): 'BAD_ARGUMENT',
        save(toLon: 'null'): 'BAD_ARGUMENT',
        save(toLon: '181'): 'BAD_ARGUMENT',
        save(price: 'null'): 'BAD_ARGUMENT',
        save(price: '0'): 'BAD_ARGUMENT',
        save(price: '-1'): 'BAD_ARGUMENT',
        save(price: '1000001'): 'BAD_ARGUMENT',
        save(minutes: 'null'): 'BAD_ARGUMENT',
        save(minutes: '0'): 'BAD_ARGUMENT',
        save(minutes: '601'): 'BAD_ARGUMENT',
        save(length: 'null'): 'BAD_ARGUMENT',
        save(length: '99'): 'BAD_ARGUMENT',
        save(length: '200001'): 'BAD_ARGUMENT',
        save(length: '2147483647'): 'BAD_ARGUMENT',
        save(color: 'null'): 'BAD_ARGUMENT',
        // код занят другим маршрутом: и при создании, и при переименовании
        save(code: "'M1'"): 'ROUTE_CODE_TAKEN',
        save(id: "'$draftRoute'", code: "'M1'"): 'ROUTE_CODE_TAKEN',
        save(id: "'$route'", code: "'DRAFT'"): 'ROUTE_CODE_TAKEN',
        save(id: "'$nobody'", code: "'GHOST'"): 'ROUTE_NOT_FOUND',
        save(id: "'$trip'", code: "'GHOST'"): 'ROUTE_NOT_FOUND',
        // на маршруте M1 стоит рейс: точки, длину и время в пути менять нельзя
        save(id: "'$route'", code: "'M1'", minutes: '26'): 'ROUTE_HAS_ACTIVE_TRIPS',
        save(id: "'$route'", code: "'M1'", length: '9001'): 'ROUTE_HAS_ACTIVE_TRIPS',
        save(id: "'$route'", code: "'M1'", fromLat: '40.2265'): 'ROUTE_HAS_ACTIVE_TRIPS',
        save(id: "'$route'", code: "'M1'", toLon: '44.5127'): 'ROUTE_HAS_ACTIVE_TRIPS',
        "select staff_set_route_status(null, 'published')": 'ROUTE_NOT_FOUND',
        "select staff_set_route_status('$nobody', 'published')": 'ROUTE_NOT_FOUND',
        "select staff_set_route_status('$draftRoute', null)": 'BAD_ARGUMENT',
        "select staff_set_route_status('$draftRoute', 'hacked')": badText,
        "select staff_set_route_status('$route', 'archived')": 'ROUTE_HAS_ACTIVE_TRIPS',
        "select staff_set_route_status('$route', 'draft')": 'ROUTE_HAS_ACTIVE_TRIPS',
      };
      Future<Object?> snapshot() => w.scalar("select string_agg(r::text, ';' order by r.id) from routes r");
      final before = await snapshot();
      final audit = await total("audit_log where entity = 'route'");
      for (final c in cases.entries) {
        expect(await w.moderator.refusal(c.key), c.value, reason: c.key);
      }
      expect(await snapshot(), before, reason: 'ни один маршрут не появился и не изменился');
      expect(await total("audit_log where entity = 'route'"), audit);
      expect(await w.scalar("select status::text from routes where id = '$route'"), 'published');
    });

    test('выплаты и блокировки: пустые и несуществующие номера', () async {
      expect(await w.finance.refusal('select finance_mark_paid(null)'), 'PAYOUT_NOT_FOUND');
      expect(await w.finance.refusal("select finance_mark_paid('00000000-0000-0000-0000-000000000000')"), 'PAYOUT_NOT_FOUND');
      final blocks = await total("audit_log where action in ('block_user', 'unblock_user')");
      expect(await w.support.refusal('select staff_block_user(null, true)'), 'USER_NOT_FOUND');
      expect(await w.support.refusal("select staff_block_user('$nobody', true)"), 'USER_NOT_FOUND');
      expect(await w.support.refusal("select staff_block_user('$nobody', false)"), 'USER_NOT_FOUND');
      expect(await w.support.refusal("select staff_block_user('${ani.id}', null)"), 'BAD_ARGUMENT');
      expect(await w.support.refusal('select staff_block_user(null, null)'), 'BAD_ARGUMENT');
      expect(await w.scalar("select blocked from profiles where id = '${ani.id}'"), isFalse);
      expect(await total("audit_log where action in ('block_user', 'unblock_user')"), blocks);
      // повторный запуск начисления и выплат ничего не добавляет
      final ledger = await total('ledger');
      expect(await w.finance.one('select accrue_due()'), 0);
      expect(await w.finance.one('select finance_create_payouts()'), 0);
      expect(await total('ledger'), ledger);
    });
  });

  // =====================================================================================================
  group('повышение прав и блокировки', () {
    /// Кто из сотрудников заблокирован и какие блокировки записаны в журнал действий.
    Future<Object?> blockState() => w.scalar('''
      select (select coalesce(string_agg(s.user_id::text, ',' order by s.user_id), '')
              from staff s join profiles p on p.id = s.user_id where p.blocked)
          || ' / ' || (select count(*) from audit_log where action in ('block_user', 'unblock_user'))''');

    // ИСПРАВЛЕНО: владельца заблокировать нельзя никому — CANNOT_BLOCK_OWNER (сначала с него снимают роль).
    test('поддержка не может заблокировать владельца', () async {
      final before = await blockState();
      expect(await w.support.refusal("select staff_block_user('${w.owner.id}', true)"), 'CANNOT_BLOCK_OWNER');
      expect(await w.support.refusal("select staff_block_user('${w.owner.id}', false)"), 'FORBIDDEN'); // снять блокировку с сотрудника тоже может только владелец
      expect(await w.scalar("select blocked from profiles where id = '${w.owner.id}'"), isFalse);
      expect(await blockState(), before);
      // владелец по-прежнему управляет ролями
      expect(await w.owner.one("select has_role('owner')"), isTrue);
    });

    // ИСПРАВЛЕНО: сотрудника блокирует только владелец; себя заблокировать нельзя.
    test('блокировка сотрудников: поддержка не блокирует ни себя, ни коллег; владелец не блокирует себя', () async {
      final before = await blockState();
      expect(await w.support.refusal("select staff_block_user('${w.support.id}', true)"), 'CANNOT_BLOCK_SELF');
      expect(await w.owner.refusal("select staff_block_user('${w.owner.id}', true)"), 'CANNOT_BLOCK_SELF');
      for (final a in [w.finance, w.moderator, w.verifier]) {
        expect(await w.support.refusal("select staff_block_user('${a.id}', true)"), 'FORBIDDEN', reason: a.name);
        expect(await w.support.refusal("select staff_block_user('${a.id}', false)"), 'FORBIDDEN', reason: a.name);
      }
      final secondSupport = await w.newStaff('Вторая поддержка', ['support']);
      expect(await w.support.refusal("select staff_block_user('${secondSupport.id}', true)"), 'FORBIDDEN');
      expect(await secondSupport.refusal("select staff_block_user('${w.support.id}', true)"), 'FORBIDDEN');
      expect(await blockState(), before);
      final working = {w.support: 'support', w.finance: 'finance', w.moderator: 'moderator', w.verifier: 'verifier', secondSupport: 'support'};
      for (final e in working.entries) {
        expect(await e.key.one('select has_role(@r)', {'r': e.value}), isTrue, reason: '${e.key.name} по-прежнему работает');
      }
    });

    // ИСПРАВЛЕНО: последний действующий владелец не может лишиться роли — LAST_OWNER.
    test('последнего владельца нельзя лишить роли', () async {
      final before = await w.scalar("select string_agg(user_id::text || roles::text, ',' order by user_id) from staff");
      final audit = await total("audit_log where action = 'staff_set_roles'");
      for (final roles in ["'{}'", 'null', "'{support}'", "'{moderator,verifier,support,finance}'"]) {
        expect(await w.owner.refusal("select staff_set_roles('${w.owner.id}', $roles)"), 'LAST_OWNER', reason: roles);
      }
      final staffNow = await w.scalar("select string_agg(user_id::text || roles::text, ',' order by user_id) from staff");
      // если владельца всё же сняли — возвращаем, чтобы остальные проверки шли на рабочем стенде
      await w.admin.execute(
          "insert into staff (user_id, roles) values ('${w.owner.id}', '{owner}') on conflict (user_id) do update set roles = excluded.roles");
      expect(staffNow, before);
      expect(await total("audit_log where action = 'staff_set_roles'"), audit);
    });

    // Второй владелец, если он заблокирован, «действующим» не считается: первый всё равно не может уйти.
    test('заблокированный второй владелец не считается действующим', () async {
      final spare = await w.newUser('Запасной владелец');
      await w.support.q("select staff_block_user('${spare.id}', true)");
      await w.owner.q("select staff_set_roles('${spare.id}', '{owner}')");
      try {
        expect(await spare.one("select has_role('owner')"), isFalse, reason: 'заблокированный ролей не имеет');
        expect(await spare.refusal("select staff_set_roles('${spare.id}', '{owner}')"), 'BLOCKED');
        expect(await w.owner.refusal("select staff_set_roles('${w.owner.id}', '{}')"), 'LAST_OWNER');
        expect(await total("staff where user_id = '${w.owner.id}' and roles = '{owner}'"), 1);
      } finally {
        await w.owner.refusal("select staff_set_roles('${spare.id}', '{}')");
        await w.admin.execute("delete from staff where user_id = '${spare.id}'");
      }
      expect(await total("staff where 'owner' = any (roles)"), 1);
    });

    test('заблокированный не может вызвать ни одну изменяющую функцию и не может разблокировать себя', () async {
      final exSupport = await w.newStaff('Бывшая поддержка', ['support']);
      // сотрудника блокирует только владелец
      expect(await w.support.refusal("select staff_block_user('${exSupport.id}', true)"), 'FORBIDDEN');
      expect(await w.scalar("select blocked from profiles where id = '${exSupport.id}'"), isFalse);
      await w.owner.q("select staff_block_user('${exSupport.id}', true)");
      final ledger = await total('ledger');
      for (final sql in [
        "select staff_block_user('${exSupport.id}', false)",
        "select staff_block_user('${ani.id}', true)",
        "select staff_refund_booking('$booking', 'жалоба')",
        "select cancel_booking('$booking')",
        "select driver_cancel_trip('$trip')",
        "select * from trip_passengers('$trip')",
        "select apply_driver('a', 'b', 'c', 4, 'd')",
        "select bind_card_sim('4111111111111111')",
        "select register_profile('Новое имя', 'ru')",
        'select driver_earnings()',
      ]) {
        expect(await exSupport.refusal(sql), 'BLOCKED', reason: sql);
      }
      expect(await w.scalar("select blocked from profiles where id = '${exSupport.id}'"), isTrue);
      expect(await w.scalar("select name from profiles where id = '${exSupport.id}'"), 'Бывшая поддержка');
      expect(await w.scalar("select blocked from profiles where id = '${ani.id}'"), isFalse);
      expect(await w.scalar("select status::text || '/' || refund from bookings where id = '$booking'"), 'paid/0');
      expect(await w.scalar("select status::text from trips where id = '$trip'"), 'planned');
      expect(await total('ledger'), ledger);
    });

    // ИСПРАВЛЕНО: has_role для заблокированного сотрудника — «нет»: вместе с функциями он теряет и чтение.
    test('заблокированный сотрудник поддержки больше не читает телефоны пользователей', () async {
      final ex = await w.newStaff('Уволенная поддержка', ['support']);
      // до блокировки читает — значит, доступ закрывает именно блокировка
      expect(await count(ex, "profiles where id <> '${ex.id}'"), greaterThan(0));
      expect(await count(ex, 'bookings'), greaterThan(0));
      expect(await count(ex, 'payments'), greaterThan(0));
      await w.owner.q("select staff_block_user('${ex.id}', true)");
      expect(await ex.one("select has_role('support')"), isFalse);
      expect(await count(ex, "profiles where id <> '${ex.id}'"), 0);
      expect(await ex.one('select max(phone) from profiles'), ex.phone, reason: 'виден только свой профиль');
      expect(await count(ex, 'bookings'), 0);
      expect(await count(ex, 'payments'), 0);
      expect(await ex.refusal(refundSql, {'b': booking, 'r': 'жалоба'}), 'BLOCKED');
      expect(await ex.refusal("select cancel_booking('$booking')"), 'BLOCKED');
      expect(await w.scalar("select status::text || '/' || refund from bookings where id = '$booking'"), 'paid/0');
    });

    // ИСПРАВЛЕНО: то же для финансов — заблокированный финансист не читает ни журнал денег, ни выплаты.
    test('заблокированный финансист больше не читает журнал денег', () async {
      final ex = await w.newStaff('Уволенный финансист', ['finance']);
      expect(await count(ex, 'ledger'), greaterThan(0));
      expect(await count(ex, 'payouts'), greaterThan(0));
      await w.owner.q("select staff_block_user('${ex.id}', true)");
      final payouts = await total('payouts');
      expect(await ex.refusal('select finance_create_payouts()'), 'BLOCKED');
      expect(await ex.refusal("select finance_mark_paid('$payout')"), 'BLOCKED');
      expect(await ex.refusal('select accrue_due()'), 'BLOCKED');
      expect(await ex.one("select has_role('finance')"), isFalse);
      expect(await count(ex, 'ledger'), 0);
      expect(await count(ex, 'payouts'), 0);
      expect(await count(ex, 'payments'), 0);
      expect(await count(ex, 'bookings'), 0);
      expect(await total('payouts'), payouts);
      expect(await w.scalar("select status from payouts where id = '$payout'"), 'created');
    });

    // ИСПРАВЛЕНО: заблокированный пользователь не может менять имя и язык — BLOCKED.
    test('заблокированный не может изменить своё имя', () async {
      final bad = await w.newPassenger('Нарушитель');
      await w.support.q("select staff_block_user('${bad.id}', true)");
      expect(await bad.refusal("select register_profile('Честный человек', 'en')"), 'BLOCKED');
      expect(await w.scalar("select name || '/' || lang || '/' || blocked from profiles where id = '${bad.id}'"), 'Нарушитель/ru/true');
      // поддержка снимает блокировку — имя снова можно менять
      await w.support.q("select staff_block_user('${bad.id}', false)");
      await bad.q("select register_profile('Нарушитель', 'en')");
      expect(await w.scalar("select name || '/' || lang || '/' || blocked from profiles where id = '${bad.id}'"), 'Нарушитель/en/false');
    });

    test('регистрация: телефон берётся только из токена входа и после регистрации не меняется', () async {
      // тот же человек приходит с токеном, где указан чужой телефон: профиль остаётся со старым номером
      final forged = Actor(w, intruder.id, ani.phone, 'Любопытный');
      await forged.q("select register_profile('Любопытный', 'ru')");
      await forged.close();
      expect(await w.scalar("select phone from profiles where id = '${intruder.id}'"), intruder.phone);

      // новый вход, в токене — телефон Ани: второй профиль на её номер не создаётся
      // (каким именно отказом — проверяет следующий тест)
      final id = (await w.admin.execute("insert into auth.users (phone) values ('+37400000077') returning id")).first.first as String;
      final thief = Actor(w, id, ani.phone, 'Вор номера');
      expect(await thief.refusal("select register_profile('Ани', 'ru')"), isNotNull);
      await thief.close();
      expect(await total("profiles where id = '$id'"), 0);
      expect(await total("profiles where phone = '${ani.phone}'"), 1);
      expect(await w.scalar("select id::text from profiles where phone = '${ani.phone}'"), ani.id);

      // вход без телефона (например, по почте): профиль не создаётся
      final id2 = (await w.admin.execute('insert into auth.users (phone) values (null) returning id')).first.first as String;
      final noPhone = Actor(w, id2, '', 'Без телефона');
      expect(await noPhone.refusal("select register_profile('Без телефона', 'ru')"), 'NO_PHONE');
      await noPhone.close();
      expect(await total("profiles where id = '$id2'"), 0);
    });

    // ИСПРАВЛЕНО (низкая): номер телефона занят другим профилем — register_profile отвечает сырой ошибкой базы 23505
    // («duplicate key value violates unique constraint "profiles_phone_key"», в подробностях — сам номер),
    // а не понятным кодом. Так будет и без подделки токена: телефон в профиле после регистрации не меняется,
    // поэтому номер, который прежний владелец сменил во входе, остаётся занят его профилем,
    // и новый человек с этим номером зарегистрироваться не сможет.
    test('регистрация на занятый номер телефона отклоняется понятным отказом', () async {
      final id = (await w.admin.execute("insert into auth.users (phone) values ('+37400000078') returning id")).first.first as String;
      final second = Actor(w, id, ani.phone, 'Второй на номер');
      final text = await message(second, "select register_profile('Второй', 'ru')");
      await second.close();
      expect(await total("profiles where id = '$id'"), 0);
      expect(text, cleanCode, reason: 'приложение получило сырую ошибку базы');
    });

    test('регистрация: мусор в имени и языке отклоняется', () async {
      final cases = <String, String>{
        "select register_profile(null, 'ru')": 'BAD_NAME',
        "select register_profile('', 'ru')": 'BAD_NAME',
        "select register_profile('     ', 'ru')": 'BAD_NAME',
        "select register_profile('${'я' * 61}', 'ru')": 'BAD_NAME',
        "select register_profile(null, null)": 'BAD_NAME',
        "select register_profile('Имя', 'xx')": 'BAD_LANG',
        "select register_profile('Имя', null)": 'BAD_LANG',
        "select register_profile('Имя', '')": 'BAD_LANG',
        "select register_profile('Имя', 'RU')": 'BAD_LANG',
        "select register_profile('Имя', 'ru ')": 'BAD_LANG',
      };
      for (final c in cases.entries) {
        expect(await intruder.refusal(c.key), c.value, reason: c.key);
      }
      expect(await w.scalar("select name || '/' || lang || '/' || blocked from profiles where id = '${intruder.id}'"),
          'Любопытный/ru/false');
      // новый человек с мусором вместо имени профиль не получает
      final id = (await w.admin.execute("insert into auth.users (phone) values ('+37400000079') returning id")).first.first as String;
      final fresh = Actor(w, id, '+37400000079', 'Без имени');
      expect(await fresh.refusal("select register_profile('   ', 'ru')"), 'BAD_NAME');
      expect(await fresh.refusal("select register_profile('Имя', 'de')"), 'BAD_LANG');
      await fresh.close();
      expect(await total("profiles where id = '$id'"), 0);
    });

    test('настройки и часы сервера: только чтение, мусор не ломает', () async {
      final before = await w.scalar("select string_agg(key || '=' || value::text, ',' order by key) from app_settings");
      expect(await intruder.one("select setting_int('commission_percent')"), 10);
      for (final k in ['нет такой', '', "x' or '1'='1", null]) {
        expect(await intruder.one('select setting_int(@k)', {'k': k}), isNull, reason: '$k');
      }
      expect(await intruder.one("select setting_int('max_cards')"), 5);
      final serverNow = await w.now();
      final seen = await intruder.one('select app_now()') as DateTime;
      expect(seen.difference(serverNow).inSeconds.abs(), lessThan(5), reason: 'часы у всех одни');
      expect(await w.scalar("select string_agg(key || '=' || value::text, ',' order by key) from app_settings"), before);
    });
  });

  // =====================================================================================================
  group('водитель, у которого отозвали допуск', () {
    late Actor revoked, rider;
    late String revTrip, startedTrip, revBooking;

    // У водителя два рейса: один уже начат, второй ещё нет и на него куплено место. После этого допуск отзывают.
    setUpAll(() async {
      revoked = await w.newDriver('Отозванный');
      rider = await w.newPassenger('Пассажир отозванного');
      final now = await w.now();
      startedTrip = await revoked.createTrip(route, now.add(const Duration(minutes: 20)), seats: {'front': 600, 'rm': 500});
      revTrip = await revoked.createTrip(route, now.add(const Duration(minutes: 120)), seats: {'front': 600, 'rm': 500});
      revBooking = (await rider.book(revTrip, ['front']))['booking_id'] as String;
      await w.advance(const Duration(minutes: 6));
      await revoked.q("select driver_start_trip('$startedTrip')");
      await w.verifier.q("select staff_review_driver('${revoked.id}', false, 'поддельные документы')");
    });

    tearDownAll(() async {
      // убираем за собой, чтобы итоговая сверка смотрела на чистое состояние:
      // начатый рейс водитель доезжает (завершить можно не раньше времени отправления)
      await w.advance(const Duration(minutes: 15));
      await revoked.refusal("select driver_finish_trip('$startedTrip')");
      await w.support.refusal("select driver_cancel_trip('$revTrip')");
      await w.admin.execute("update drivers set seats_total = 4 where user_id = '${revoked.id}'");
    });

    test('исчезает из витрины и не может поставить новый рейс', () async {
      expect(await count(intruder, "driver_public where user_id = '${revoked.id}'"), 0);
      expect(
          await revoked.refusal(tripSql, {
            'r': route, 'd': (await w.now()).add(const Duration(minutes: 700)).toIso8601String(), 'm': '0',
            's': '[{"id":"front","price":500}]',
          }),
          'DRIVER_NOT_APPROVED');
      expect(await total("trips where driver_id = '${revoked.id}'"), 2);
    });

    // ИСПРАВЛЕНО: при отзыве допуска не начатые рейсы отменяются, пассажирам возвращаются все деньги.
    test('его не начатые рейсы отменены, пассажиру возвращено всё; начатый рейс идёт дальше', () async {
      expect(await w.scalar("select status::text from trips where id = '$revTrip'"), 'cancelled');
      expect(await w.scalar("select status::text from trips where id = '$startedTrip'"), 'started');
      expect(await w.scalar("select status::text || '/' || amount || '/' || refund from bookings where id = '$revBooking'"),
          'cancelled/600/600');
      expect(await rider.one("select status::text || '/' || refund from bookings where id = '$revBooking'"), 'cancelled/600');
      expect(await w.scalar("select coalesce(sum(amount), 0)::int from ledger where booking_id = '$revBooking' and kind = 'refund'"), 600);
      expect(await total("payments where booking_id = '$revBooking' and kind = 'refund' and ok and amount = 600"), 1);
      expect(await total("trip_seats where trip_id = '$revTrip' and booking_id is not null"), 0);
      expect(await total("audit_log where action = 'cancel_trip' and entity_id = '$revTrip' and details ->> 'reason' = 'driver_rejected'"), 1);
    });

    // ИСПРАВЛЕНО: рейс отменён вместе с допуском — TRIP_CLOSED, брони и списания не появляется.
    test('на его рейс больше нельзя купить место', () async {
      final before = await total('bookings');
      final payments = await total('payments');
      expect(await bob.refusal(bookSql, {'t': revTrip, 's': '{front}', 'c': bob.cardId, 'k': 'after-revoke-1'}), 'TRIP_CLOSED');
      expect(await bob.refusal(bookSql, {'t': revTrip, 's': '{rm}', 'c': bob.cardId, 'k': 'after-revoke-2'}), 'TRIP_CLOSED');
      expect(await bob.refusal(bookSql, {'t': startedTrip, 's': '{front}', 'c': bob.cardId, 'k': 'after-revoke-3'}), 'TRIP_CLOSED');
      expect(await total('bookings'), before);
      expect(await total('payments'), payments);
    });

    // ИСПРАВЛЕНО: менять машину нельзя при любом статусе водителя, пока у него есть не завершённый рейс, —
    // DRIVER_HAS_ACTIVE_TRIPS. (На начатом рейсе выставлено среднее место «rm», а в заявке — машина на 3 места.)
    test('не может сменить машину, пока у него есть действующий рейс', () async {
      Future<Object?> card() => w.scalar("select status::text || '/' || car || '/' || seats_total || '/' || coalesce(reject_reason, '') "
          "from drivers where user_id = '${revoked.id}'");
      final before = await card();
      expect(await revoked.refusal(applySql, {'c': 'Smart', 'k': 'красная', 'p': '35 SS 001', 's': '3', 't': '0777'}),
          'DRIVER_HAS_ACTIVE_TRIPS');
      expect(await revoked.refusal(applySql, {'c': 'Toyota Camry', 'k': 'белая', 'p': '35 SS 001', 's': '4', 't': '0777'}),
          'DRIVER_HAS_ACTIVE_TRIPS', reason: 'и с той же машиной: заявка вернула бы статус «на проверке» посреди рейса');
      expect(await card(), before);
      expect(before, 'rejected/Toyota Camry/4/поддельные документы');
      expect(await violations(w), isEmpty);
    });

    // ИСПРАВЛЕНО: начать рейс может только одобренный водитель — DRIVER_NOT_APPROVED.
    test('не может начать рейс', () async {
      expect(await revoked.refusal("select driver_start_trip('$revTrip')"), 'DRIVER_NOT_APPROVED');
      expect(await w.scalar("select status::text || '/' || (started_at is null) from trips where id = '$revTrip'"), 'cancelled/true');
    });
  });

  // =====================================================================================================
  // Вторая линия защиты. Серверные функции не оставляют не начатый рейс у водителя без допуска или под блокировкой
  // (такие рейсы отменяются сразу). Здесь это состояние выставлено напрямую в базе — как если бы первая линия
  // дала сбой, — и проверяется, что продажа и старт рейса закрыты сами по себе.
  group('рейс, оставшийся у водителя без допуска (вторая линия защиты)', () {
    late Actor shadow, buyer;
    late String shadowTrip;

    setUpAll(() async {
      shadow = await w.newDriver('Вторая линия');
      buyer = await w.newPassenger('Покупатель');
      shadowTrip = await shadow.createTrip(route, (await w.now()).add(const Duration(minutes: 20)), seats: {'front': 600});
      await w.advance(const Duration(minutes: 6)); // до отправления 14 минут: продажа ещё открыта, рейс уже можно начать
    });

    Future<void> restore() async {
      await w.admin.execute("update drivers set status = 'approved' where user_id = '${shadow.id}'");
      await w.admin.execute("update profiles set blocked = false where id = '${shadow.id}'");
    }

    tearDownAll(() async {
      await restore();
      await shadow.refusal("select driver_cancel_trip('$shadowTrip')");
    });

    Future<void> expectClosed(String state, String startCode) async {
      final before = await total('bookings');
      final payments = await total('payments');
      expect(await buyer.refusal(bookSql, {'t': shadowTrip, 's': '{front}', 'c': buyer.cardId, 'k': 'shadow-$state'}), 'TRIP_CLOSED',
          reason: state);
      expect(await shadow.refusal("select driver_start_trip('$shadowTrip')"), startCode, reason: state);
      expect(await total('bookings'), before, reason: state);
      expect(await total('payments'), payments, reason: state);
      expect(await w.scalar("select status::text from trips where id = '$shadowTrip'"), 'planned', reason: state);
    }

    test('водитель без допуска (отклонён, на проверке, статус «заблокирован»): место не продаётся, рейс не начинается', () async {
      try {
        for (final status in ['rejected', 'pending', 'blocked']) {
          await w.admin.execute("update drivers set status = '$status' where user_id = '${shadow.id}'");
          await expectClosed(status, 'DRIVER_NOT_APPROVED');
        }
      } finally {
        await restore();
      }
    });

    test('водитель заблокирован: место не продаётся, рейс не начинается', () async {
      try {
        await w.admin.execute("update profiles set blocked = true where id = '${shadow.id}'");
        await expectClosed('profile-blocked', 'BLOCKED');
      } finally {
        await restore();
      }
    });

    test('с допуском и без блокировки тот же рейс продаётся: закрывал его именно статус водителя', () async {
      final sold = await buyer.book(shadowTrip, ['front']);
      expect(sold['status'], 'paid');
      // водитель отменяет рейс — покупателю возвращается всё
      expect(await shadow.one("select driver_cancel_trip('$shadowTrip')"), 1);
      expect(await w.scalar("select status::text || '/' || refund from bookings where id = '${sold['booking_id']}'"), 'cancelled/600');
    });
  });

  // =====================================================================================================
  group('заблокированный водитель', () {
    late Actor blocked, rider;
    late String blockedTrip, blockedBooking;

    setUpAll(() async {
      blocked = await w.newDriver('Заблокированный водитель');
      rider = await w.newPassenger('Пассажир заблокированного');
      blockedTrip = await blocked.createTrip(route, (await w.now()).add(const Duration(minutes: 150)));
      blockedBooking = (await rider.book(blockedTrip, ['front', 'rl']))['booking_id'] as String;
      await w.support.q("select staff_block_user('${blocked.id}', true)");
    });

    tearDownAll(() async {
      await w.support.refusal("select driver_cancel_trip('$blockedTrip')");
    });

    test('сам ничего сделать не может', () async {
      expect(await blocked.refusal("select driver_cancel_trip('$blockedTrip')"), 'BLOCKED');
      expect(await blocked.refusal("select driver_start_trip('$blockedTrip')"), 'BLOCKED');
      expect(await blocked.refusal("select * from trip_passengers('$blockedTrip')"), 'BLOCKED');
      expect(
          await blocked.refusal(tripSql, {
            'r': route, 'd': (await w.now()).add(const Duration(minutes: 800)).toIso8601String(), 'm': '0',
            's': '[{"id":"front","price":500}]',
          }),
          'BLOCKED');
      expect(await total("trips where driver_id = '${blocked.id}'"), 1);
    });

    // ИСПРАВЛЕНО: в витрине показываются только одобренные и не заблокированные водители.
    test('не показывается в витрине водителей', () async {
      expect(await count(intruder, "driver_public where user_id = '${blocked.id}'"), 0);
      expect(await count(rider, "driver_public where user_id = '${blocked.id}'"), 0);
      expect(await count(intruder, "driver_public where name = 'Заблокированный водитель'"), 0);
    });

    // ИСПРАВЛЕНО (низкая, приватность): карточку заблокированного водителя всё же можно вытащить из витрины перебором.
    // Витрина driver_public создана без security_barrier: условие из запроса вычисляется по строке водителя раньше,
    // чем отбор «не заблокирован». Верная догадка о скрытой строке даёт ошибку деления на ноль, неверная — пустой ответ.
    test('скрытую строку витрины нельзя подобрать перебором', () async {
      String guess(int seats) => "select count(*) from driver_public where user_id = '${blocked.id}' and 1 / (seats_total - $seats) > 0";
      final answers = {for (final seats in [3, 4]) seats: await intruder.refusal(guess(seats))};
      expect(answers, {3: null, 4: null}, reason: 'ответ на верную догадку отличается: посторонний узнал, что в машине 4 места');
    });

    // ИСПРАВЛЕНО: при блокировке водителя его не начатые рейсы отменяются, пассажирам возвращаются все деньги.
    test('его не начатые рейсы отменены, пассажиру возвращено всё', () async {
      expect(await w.scalar("select status::text from trips where id = '$blockedTrip'"), 'cancelled');
      expect(await w.scalar("select status::text || '/' || amount || '/' || refund from bookings where id = '$blockedBooking'"),
          'cancelled/1100/1100');
      expect(await rider.one("select status::text || '/' || refund from bookings where id = '$blockedBooking'"), 'cancelled/1100');
      expect(await w.scalar("select coalesce(sum(amount), 0)::int from ledger where booking_id = '$blockedBooking' and kind = 'refund'"), 1100);
      expect(await total("payments where booking_id = '$blockedBooking' and kind = 'refund' and ok and amount = 1100"), 1);
      expect(await total("trip_seats where trip_id = '$blockedTrip' and booking_id is not null"), 0);
      expect(await total("audit_log where action = 'cancel_trip' and entity_id = '$blockedTrip' and details ->> 'reason' = 'driver_blocked'"), 1);
    });

    // ИСПРАВЛЕНО: рейс отменён вместе с блокировкой — TRIP_CLOSED, брони и списания не появляется.
    test('на его рейс нельзя купить место', () async {
      final before = await total('bookings');
      final payments = await total('payments');
      expect(await bob.refusal(bookSql, {'t': blockedTrip, 's': '{front}', 'c': bob.cardId, 'k': 'blocked-driver-1'}), 'TRIP_CLOSED');
      expect(await bob.refusal(bookSql, {'t': blockedTrip, 's': '{rr}', 'c': bob.cardId, 'k': 'blocked-driver-2'}), 'TRIP_CLOSED');
      expect(await total('bookings'), before);
      expect(await total('payments'), payments);
    });

    test('снятие блокировки не возвращает отменённые рейсы и возвращённые деньги', () async {
      await w.support.q("select staff_block_user('${blocked.id}', false)");
      try {
        expect(await w.scalar("select status::text from trips where id = '$blockedTrip'"), 'cancelled');
        expect(await blocked.refusal("select driver_start_trip('$blockedTrip')"), 'TRIP_NOT_PLANNED');
        expect(await w.scalar("select status::text || '/' || refund from bookings where id = '$blockedBooking'"), 'cancelled/1100');
      } finally {
        await w.support.q("select staff_block_user('${blocked.id}', true)");
      }
      expect(await count(intruder, "driver_public where user_id = '${blocked.id}'"), 0);
    });
  });

  // =====================================================================================================
  group('возврат по жалобе: только поддержка', () {
    Future<String> moneyState() async => '${await total('ledger')} / ${await total('payments')} / '
        '${await w.scalar("select string_agg(status::text || ':' || refund, ',' order by id) from bookings")}';

    test('пассажир, водитель и остальные сотрудники вернуть деньги не могут; без входа — тоже', () async {
      final before = await moneyState();
      for (final a in [ani, bob, intruder, driver, otherDriver, w.finance, w.moderator, w.verifier]) {
        expect(await a.refusal(refundSql, {'b': booking, 'r': 'верните деньги'}), 'FORBIDDEN', reason: a.name);
      }
      expect(await cara.refusal(refundSql, {'b': doneBooking, 'r': 'плохая поездка'}), 'FORBIDDEN',
          reason: 'пассажир не возвращает деньги сам себе');
      // отказ не выдаёт, существует ли бронь, и не зависит от причины
      expect(await intruder.refusal(refundSql, {'b': nobody, 'r': 'x'}), 'FORBIDDEN');
      expect(await intruder.refusal(refundSql, {'b': null, 'r': null}), 'FORBIDDEN');
      expect(await intruder.refusal(refundSql, {'b': booking, 'r': injection}), 'FORBIDDEN');
      for (final claims in ['{"role":"anon"}', '{"role":"anon","sub":"${w.support.id}"}', '{"role":"anon","sub":"${w.owner.id}"}']) {
        expect(await rawRefusal('anon', claims, "select staff_refund_booking('$booking', 'жалоба')"), denied, reason: claims);
      }
      expect(await moneyState(), before);
      expect(await w.scalar("select booking_id::text from trip_seats where trip_id = '$trip' and seat_id = 'front'"), booking);
      expect(await total("audit_log where action = 'refund_booking'"), 0);
    });

    test('поддержка: без причины, без брони, после отказа банка и после начисления возврата нет', () async {
      final before = await moneyState();
      for (final reason in [null, '', '   ']) {
        expect(await w.support.refusal(refundSql, {'b': booking, 'r': reason}), 'REASON_REQUIRED', reason: '«$reason»');
      }
      expect(await w.support.refusal(refundSql, {'b': null, 'r': 'жалоба'}), 'BOOKING_NOT_FOUND');
      expect(await w.support.refusal(refundSql, {'b': nobody, 'r': 'жалоба'}), 'BOOKING_NOT_FOUND');
      expect(await w.support.refusal(refundSql, {'b': trip, 'r': 'жалоба'}), 'BOOKING_NOT_FOUND');
      expect(await w.support.refusal(refundSql, {'b': 'not-a-uuid', 'r': 'жалоба'}), badText);
      expect(await w.support.refusal(refundSql, {'b': failedBooking, 'r': 'жалоба'}), 'NOTHING_TO_REFUND',
          reason: 'банк отказал — возвращать нечего');
      expect(await w.support.refusal(refundSql, {'b': doneBooking, 'r': 'жалоба'}), 'ALREADY_ACCRUED',
          reason: 'доли по рейсу уже начислены и выплата создана');
      expect(await w.owner.refusal(refundSql, {'b': doneBooking, 'r': 'жалоба'}), 'ALREADY_ACCRUED', reason: 'и владельцу тоже');
      expect(await moneyState(), before);
      expect(await total("audit_log where action = 'refund_booking'"), 0);
      expect(await w.scalar("select status || '/' || amount from payouts where id = '$payout'"), 'created/516');
    });

    test('поддержка возвращает оплаченную бронь полностью, один раз, с записью в журнал действий', () async {
      final complainer = await w.newPassenger('Жалобщик');
      final mine = (await complainer.book(trip, ['rm']))['booking_id'] as String;
      final ledger = await total('ledger');
      expect(await w.support.one(refundSql, {'b': mine, 'r': '  $injection  '}), 500);
      expect(await w.scalar("select status::text || '/' || amount || '/' || refund from bookings where id = '$mine'"), 'cancelled/500/500');
      expect(await w.scalar("select booking_id::text from trip_seats where trip_id = '$trip' and seat_id = 'rm'"), isNull);
      expect(await w.scalar("select coalesce(sum(amount), 0)::int from ledger where booking_id = '$mine' and kind = 'refund'"), 500);
      expect(await total('ledger'), ledger + 1);
      expect(
          await w.scalar("select actor::text || '|' || (details ->> 'amount') || '|' || (details ->> 'reason') from audit_log "
              "where action = 'refund_booking' and entity_id = '$mine'"),
          '${w.support.id}|500|$injection', reason: 'кто, сколько и почему; причина сохранена как обычный текст');
      // второй раз возвращать нечего — ни поддержке, ни самому пассажиру через отмену
      expect(await w.support.refusal(refundSql, {'b': mine, 'r': 'ещё раз'}), 'NOTHING_TO_REFUND');
      expect(await complainer.refusal("select cancel_booking('$mine')"), 'NOT_CANCELLABLE');
      expect(await total('ledger'), ledger + 1);
      expect(await total("audit_log where action = 'refund_booking'"), 1);
      expect(await total("pg_tables where schemaname = 'public' and tablename = 'bookings'"), 1, reason: 'таблица на месте');
    });
  });

  // =====================================================================================================
  group('строки, похожие на SQL-инъекцию', () {
    test('сохраняются как обычный текст и ничего не выполняют', () async {
      final tables = await total("pg_tables where schemaname = 'public'");
      final staffBefore = await total("staff where 'owner' = any (roles)");
      final bookingsBefore = await total('bookings');

      final inj = await w.newUser('Инъекция');
      const name = "Robert'); drop table profiles; --";
      await inj.q('select register_profile(@n, @l)', {'n': name, 'l': 'ru'});
      expect(await w.scalar("select name from profiles where id = '${inj.id}'"), name);

      await inj.q(applySql, {'c': "'; drop table drivers; --", 'k': "' or 1=1 --", 'p': "'; select 1; --", 's': '4', 't': "1' or '1'='1"});
      expect(await w.scalar("select car from drivers where user_id = '${inj.id}'"), "'; drop table drivers; --");
      expect(await w.scalar("select status::text from drivers where user_id = '${inj.id}'"), 'pending');

      const reason = "'); update drivers set status = 'approved'; --";
      await w.verifier.q('select staff_review_driver(@d::uuid, false, @r)', {'d': inj.id, 'r': reason});
      expect(await w.scalar("select status::text || '|' || reject_reason from drivers where user_id = '${inj.id}'"), 'rejected|$reason');

      await inj.bindCard('4111111111111111');
      expect(await inj.refusal(bookSql, {'t': trip, 's': '{front}', 'c': inj.cardId, 'k': injection}), 'SEAT_TAKEN');
      final mine = await inj.book(trip, ['rr'], idem: injection);
      expect(mine['status'], 'paid');
      expect((await inj.book(trip, ['rr'], idem: injection))['repeat'], isTrue, reason: 'тот же номер операции — та же бронь');
      await inj.cancel(mine['booking_id'] as String);

      expect(await inj.refusal("select driver_mark_boarding(@t::uuid, @s, @m)", {'t': trip, 's': injection, 'm': injection}), 'FORBIDDEN');
      expect(await inj.one('select has_role(@r)', {'r': injection}), isFalse);

      expect(await total("pg_tables where schemaname = 'public'"), tables);
      expect(await total("staff where 'owner' = any (roles)"), staffBefore);
      expect(await total('bookings'), bookingsBefore + 1);
    });
  });

  // =====================================================================================================
  group('без входа', () {
    test('нельзя прочитать ни одну таблицу и вызвать ни одну функцию, включая справочные', () async {
      for (final sql in [
        'select * from app_settings',
        'select count(*) from bookings',
        'select trip_id from trip_seats',
        'select * from drivers',
        'select * from staff',
        'select * from cards',
        'select * from ledger',
        'select * from payments',
        'select * from payouts',
        'select * from audit_log',
        'select * from driver_public',
        'select * from my_ratings',
        'select * from profiles',
        'select * from trips',
        'select * from routes',
        "select has_role('owner')",
        "select setting_int('max_cards')",
        'select app_now()',
        'select accrue_due()',
        'select driver_earnings()',
        'select finance_create_payouts()',
        "select * from trip_passengers('$trip')",
        "select cancel_booking('$booking')",
        "select staff_refund_booking('$booking', 'жалоба')",
        "select staff_block_user('${w.owner.id}', true)",
        "select register_profile('Без входа', 'ru')",
        "select staff_set_roles('${intruder.id}', '{owner}')",
        "select apply_driver('a', 'b', 'c', 4, 'd')",
        "select bind_card_sim('4111111111111111')",
      ]) {
        expect(await rawRefusal('anon', '{"role":"anon"}', sql), denied, reason: sql);
        // даже если без входа подставить в «токен» чужой номер пользователя
        expect(await rawRefusal('anon', '{"role":"anon","sub":"${w.owner.id}"}', sql), denied, reason: 'с чужим sub: $sql');
      }
    });
  });

  // =====================================================================================================
  group('после всех атак', () {
    test('данные целы: все проверки целостности сходятся', () async {
      expect(await violations(w), isEmpty);
    });

    test('брони и деньги пассажиров, на которых нападали, не изменились', () async {
      expect(await w.scalar("select status::text || '/' || amount || '/' || refund from bookings where id = '$booking'"), 'paid/600/0');
      expect(await w.scalar("select status::text || '/' || amount || '/' || refund from bookings where id = '$bobBooking'"), 'paid/500/0');
      expect(await w.scalar("select status::text || '/' || coalesce(rating, 0) from bookings where id = '$doneBooking'"), 'done/2');
      expect(await w.scalar("select booking_id::text from trip_seats where trip_id = '$trip' and seat_id = 'front'"), booking);
      expect(await w.scalar("select status || '/' || amount from payouts where id = '$payout'"), 'created/516');
      expect(await total("staff where 'owner' = any (roles)"), 1);
      expect(await w.scalar("select blocked from profiles where id = '${w.owner.id}'"), isFalse);
    });
  });
}
