// Деньги и время «на излом»: сценарии сверх rules_test.dart.
//
// Каждый сценарий утверждает то, чего требуют бизнес-правила: возврат, списание, доли, выплаты, сроки.
// Пометки в тексте:
//   FINDING:    тест падает — это ошибка сервера (или расхождение сервера с приложением), её надо чинить.
//   AMBIGUITY:  тест проходит и фиксирует, как сервер ведёт себя сейчас, но правило требует решения бизнеса.
//   ИСПРАВЛЕНО: прежняя находка или неясность закрыта изменением сервера; тест утверждает новое правило.
import 'package:postgres/postgres.dart' show ServerException;
import 'package:server_tests/harness.dart';
import 'package:server_tests/invariants.dart';
import 'package:test/test.dart';
import 'package:transport_core/transport_core.dart';

/// Дополнительные проверки денег после каждого теста (строже общих из invariants.dart).
const _strict = <String, String>{
  'по брони возвращено не больше, чем списано': '''
    select count(*) from bookings b
    where (select coalesce(sum(amount), 0) from ledger l where l.booking_id = b.id and l.kind = 'refund')
        > (select coalesce(sum(amount), 0) from ledger l where l.booking_id = b.id and l.kind = 'charge')''',
  'по брони не больше одной записи каждого вида (списание, возврат, доли)': '''
    select count(*) from (
      select booking_id, kind from ledger
      where booking_id is not null and kind in ('charge', 'refund', 'driver_accrual', 'commission', 'state_duty')
      group by booking_id, kind having count(*) > 1) x''',
  'по неудачной брони в журнале денег ничего нет': '''
    select count(*) from ledger l join bookings b on b.id = l.booking_id where b.status = 'failed' ''',
  'доли записаны на водителя этого рейса': '''
    select count(*) from ledger l join trips t on t.id = l.trip_id
    where l.kind in ('driver_accrual', 'commission', 'state_duty') and l.driver_id is distinct from t.driver_id''',
  'сумма выплат равна сумме записей о выплатах в журнале': '''
    select count(*) from (
      select (select coalesce(sum(amount), 0) from payouts) - (select coalesce(sum(amount), 0) from ledger where kind = 'payout') as d
    ) x where d <> 0''',
};

void main() {
  late World w;
  late String route; // базовая цена 500, в пути 25 минут
  late String wide; // базовая цена 1000: цена места от 1 до 3000
  final made = <Actor>[]; // пользователи текущего теста: их подключения закрываются после теста

  const day = Duration(hours: 24, minutes: 5);
  const goodCard = '4111111111111111';
  const badCard = '4111111111110002';
  const bookSql = 'select book_seats(@t::uuid, @s::text[], @c::uuid, @k)';
  const refundSql = 'select staff_refund_booking(@b::uuid, @r)';

  setUpAll(() async {
    w = await World.create('tt_agent_money');
    route = await w.newRoute('A1');
    wide = await w.newRoute('A2', price: 1000);
  });

  tearDown(() async {
    for (final a in made) {
      await a.close();
    }
    made.clear();
    expect(await violations(w), isEmpty, reason: 'целостность данных после теста');
    final broken = <String, int>{};
    for (final e in _strict.entries) {
      final n = await w.scalar(e.value) as int;
      if (n != 0) broken[e.key] = n;
    }
    expect(broken, isEmpty, reason: 'строгие проверки денег после теста');
  });
  tearDownAll(() => w.close());

  // ---------- помощники ----------

  Future<Actor> newDriver(String name, {int seats = 4}) async {
    final a = await w.newDriver(name, seats: seats);
    made.add(a);
    return a;
  }

  Future<Actor> newPax(String name, {String card = goodCard}) async {
    final a = await w.newPassenger(name, card: card);
    made.add(a);
    return a;
  }

  /// Второе подключение того же человека — для одновременных действий.
  Actor twin(Actor a) {
    final t = Actor(w, a.id, a.phone, a.name)..cardId = a.cardId;
    made.add(t);
    return t;
  }

  Future<Actor> newFinance(String name) async {
    final a = await w.newStaff(name, ['finance']);
    made.add(a);
    return a;
  }

  String id(Map<String, dynamic> r) => r['booking_id'] as String;

  Future<DateTime> inMinutes(int m) async => (await w.now()).add(Duration(minutes: m));

  /// Перевести часы сервера так, чтобы наступил момент [t] (назад часы не идут).
  Future<void> advanceTo(DateTime t) async {
    final d = t.difference(await w.now());
    if (d > Duration.zero) await w.advance(d + const Duration(seconds: 1));
  }

  /// Сумма (или число) записей журнала денег данного вида.
  Future<int> led(String kind, {String? booking, String? trip, String? driver, bool count = false}) async {
    final where = ['kind = @k'];
    final p = <String, Object?>{'k': kind};
    if (booking != null) {
      where.add('booking_id = @b::uuid');
      p['b'] = booking;
    }
    if (trip != null) {
      where.add('trip_id = @t::uuid');
      p['t'] = trip;
    }
    if (driver != null) {
      where.add('driver_id = @d::uuid');
      p['d'] = driver;
    }
    final what = count ? 'count(*)' : 'coalesce(sum(amount), 0)';
    return await w.scalar('select $what::int from ledger where ${where.join(' and ')}', p) as int;
  }

  Future<int> distributed(String booking) async =>
      await led('driver_accrual', booking: booking) + await led('commission', booking: booking) + await led('state_duty', booking: booking);

  /// Доли по брони совпадают с расчётом приложения для суммы [kept].
  Future<void> expectSplit(String booking, int kept, {int cp = 10, int sp = 4}) async {
    final s = MoneySplit.of(kept, commissionPercent: cp, statePercent: sp);
    expect(await led('driver_accrual', booking: booking), s.driver, reason: 'доля водителя с $kept');
    expect(await led('commission', booking: booking), s.commission, reason: 'комиссия с $kept');
    expect(await led('state_duty', booking: booking), s.duty, reason: 'госпошлина с $kept');
    expect(await distributed(booking), kept, reason: 'распределено всё до драма');
  }

  Future<void> expectNoSplit(String booking) async => expect(await distributed(booking), 0, reason: 'по брони ничего не распределяется');

  Future<Map> earn(Actor d) async => await d.one('select driver_earnings()') as Map;
  Future<String> bStatus(String b) async => await w.scalar('select status::text from bookings where id = @b::uuid', {'b': b}) as String;
  Future<int> bRefund(String b) async => await w.scalar('select refund from bookings where id = @b::uuid', {'b': b}) as int;
  Future<String> tStatus(String t) async => await w.scalar('select status::text from trips where id = @t::uuid', {'t': t}) as String;
  Future<DateTime> tTime(String t, String col) async => await w.scalar('select $col from trips where id = @t::uuid', {'t': t}) as DateTime;
  Future<String?> seatOwner(String t, String seat) async =>
      await w.scalar('select booking_id::text from trip_seats where trip_id = @t::uuid and seat_id = @s', {'t': t, 's': seat}) as String?;

  /// Сколько всего списано с пассажира и сколько ему возвращено.
  Future<int> paxLedger(Actor p, String kind) async => await w.scalar(
      'select coalesce(sum(l.amount), 0)::int from ledger l join bookings b on b.id = l.booking_id where b.passenger_id = @u::uuid and l.kind = @k',
      {'u': p.id, 'k': kind}) as int;

  Future<int> accrue() async => await w.scalar('select accrue_due()') as int;
  Future<int> payouts() async => await w.finance.one('select finance_create_payouts()') as int;
  Future<int> payoutCount(Actor d) async => await w.scalar('select count(*)::int from payouts where driver_id = @d::uuid', {'d': d.id}) as int;
  Future<int> payoutSum(Actor d) async =>
      await w.scalar('select coalesce(sum(amount), 0)::int from payouts where driver_id = @d::uuid', {'d': d.id}) as int;

  Future<void> start(Actor d, String trip) => d.q('select driver_start_trip(@t::uuid)', {'t': trip});
  Future<void> finish(Actor d, String trip) => d.q('select driver_finish_trip(@t::uuid)', {'t': trip});
  Future<int> cancelTrip(Actor who, String trip) async => await who.one('select driver_cancel_trip(@t::uuid)', {'t': trip}) as int;

  /// Провести рейс: начать за 10 минут до отправления, завершить в минуту отправления (раньше сервер не даёт).
  Future<void> drive(Actor d, String trip, DateTime dep) async {
    await advanceTo(dep.subtract(const Duration(minutes: 10)));
    await start(d, trip);
    await advanceTo(dep);
    await finish(d, trip);
  }

  Future<void> setting(String key, int v) => w.scalar("update app_settings set value = to_jsonb(@v::int) where key = @k", {'v': '$v', 'k': key});

  /// Попытка изменить настройку: код отказа базы или null, если значение принято.
  Future<String?> settingRefusal(String key, int v) async {
    try {
      await setting(key, v);
      return null;
    } on ServerException catch (e) {
      return RegExp(r'^[A-Z][A-Z0-9_]+').stringMatch(e.message) ?? (e.code ?? 'ERROR');
    }
  }

  /// Возврат по жалобе от имени сотрудника [who]: сколько вернули.
  Future<int> staffRefund(Actor who, String booking, [String reason = 'жалоба пассажира']) async =>
      await who.one(refundSql, {'b': booking, 'r': reason}) as int;

  Future<int> ledgerRows() async => await w.scalar('select count(*)::int from ledger') as int;

  /// Деньги по рейсу до драма: сколько списано, сколько возвращено и сколько распределено на доли.
  Future<void> expectTripMoney(String trip, {required int charged, required int refunded, required int shared}) async {
    expect(await led('charge', trip: trip), charged, reason: 'списано по рейсу');
    expect(await led('refund', trip: trip), refunded, reason: 'возвращено по рейсу');
    expect(await led('driver_accrual', trip: trip) + await led('commission', trip: trip) + await led('state_duty', trip: trip), shared,
        reason: 'распределено по рейсу');
  }

  /// Довести до конца всё, что осталось от прошлых тестов: рейсы закрыты, доли начислены и выплачены.
  Future<void> settle() async {
    await w.advance(const Duration(days: 3));
    await accrue();
    await payouts();
  }

  /// Действие, которое может получить отказ: возвращает ответ или сам отказ.
  Future<Object?> attempt(Future<Object?> Function() f) async {
    try {
      return await f();
    } on Refused catch (e) {
      return e;
    }
  }

  /// «Затвор» для одновременных действий. Служебное подключение ненадолго блокирует строки рейсов [trips]; за это время
  /// действия [actions] отправляются по порядку с шагом [gapMs] и встают в очередь за этими строками. Когда затвор
  /// отпускает строки, все участники уже ждут и срабатывают действительно одновременно, в порядке очереди.
  /// Внутри [actions] нельзя обращаться к базе от имени сервера (w.scalar, accrue, led…): служебное подключение занято.
  Future<List<Object?>> gated(List<String> trips, List<Future<Object?> Function()> actions, {int gapMs = 40}) async {
    final hold = w.scalar(
        'with l as materialized (select id from trips where id = any (@ids::uuid[]) for update) '
        'select (pg_sleep(@s::float8))::text from (select count(*) from l) c',
        {'ids': '{${trips.join(',')}}', 's': '${(150 + actions.length * gapMs + 2500) / 1000}'});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final running = <Future<Object?>>[];
    for (final a in actions) {
      running.add(attempt(a));
      await Future<void>.delayed(Duration(milliseconds: gapMs));
    }
    await hold;
    return Future.wait(running);
  }

  // =====================================================================================
  group('доли: комиссия, госпошлина, водитель', () {
    test('некруглые цены: доли по каждой брони совпадают с расчётом приложения до драма', () async {
      const prices = [1, 3, 7, 10, 25, 99, 149, 333, 1000, 1501, 2999, 50];
      const seatIds = ['front', 'rl', 'rm', 'rr'];
      final pass = await newPax('Счётный');
      final dep = await inMinutes(40);
      final booked = <String, int>{}; // бронь → цена
      final trips = <(Actor, String, int)>[];
      for (var i = 0; i < prices.length; i += 4) {
        final d = await newDriver('Водитель цен $i');
        final seats = {for (var j = 0; j < 4; j++) seatIds[j]: prices[i + j]};
        final trip = await d.createTrip(wide, dep, seats: seats);
        var sumDriver = 0;
        for (final s in seatIds) {
          final r = await pass.book(trip, [s]);
          expect(r['status'], 'paid');
          expect(r['amount'], seats[s]);
          booked[id(r)] = seats[s]!;
          sumDriver += MoneySplit.of(seats[s]!).driver;
        }
        trips.add((d, trip, sumDriver));
      }
      for (final (d, trip, _) in trips) {
        await drive(d, trip, dep);
      }
      await w.advance(day);
      await accrue();
      for (final e in booked.entries) {
        await expectSplit(e.key, e.value);
      }
      // Несколько значений посчитаны вручную — чтобы тест не зависел только от формулы приложения.
      Future<List<int>> parts(int price) async {
        final b = booked.entries.firstWhere((e) => e.value == price).key;
        return [await led('driver_accrual', booking: b), await led('commission', booking: b), await led('state_duty', booking: b)];
      }

      expect(await parts(1), [1, 0, 0]);
      expect(await parts(7), [7, 0, 0]);
      expect(await parts(10), [9, 1, 0]);
      expect(await parts(25), [22, 2, 1]);
      expect(await parts(99), [87, 9, 3]);
      expect(await parts(333), [287, 33, 13]);
      expect(await parts(1501), [1291, 150, 60]);
      expect(await parts(2999), [2581, 299, 119]);
      for (final (d, _, sumDriver) in trips) {
        final e = await earn(d);
        expect(e['accrued'], sumDriver);
        expect(e['to_pay'], sumDriver);
      }
    });

    test('бронь на несколько мест: доли считаются с суммы брони, а не по каждому месту', () async {
      final d = await newDriver('Три по 99');
      final p = await newPax('Семья');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(wide, dep, seats: {'front': 99, 'rl': 99, 'rr': 99});
      final r = await p.book(trip, ['front', 'rl', 'rr']);
      expect(r['amount'], 297);
      await drive(d, trip, dep);
      await w.advance(day);
      await accrue();
      await expectSplit(id(r), 297);
      expect(await led('commission', booking: id(r)), 29, reason: '297 * 10 / 100 = 29 (по местам было бы 27)');
      expect(await led('state_duty', booking: id(r)), 11, reason: '297 * 4 / 100 = 11 (по местам было бы 9)');
      expect(await led('driver_accrual', booking: id(r)), 257);
    });

    test('два места одной бронью: доля водителя за рейс равна той, что показывает приложение', () async {
      final d = await newDriver('Одна бронь');
      final p = await newPax('Двое');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(wide, dep, seats: {'front': 99, 'rl': 99});
      await p.book(trip, ['front', 'rl']);
      await drive(d, trip, dep);
      await w.advance(day);
      await accrue();
      expect(await led('driver_accrual', trip: trip), MoneySplit.of(198).driver);
      expect(await led('driver_accrual', trip: trip), 172);
    });

    // ИСПРАВЛЕНО (решением, не кодом сервера): правило — доли округляются по каждой брони отдельно, как считает сервер.
    // Два места по 99 драм двумя бронями дают водителю 87 + 87 = 174 драма. Приложение водителя пока показывает
    // MoneySplit.of(сумма рейса) = 172 (apps/driver/lib/home.dart) — его переведут на сумму долей по броням.
    test('два места двумя бронями: доля водителя за рейс — сумма долей по броням (87 + 87 = 174), а не доля с суммы рейса', () async {
      final d = await newDriver('Две брони');
      final p1 = await newPax('Первый');
      final p2 = await newPax('Второй');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(wide, dep, seats: {'front': 99, 'rl': 99});
      final b1 = await p1.book(trip, ['front']);
      final b2 = await p2.book(trip, ['rl']);
      await drive(d, trip, dep);
      await w.advance(day);
      await accrue();
      await expectSplit(id(b1), 99); // по каждой брони расчёт верный: 87 + 9 + 3
      await expectSplit(id(b2), 99);
      expect(await led('driver_accrual', trip: trip), MoneySplit.of(99).driver + MoneySplit.of(99).driver);
      expect(await led('driver_accrual', trip: trip), 174);
      expect(await led('commission', trip: trip), 9 + 9);
      expect(await led('state_duty', trip: trip), 3 + 3);
      await expectTripMoney(trip, charged: 198, refunded: 0, shared: 198);
      expect(await earn(d), {'accrued': 174, 'paid_out': 0, 'to_pay': 174});
      expect(MoneySplit.of(198).driver, 172, reason: 'расчёт с суммы рейса дал бы на 2 драма меньше — так считать нельзя');
    });

    test('оценка поездки ничего не меняет в деньгах', () async {
      final d = await newDriver('Оцениваемый');
      final p1 = await newPax('Строгий');
      final p2 = await newPax('Добрый');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      final b1 = await p1.book(trip, ['front']);
      final b2 = await p2.book(trip, ['rl']);
      await drive(d, trip, dep);
      final before = await w.scalar('select count(*)::int from ledger') as int;
      final sumBefore = await w.scalar('select coalesce(sum(amount), 0)::int from ledger') as int;
      await p1.q('select rate_booking(@b::uuid, 1)', {'b': id(b1)});
      await p2.q('select rate_booking(@b::uuid, 5)', {'b': id(b2)});
      expect(await w.scalar('select count(*)::int from ledger'), before);
      expect(await w.scalar('select coalesce(sum(amount), 0)::int from ledger'), sumBefore);
      expect(await bRefund(id(b1)), 0, reason: 'плохая оценка — не возврат');
      await w.advance(day);
      await accrue();
      await expectSplit(id(b1), 600);
      await expectSplit(id(b2), 500);
      expect((await earn(d))['accrued'], 516 + 430);
    });

    test('отметка «не пришёл»: водитель всё равно получает долю, пассажиру ничего не возвращается', () async {
      final d = await newDriver('Ждал');
      final came = await newPax('Пришёл');
      final missed = await newPax('Не пришёл');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      final b1 = await came.book(trip, ['front']);
      final b2 = await missed.book(trip, ['rl']);
      await advanceTo(dep.subtract(const Duration(minutes: 10)));
      await start(d, trip);
      await d.q("select driver_mark_boarding(@t::uuid, 'front', 'boarded')", {'t': trip});
      await d.q("select driver_mark_boarding(@t::uuid, 'rl', 'no_show')", {'t': trip});
      await advanceTo(dep); // раньше времени отправления рейс завершить нельзя
      await finish(d, trip);
      await w.advance(day);
      await accrue();
      await expectSplit(id(b1), 600);
      await expectSplit(id(b2), 500);
      expect(await bStatus(id(b2)), 'done');
      expect(await bRefund(id(b2)), 0);
      expect(await led('refund', trip: trip), 0);
      expect((await earn(d))['accrued'], 516 + 430);
    });
  });

  // =====================================================================================
  group('отмены и возвраты', () {
    test('один рейс: поездка, поздняя отмена, ранняя отмена и отказ банка — доли только с удержанного', () async {
      final d = await newDriver('Смешанный');
      final a = await newPax('Едет');
      final b = await newPax('Поздно');
      final c = await newPax('Рано');
      final x = await newPax('Отказ', card: badCard);
      final dep = await inMinutes(125);
      final trip = await d.createTrip(wide, dep, seats: {'front': 333, 'rl': 1501, 'rm': 99, 'rr': 7});
      final ba = await a.book(trip, ['front']);
      final bb = await b.book(trip, ['rl']);
      final bc = await c.book(trip, ['rm']);
      final bx = await x.book(trip, ['rr']);
      expect(bx['status'], 'failed');
      expect((await c.cancel(id(bc)))['refund'], 99);
      await advanceTo(dep.subtract(const Duration(minutes: 59)));
      expect((await b.cancel(id(bb)))['refund'], 0);
      await drive(d, trip, dep);
      await w.advance(day);
      await accrue();

      await expectSplit(id(ba), 333);
      await expectSplit(id(bb), 1501);
      await expectNoSplit(id(bc));
      await expectNoSplit(id(bx));
      expect(await led('charge', trip: trip), 333 + 1501 + 99);
      expect(await led('refund', trip: trip), 99);
      expect(await led('driver_accrual', trip: trip) + await led('commission', trip: trip) + await led('state_duty', trip: trip), 333 + 1501);
      expect((await earn(d))['accrued'], 287 + 1291);
      expect([await bStatus(id(ba)), await bStatus(id(bb)), await bStatus(id(bc)), await bStatus(id(bx))], ['done', 'cancelled', 'cancelled', 'failed']);
    });

    test('две брони одного пассажира на один рейс: отмена одной не трогает другую', () async {
      final d = await newDriver('Двойной');
      final p = await newPax('Дважды');
      final dep = await inMinutes(125);
      final trip = await d.createTrip(route, dep);
      final b1 = await p.book(trip, ['front']);
      final b2 = await p.book(trip, ['rl']);
      expect(id(b1), isNot(id(b2)));
      expect((await p.cancel(id(b1)))['refund'], 600);
      expect(await seatOwner(trip, 'front'), isNull);
      expect(await seatOwner(trip, 'rl'), id(b2));
      await drive(d, trip, dep);
      await w.advance(day);
      await accrue();
      await expectNoSplit(id(b1));
      await expectSplit(id(b2), 500);
      expect(await paxLedger(p, 'charge'), 1100);
      expect(await paxLedger(p, 'refund'), 600);
      expect((await earn(d))['accrued'], 430);
    });

    test('место после отмены с возвратом куплено другим пассажиром: доли только по второй брони', () async {
      final d = await newDriver('Перепродажа');
      final p1 = await newPax('Передумал');
      final p2 = await newPax('Подхватил');
      final dep = await inMinutes(125);
      final trip = await d.createTrip(route, dep);
      final b1 = await p1.book(trip, ['front']);
      expect((await p1.cancel(id(b1)))['refund'], 600);
      final b2 = await p2.book(trip, ['front']);
      expect(b2['status'], 'paid');
      expect(await seatOwner(trip, 'front'), id(b2));
      await drive(d, trip, dep);
      await w.advance(day);
      await accrue();
      await expectNoSplit(id(b1));
      await expectSplit(id(b2), 600);
      expect(await led('charge', trip: trip), 1200);
      expect(await led('refund', trip: trip), 600);
      expect((await earn(d))['accrued'], 516);
    });

    test('пассажир трижды покупает и дважды отменяет одно место: в итоге оплачено ровно одно', () async {
      final d = await newDriver('Терпеливый');
      final p = await newPax('Нерешительный');
      final dep = await inMinutes(125);
      final trip = await d.createTrip(route, dep);
      final ids = <String>[];
      for (var i = 0; i < 3; i++) {
        final r = await p.book(trip, ['rr']);
        expect(r['status'], 'paid');
        ids.add(id(r));
        if (i < 2) expect((await p.cancel(id(r)))['refund'], 500);
      }
      expect(ids.toSet().length, 3);
      expect(await paxLedger(p, 'charge'), 1500);
      expect(await paxLedger(p, 'refund'), 1000);
      await drive(d, trip, dep);
      await w.advance(day);
      await accrue();
      await expectNoSplit(ids[0]);
      await expectNoSplit(ids[1]);
      await expectSplit(ids[2], 500);
    });

    test('бронь на два места, поздняя отмена: оба места остаются за пассажиром, доля — с полной суммы', () async {
      final d = await newDriver('Два места');
      final p = await newPax('Пара');
      final other = await newPax('Желающий');
      final dep = await inMinutes(90);
      final trip = await d.createTrip(wide, dep, seats: {'front': 333, 'rl': 149});
      final b = await p.book(trip, ['front', 'rl']);
      await advanceTo(dep.subtract(const Duration(minutes: 50)));
      expect((await p.cancel(id(b)))['refund'], 0);
      expect(await seatOwner(trip, 'front'), id(b));
      expect(await seatOwner(trip, 'rl'), id(b));
      expect(await other.refusal(bookSql, {'t': trip, 's': '{rl}', 'c': other.cardId, 'k': w.nextKey()}), 'SEAT_TAKEN');
      await drive(d, trip, dep);
      await w.advance(day);
      await accrue();
      await expectSplit(id(b), 482);
      expect(await bStatus(id(b)), 'cancelled');
    });

    test('бронь на два места, ранняя отмена: возврат одной записью на всю сумму, оба места снова в продаже', () async {
      final d = await newDriver('Освободил');
      final p = await newPax('Двое передумали');
      final other = await newPax('Взял оба');
      final dep = await inMinutes(125);
      final trip = await d.createTrip(wide, dep, seats: {'front': 333, 'rl': 149});
      final b = await p.book(trip, ['front', 'rl']);
      expect((await p.cancel(id(b)))['refund'], 482);
      expect(await led('refund', booking: id(b), count: true), 1);
      expect(await led('refund', booking: id(b)), 482);
      final b2 = await other.book(trip, ['rl', 'front']);
      expect(b2['status'], 'paid');
      expect(b2['amount'], 482);
    });

    test('поздняя отмена, потом водитель отменил рейс: полный возврат одной записью, начислений нет никогда', () async {
      final d = await newDriver('Отменил');
      final p = await newPax('Поздний');
      final dep = await inMinutes(90);
      final trip = await d.createTrip(route, dep);
      final b = await p.book(trip, ['front']);
      await advanceTo(dep.subtract(const Duration(minutes: 50)));
      expect((await p.cancel(id(b)))['refund'], 0);
      expect(await cancelTrip(d, trip), 1);
      expect(await bRefund(id(b)), 600);
      expect(await led('refund', booking: id(b), count: true), 1);
      expect(await led('refund', booking: id(b)), 600);
      await w.advance(const Duration(days: 3));
      await accrue();
      await expectNoSplit(id(b));
      expect((await earn(d))['accrued'], 0);
      expect(await tStatus(trip), 'cancelled');
    });

    test('водитель отменил рейс после части возвратов: уже возвращённое не возвращается второй раз', () async {
      final d = await newDriver('Частичный');
      final p1 = await newPax('Вернул сам');
      final p2 = await newPax('Оплатил');
      final p3 = await newPax('Опоздал');
      final x = await newPax('С отказом', card: badCard);
      final dep = await inMinutes(125);
      final trip = await d.createTrip(route, dep);
      final b1 = await p1.book(trip, ['front']);
      final b2 = await p2.book(trip, ['rl']);
      final b3 = await p3.book(trip, ['rr']);
      expect((await p1.cancel(id(b1)))['refund'], 600);
      final bx = await x.book(trip, ['front']);
      expect(bx['status'], 'failed');
      await advanceTo(dep.subtract(const Duration(minutes: 30)));
      expect((await p3.cancel(id(b3)))['refund'], 0);

      expect(await cancelTrip(d, trip), 2, reason: 'возврат сейчас получают двое: оплативший и опоздавший с отменой');
      expect([await bRefund(id(b1)), await bRefund(id(b2)), await bRefund(id(b3))], [600, 500, 500]);
      for (final b in [b1, b2, b3]) {
        expect(await led('refund', booking: id(b), count: true), 1);
      }
      expect(await bStatus(id(bx)), 'failed');
      expect(await bRefund(id(bx)), 0);
      expect(await led('charge', trip: trip), 1600);
      expect(await led('refund', trip: trip), 1600);
      expect(await d.refusal('select driver_cancel_trip(@t::uuid)', {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await led('refund', trip: trip), 1600);
    });

    test('рейс отменяют одновременно водитель (дважды) и поддержка: возврат каждому один раз', () async {
      final d = await newDriver('Торопливый');
      final p1 = await newPax('Раз');
      final p2 = await newPax('Два');
      final trip = await d.createTrip(route, await inMinutes(125));
      final b1 = await p1.book(trip, ['front']);
      final b2 = await p2.book(trip, ['rl', 'rr']);
      final results = await Future.wait([
        attempt(() => cancelTrip(d, trip)),
        attempt(() => cancelTrip(twin(d), trip)),
        attempt(() => cancelTrip(w.support, trip)),
      ]);
      expect(results.whereType<int>(), [2], reason: 'прошла ровно одна отмена: $results');
      expect(results.whereType<Refused>().map((e) => e.code).toSet(), {'TRIP_NOT_PLANNED'});
      expect(await led('refund', booking: id(b1)), 600);
      expect(await led('refund', booking: id(b2)), 1000);
      expect(await led('refund', trip: trip, count: true), 2);
    });

    test('одну бронь отменяют одновременно пассажир (дважды) и поддержка: возврат один', () async {
      final d = await newDriver('Наблюдатель');
      final p = await newPax('Нажал трижды');
      final trip = await d.createTrip(route, await inMinutes(125));
      final b = await p.book(trip, ['front']);
      final results = await Future.wait([
        attempt(() => p.cancel(id(b))),
        attempt(() => twin(p).cancel(id(b))),
        attempt(() async => await w.support.one('select cancel_booking(@b::uuid)', {'b': id(b)})),
      ]);
      expect(results.whereType<Map>().length, 1, reason: 'прошла ровно одна отмена: $results');
      expect((results.whereType<Map>().single)['refund'], 600);
      expect(results.whereType<Refused>().map((e) => e.code).toSet(), {'NOT_CANCELLABLE'});
      expect(await led('refund', booking: id(b), count: true), 1);
      expect(await led('refund', booking: id(b)), 600);
      expect(await seatOwner(trip, 'front'), isNull);
    });

    test('пассажир отменяет бронь, а водитель в тот же миг — рейс: возврат ровно один и полный', () async {
      final d = await newDriver('Гонка');
      final p = await newPax('Гонщик');
      final start0 = await inMinutes(125);
      for (var i = 0; i < 5; i++) {
        final trip = await d.createTrip(route, start0.add(Duration(minutes: 30 * i)));
        final b = await p.book(trip, ['front']);
        final results = await Future.wait([attempt(() => p.cancel(id(b))), attempt(() => cancelTrip(d, trip))]);
        expect(results[1], isA<int>(), reason: 'отмена рейса проходит всегда: $results');
        if (results[0] is Refused) expect((results[0] as Refused).code, 'NOT_CANCELLABLE');
        expect(await led('refund', booking: id(b), count: true), 1, reason: 'попытка $i: $results');
        expect(await led('refund', booking: id(b)), 600);
        expect(await bRefund(id(b)), 600);
        expect(await tStatus(trip), 'cancelled');
      }
      expect(await paxLedger(p, 'charge'), 3000);
      expect(await paxLedger(p, 'refund'), 3000);
    });

    test('после начала рейса и после его конца бронь отменить нельзя, денег не возвращают', () async {
      final d = await newDriver('В пути');
      final p = await newPax('Опомнился');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      final b = await p.book(trip, ['front']);
      await advanceTo(dep.subtract(const Duration(minutes: 10)));
      await start(d, trip);
      expect(await p.refusal('select cancel_booking(@b::uuid)', {'b': id(b)}), 'TRIP_ALREADY_STARTED');
      expect(await w.support.refusal('select cancel_booking(@b::uuid)', {'b': id(b)}), 'TRIP_ALREADY_STARTED');
      expect(await d.refusal('select driver_cancel_trip(@t::uuid)', {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await bStatus(id(b)), 'paid');
      await advanceTo(dep); // раньше времени отправления рейс завершить нельзя
      await finish(d, trip);
      expect(await p.refusal('select cancel_booking(@b::uuid)', {'b': id(b)}), 'NOT_CANCELLABLE');
      expect(await w.support.refusal('select cancel_booking(@b::uuid)', {'b': id(b)}), 'NOT_CANCELLABLE');
      expect(await led('refund', booking: id(b)), 0);
      expect(await bStatus(id(b)), 'done');
      await w.advance(day);
      await accrue();
      await expectSplit(id(b), 600);
    });

    test('поддержка отменяет бронь по тем же правилам; посторонний отменить не может', () async {
      final d = await newDriver('С поддержкой');
      final p1 = await newPax('Просит рано');
      final p2 = await newPax('Просит поздно');
      final stranger = await newPax('Посторонний');
      final dep = await inMinutes(180);
      final trip = await d.createTrip(route, dep);
      final b1 = await p1.book(trip, ['front']);
      final b2 = await p2.book(trip, ['rl']);
      expect(await stranger.refusal('select cancel_booking(@b::uuid)', {'b': id(b1)}), 'BOOKING_NOT_FOUND');
      expect(await d.refusal('select cancel_booking(@b::uuid)', {'b': id(b1)}), 'BOOKING_NOT_FOUND', reason: 'водитель чужую бронь не отменяет');
      expect(await bStatus(id(b1)), 'paid');
      expect((await w.support.one('select cancel_booking(@b::uuid)', {'b': id(b1)}) as Map)['refund'], 600);
      expect(await led('refund', booking: id(b1)), 600);
      await advanceTo(dep.subtract(const Duration(minutes: 30)));
      expect((await w.support.one('select cancel_booking(@b::uuid)', {'b': id(b2)}) as Map)['refund'], 0);
      expect(await led('refund', booking: id(b2)), 0);
      expect(await seatOwner(trip, 'rl'), id(b2));
    });

    test('карта удалена после покупки: возврат всё равно проходит', () async {
      final d = await newDriver('Без карты');
      final p = await newPax('Удалил карту');
      final trip = await d.createTrip(route, await inMinutes(125));
      final b = await p.book(trip, ['front']);
      await p.q('select remove_card(@c::uuid)', {'c': p.cardId});
      expect((await p.cancel(id(b)))['refund'], 600);
      expect(await paxLedger(p, 'refund'), 600);
    });

    test('заблокированный пассажир сам отменить не может; поддержка отменяет за него с полным возвратом', () async {
      final d = await newDriver('Ни при чём');
      final p = await newPax('Заблокированный');
      final trip = await d.createTrip(route, await inMinutes(180));
      final b = await p.book(trip, ['front']);
      await w.support.q('select staff_block_user(@u::uuid, true)', {'u': p.id});
      try {
        // AMBIGUITY: заблокированный пассажир не может сам отменить оплаченную бронь даже задолго до рейса.
        expect(await p.refusal('select cancel_booking(@b::uuid)', {'b': id(b)}), 'BLOCKED');
        expect((await w.support.one('select cancel_booking(@b::uuid)', {'b': id(b)}) as Map)['refund'], 600);
        expect(await led('refund', booking: id(b)), 600);
      } finally {
        await w.support.q('select staff_block_user(@u::uuid, false)', {'u': p.id});
      }
    });
  });

  // =====================================================================================
  group('сроки', () {
    test('отмена за 120, 61, 59 и 10 минут: сервер возвращает ровно столько, сколько обещает приложение', () async {
      final d = await newDriver('Часы');
      final dep = await inMinutes(130);
      final trip = await d.createTrip(route, dep, seats: {'front': 600, 'rl': 500, 'rm': 450, 'rr': 400});
      const plan = [(120, 'front', 600), (61, 'rl', 500), (59, 'rm', 450), (10, 'rr', 400)];
      final books = <String, (Actor, String)>{};
      for (final (_, seat, _) in plan) {
        final p = await newPax('Отмена $seat');
        books[seat] = (p, id(await p.book(trip, [seat])));
      }
      for (final (mins, seat, amount) in plan) {
        await advanceTo(dep.subtract(Duration(minutes: mins)));
        final (p, b) = books[seat]!;
        final app = refundFor(amount: amount, pickupTime: dep, now: await w.now());
        final r = await p.cancel(b);
        expect(r['refund'], mins >= 60 ? amount : 0, reason: 'отмена за $mins минут');
        expect(r['refund'], app, reason: 'приложение обещало $app за $mins минут');
        expect(await led('refund', booking: b), r['refund']);
        expect(await seatOwner(trip, seat), mins >= 60 ? isNull : b);
      }
    });

    test('куплено за полчаса до рейса и сразу отменено: возврата нет', () async {
      // AMBIGUITY: правило «позже чем за 60 минут — без возврата» действует и на бронь, купленную минуту назад.
      final d = await newDriver('Скоро едет');
      final p = await newPax('Ошибся рейсом');
      final dep = await inMinutes(30);
      final trip = await d.createTrip(route, dep);
      final b = await p.book(trip, ['front']);
      expect((await p.cancel(id(b)))['refund'], 0);
      expect(await seatOwner(trip, 'front'), id(b));
      await drive(d, trip, dep);
      await w.advance(day);
      await accrue();
      await expectSplit(id(b), 600);
    });

    // ИСПРАВЛЕНО: рейс, который водитель так и не начал, больше не считается состоявшимся: через 2 часа после конца
    // по расписанию он отменяется сам, пассажирам возвращается всё. Сам закрывается только начатый рейс.
    test('забытый рейс: до 2 часов после конца не трогается; начатый закрыт концом по расписанию, доля через 24 часа от него; не начатый отменён с полным возвратом', () async {
      final d1 = await newDriver('Начал и забыл');
      final d2 = await newDriver('Не начинал');
      final p = await newPax('Пассажир забытых');
      final dep = await inMinutes(30);
      final t1 = await d1.createTrip(route, dep);
      final t2 = await d2.createTrip(route, dep);
      final b1 = await p.book(t1, ['front']);
      final b2 = await p.book(t2, ['rl']);
      await advanceTo(dep.subtract(const Duration(minutes: 10)));
      await start(d1, t1);
      final ends = await tTime(t1, 'ends_at');
      expect(ends.isAtSameMomentAs(dep.add(const Duration(minutes: 25))), isTrue);

      await advanceTo(ends.add(const Duration(hours: 1, minutes: 59)));
      await accrue();
      expect([await tStatus(t1), await tStatus(t2)], ['started', 'planned'], reason: 'до двух часов после конца рейс не трогается');
      expect([await bStatus(id(b1)), await bStatus(id(b2))], ['paid', 'paid']);
      expect(await paxLedger(p, 'refund'), 0);

      await advanceTo(ends.add(const Duration(hours: 2, minutes: 1)));
      await accrue();
      expect([await tStatus(t1), await tStatus(t2)], ['finished', 'cancelled']);
      expect((await tTime(t1, 'finished_at')).isAtSameMomentAs(ends), isTrue, reason: 'временем конца считается конец по расписанию');
      expect([await bStatus(id(b1)), await bStatus(id(b2))], ['done', 'cancelled']);
      expect([await bRefund(id(b1)), await bRefund(id(b2))], [0, 500]);
      expect(await led('refund', booking: id(b2), count: true), 1);
      expect(await led('refund', booking: id(b2)), 500);
      expect(await seatOwner(t2, 'rl'), isNull);
      expect(await seatOwner(t1, 'front'), id(b1));
      await expectNoSplit(id(b1));
      await expectNoSplit(id(b2));

      await advanceTo(ends.add(const Duration(hours: 23, minutes: 55)));
      await accrue();
      await expectNoSplit(id(b1));
      await expectNoSplit(id(b2));
      expect((await earn(d1))['accrued'], 0);

      await advanceTo(ends.add(const Duration(hours: 24, minutes: 5)));
      await accrue();
      await expectSplit(id(b1), 600);
      await expectNoSplit(id(b2));
      expect(await earn(d1), {'accrued': 516, 'paid_out': 0, 'to_pay': 516});
      expect(await earn(d2), {'accrued': 0, 'paid_out': 0, 'to_pay': 0}, reason: 'водитель, не начавший рейс, не получает ничего');
      await expectTripMoney(t1, charged: 600, refunded: 0, shared: 600);
      await expectTripMoney(t2, charged: 500, refunded: 500, shared: 0);
      expect(await led('refund', booking: id(b2), count: true), 1, reason: 'повторные запуски расчёта не возвращают второй раз');
      expect(await d2.refusal('select driver_start_trip(@t::uuid)', {'t': t2}), 'TRIP_NOT_PLANNED');
    });

    test('рейс завершён водителем: начисление ровно через 24 часа, сколько бы раз ни запускали расчёт', () async {
      final d = await newDriver('Точный');
      final p = await newPax('Свидетель');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      final b = await p.book(trip, ['front']);
      await drive(d, trip, dep);
      final fin = await tTime(trip, 'finished_at');
      for (var h = 1; h <= 23; h++) {
        await w.advance(const Duration(hours: 1));
        await accrue();
        await w.finance.one('select accrue_due()');
        expect(await led('driver_accrual', booking: id(b), count: true), 0, reason: 'через $h ч после конца рейса начислять рано');
      }
      await advanceTo(fin.add(const Duration(hours: 23, minutes: 55)));
      await accrue();
      await expectNoSplit(id(b));
      expect((await earn(d))['to_pay'], 0);

      await advanceTo(fin.add(const Duration(hours: 24, minutes: 5)));
      await accrue();
      await expectSplit(id(b), 600);
      for (var i = 0; i < 6; i++) {
        await w.advance(const Duration(hours: 7));
        await accrue();
        await w.finance.one('select accrue_due()');
      }
      expect(await led('driver_accrual', booking: id(b), count: true), 1);
      await expectSplit(id(b), 600);
      expect((await earn(d))['accrued'], 516);
    });

    test('водитель завершил рейс на час позже расписания: 24 часа считаются от настоящего завершения', () async {
      final d = await newDriver('Задержался');
      final p = await newPax('Долго ехал');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      final b = await p.book(trip, ['front']);
      await advanceTo(dep.subtract(const Duration(minutes: 10)));
      await start(d, trip);
      final ends = await tTime(trip, 'ends_at');
      await advanceTo(ends.add(const Duration(hours: 1)));
      await finish(d, trip);
      final fin = await tTime(trip, 'finished_at');
      expect(fin.isAfter(ends.add(const Duration(minutes: 59))), isTrue);

      await advanceTo(ends.add(const Duration(hours: 24, minutes: 30)));
      await accrue();
      await expectNoSplit(id(b));
      await advanceTo(fin.add(const Duration(hours: 24, minutes: 5)));
      await accrue();
      await expectSplit(id(b), 600);
    });

    // ИСПРАВЛЕНО: раньше водитель мог начать рейс за 15 минут до отправления и тут же завершить его — пассажир,
    // который ещё шёл к месту посадки, получал «поездка завершена», а срок начисления шёл от этого раннего завершения.
    // Теперь завершить рейс до времени отправления нельзя (TOO_EARLY), начать — не раньше чем за 15 минут.
    test('начать рейс раньше чем за 15 минут и завершить его до отправления нельзя (TOO_EARLY); доля — через 24 часа после настоящего завершения', () async {
      final d = await newDriver('Спешит');
      final p = await newPax('Ещё идёт');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      final b = await p.book(trip, ['front']);
      await advanceTo(dep.subtract(const Duration(minutes: 17)));
      expect(await d.refusal('select driver_start_trip(@t::uuid)', {'t': trip}), 'TOO_EARLY');
      expect(await tStatus(trip), 'planned');
      await advanceTo(dep.subtract(const Duration(minutes: 14)));
      await start(d, trip);
      expect(await d.refusal('select driver_finish_trip(@t::uuid)', {'t': trip}), 'TOO_EARLY');
      await advanceTo(dep.subtract(const Duration(minutes: 1)));
      expect(await d.refusal('select driver_finish_trip(@t::uuid)', {'t': trip}), 'TOO_EARLY');
      expect(await tStatus(trip), 'started');
      expect(await bStatus(id(b)), 'paid', reason: 'до отправления поездка не может стать завершённой');
      await advanceTo(dep);
      await finish(d, trip);
      final fin = await tTime(trip, 'finished_at');
      expect(fin.isBefore(dep), isFalse, reason: 'рейс завершён не раньше времени отправления');
      expect(await bStatus(id(b)), 'done');
      expect(await p.refusal('select cancel_booking(@b::uuid)', {'b': id(b)}), 'NOT_CANCELLABLE');
      await advanceTo(fin.add(const Duration(hours: 23, minutes: 50)));
      await accrue();
      await expectNoSplit(id(b));
      await advanceTo(fin.add(const Duration(hours: 24, minutes: 1)));
      await accrue();
      await expectSplit(id(b), 600);
      expect((await w.now()).isBefore(dep.add(const Duration(hours: 24))), isFalse, reason: 'начислено не раньше чем через 24 часа после отправления');
    });

    // ИСПРАВЛЕНО: раньше рейс, который водитель не начинал вовсе, через 2 часа считался состоявшимся — водитель получал
    // деньги и с опоздавшего с отменой, и с тех, кто ждал машину. Теперь такой рейс отменяется сам: поездки не было,
    // никто не платит — деньги возвращаются и тому, кто отменил поздно и остался без возврата.
    test('поздняя отмена на рейсе, который водитель так и не начал: рейс отменяется сам, всем полный возврат, водителю ничего', () async {
      final d = await newDriver('Не приехал');
      final p1 = await newPax('Отменил поздно');
      final p2 = await newPax('Ждал машину');
      final p3 = await newPax('Отменил рано');
      final x = await newPax('Банк отказал', card: badCard);
      final dep = await inMinutes(125);
      final trip = await d.createTrip(route, dep);
      final b1 = await p1.book(trip, ['front']);
      final b2 = await p2.book(trip, ['rl']);
      final b3 = await p3.book(trip, ['rr']);
      expect((await p3.cancel(id(b3)))['refund'], 500);
      final bx = await x.book(trip, ['rr']);
      expect(bx['status'], 'failed');
      await advanceTo(dep.subtract(const Duration(minutes: 50)));
      expect((await p1.cancel(id(b1)))['refund'], 0);
      expect(await led('refund', booking: id(b1)), 0);
      final ends = await tTime(trip, 'ends_at');
      await advanceTo(ends.add(const Duration(minutes: 1)));
      expect(await d.refusal('select driver_start_trip(@t::uuid)', {'t': trip}), 'TOO_LATE', reason: 'после конца по расписанию рейс уже не начать');
      await advanceTo(ends.add(const Duration(hours: 1, minutes: 59)));
      await accrue();
      expect(await tStatus(trip), 'planned');
      expect(await led('refund', trip: trip), 500, reason: 'до двух часов после конца возвращено только отменившему рано');

      await advanceTo(ends.add(const Duration(hours: 2, minutes: 1)));
      await accrue();
      expect(await tStatus(trip), 'cancelled');
      expect([await bStatus(id(b1)), await bStatus(id(b2)), await bStatus(id(b3)), await bStatus(id(bx))], ['cancelled', 'cancelled', 'cancelled', 'failed']);
      expect([await bRefund(id(b1)), await bRefund(id(b2)), await bRefund(id(b3)), await bRefund(id(bx))], [600, 500, 500, 0]);
      for (final b in [b1, b2, b3]) {
        expect(await led('refund', booking: id(b), count: true), 1);
      }
      expect(await led('refund', booking: id(bx), count: true), 0);
      for (final s in ['front', 'rl', 'rr']) {
        expect(await seatOwner(trip, s), isNull);
      }
      await expectTripMoney(trip, charged: 1600, refunded: 1600, shared: 0);

      await w.advance(day);
      await accrue();
      await accrue();
      for (final b in [b1, b2, b3, bx]) {
        await expectNoSplit(id(b));
      }
      await expectTripMoney(trip, charged: 1600, refunded: 1600, shared: 0);
      expect(await earn(d), {'accrued': 0, 'paid_out': 0, 'to_pay': 0});
      await payouts();
      expect(await payoutCount(d), 0);
      expect(await d.refusal('select driver_start_trip(@t::uuid)', {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await d.refusal('select driver_cancel_trip(@t::uuid)', {'t': trip}), 'TRIP_NOT_PLANNED');
    });

    test('водитель отменил рейс после конца по расписанию, но до автоматической отмены: всем полный возврат, начислений нет', () async {
      final d = await newDriver('Признался');
      final p1 = await newPax('Ждал зря');
      final p2 = await newPax('Отменил за полчаса');
      final dep = await inMinutes(90);
      final trip = await d.createTrip(route, dep);
      final b1 = await p1.book(trip, ['front']);
      final b2 = await p2.book(trip, ['rl']);
      await advanceTo(dep.subtract(const Duration(minutes: 30)));
      expect((await p2.cancel(id(b2)))['refund'], 0);
      final ends = await tTime(trip, 'ends_at');
      await advanceTo(ends.add(const Duration(hours: 1)));
      await accrue();
      expect(await tStatus(trip), 'planned');
      expect(await cancelTrip(d, trip), 2);
      expect([await bRefund(id(b1)), await bRefund(id(b2))], [600, 500]);
      await w.advance(const Duration(days: 2));
      await accrue();
      await expectNoSplit(id(b1));
      await expectNoSplit(id(b2));
      expect((await earn(d))['accrued'], 0);
      expect(await led('refund', trip: trip), 1100);
    });

    // ИСПРАВЛЕНО: раньше после закрытия рейса (в том числе автоматического) на сервере не было способа вернуть деньги
    // пассажиру, хотя доля водителя ещё 24 часа не начислена. Теперь есть возврат по жалобе (staff_refund_booking).
    // Сам закрывается только начатый рейс; не начатый — отменяется (см. тесты выше).
    test('после автозакрытия начатого рейса отменить его нельзя — ни водителю, ни поддержке; до начисления деньги возвращает поддержка по жалобе', () async {
      final d = await newDriver('Поздно спохватился');
      final p = await newPax('Хочет возврат');
      final p2 = await newPax('Доехал');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      final b = await p.book(trip, ['front']);
      final b2 = await p2.book(trip, ['rl']);
      await advanceTo(dep.subtract(const Duration(minutes: 10)));
      await start(d, trip);
      final ends = await tTime(trip, 'ends_at');
      await advanceTo(ends.add(const Duration(hours: 2, minutes: 1)));
      await accrue();
      expect(await tStatus(trip), 'finished');
      expect(await d.refusal('select driver_finish_trip(@t::uuid)', {'t': trip}), 'TRIP_NOT_STARTED');
      expect(await d.refusal('select driver_cancel_trip(@t::uuid)', {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await w.support.refusal('select driver_cancel_trip(@t::uuid)', {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await p.refusal('select cancel_booking(@b::uuid)', {'b': id(b)}), 'NOT_CANCELLABLE');
      expect(await w.support.refusal('select cancel_booking(@b::uuid)', {'b': id(b)}), 'NOT_CANCELLABLE');
      expect(await led('refund', booking: id(b)), 0);
      expect(await p.refusal(refundSql, {'b': id(b), 'r': 'верните'}), 'FORBIDDEN', reason: 'сам пассажир вернуть себе деньги не может');
      expect(await d.refusal(refundSql, {'b': id(b), 'r': 'верните'}), 'FORBIDDEN');

      expect(await staffRefund(w.support, id(b), 'водитель не довёз'), 600);
      expect(await bStatus(id(b)), 'cancelled');
      expect(await bRefund(id(b)), 600);
      expect(await led('refund', booking: id(b), count: true), 1);
      await w.advance(day);
      await accrue();
      await expectNoSplit(id(b));
      await expectSplit(id(b2), 500);
      await expectTripMoney(trip, charged: 1100, refunded: 600, shared: 500);
      expect(await earn(d), {'accrued': 430, 'paid_out': 0, 'to_pay': 430});
    });

    test('расчёт запущен пять раз одновременно: каждый рейс начислен ровно один раз', () async {
      await settle();
      final p = await newPax('Один на всех');
      final dep = await inMinutes(40);
      final list = <(Actor, String, String, int)>[];
      const prices = [333, 1501, 99];
      for (var i = 0; i < 3; i++) {
        final d = await newDriver('Одновременный $i');
        final trip = await d.createTrip(wide, dep, seats: {'front': prices[i]});
        list.add((d, trip, id(await p.book(trip, ['front'])), prices[i]));
      }
      for (final (d, trip, _, _) in list) {
        await drive(d, trip, dep);
      }
      await w.advance(day);
      final f2 = await newFinance('Финансист 2');
      final f3 = await newFinance('Финансист 3');
      final f4 = await newFinance('Финансист 4');
      final counts = await Future.wait([
        accrue(),
        for (final f in [w.finance, f2, f3, f4]) f.one('select accrue_due()'),
      ]);
      expect(counts.fold<int>(0, (s, c) => s + (c as int)), 3, reason: 'три рейса начислены по одному разу: $counts');
      for (final (d, _, b, price) in list) {
        expect(await led('driver_accrual', booking: b, count: true), 1);
        await expectSplit(b, price);
        expect((await earn(d))['accrued'], MoneySplit.of(price).driver);
      }
      expect(await accrue(), 0);
    });
  });

  // =====================================================================================
  group('выплаты', () {
    test('выплаты после частичных начислений: каждая часть выплачена один раз', () async {
      final d = await newDriver('Два рейса');
      final p = await newPax('Постоянный');
      final dep1 = await inMinutes(30);
      final dep2 = await inMinutes(600);
      final t1 = await d.createTrip(route, dep1, seats: {'front': 600});
      final t2 = await d.createTrip(wide, dep2, seats: {'front': 333, 'rl': 1501});
      final b1 = await p.book(t1, ['front']);
      final b2 = await p.book(t2, ['front']);
      final b3 = await p.book(t2, ['rl']);
      await drive(d, t1, dep1);
      await drive(d, t2, dep2);
      final f1 = await tTime(t1, 'finished_at');
      final f2 = await tTime(t2, 'finished_at');
      const s1 = 516, s2 = 287 + 1291;

      expect(await payoutCount(d), 0);
      await payouts();
      expect(await payoutCount(d), 0, reason: 'до начисления выплачивать нечего');

      await advanceTo(f1.add(day));
      await accrue();
      await expectSplit(id(b1), 600);
      await expectNoSplit(id(b2));
      expect(await earn(d), {'accrued': s1, 'paid_out': 0, 'to_pay': s1});
      await payouts();
      expect([await payoutCount(d), await payoutSum(d)], [1, s1]);
      expect(await earn(d), {'accrued': s1, 'paid_out': s1, 'to_pay': 0});
      await payouts();
      expect(await payoutCount(d), 1, reason: 'повторный запуск не платит второй раз');

      await advanceTo(f2.add(day));
      await accrue();
      await expectSplit(id(b2), 333);
      await expectSplit(id(b3), 1501);
      expect(await earn(d), {'accrued': s1 + s2, 'paid_out': s1, 'to_pay': s2});
      await payouts();
      expect([await payoutCount(d), await payoutSum(d)], [2, s1 + s2]);
      expect(await earn(d), {'accrued': s1 + s2, 'paid_out': s1 + s2, 'to_pay': 0});
      await payouts();
      await payouts();
      expect([await payoutCount(d), await payoutSum(d)], [2, s1 + s2]);
      expect(await led('payout', driver: d.id), s1 + s2);
    });

    test('отметка «выплачено»: один раз; повтор и неизвестная выплата — отказ; деньги не меняются', () async {
      final d = await newDriver('Получатель');
      final p = await newPax('Плательщик');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      await p.book(trip, ['front']);
      await drive(d, trip, dep);
      await w.advance(day);
      await accrue();
      await payouts();
      final pid = await w.scalar('select id::text from payouts where driver_id = @d::uuid', {'d': d.id}) as String;
      final ledgerRows = await w.scalar('select count(*)::int from ledger') as int;

      expect(await d.refusal('select finance_mark_paid(@p::uuid)', {'p': pid}), 'FORBIDDEN', reason: 'водитель сам себе выплату не отмечает');
      expect(await d.refusal('select finance_create_payouts()'), 'FORBIDDEN');
      expect(await d.refusal('select accrue_due()'), 'FORBIDDEN');
      expect(await w.finance.refusal('select finance_mark_paid(@p::uuid)', {'p': pid}), isNull);
      expect(await w.scalar('select status from payouts where id = @p::uuid', {'p': pid}), 'paid');
      expect(await w.finance.refusal('select finance_mark_paid(@p::uuid)', {'p': pid}), 'PAYOUT_NOT_FOUND');
      expect(await w.finance.refusal('select finance_mark_paid(@p::uuid)', {'p': '00000000-0000-4000-8000-000000000000'}), 'PAYOUT_NOT_FOUND');
      expect(await w.scalar('select count(*)::int from ledger'), ledgerRows);
      expect(await earn(d), {'accrued': 516, 'paid_out': 516, 'to_pay': 0});
      await payouts();
      expect([await payoutCount(d), await payoutSum(d)], [1, 516], reason: 'после отметки новая выплата не создаётся');
    });

    test('несколько водителей: каждому своё, без рейсов и с отменённым рейсом — ничего', () async {
      await settle();
      final pa = await newPax('Ездит со всеми');
      final pb = await newPax('Отменяет поздно');
      final d1 = await newDriver('Один пассажир');
      final d2 = await newDriver('Двое, один отменил поздно');
      final d3 = await newDriver('Сам отменил рейс');
      final d4 = await newDriver('Пустой рейс');
      final d5 = await newDriver('Без рейсов');
      final dep = await inMinutes(125);
      final t1 = await d1.createTrip(route, dep, seats: {'front': 600});
      final t2 = await d2.createTrip(route, dep, seats: {'front': 500, 'rl': 500});
      final t3 = await d3.createTrip(route, dep);
      final t4 = await d4.createTrip(route, dep);
      await pa.book(t1, ['front']);
      await pa.book(t2, ['front']);
      final late2 = await pb.book(t2, ['rl']);
      await pa.book(t3, ['front']);
      expect(await cancelTrip(d3, t3), 1);
      await advanceTo(dep.subtract(const Duration(minutes: 59)));
      expect((await pb.cancel(id(late2)))['refund'], 0);
      await drive(d1, t1, dep);
      await drive(d2, t2, dep);
      await drive(d4, t4, dep);
      await w.advance(day);
      expect(await accrue(), 3, reason: 'три завершённых рейса; отменённый не начисляется');

      expect(await earn(d1), {'accrued': 516, 'paid_out': 0, 'to_pay': 516});
      expect(await earn(d2), {'accrued': 860, 'paid_out': 0, 'to_pay': 860});
      for (final d in [d3, d4, d5]) {
        expect(await earn(d), {'accrued': 0, 'paid_out': 0, 'to_pay': 0});
      }
      expect(await earn(pa), {'accrued': 0, 'paid_out': 0, 'to_pay': 0}, reason: 'у пассажира заработка нет');

      expect(await payouts(), 2);
      expect([await payoutCount(d1), await payoutSum(d1)], [1, 516]);
      expect([await payoutCount(d2), await payoutSum(d2)], [1, 860]);
      for (final d in [d3, d4, d5]) {
        expect(await payoutCount(d), 0);
      }
      expect(await earn(d1), {'accrued': 516, 'paid_out': 516, 'to_pay': 0});
      expect(await earn(d2), {'accrued': 860, 'paid_out': 860, 'to_pay': 0});
      expect(await payouts(), 0);
    });

    test('выплаты и расчёт долей запущены одновременно несколькими финансистами: никто не получил дважды', () async {
      await settle();
      final p = await newPax('Платит троим');
      final dep = await inMinutes(40);
      final list = <(Actor, int)>[];
      final trips = <(Actor, String)>[];
      const prices = [149, 2999, 1000];
      for (var i = 0; i < 3; i++) {
        final d = await newDriver('К выплате $i');
        final trip = await d.createTrip(wide, dep, seats: {'front': prices[i]});
        await p.book(trip, ['front']);
        trips.add((d, trip));
        list.add((d, MoneySplit.of(prices[i]).driver));
      }
      for (final (d, trip) in trips) {
        await drive(d, trip, dep);
      }
      await w.advance(day);
      final fs = [w.finance, await newFinance('Касса 2'), await newFinance('Касса 3'), await newFinance('Касса 4')];
      await Future.wait([
        fs[0].one('select accrue_due()'),
        fs[1].one('select finance_create_payouts()'),
        fs[2].one('select accrue_due()'),
        fs[3].one('select finance_create_payouts()'),
      ]);
      await Future.wait([for (final f in fs) f.one('select finance_create_payouts()')]);
      for (final (d, share) in list) {
        expect(await earn(d), {'accrued': share, 'paid_out': share, 'to_pay': 0});
        expect(await payoutSum(d), share);
        expect(await payoutCount(d), 1);
      }
      expect(await payouts(), 0);
    });

    test('пока 24 часа не прошли, выплата не создаётся; отменённый рейс не оплачивается никогда', () async {
      final d = await newDriver('Ждёт выплату');
      final p = await newPax('Только что ехал');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      await p.book(trip, ['front']);
      await drive(d, trip, dep);
      await w.advance(const Duration(hours: 23));
      await accrue();
      await payouts();
      expect(await payoutCount(d), 0);
      expect(await earn(d), {'accrued': 0, 'paid_out': 0, 'to_pay': 0});
      await w.advance(const Duration(hours: 1, minutes: 10));
      await accrue();
      await payouts();
      expect([await payoutCount(d), await payoutSum(d)], [1, 516]);
    });
  });

  // =====================================================================================
  group('настройки процентов и сроков', () {
    test('проценты изменили между покупкой и начислением: всё распределено до драма', () async {
      // AMBIGUITY: применяется ставка на момент начисления (здесь 20% + 5%), а не та, что действовала,
      // когда водитель ставил рейс и пассажир платил (10% + 4%). Водитель получает 750 вместо обещанных 860.
      await settle();
      final d = await newDriver('До повышения');
      final p = await newPax('Платил по-старому');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(wide, dep, seats: {'front': 1000, 'rl': 333});
      final b1 = await p.book(trip, ['front']);
      final b2 = await p.book(trip, ['rl']);
      await drive(d, trip, dep);
      await w.advance(day);
      try {
        await setting('commission_percent', 20);
        await setting('state_percent', 5);
        expect(await accrue(), 1);
      } finally {
        await setting('commission_percent', 10);
        await setting('state_percent', 4);
      }
      expect(await distributed(id(b1)), 1000);
      expect(await distributed(id(b2)), 333);
      await expectSplit(id(b1), 1000, cp: 20, sp: 5);
      await expectSplit(id(b2), 333, cp: 20, sp: 5);
      expect((await earn(d))['accrued'], 750 + (333 - 66 - 16));
      expect(await accrue(), 0, reason: 'после возврата прежних процентов ничего не пересчитывается');
    });

    test('проценты 0% и 0%: водитель получает всё, записей о комиссии и госпошлине нет', () async {
      await settle();
      final d = await newDriver('Без удержаний');
      final p = await newPax('Платит водителю');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(wide, dep, seats: {'front': 333});
      final b = await p.book(trip, ['front']);
      await drive(d, trip, dep);
      await w.advance(day);
      try {
        await setting('commission_percent', 0);
        await setting('state_percent', 0);
        expect(await accrue(), 1);
      } finally {
        await setting('commission_percent', 10);
        await setting('state_percent', 4);
      }
      expect(await led('driver_accrual', booking: id(b)), 333);
      expect(await led('commission', booking: id(b), count: true), 0);
      expect(await led('state_duty', booking: id(b), count: true), 0);
      expect(await earn(d), {'accrued': 333, 'paid_out': 0, 'to_pay': 333});
    });

    // ИСПРАВЛЕНО: раньше accrue_due падал целиком, если доля водителя по какой-то одной брони выходила 0 драм
    // (запись driver_accrual с суммой 0 нарушала ограничение ledger.amount > 0), и не начислялось ничего и никому.
    // Теперь нулевые записи в журнал не пишутся, а проценты ограничены: каждый от 0 до 100, вместе не больше 100.
    test('проценты 50% + 50%: расчёт проходит, доля водителя 0 или 1 драм, нулевых записей нет; больше 100% в сумме задать нельзя', () async {
      await settle();
      final d1 = await newDriver('Чётная сумма');
      final d2 = await newDriver('Нечётная сумма');
      final p = await newPax('Платит пополам');
      final dep = await inMinutes(40);
      final t1 = await d1.createTrip(wide, dep, seats: {'front': 600});
      final t2 = await d2.createTrip(wide, dep, seats: {'front': 601});
      final b1 = await p.book(t1, ['front']);
      final b2 = await p.book(t2, ['front']);
      await drive(d1, t1, dep);
      await drive(d2, t2, dep);
      await w.advance(day);
      String? refused;
      final over = <String?>[];
      late List<int> parts1, parts2, kept;
      try {
        await setting('commission_percent', 50);
        await setting('state_percent', 50);
        over.add(await settingRefusal('commission_percent', 51)); // 51 + 50 > 100
        over.add(await settingRefusal('state_percent', 51));
        over.add(await settingRefusal('commission_percent', -1));
        over.add(await settingRefusal('state_percent', 101));
        kept = [await w.scalar("select setting_int('commission_percent')") as int, await w.scalar("select setting_int('state_percent')") as int];
        refused = await w.finance.refusal('select accrue_due()');
        parts1 = [await led('driver_accrual', booking: id(b1)), await led('commission', booking: id(b1)), await led('state_duty', booking: id(b1))];
        parts2 = [await led('driver_accrual', booking: id(b2)), await led('commission', booking: id(b2)), await led('state_duty', booking: id(b2))];
      } finally {
        await setting('state_percent', 4);
        await setting('commission_percent', 10);
        await accrue(); // чтобы незавершённый расчёт не мешал следующим тестам
      }
      expect(over, ['BAD_SETTINGS', 'BAD_SETTINGS', 'BAD_SETTINGS', 'BAD_SETTINGS'], reason: 'проценты вне 0..100 или больше 100 в сумме не принимаются');
      expect(kept, [50, 50], reason: 'отказанные значения не записаны');
      expect(refused, isNull, reason: 'accrue_due отказал с кодом $refused: из-за брони с нулевой долей водителя не начислено ничего и никому');
      expect(parts1, [0, 300, 300]);
      expect(parts2, [1, 300, 300]);
      expect(await led('driver_accrual', booking: id(b1), count: true), 0, reason: 'нулевая доля в журнал не пишется');
      expect(await w.scalar('select count(*)::int from ledger where amount <= 0'), 0);
      await expectTripMoney(t1, charged: 600, refunded: 0, shared: 600);
      await expectTripMoney(t2, charged: 601, refunded: 0, shared: 601);
      await payouts();
      expect(await payoutCount(d1), 0, reason: 'выплаты на 0 драм не бывает');
      expect([await payoutCount(d2), await payoutSum(d2)], [1, 1]);
    });

    // ИСПРАВЛЕНО: раньше произведение «сумма × процент» считалось в 32-битном int, а сервер принимал места по 9 999 999
    // драм: бронь на 39 999 996 при комиссии 60% давала «integer out of range», и расчёт падал целиком для всех.
    // Теперь расчёт идёт в bigint, а цены ограничены: базовая цена маршрута — до 1 000 000, место — до трёх базовых цен.
    // Самая дорогая возможная бронь — 4 места по 3 000 000 = 12 000 000 драм; проценты в сумме не больше 100.
    test('самая дорогая возможная бронь (4 места по 3 000 000) и предельные проценты 96% + 4%: расчёт проходит и сходится до драма', () async {
      await settle();
      const saveRoute = 'select staff_save_route(null, @code, @fn, 40.2264, 44.4930, @tn, 40.1777, 44.5126, @p::int, 25, 9000)';
      for (final price in ['3400000', '1000001', '0']) {
        expect(await w.moderator.refusal(saveRoute, {'code': 'A8', 'fn': 'Давташен', 'tn': 'Площадь Республики', 'p': price}), 'BAD_ARGUMENT',
            reason: 'базовая цена $price вне пределов 1..1 000 000');
      }
      final lux = await w.newRoute('A9', price: 1000000);
      const seats = ['front', 'rl', 'rm', 'rr'];
      final d1 = await newDriver('Лимузин');
      final d2 = await newDriver('Почти лимузин');
      final d3 = await newDriver('Лимузин по обычной ставке');
      final p = await newPax('Миллионер');
      final dep = await inMinutes(40);
      final dep3 = dep.add(const Duration(hours: 2));
      final tooDear = await attempt(() => d1.createTrip(lux, dep, seats: {'front': 3000001}));
      expect(tooDear, isA<Refused>().having((e) => e.code, 'код', 'BAD_PRICE'), reason: 'место дороже трёх базовых цен не выставить');
      final t1 = await d1.createTrip(lux, dep, seats: {for (final s in seats) s: 3000000});
      final t2 = await d2.createTrip(lux, dep, seats: {for (final s in seats) s: 2999999});
      final t3 = await d3.createTrip(lux, dep3, seats: {for (final s in seats) s: 3000000});
      final b1 = await p.book(t1, seats);
      final b2 = await p.book(t2, seats);
      final b3 = await p.book(t3, seats);
      expect([b1['amount'], b2['amount'], b3['amount']], [12000000, 11999996, 12000000]);
      await drive(d1, t1, dep);
      await drive(d2, t2, dep);
      await drive(d3, t3, dep3);
      final fin2 = await tTime(t2, 'finished_at');
      final fin3 = await tTime(t3, 'finished_at');
      await advanceTo(fin2.add(day)); // третий рейс завершён на два часа позже — его срок ещё не вышел
      String? refused;
      try {
        await setting('commission_percent', 96);
        refused = await w.finance.refusal('select accrue_due()');
      } finally {
        await setting('commission_percent', 10);
      }
      expect(refused, isNull, reason: 'accrue_due отказал с кодом $refused (22003 — число не помещается в int)');
      await expectSplit(id(b1), 12000000, cp: 96, sp: 4);
      await expectSplit(id(b2), 11999996, cp: 96, sp: 4);
      Future<List<int>> parts(Map<String, dynamic> b) async =>
          [await led('driver_accrual', booking: id(b)), await led('commission', booking: id(b)), await led('state_duty', booking: id(b))];
      expect(await parts(b1), [0, 11520000, 480000]);
      expect(await parts(b2), [1, 11519996, 479999]);
      expect(await led('driver_accrual', booking: id(b1), count: true), 0, reason: 'нулевая доля в журнал не пишется');
      await expectNoSplit(id(b3));

      // Та же предельная бронь по обычным 10% + 4%: водителю 10 320 000, и выплата проходит на всю сумму.
      await advanceTo(fin3.add(day));
      expect(await accrue(), 1);
      await expectSplit(id(b3), 12000000);
      expect(await parts(b3), [10320000, 1200000, 480000]);
      await expectTripMoney(t1, charged: 12000000, refunded: 0, shared: 12000000);
      await expectTripMoney(t2, charged: 11999996, refunded: 0, shared: 11999996);
      await expectTripMoney(t3, charged: 12000000, refunded: 0, shared: 12000000);
      await payouts();
      expect(await payoutCount(d1), 0);
      expect([await payoutCount(d2), await payoutSum(d2)], [1, 1]);
      expect([await payoutCount(d3), await payoutSum(d3)], [1, 10320000]);
      expect(await earn(d3), {'accrued': 10320000, 'paid_out': 10320000, 'to_pay': 0});
    });

    test('проценты изменили между двумя начислениями одного водителя: заработок и выплаты сходятся', () async {
      await settle();
      final d = await newDriver('До и после');
      final p = await newPax('Два раза');
      final dep1 = await inMinutes(30);
      final dep2 = await inMinutes(600);
      final t1 = await d.createTrip(wide, dep1, seats: {'front': 1000});
      final t2 = await d.createTrip(wide, dep2, seats: {'front': 1000});
      final b1 = await p.book(t1, ['front']);
      final b2 = await p.book(t2, ['front']);
      await drive(d, t1, dep1);
      await drive(d, t2, dep2);
      final f1 = await tTime(t1, 'finished_at');
      final f2 = await tTime(t2, 'finished_at');
      await advanceTo(f1.add(day));
      expect(await accrue(), 1);
      await expectSplit(id(b1), 1000);
      await payouts();
      await advanceTo(f2.add(day));
      try {
        await setting('commission_percent', 30);
        await setting('state_percent', 0);
        expect(await accrue(), 1);
      } finally {
        await setting('commission_percent', 10);
        await setting('state_percent', 4);
      }
      await expectSplit(id(b2), 1000, cp: 30, sp: 0);
      await expectSplit(id(b1), 1000); // первое начисление не пересчитано
      expect(await earn(d), {'accrued': 860 + 700, 'paid_out': 860, 'to_pay': 700});
      await payouts();
      expect([await payoutCount(d), await payoutSum(d)], [2, 1560]);
    });

    test('срок бесплатной отмены изменили после покупки: действует срок на момент отмены', () async {
      // AMBIGUITY: пассажир покупал при правиле «60 минут», а отменяет при «120 минутах» — возврата нет.
      final d = await newDriver('Новые правила');
      final p1 = await newPax('Попал под новые');
      final p2 = await newPax('Успел по старым');
      final dep = await inMinutes(200);
      final trip = await d.createTrip(route, dep);
      final b1 = await p1.book(trip, ['front']);
      final b2 = await p2.book(trip, ['rl']);
      await advanceTo(dep.subtract(const Duration(minutes: 90)));
      try {
        await setting('free_cancel_minutes', 120);
        expect((await p1.cancel(id(b1)))['refund'], 0);
      } finally {
        await setting('free_cancel_minutes', 60);
      }
      expect((await p2.cancel(id(b2)))['refund'], 500);
      expect(await cancelTrip(d, trip), 1, reason: 'при отмене рейса водителем деньги возвращаются и тому, кто остался без возврата');
      expect(await bRefund(id(b1)), 600);
    });

    test('срок начисления 0 часов: доля начисляется сразу после рейса и только один раз', () async {
      await settle();
      final d = await newDriver('Мгновенный');
      final p = await newPax('Быстрый');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      final b = await p.book(trip, ['front']);
      await drive(d, trip, dep);
      expect(await accrue(), 0, reason: 'при сроке 24 часа сразу после рейса начислять рано');
      try {
        await setting('accrual_delay_hours', 0);
        expect(await accrue(), 1);
      } finally {
        await setting('accrual_delay_hours', 24);
      }
      await expectSplit(id(b), 600);
      await w.advance(const Duration(days: 2));
      expect(await accrue(), 0);
      expect(await led('driver_accrual', booking: id(b), count: true), 1);
    });
  });

  // =====================================================================================
  group('номер операции и банк', () {
    // ИСПРАВЛЕНО: раньше сервер молча отвечал прежней бронью (status = paid, repeat = true) и не сообщал, что рейс
    // в запросе другой, — приложение, повторно использовавшее номер, решило бы, что место на втором рейсе куплено.
    // Теперь тот же номер с другим рейсом — отказ IDEM_KEY_REUSED; точный повтор по-прежнему возвращает ту же бронь.
    test('тот же номер операции на другой рейс: отказ IDEM_KEY_REUSED, второго списания нет, на втором рейсе место не занято', () async {
      final d1 = await newDriver('Рейс один');
      final d2 = await newDriver('Рейс два');
      final p = await newPax('Повторяет номер');
      final dep = await inMinutes(125);
      final t1 = await d1.createTrip(route, dep);
      final t2 = await d2.createTrip(route, dep);
      final a = await p.book(t1, ['front'], idem: 'same-op');
      expect(a['status'], 'paid');
      final rows = await ledgerRows();
      expect(await p.refusal(bookSql, {'t': t2, 's': '{rl}', 'c': p.cardId, 'k': 'same-op'}), 'IDEM_KEY_REUSED');
      expect(await p.refusal(bookSql, {'t': t2, 's': '{front}', 'c': p.cardId, 'k': 'same-op'}), 'IDEM_KEY_REUSED', reason: 'то же место, но рейс другой');
      expect(await seatOwner(t2, 'rl'), isNull);
      expect(await seatOwner(t2, 'front'), isNull);
      expect(await w.scalar('select count(*)::int from bookings where trip_id = @t::uuid', {'t': t2}), 0);
      expect(await paxLedger(p, 'charge'), 600);
      expect(await ledgerRows(), rows, reason: 'отказ ничего не списал и не вернул');
      expect(await w.scalar('select count(*)::int from payments p join bookings b on b.id = p.booking_id where b.passenger_id = @u::uuid', {'u': p.id}), 1);

      final again = await p.book(t1, ['front'], idem: 'same-op');
      expect(again['booking_id'], a['booking_id']);
      expect(again['status'], 'paid');
      expect(again['repeat'], true);
      expect(await paxLedger(p, 'charge'), 600, reason: 'точный повтор операции не списывает второй раз');

      final b = await p.book(t2, ['rl']);
      expect(b['status'], 'paid', reason: 'с новым номером операции место на втором рейсе покупается');
      expect(await paxLedger(p, 'charge'), 1100);
    });

    // ИСПРАВЛЕНО: раньше тот же номер с другими местами молча возвращал прежнюю бронь. Теперь — отказ IDEM_KEY_REUSED.
    test('тот же номер операции на другие места того же рейса: отказ IDEM_KEY_REUSED, второго списания нет, места свободны', () async {
      final d = await newDriver('Один рейс');
      final p = await newPax('Хочет ещё место');
      final other = await newPax('Берёт свободное');
      final trip = await d.createTrip(route, await inMinutes(125));
      final a = await p.book(trip, ['front'], idem: 'op-7');
      expect(a['amount'], 600);
      for (final s in ['{rl,rr}', '{rl}', '{front,rl}', '{front,rl,rr}']) {
        expect(await p.refusal(bookSql, {'t': trip, 's': s, 'c': p.cardId, 'k': 'op-7'}), 'IDEM_KEY_REUSED', reason: 'места $s вместо {front}');
      }
      expect(await paxLedger(p, 'charge'), 600);
      expect(await seatOwner(trip, 'rl'), isNull);
      expect(await seatOwner(trip, 'rr'), isNull);
      expect(await w.scalar('select count(*)::int from bookings where passenger_id = @u::uuid', {'u': p.id}), 1);

      // Те же места в другом порядке — это та же операция, а не новая.
      final two = await p.book(trip, ['rl', 'rr'], idem: 'op-8');
      expect(two['amount'], 1000);
      final swapped = await p.book(trip, ['rr', 'rl'], idem: 'op-8');
      expect(swapped['booking_id'], two['booking_id']);
      expect(swapped['repeat'], true);
      expect(await paxLedger(p, 'charge'), 1600);
      expect((await p.cancel(id(two)))['refund'], 1000);
      expect((await other.book(trip, ['rl']))['status'], 'paid');
      expect(await p.refusal(bookSql, {'t': trip, 's': '{rr}', 'c': p.cardId, 'k': 'op-8'}), 'IDEM_KEY_REUSED', reason: 'номер отменённой брони тоже не переиспользуется');
      expect(await seatOwner(trip, 'rr'), isNull);
      expect(await paxLedger(p, 'charge'), 1600);
    });

    test('одинаковый номер операции у двух разных пассажиров: брони независимы, каждый платит один раз', () async {
      final d = await newDriver('Общий');
      final p1 = await newPax('Номер раз');
      final p2 = await newPax('Номер два');
      final trip = await d.createTrip(route, await inMinutes(125));
      final a = await p1.book(trip, ['front'], idem: 'shared-key');
      final b = await p2.book(trip, ['rl'], idem: 'shared-key');
      expect(a['status'], 'paid');
      expect(b['status'], 'paid');
      expect(b['booking_id'], isNot(a['booking_id']));
      expect(b['repeat'], isNull);
      expect(await paxLedger(p1, 'charge'), 600);
      expect(await paxLedger(p2, 'charge'), 500);
    });

    test('банк отказал, повтор другой картой: с тем же номером операции не списывается, с новым — одно списание', () async {
      // AMBIGUITY: после отказа банка номер операции «сгорает»: повтор с ним и исправной картой снова отвечает
      // «failed» и ничего не покупает. Приложение обязано брать новый номер на каждую попытку оплаты.
      final d = await newDriver('Ждёт оплату');
      final p = await newPax('Сменил карту', card: badCard);
      final bad = p.cardId!;
      final good = await p.bindCard(goodCard);
      final trip = await d.createTrip(route, await inMinutes(125));
      final r1 = await p.book(trip, ['front'], card: bad, idem: 'pay-1');
      expect(r1['status'], 'failed');
      final r2 = await p.book(trip, ['front'], card: good, idem: 'pay-1');
      expect(r2['booking_id'], r1['booking_id']);
      expect(r2['status'], 'failed');
      expect(await paxLedger(p, 'charge'), 0);
      expect(await seatOwner(trip, 'front'), isNull);
      final r3 = await p.book(trip, ['front'], card: good, idem: 'pay-2');
      expect(r3['status'], 'paid');
      expect(await paxLedger(p, 'charge'), 600);
      expect(await seatOwner(trip, 'front'), id(r3));
      expect(await w.scalar('select count(*)::int from payments p join bookings b on b.id = p.booking_id where b.passenger_id = @u::uuid and p.ok', {'u': p.id}), 1);
      expect(await w.scalar('select count(*)::int from payments p join bookings b on b.id = p.booking_id where b.passenger_id = @u::uuid and not p.ok', {'u': p.id}), 1);
    });

    test('банк был недоступен: номер операции не сгорает, повтор с ним проходит и списывает один раз', () async {
      final d = await newDriver('Банк лежал');
      final p = await newPax('Повторил позже', card: '4111111111110119');
      final down = p.cardId!;
      final good = await p.bindCard(goodCard);
      final trip = await d.createTrip(route, await inMinutes(125));
      expect(await p.refusal(bookSql, {'t': trip, 's': '{front}', 'c': down, 'k': 'net-1'}), 'BANK_UNAVAILABLE');
      expect(await w.scalar('select count(*)::int from bookings where passenger_id = @u::uuid', {'u': p.id}), 0);
      expect(await seatOwner(trip, 'front'), isNull);
      final r = await p.book(trip, ['front'], card: good, idem: 'net-1');
      expect(r['status'], 'paid');
      expect(r['repeat'], isNull);
      final again = await p.book(trip, ['front'], card: good, idem: 'net-1');
      expect(again['booking_id'], r['booking_id']);
      expect(await paxLedger(p, 'charge'), 600);
    });

    test('повтор операции после отмены с возвратом: нового списания нет, место остаётся свободным', () async {
      final d = await newDriver('После отмены');
      final p = await newPax('Отменил и повторил');
      final trip = await d.createTrip(route, await inMinutes(125));
      final a = await p.book(trip, ['front'], idem: 'again');
      expect((await p.cancel(id(a)))['refund'], 600);
      final b = await p.book(trip, ['front'], idem: 'again');
      expect(b['booking_id'], a['booking_id']);
      expect(b['status'], 'cancelled');
      expect(b['repeat'], true);
      expect(await paxLedger(p, 'charge'), 600);
      expect(await paxLedger(p, 'refund'), 600);
      expect(await seatOwner(trip, 'front'), isNull);
    });

    test('повтор операции после завершения рейса: та же бронь, без списания; новая операция — отказ', () async {
      final d = await newDriver('Уже доехал');
      final p = await newPax('Запоздалый повтор');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      final a = await p.book(trip, ['front'], idem: 'late-retry');
      await drive(d, trip, dep);
      final b = await p.book(trip, ['front'], idem: 'late-retry');
      expect(b['booking_id'], a['booking_id']);
      expect(b['status'], 'done');
      expect(await led('charge', booking: id(a), count: true), 1);
      expect(await p.refusal(bookSql, {'t': trip, 's': '{rl}', 'c': p.cardId, 'k': w.nextKey()}), 'TRIP_CLOSED');
      expect(await paxLedger(p, 'charge'), 600);
    });

    // ИСПРАВЛЕНО: раньше book_seats искал прежнюю бронь по номеру операции под блокировкой РЕЙСА: один номер,
    // пришедший одновременно на два разных рейса, проходил проверку дважды, оба запроса обращались к банку, и проигравший
    // падал уже ПОСЛЕ списания на unique (passenger_id, idem_key) — приложение получало ошибку базы 23505.
    // Теперь операции одного пассажира с одним номером идут строго по очереди: до банка доходит только первая,
    // вторая получает чистый отказ IDEM_KEY_REUSED (рейс в ней другой).
    test('один номер операции одновременно на два разных рейса: одна бронь, одно списание, второй получает отказ IDEM_KEY_REUSED', () async {
      final d1 = await newDriver('Параллельный 1');
      final d2 = await newDriver('Параллельный 2');
      final p = await newPax('Двойное нажатие');
      final p2 = twin(p);
      await p2.q('select 1'); // подключение открыто заранее: запросы уйдут действительно одновременно
      final dep = await inMinutes(125);
      const rounds = 6;
      for (var i = 0; i < rounds; i++) {
        final t1 = await d1.createTrip(route, dep.add(Duration(minutes: 30 * i)));
        final t2 = await d2.createTrip(route, dep.add(Duration(minutes: 30 * i)));
        final key = 'race-$i';
        final results = await Future.wait([
          attempt(() => p.book(t1, ['front'], idem: key)),
          attempt(() => p2.book(t2, ['front'], idem: key)),
        ]);
        expect(await w.scalar('select count(*)::int from bookings where passenger_id = @u::uuid and idem_key = @k', {'u': p.id, 'k': key}), 1,
            reason: 'попытка $i: $results');
        final taken = [await seatOwner(t1, 'front'), await seatOwner(t2, 'front')].whereType<String>().toList();
        expect(taken.length, 1, reason: 'место занято только на одном рейсе');
        expect(await led('charge', booking: taken.single, count: true), 1);
        expect(results.whereType<Map>().length, 1, reason: 'попытка $i: прошла ровно одна покупка: $results');
        expect(results.whereType<Map>().single['booking_id'], taken.single);
        expect(results.whereType<Map>().single['status'], 'paid');
        expect(results.whereType<Refused>().map((e) => e.code).toList(), ['IDEM_KEY_REUSED'],
            reason: 'попытка $i: проигравший получает чистый отказ, а не ошибку базы: $results');
      }
      expect(await paxLedger(p, 'charge'), rounds * 600);
      expect(await w.scalar('select count(*)::int from bookings where passenger_id = @u::uuid', {'u': p.id}), rounds);
      expect(await w.scalar('select count(*)::int from payments p join bookings b on b.id = p.booking_id where b.passenger_id = @u::uuid', {'u': p.id}), rounds,
          reason: 'к банку по каждой операции обращались один раз');
    });

    test('три отказа банка подряд, потом место купил другой: неудачные попытки не оставляют денег и не мешают', () async {
      final d = await newDriver('Многострадальный');
      final x = await newPax('Плохая карта', card: badCard);
      final ok = await newPax('Хорошая карта');
      final dep = await inMinutes(40);
      final trip = await d.createTrip(route, dep);
      for (var i = 0; i < 3; i++) {
        final r = await x.book(trip, ['front', 'rl']);
        expect(r['status'], 'failed');
        expect(r['amount'], 1100);
        expect(await led('charge', booking: id(r), count: true), 0);
      }
      expect(await paxLedger(x, 'charge'), 0);
      expect(await w.scalar('select count(*)::int from payments p join bookings b on b.id = p.booking_id where b.passenger_id = @u::uuid and not p.ok', {'u': x.id}), 3);
      final b = await ok.book(trip, ['front', 'rl']);
      expect(b['status'], 'paid');
      await drive(d, trip, dep);
      await w.advance(day);
      await accrue();
      await expectSplit(id(b), 1100);
      expect(await led('driver_accrual', trip: trip), 946);
      expect(await w.scalar("select count(*)::int from bookings where passenger_id = @u::uuid and status = 'failed'", {'u': x.id}), 3);
    });
  });

  // =====================================================================================
  group('возврат по жалобе', () {
    test('возврат по жалобе после рейса, до начисления: по этой брони водитель не получает ничего, остальные брони не задеты', () async {
      final d = await newDriver('Спорный рейс');
      final a = await newPax('Жалуется');
      final b = await newPax('Доволен');
      final c = await newPax('Отменил поздно и молчит');
      final dep = await inMinutes(90);
      final trip = await d.createTrip(wide, dep, seats: {'front': 333, 'rl': 1501, 'rr': 99});
      final ba = await a.book(trip, ['front']);
      final bb = await b.book(trip, ['rl']);
      final bc = await c.book(trip, ['rr']);
      await advanceTo(dep.subtract(const Duration(minutes: 50)));
      expect((await c.cancel(id(bc)))['refund'], 0);
      await drive(d, trip, dep);
      expect(await bStatus(id(ba)), 'done');

      // Вернуть может только поддержка (или владелец) и только с причиной.
      for (final who in [a, b, d, w.finance, w.moderator, w.verifier]) {
        expect(await who.refusal(refundSql, {'b': id(ba), 'r': 'верните'}), 'FORBIDDEN', reason: who.name);
      }
      for (final reason in ['', '   ']) {
        expect(await w.support.refusal(refundSql, {'b': id(ba), 'r': reason}), 'REASON_REQUIRED');
      }
      expect(await w.support.refusal('select staff_refund_booking(@b::uuid, null)', {'b': id(ba)}), 'REASON_REQUIRED');
      expect(await w.support.refusal(refundSql, {'b': '00000000-0000-4000-8000-000000000000', 'r': 'нет такой брони'}), 'BOOKING_NOT_FOUND');
      expect(await led('refund', trip: trip), 0, reason: 'отказы денег не двигают');
      expect(await bStatus(id(ba)), 'done');

      expect(await staffRefund(w.support, id(ba), 'водитель высадил на полпути'), 333);
      expect(await bStatus(id(ba)), 'cancelled');
      expect(await bRefund(id(ba)), 333);
      expect(await led('refund', booking: id(ba), count: true), 1);
      expect(await led('refund', booking: id(ba)), 333);
      expect(await paxLedger(a, 'refund'), 333);
      expect(await w.scalar("select count(*)::int from payments where booking_id = @b::uuid and kind = 'refund' and ok and amount = 333", {'b': id(ba)}), 1);
      expect(await seatOwner(trip, 'front'), isNull);
      expect([await bStatus(id(bb)), await bStatus(id(bc))], ['done', 'cancelled'], reason: 'остальные брони не задеты');
      expect([await bRefund(id(bb)), await bRefund(id(bc))], [0, 0]);

      await w.advance(day);
      expect(await accrue(), 1);
      await expectNoSplit(id(ba));
      await expectSplit(id(bb), 1501);
      await expectSplit(id(bc), 99);
      await expectTripMoney(trip, charged: 333 + 1501 + 99, refunded: 333, shared: 1501 + 99);
      expect(await earn(d), {'accrued': 1291 + 87, 'paid_out': 0, 'to_pay': 1291 + 87});
      await payouts();
      expect([await payoutCount(d), await payoutSum(d)], [1, 1291 + 87]);
    });

    test('возврат по жалобе после начисления: отказ ALREADY_ACCRUED, деньги и выплата не меняются', () async {
      final d = await newDriver('Уже начислено');
      final p1 = await newPax('Опоздал с жалобой');
      final p2 = await newPax('Отменил поздно, жалуется после срока');
      final dep = await inMinutes(90);
      final trip = await d.createTrip(route, dep);
      final b1 = await p1.book(trip, ['front']);
      final b2 = await p2.book(trip, ['rl']);
      await advanceTo(dep.subtract(const Duration(minutes: 50)));
      expect((await p2.cancel(id(b2)))['refund'], 0);
      await drive(d, trip, dep);
      final fin = await tTime(trip, 'finished_at');
      await advanceTo(fin.add(day));
      expect(await accrue(), 1);
      Future<int> tripRows() async => await w.scalar('select count(*)::int from ledger where trip_id = @t::uuid', {'t': trip}) as int;
      final rows = await tripRows();

      for (final who in [w.support, w.owner]) {
        expect(await who.refusal(refundSql, {'b': id(b1), 'r': 'плохо довёз'}), 'ALREADY_ACCRUED');
        expect(await who.refusal(refundSql, {'b': id(b2), 'r': 'не ездил'}), 'ALREADY_ACCRUED');
      }
      expect(await tripRows(), rows);
      expect([await bStatus(id(b1)), await bStatus(id(b2))], ['done', 'cancelled']);
      expect([await bRefund(id(b1)), await bRefund(id(b2))], [0, 0]);
      expect(await seatOwner(trip, 'front'), id(b1));
      await payouts();
      expect([await payoutCount(d), await payoutSum(d)], [1, 516 + 430]);
      expect(await w.support.refusal(refundSql, {'b': id(b1), 'r': 'уже выплачено'}), 'ALREADY_ACCRUED');
      expect(await tripRows(), rows);
      await expectSplit(id(b1), 600);
      await expectSplit(id(b2), 500);
      await expectTripMoney(trip, charged: 1100, refunded: 0, shared: 1100);
      expect(await earn(d), {'accrued': 946, 'paid_out': 946, 'to_pay': 0});
    });

    test('повторный возврат по жалобе: отказ NOTHING_TO_REFUND; трое сотрудников одновременно — возврат один', () async {
      final d = await newDriver('Одна жалоба');
      final p1 = await newPax('Жалуется всем сразу');
      final p2 = await newPax('Просто доехал');
      final p3 = await newPax('Отменил заранее');
      final x = await newPax('Не смог оплатить', card: badCard);
      final dep = await inMinutes(125);
      final trip = await d.createTrip(route, dep);
      final b1 = await p1.book(trip, ['front']);
      final b2 = await p2.book(trip, ['rl']);
      final b3 = await p3.book(trip, ['rr']);
      expect((await p3.cancel(id(b3)))['refund'], 500);
      final bx = await x.book(trip, ['rr']);
      expect(bx['status'], 'failed');
      expect(await w.support.refusal(refundSql, {'b': id(b3), 'r': 'верните ещё раз'}), 'NOTHING_TO_REFUND', reason: 'по этой брони всё уже возвращено');
      expect(await w.support.refusal(refundSql, {'b': id(bx), 'r': 'банк отказал'}), 'NOTHING_TO_REFUND', reason: 'по неудачной брони ничего не списано');
      expect(await led('refund', booking: id(b3), count: true), 1);
      expect(await led('refund', booking: id(bx), count: true), 0);
      expect(await bStatus(id(bx)), 'failed');
      await drive(d, trip, dep);
      final fin = await tTime(trip, 'finished_at');

      // Сутки почти прошли, расчёт уже запускали, но срок не вышел — возврат ещё возможен.
      await advanceTo(fin.add(const Duration(hours: 23, minutes: 50)));
      expect(await accrue(), 0);
      final s2 = await w.newStaff('Поддержка 2', ['support']);
      made.add(s2);
      await s2.q('select 1');
      final results = await gated([trip], [
        () => staffRefund(w.support, id(b1)),
        () => staffRefund(s2, id(b1)),
        () => staffRefund(w.owner, id(b1)),
      ]);
      expect(results.whereType<int>(), [600], reason: 'прошёл ровно один возврат: $results');
      expect(results.whereType<Refused>().map((e) => e.code).toList(), ['NOTHING_TO_REFUND', 'NOTHING_TO_REFUND'], reason: '$results');
      expect(await led('refund', booking: id(b1), count: true), 1);
      expect(await led('refund', booking: id(b1)), 600);
      expect(await bRefund(id(b1)), 600);
      expect(await w.support.refusal(refundSql, {'b': id(b1), 'r': 'и ещё раз'}), 'NOTHING_TO_REFUND');
      expect(await p1.refusal('select cancel_booking(@b::uuid)', {'b': id(b1)}), 'NOT_CANCELLABLE');
      expect(await led('refund', booking: id(b1), count: true), 1);

      await advanceTo(fin.add(day));
      expect(await accrue(), 1);
      await expectNoSplit(id(b1));
      await expectSplit(id(b2), 500);
      await expectNoSplit(id(b3));
      await expectNoSplit(id(bx));
      await expectTripMoney(trip, charged: 1600, refunded: 1100, shared: 500);
      expect(await earn(d), {'accrued': 430, 'paid_out': 0, 'to_pay': 430});
    });

    test('возврат по жалобе по брони, отменённой поздно (без возврата): возвращается вся сумма один раз, место освобождается, доли с неё нет', () async {
      final d = await newDriver('Поздние отмены');
      final p1 = await newPax('Отменил поздно, жалоба до рейса');
      final p2 = await newPax('Купил освободившееся');
      final p3 = await newPax('Отменил поздно, жалоба после рейса');
      final p4 = await newPax('Едет');
      final dep = await inMinutes(90);
      final trip = await d.createTrip(route, dep);
      final b1 = await p1.book(trip, ['front']);
      final b3 = await p3.book(trip, ['rl']);
      final b4 = await p4.book(trip, ['rr']);
      await advanceTo(dep.subtract(const Duration(minutes: 50)));
      expect((await p1.cancel(id(b1)))['refund'], 0);
      expect((await p3.cancel(id(b3)))['refund'], 0);
      expect(await seatOwner(trip, 'front'), id(b1), reason: 'после поздней отмены место остаётся за пассажиром');

      // До рейса: деньги возвращены, место снова в продаже.
      expect(await staffRefund(w.support, id(b1), 'купил не тот рейс'), 600);
      expect(await bStatus(id(b1)), 'cancelled');
      expect(await bRefund(id(b1)), 600);
      expect(await led('refund', booking: id(b1), count: true), 1);
      expect(await seatOwner(trip, 'front'), isNull);
      expect(await w.support.refusal(refundSql, {'b': id(b1), 'r': 'ещё раз'}), 'NOTHING_TO_REFUND');
      final b2 = await p2.book(trip, ['front']);
      expect(b2['status'], 'paid');
      expect(await seatOwner(trip, 'front'), id(b2));

      // После рейса: по второй поздней отмене деньги тоже возвращаются, пока доля не начислена.
      await drive(d, trip, dep);
      expect(await bStatus(id(b3)), 'cancelled');
      expect(await staffRefund(w.support, id(b3), 'водитель согласен вернуть'), 500);
      expect(await bRefund(id(b3)), 500);
      expect(await led('refund', booking: id(b3), count: true), 1);
      expect(await w.support.refusal(refundSql, {'b': id(b3), 'r': 'ещё раз'}), 'NOTHING_TO_REFUND');

      await w.advance(day);
      expect(await accrue(), 1);
      await expectNoSplit(id(b1));
      await expectNoSplit(id(b3));
      await expectSplit(id(b2), 600);
      await expectSplit(id(b4), 500);
      await expectTripMoney(trip, charged: 600 + 500 + 500 + 600, refunded: 600 + 500, shared: 600 + 500);
      expect(await earn(d), {'accrued': 516 + 430, 'paid_out': 0, 'to_pay': 516 + 430});

      // Возврат по жалобе, а потом рейс отменён (водителем или сам, как не начатый): второго возврата нет.
      final d2 = await newDriver('Потом отменил');
      final d3 = await newDriver('Потом не приехал');
      final depB = await inMinutes(90);
      final tB = await d2.createTrip(route, depB);
      final tC = await d3.createTrip(route, depB);
      final late = <String>[];
      final paid = <String>[];
      for (final t in [tB, tC]) {
        late.add(id(await p1.book(t, ['front'])));
        paid.add(id(await p4.book(t, ['rl'])));
      }
      await advanceTo(depB.subtract(const Duration(minutes: 50)));
      for (final b in late) {
        expect((await p1.cancel(b))['refund'], 0);
        expect(await staffRefund(w.support, b, 'по жалобе'), 600);
      }
      expect(await cancelTrip(d2, tB), 1, reason: 'при отмене рейса возврат получает только тот, кому ещё не вернули');
      await advanceTo((await tTime(tC, 'ends_at')).add(const Duration(hours: 2, minutes: 1)));
      await accrue();
      expect([await tStatus(tB), await tStatus(tC)], ['cancelled', 'cancelled']);
      for (final b in late) {
        expect(await led('refund', booking: b, count: true), 1);
        expect(await led('refund', booking: b), 600);
      }
      for (final b in paid) {
        expect(await led('refund', booking: b, count: true), 1);
        expect(await led('refund', booking: b), 500);
      }
      await expectTripMoney(tB, charged: 1100, refunded: 1100, shared: 0);
      await expectTripMoney(tC, charged: 1100, refunded: 1100, shared: 0);
    });

    test('возврат по жалобе и расчёт долей одновременно: по брони либо возврат, либо доля — никогда оба', () async {
      await settle();
      const n = 6;
      final p = await newPax('Жалоба в последнюю минуту');
      final q = await newPax('Без жалоб');
      final dep = await inMinutes(40);
      final list = <(Actor, String, String, String)>[]; // водитель, рейс, спорная бронь, обычная бронь
      for (var i = 0; i < n; i++) {
        final d = await newDriver('Спор $i');
        final trip = await d.createTrip(route, dep);
        list.add((d, trip, id(await p.book(trip, ['front'])), id(await q.book(trip, ['rl']))));
      }
      for (final (d, trip, _, _) in list) {
        await drive(d, trip, dep);
      }
      await w.advance(day);
      // Расчёт берёт рейсы по порядку их номеров. По трём последним рейсам жалобы приходят раньше расчёта,
      // по трём первым — сразу за ним: в очереди за одними и теми же рейсами стоят и возвраты, и расчёт.
      list.sort((a, b) => a.$2.compareTo(b.$2));
      final staff = [for (var i = 0; i < n; i++) twin(w.support)];
      final f2 = await newFinance('Расчёт в ту же секунду');
      for (final s in [...staff, f2]) {
        await s.q('select 1'); // подключения открыты заранее
      }
      final results = await gated([for (final e in list) e.$2], [
        for (var i = n ~/ 2; i < n; i++) () => staffRefund(staff[i], list[i].$3),
        () => w.finance.one('select accrue_due()'),
        () => f2.one('select accrue_due()'),
        for (var i = 0; i < n ~/ 2; i++) () => staffRefund(staff[i], list[i].$3),
      ]);
      final refunds = [...results.sublist(n ~/ 2 + 2), ...results.sublist(0, n ~/ 2)]; // снова в порядке рейсов
      final accrued = results.sublist(n ~/ 2, n ~/ 2 + 2);
      expect(accrued.whereType<int>().fold<int>(0, (s, c) => s + c), n, reason: 'каждый рейс начислен ровно один раз: $accrued');
      var refundedCount = 0;
      for (var i = 0; i < n; i++) {
        final (d, trip, disputed, plain) = list[i];
        final r = refunds[i];
        if (r is Refused) {
          expect(r.code, 'ALREADY_ACCRUED', reason: 'рейс $i: $results');
          expect(await bRefund(disputed), 0);
          expect(await led('refund', booking: disputed, count: true), 0);
          await expectSplit(disputed, 600);
          expect(await earn(d), {'accrued': 516 + 430, 'paid_out': 0, 'to_pay': 516 + 430});
          await expectTripMoney(trip, charged: 1100, refunded: 0, shared: 1100);
        } else {
          refundedCount++;
          expect(r, 600, reason: 'рейс $i: $results');
          expect(await bRefund(disputed), 600);
          expect(await led('refund', booking: disputed, count: true), 1);
          await expectNoSplit(disputed);
          expect(await earn(d), {'accrued': 430, 'paid_out': 0, 'to_pay': 430});
          await expectTripMoney(trip, charged: 1100, refunded: 600, shared: 500);
        }
        await expectSplit(plain, 500);
      }
      // Если это условие не выполнено, виноват не сервер, а сам тест: гонка не состоялась (затвор не удержал очередь).
      expect(refundedCount, inInclusiveRange(1, n - 1), reason: 'гонка должна сыграть в обе стороны — и возврат, и начисление: $refunds');
      expect(await accrue(), 0);
    });
  });

  // =====================================================================================
  group('не начатый рейс: одновременный расчёт', () {
    test('не начатые рейсы и расчёт с пяти подключений одновременно: каждый пассажир получил возврат ровно один раз', () async {
      await settle();
      final p1 = await newPax('Ждал машину');
      final p2 = await newPax('Отменил поздно');
      final p3 = await newPax('Отменил рано');
      final x = await newPax('Банк отказал', card: badCard);
      final dep = await inMinutes(125);
      final idle = <(Actor, String, List<String>)>[]; // водитель, рейс, брони: оплачена, отменена поздно, отменена рано, неудачная
      for (var i = 0; i < 3; i++) {
        final d = await newDriver('Не приехал $i');
        final trip = await d.createTrip(route, dep);
        final paid = id(await p1.book(trip, ['front']));
        final late = id(await p2.book(trip, ['rl']));
        final early = id(await p3.book(trip, ['rr']));
        expect((await p3.cancel(early))['refund'], 500);
        final failed = await x.book(trip, ['rr']);
        expect(failed['status'], 'failed');
        idle.add((d, trip, [paid, late, early, id(failed)]));
      }
      final dStarted = await newDriver('Начал и забыл завершить');
      final tStarted = await dStarted.createTrip(route, dep);
      final bStarted = id(await p1.book(tStarted, ['front']));
      await advanceTo(dep.subtract(const Duration(minutes: 50)));
      for (final (_, _, b) in idle) {
        expect((await p2.cancel(b[1]))['refund'], 0);
      }
      await advanceTo(dep.subtract(const Duration(minutes: 10)));
      await start(dStarted, tStarted);
      final ends = await tTime(tStarted, 'ends_at');
      await advanceTo(ends.add(const Duration(hours: 2, minutes: 1)));

      final fs = [w.finance, for (var i = 2; i <= 5; i++) await newFinance('Расчёт $i')];
      for (final f in fs) {
        await f.q('select 1');
      }
      final allTrips = [for (final e in idle) e.$2, tStarted];
      Future<List<Object?>> wave() => gated(allTrips, [for (final f in fs) () => f.one('select accrue_due()')], gapMs: 20);
      final first = await wave();
      expect(first, [0, 0, 0, 0, 0], reason: 'расчёт прошёл на всех подключениях, начислять пока нечего: $first');
      Future<void> check() async {
        for (final (d, trip, b) in idle) {
          expect(await tStatus(trip), 'cancelled');
          expect([for (final bk in b) await bStatus(bk)], ['cancelled', 'cancelled', 'cancelled', 'failed']);
          expect([for (final bk in b) await bRefund(bk)], [600, 500, 500, 0]);
          expect([for (final bk in b) await led('refund', booking: bk, count: true)], [1, 1, 1, 0], reason: 'каждому возврат ровно один раз');
          expect([for (final bk in b) await led('refund', booking: bk)], [600, 500, 500, 0]);
          for (final s in ['front', 'rl', 'rr']) {
            expect(await seatOwner(trip, s), isNull);
          }
          await expectTripMoney(trip, charged: 1600, refunded: 1600, shared: 0);
          expect(await earn(d), {'accrued': 0, 'paid_out': 0, 'to_pay': 0});
        }
      }

      await check();
      expect(await tStatus(tStarted), 'finished');
      expect(await bStatus(bStarted), 'done');
      expect(await led('refund', booking: bStarted, count: true), 0);
      expect(await w.scalar("select count(*)::int from audit_log where action = 'cancel_trip' and details ->> 'reason' = 'never_started' and entity_id = any (@ids::text[])",
          {'ids': '{${idle.map((e) => e.$2).join(',')}}'}), 3, reason: 'каждая автоматическая отмена записана в журнал действий один раз');

      final rows = await ledgerRows();
      expect(await wave(), [0, 0, 0, 0, 0]);
      expect(await ledgerRows(), rows, reason: 'вторая волна расчёта ничего не меняет');

      await advanceTo(ends.add(day));
      final third = await wave();
      expect(third.whereType<int>().fold<int>(0, (s, c) => s + c), 1, reason: 'начислен только начатый рейс, один раз: $third');
      expect(third.whereType<Refused>(), isEmpty);
      await check();
      await expectSplit(bStarted, 600);
      expect(await earn(dStarted), {'accrued': 516, 'paid_out': 0, 'to_pay': 516});
    });
  });

  // =====================================================================================
  group('заблокированный и отклонённый водитель', () {
    const blockSql = 'select staff_block_user(@u::uuid, @b::boolean)';
    Future<void> block(Actor who, Actor target, bool blocked) => who.q(blockSql, {'u': target.id, 'b': '$blocked'});

    /// Сколько броней на рейсах водителя не возвращено полностью и ровно один раз (неудачные не в счёт).
    Future<int> notRefundedOnce(Actor d) async => await w.scalar('''
      select count(*)::int from bookings b join trips t on t.id = b.trip_id
      where t.driver_id = @d::uuid and b.status <> 'failed'
        and (b.status <> 'cancelled' or b.refund <> b.amount
             or (select count(*) from ledger l where l.booking_id = b.id and l.kind = 'refund') <> 1
             or (select coalesce(sum(l.amount), 0) from ledger l where l.booking_id = b.id and l.kind = 'refund') <> b.amount)''',
        {'d': d.id}) as int;

    // ИСПРАВЛЕНО: раньше блокировка водителя не трогала его рейсы: места продолжали продаваться, а рейс отменяла
    // поддержка вручную. Теперь блокировка сразу отменяет все не начатые рейсы водителя с полным возвратом.
    test('водителя заблокировали до рейса: все его не начатые рейсы отменены сразу, деньги возвращены один раз, места больше не продаются', () async {
      final d = await newDriver('Заблокирован');
      final p1 = await newPax('Купил и ждёт');
      final p2 = await newPax('Отменил поздно');
      final p3 = await newPax('Отменил рано');
      final x = await newPax('С отказом банка', card: badCard);
      final late = await newPax('Пришёл после блокировки');
      final dep1 = await inMinutes(125);
      final dep2 = await inMinutes(300);
      final t1 = await d.createTrip(route, dep1);
      final t2 = await d.createTrip(wide, dep2, seats: {'front': 333, 'rl': 1501});
      final b1 = await p1.book(t1, ['front']);
      final b2 = await p2.book(t1, ['rl']);
      final b3 = await p3.book(t1, ['rr']);
      final b4 = await p1.book(t2, ['front', 'rl']);
      expect(b4['amount'], 1834);
      expect((await p3.cancel(id(b3)))['refund'], 500);
      final bx = await x.book(t1, ['rr']);
      expect(bx['status'], 'failed');
      await advanceTo(dep1.subtract(const Duration(minutes: 50)));
      expect((await p2.cancel(id(b2)))['refund'], 0);

      await block(w.support, d, true);
      try {
        expect([await tStatus(t1), await tStatus(t2)], ['cancelled', 'cancelled']);
        expect([await bRefund(id(b1)), await bRefund(id(b2)), await bRefund(id(b3)), await bRefund(id(b4))], [600, 500, 500, 1834],
            reason: 'возврат всем, в том числе отменившему поздно: поездки не будет');
        for (final b in [b1, b2, b3, b4]) {
          expect(await bStatus(id(b)), 'cancelled');
          expect(await led('refund', booking: id(b), count: true), 1);
        }
        expect([await bStatus(id(bx)), await bRefund(id(bx))], ['failed', 0]);
        expect(await notRefundedOnce(d), 0);
        for (final (t, s) in [(t1, 'front'), (t1, 'rl'), (t1, 'rr'), (t2, 'front'), (t2, 'rl')]) {
          expect(await seatOwner(t, s), isNull);
        }
        await expectTripMoney(t1, charged: 1600, refunded: 1600, shared: 0);
        await expectTripMoney(t2, charged: 1834, refunded: 1834, shared: 0);

        expect(await late.refusal(bookSql, {'t': t1, 's': '{front}', 'c': late.cardId, 'k': w.nextKey()}), 'TRIP_CLOSED');
        expect(await late.refusal(bookSql, {'t': t2, 's': '{front}', 'c': late.cardId, 'k': w.nextKey()}), 'TRIP_CLOSED');
        expect(await paxLedger(late, 'charge'), 0);
        expect(await d.refusal('select driver_cancel_trip(@t::uuid)', {'t': t1}), 'BLOCKED');
        expect(await w.support.refusal('select driver_cancel_trip(@t::uuid)', {'t': t1}), 'TRIP_NOT_PLANNED');
        expect(await p1.refusal('select cancel_booking(@b::uuid)', {'b': id(b1)}), 'NOT_CANCELLABLE');
        expect(await w.support.refusal(refundSql, {'b': id(b1), 'r': 'ещё раз'}), 'NOTHING_TO_REFUND');

        final rows = await ledgerRows();
        await block(w.support, d, true);
        expect(await ledgerRows(), rows, reason: 'повторная блокировка ничего не возвращает второй раз');
      } finally {
        await block(w.support, d, false);
      }
      // После снятия блокировки отменённые рейсы не «оживают», деньги не меняются.
      expect([await tStatus(t1), await tStatus(t2)], ['cancelled', 'cancelled']);
      expect(await d.refusal('select driver_start_trip(@t::uuid)', {'t': t1}), 'TRIP_NOT_PLANNED');
      await w.advance(const Duration(days: 3));
      await accrue();
      for (final b in [b1, b2, b3, b4, bx]) {
        await expectNoSplit(id(b));
      }
      expect(await notRefundedOnce(d), 0);
      expect(await earn(d), {'accrued': 0, 'paid_out': 0, 'to_pay': 0});
      await payouts();
      expect(await payoutCount(d), 0);
    });

    // ИСПРАВЛЕНО: раньше блокировка не отменяла рейсы: не начатый рейс заблокированного водителя через 2 часа считался
    // состоявшимся, пассажир оставался без денег, а блокированному начислялась доля и создавалась выплата.
    // Теперь не начатый рейс отменяется в момент блокировки, деньги возвращаются.
    // AMBIGUITY: рейс, который в момент блокировки уже НАЧАТ, не отменяется. Завершить его заблокированный водитель
    // не может (BLOCKED), рейс закрывается сам, доля начисляется и выплачивается заблокированному — если поддержка
    // до начисления не вернёт деньги пассажирам по жалобе (staff_refund_booking).
    test('водителя заблокировали во время рейса: не начатый рейс отменён с возвратом; начатый закрывается сам, блокированному начисляется и выплачивается только он', () async {
      final d = await newDriver('Блок в пути');
      final p = await newPax('Уже едет');
      final p2 = await newPax('Остался без поездки');
      final dep1 = await inMinutes(40);
      final dep2 = await inMinutes(200);
      final t1 = await d.createTrip(route, dep1);
      final t2 = await d.createTrip(route, dep2);
      final b1 = await p.book(t1, ['front']);
      final b2 = await p2.book(t2, ['front']);
      await advanceTo(dep1.subtract(const Duration(minutes: 10)));
      await start(d, t1);
      await block(w.support, d, true);
      try {
        expect([await tStatus(t1), await tStatus(t2)], ['started', 'cancelled']);
        expect([await bStatus(id(b1)), await bStatus(id(b2))], ['paid', 'cancelled']);
        expect([await bRefund(id(b1)), await bRefund(id(b2))], [0, 600]);
        expect(await led('refund', booking: id(b2), count: true), 1);
        expect(await seatOwner(t1, 'front'), id(b1));
        await advanceTo(dep1);
        expect(await d.refusal('select driver_finish_trip(@t::uuid)', {'t': t1}), 'BLOCKED');
        final ends = await tTime(t1, 'ends_at');
        await advanceTo(ends.add(const Duration(hours: 2, minutes: 1)));
        await accrue();
        expect(await tStatus(t1), 'finished');
        expect((await tTime(t1, 'finished_at')).isAtSameMomentAs(ends), isTrue);
        expect(await bStatus(id(b1)), 'done');
        await advanceTo(ends.add(day));
        await accrue();
        await expectSplit(id(b1), 600);
        await expectNoSplit(id(b2));
        await expectTripMoney(t1, charged: 600, refunded: 0, shared: 600);
        await expectTripMoney(t2, charged: 600, refunded: 600, shared: 0);
        await payouts();
        expect([await payoutCount(d), await payoutSum(d)], [1, 516]);
        expect(await led('refund', booking: id(b2), count: true), 1);
      } finally {
        await block(w.support, d, false);
      }
      expect(await earn(d), {'accrued': 516, 'paid_out': 516, 'to_pay': 0});
    });

    test('блокировка водителя одновременно с покупкой, отменами и второй блокировкой: каждому возврат ровно один раз, занятых мест не остаётся', () async {
      const allowed = {'TRIP_CLOSED', 'NOT_CANCELLABLE', 'TRIP_NOT_PLANNED', 'BLOCKED'};
      final sup2 = twin(w.support);
      await sup2.q('select 1');
      final blockedDrivers = <Actor>[];
      final seen = <String>[];
      var boughtInRace = 0, closedInRace = 0;
      try {
        // Шесть участников; в каждой попытке первым в очереди оказывается другой.
        for (var i = 0; i < 6; i++) {
          final d = await newDriver('Блок в гонке $i');
          final p1 = await newPax('Сидит тихо $i');
          final p2 = await newPax('Отменяет в тот же миг $i');
          final buyer = await newPax('Покупает в тот же миг $i');
          final buyer2 = twin(buyer);
          await buyer2.q('select 1');
          final t1 = await d.createTrip(route, await inMinutes(125));
          final t2 = await d.createTrip(route, await inMinutes(300));
          final b1 = await p1.book(t1, ['front']);
          final b2 = await p2.book(t1, ['rl']);
          final b3 = await p1.book(t2, ['rl', 'rr']);
          blockedDrivers.add(d);
          final actions = <(String, Future<Object?> Function())>[
            ('покупка на первый рейс', () => buyer.book(t1, ['rr'])),
            ('отмена брони', () => p2.cancel(id(b2))),
            ('блокировка', () async {
              await block(w.support, d, true);
              return 'blocked';
            }),
            ('отмена рейса водителем', () => cancelTrip(d, t1)),
            ('вторая блокировка', () async {
              await block(sup2, d, true);
              return 'blocked';
            }),
            ('покупка на второй рейс', () => buyer2.book(t2, ['front'])),
          ];
          final order = [...actions.sublist(i), ...actions.sublist(0, i)];
          final raw = await gated([t1, t2], [for (final (_, f) in order) f]);
          final byName = {for (var k = 0; k < order.length; k++) order[k].$1: raw[k]};
          final results = byName.values.toList();
          final why = 'попытка $i: $byName';
          seen.add(why);
          expect(results.whereType<Refused>().map((e) => e.code).toSet().difference(allowed), isEmpty, reason: 'отказы — только понятные коды: $why');
          expect([byName['блокировка'], byName['вторая блокировка']], ['blocked', 'blocked'], reason: 'обе блокировки проходят: $why');
          expect([await tStatus(t1), await tStatus(t2)], ['cancelled', 'cancelled'], reason: why);
          expect(await notRefundedOnce(d), 0, reason: 'каждая оплаченная бронь возвращена полностью и ровно один раз: $why');
          expect([await bRefund(id(b1)), await bRefund(id(b2)), await bRefund(id(b3))], [600, 500, 1000], reason: why);
          expect(await w.scalar('select count(*)::int from trip_seats s join trips t on t.id = s.trip_id where t.driver_id = @d::uuid and s.booking_id is not null', {'d': d.id}), 0,
              reason: why);
          for (final t in [t1, t2]) {
            expect(await led('refund', trip: t), await led('charge', trip: t), reason: 'по рейсу возвращено всё списанное: $why');
          }
          expect(await paxLedger(buyer, 'refund'), await paxLedger(buyer, 'charge'), reason: 'успевшему купить вернули всё: $why');
          if (await paxLedger(buyer, 'charge') > 0) boughtInRace++;
          if (results.whereType<Refused>().any((e) => e.code == 'TRIP_CLOSED')) closedInRace++;
        }
        // Если это условие не выполнено, виноват не сервер, а сам тест: гонка не состоялась (затвор не удержал очередь).
        expect([boughtInRace > 0, closedInRace > 0], [true, true],
            reason: 'за шесть попыток должны встретиться и покупка, успевшая до блокировки, и отказ после неё:\n${seen.join('\n')}');
      } finally {
        for (final d in blockedDrivers) {
          await block(w.support, d, false);
        }
      }
    });

    test('у водителя отозвали одобрение: не начатые рейсы отменены с полным возвратом один раз; начатый рейс он довозит и получает долю только за него', () async {
      const reviewSql = 'select staff_review_driver(@d::uuid, false, @r)';
      final d = await newDriver('Отозвали одобрение');
      final p1 = await newPax('Едет сейчас и позже');
      final p2 = await newPax('Отменил поздно');
      final buyer = await newPax('Хотел купить после отзыва');
      final dep1 = await inMinutes(40);
      final dep2 = dep1.add(const Duration(minutes: 30)); // следующий рейс сразу после первого (в пути 25 минут)
      final dep3 = await inMinutes(400);
      final t1 = await d.createTrip(route, dep1);
      final t2 = await d.createTrip(route, dep2);
      final t3 = await d.createTrip(wide, dep3, seats: {'front': 333, 'rl': 1501});
      final b1 = await p1.book(t1, ['front']);
      final b2 = await p1.book(t2, ['front']);
      final b3 = await p2.book(t2, ['rl']);
      final b4 = await p2.book(t3, ['front', 'rl']);
      await advanceTo(dep1.subtract(const Duration(minutes: 10)));
      await start(d, t1);
      expect((await p2.cancel(id(b3)))['refund'], 0, reason: 'до второго рейса меньше часа');

      final rows = await ledgerRows();
      expect(await w.verifier.refusal(reviewSql, {'d': d.id, 'r': '  '}), 'REASON_REQUIRED');
      expect(await w.support.refusal(reviewSql, {'d': d.id, 'r': 'не моя роль'}), 'FORBIDDEN');
      expect(await ledgerRows(), rows);
      expect([await tStatus(t1), await tStatus(t2), await tStatus(t3)], ['started', 'planned', 'planned']);

      await w.verifier.q(reviewSql, {'d': d.id, 'r': 'истёк срок страховки'});
      expect([await tStatus(t1), await tStatus(t2), await tStatus(t3)], ['started', 'cancelled', 'cancelled']);
      expect([await bRefund(id(b1)), await bRefund(id(b2)), await bRefund(id(b3)), await bRefund(id(b4))], [0, 600, 500, 1834]);
      for (final b in [b2, b3, b4]) {
        expect(await bStatus(id(b)), 'cancelled');
        expect(await led('refund', booking: id(b), count: true), 1);
      }
      expect(await bStatus(id(b1)), 'paid');
      await expectTripMoney(t2, charged: 1100, refunded: 1100, shared: 0);
      await expectTripMoney(t3, charged: 1834, refunded: 1834, shared: 0);
      expect(await buyer.refusal(bookSql, {'t': t3, 's': '{front}', 'c': buyer.cardId, 'k': w.nextKey()}), 'TRIP_CLOSED');
      expect(await paxLedger(buyer, 'charge'), 0);
      final again = await attempt(() => d.createTrip(route, dep3));
      expect(again, isA<Refused>().having((e) => e.code, 'код', 'DRIVER_NOT_APPROVED'));

      final rows2 = await ledgerRows();
      await w.verifier.q(reviewSql, {'d': d.id, 'r': 'повторный отказ'});
      expect(await ledgerRows(), rows2, reason: 'повторный отказ ничего не возвращает второй раз');

      // Начатый рейс отклонённый водитель довозит: поездка состоялась, доля — только за неё.
      await advanceTo(dep1);
      await finish(d, t1);
      await w.advance(day);
      await accrue();
      await expectSplit(id(b1), 600);
      for (final b in [b2, b3, b4]) {
        await expectNoSplit(id(b));
      }
      await expectTripMoney(t1, charged: 600, refunded: 0, shared: 600);
      expect(await earn(d), {'accrued': 516, 'paid_out': 0, 'to_pay': 516});
    });
  });

  // =====================================================================================
  // Эта группа должна оставаться последней: пока находка не исправлена, после неё выплаты не создаются никому.
  group('предел суммы одной выплаты', () {
    // ИСПРАВЛЕНО (раньше было так): (низкая, теоретическая) finance_create_payouts складывает начисления водителя в bigint, а сумма выплаты
    // хранится в int (payouts.amount и ledger.amount). Если одному водителю к выплате накопилось больше
    // 2 147 483 647 драм, функция падает с ошибкой базы 22003 «integer out of range». Выплаты всем водителям создаются
    // одной операцией, поэтому, пока такое начисление не выплачено, выплаты не создаются НИКОМУ.
    // При нынешних пределах цен (место — до 3 000 000 драм) для этого нужно 209 полных рейсов по предельной цене
    // без единой выплаты — на практике недостижимо, но отказ «сырой» и останавливает выплаты всем.
    // Варианты исправления: bigint для сумм выплат; дробить выплату; понятный отказ только по этому водителю.
    test('водителю накопилось к выплате больше 2 147 483 647 драм: выплата создаётся на всю сумму', () async {
      await settle();
      const seats = ['front', 'rl', 'rm', 'rr'];
      const count = 209; // 209 рейсов × 10 320 000 драм водителю = 2 156 880 000 > 2 147 483 647
      const share = 10320000;
      final fast = await w.newRoute('A7', price: 1000000, minutes: 1);
      final d = await newDriver('Очень дорогой водитель');
      final p = await newPax('Платит миллиарды');
      final base = await inMinutes(20);
      final list = <(String, DateTime)>[];
      for (var i = 0; i < count; i++) {
        final dep = base.add(Duration(minutes: 2 * i));
        final trip = await d.createTrip(fast, dep, seats: {for (final s in seats) s: 3000000});
        expect((await p.book(trip, seats))['amount'], 12000000);
        list.add((trip, dep));
      }
      for (final (trip, dep) in list) {
        await drive(d, trip, dep);
      }
      await w.advance(day);
      expect(await accrue(), count);
      expect(await earn(d), {'accrued': count * share, 'paid_out': 0, 'to_pay': count * share});
      final refused = await w.finance.refusal('select finance_create_payouts()');
      expect(refused, isNull, reason: 'finance_create_payouts отказал с кодом $refused (22003 — сумма не помещается в int)');
      expect(await w.scalar('select coalesce(sum(amount), 0)::bigint from payouts where driver_id = @d::uuid', {'d': d.id}), count * share);
      expect(await earn(d), {'accrued': count * share, 'paid_out': count * share, 'to_pay': 0});
    });
  });
}
