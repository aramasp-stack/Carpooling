// Жизненный цикл рейса и одновременные действия — проверки сверх rules_test и concurrency_test.
//
// Пометки в файле:
//   FINDING:    — проверка падает, потому что сервер ведёт себя не по правилам (настоящая ошибка сервера);
//   GAP:        — правила этот случай не описывают; проверка закрепляет то, как сервер ведёт себя сейчас;
//   ИСПРАВЛЕНО: — раньше здесь была ошибка сервера (FINDING); сервер исправлен, проверка закрепляет исправление;
//   ПРАВИЛО:    — раньше был пробел в правилах (GAP) или другое правило; проверка закрепляет новое правило.
@Timeout(Duration(minutes: 15))
library;

import 'dart:math';

import 'package:server_tests/harness.dart';
import 'package:server_tests/invariants.dart';
import 'package:test/test.dart';

/// Запускает действия одновременно. Возвращает ответы и отказы по порядку.
Future<List<Object?>> together(Iterable<Future<Object?> Function()> actions) => Future.wait(actions.map((a) async {
      try {
        return await a();
      } on Refused catch (e) {
        return e;
      }
    }));

const startSql = 'select driver_start_trip(@t::uuid)';
const finishSql = 'select driver_finish_trip(@t::uuid)';
const cancelTripSql = 'select driver_cancel_trip(@t::uuid)';
const markSql = 'select driver_mark_boarding(@t::uuid, @s, @m)';
const rateSql = 'select rate_booking(@b::uuid, @s::int)';
const bookSql = 'select book_seats(@t::uuid, @s::text[], @c::uuid, @k)';
const cancelSql = 'select cancel_booking(@b::uuid)';
const applySql = 'select apply_driver(@c, @k, @p, @s::int, @t)';
const reviewSql = 'select staff_review_driver(@d::uuid, @a::boolean, @r)';
const blockSql = 'select staff_block_user(@u::uuid, @b::boolean)';
const routeStatusSql = 'select staff_set_route_status(@r::uuid, @s::route_status)';
const saveRouteSql =
    'select staff_save_route(@id::uuid, @code, @fn, 40.2264, 44.4930, @tn, 40.1777, 44.5126, @p::int, @m::int, @l::int)';
const createSql = 'select driver_create_trip(@r::uuid, @d::timestamptz, @m::int, @s::jsonb)';
const refundSql = 'select staff_refund_booking(@b::uuid, @r)';
const accrueSql = 'select accrue_due()';

const seatOrder = ['front', 'rl', 'rr', 'rm'];
const fourSeats = {'front': 600, 'rl': 500, 'rr': 500, 'rm': 400};
const nobody = '00000000-0000-4000-8000-000000000000';

/// Код ошибки самой базы (взаимная блокировка 40P01, нарушение уникальности 23505 и т. п.), а не отказ по правилам.
bool isDbError(String code) => code == 'ERROR' || (RegExp(r'^[0-9A-Z]{5}$').hasMatch(code) && code.contains(RegExp('[0-9]')));

List<String> dbErrors(Iterable<Object?> res) =>
    [for (final e in res.whereType<Refused>()) if (isDbError(e.code)) '${e.code}: ${e.message}'];

/// Действие с задержкой в миллисекундах: так в гонках встречаются оба порядка.
Future<T> after<T>(int ms, Future<T> Function() f) => Future<void>.delayed(Duration(milliseconds: ms)).then((_) => f());

void main() {
  late World w;
  late String route;
  late List<Actor> crowd;
  final temp = <Actor>[];
  var routeSeq = 0;

  setUpAll(() async {
    w = await World.create('tt_agent_flow');
    route = await w.newRoute('M1');
    crowd = [for (var i = 0; i < 48; i++) await w.newPassenger('Пассажир $i')];
  });

  Future<void> closeCrowd() async {
    for (final a in crowd) {
      await a.close();
    }
  }

  tearDown(() async {
    // Подключения не копим: база общая с другими наборами проверок.
    for (final a in temp) {
      await a.close();
    }
    temp.clear();
    await closeCrowd();
    for (final a in [w.moderator, w.verifier, w.finance, w.support, w.owner]) {
      await a.close();
    }
    expect(await violations(w), isEmpty, reason: 'целостность данных после теста');
  });
  tearDownAll(() => w.close());

  Future<DateTime> inMinutes(int m) async => (await w.now()).add(Duration(minutes: m));

  Future<Actor> drv(String name, {int seats = 4, bool approve = true}) async {
    final a = await w.newDriver(name, seats: seats, approve: approve);
    temp.add(a);
    return a;
  }

  Future<Actor> pas(String name, {String card = '4111111111111111'}) async {
    final a = await w.newPassenger(name, card: card);
    temp.add(a);
    return a;
  }

  /// Ещё одно подключение того же человека (второй телефон, повторная отправка).
  Actor clone(Actor a) {
    final c = Actor(w, a.id, a.phone, a.name)..cardId = a.cardId;
    temp.add(c);
    return c;
  }

  Future<String> newRoute({int price = 500, int minutes = 25, int length = 9000, bool publish = true}) =>
      w.newRoute('F${++routeSeq}', price: price, minutes: minutes, length: length, publish: publish);

  Future<void> editRoute(String id, String code, {required int price, required int minutes, required int length}) => w.moderator.q(
      saveRouteSql, {'id': id, 'code': code, 'fn': 'Давташен', 'tn': 'Площадь Республики', 'p': '$price', 'm': '$minutes', 'l': '$length'});

  Future<String> tStatus(String t) async => await w.scalar('select status::text from trips where id = @t::uuid', {'t': t}) as String;
  Future<String> bStatus(String b) async => await w.scalar('select status::text from bookings where id = @b::uuid', {'b': b}) as String;
  Future<int> num(String sql, [Map<String, Object?> p = const {}]) async => await w.scalar(sql, p) as int;

  /// Покупатель i берёт место i (front, rl, rr, rm). Возвращает номера броней по порядку покупателей.
  Future<List<String>> sell(String trip, List<Actor> buyers) async {
    final res = await Future.wait([for (var i = 0; i < buyers.length; i++) buyers[i].book(trip, [seatOrder[i]])]);
    for (final r in res) {
      expect(r['status'], 'paid');
    }
    return [for (final r in res) r['booking_id'] as String];
  }

  Map<String, Object?> bookArgs(Actor a, String trip, String seats) => {'t': trip, 's': seats, 'c': a.cardId, 'k': w.nextKey()};
  Map<String, Object?> applyArgs(int seats, {String car = 'Kia Rio'}) =>
      {'c': car, 'k': 'серая', 'p': '35 AA ${100 + Random().nextInt(900)}', 's': '$seats', 't': '01234567'};
  Future<void> block(Actor a, bool on) => w.support.q(blockSql, {'u': a.id, 'b': '$on'});

  /// Переводит часы сервера на время отправления рейса (плюс секунда).
  /// ПРАВИЛО: раньше времени отправления рейс завершить нельзя (TOO_EARLY).
  Future<void> toDeparture(String trip) async {
    final left = await num('select ceil(extract(epoch from departure - app_now()))::int from trips where id = @t::uuid', {'t': trip});
    if (left >= 0) await w.advance(Duration(seconds: left + 1));
  }

  String ids(Iterable<String> list) => '{${list.join(',')}}';
  Future<int> refundOf(String b) => num('select refund from bookings where id = @b::uuid', {'b': b});
  Future<int> heldSeats(Iterable<String> trips) =>
      num('select count(*)::int from trip_seats where trip_id = any(@t::uuid[]) and booking_id is not null', {'t': ids(trips)});

  /// Списано минус возвращено по рейсам.
  Future<int> moneyKept(Iterable<String> trips) => num(
      "select (coalesce(sum(amount) filter (where kind = 'charge'), 0) - coalesce(sum(amount) filter (where kind = 'refund'), 0))::int "
      'from ledger where trip_id = any(@t::uuid[])',
      {'t': ids(trips)});

  /// Брони, по которым возврат записан не один раз или не на всю сумму.
  Future<int> notRefundedOnce(Iterable<String> trips) => num('''
      select count(*)::int from bookings b where b.trip_id = any(@t::uuid[]) and b.status <> 'failed' and (
        b.status <> 'cancelled' or b.refund <> b.amount
        or (select count(*) from ledger l where l.booking_id = b.id and l.kind = 'refund') <> 1
        or (select coalesce(sum(l.amount), 0) from ledger l where l.booking_id = b.id and l.kind = 'refund') <> b.amount)''',
      {'t': ids(trips)});

  // =====================================================================================
  // ЖИЗНЕННЫЙ ЦИКЛ
  // =====================================================================================

  group('жизненный цикл', () {
    test('старт: за 16 минут рано, за 14 — можно, второй раз нельзя', () async {
      final d = await drv('Л1');
      final trip = await d.createTrip(route, await inMinutes(40));
      expect(await d.refusal(startSql, {'t': trip}), 'TOO_EARLY');
      await w.advance(const Duration(minutes: 24)); // до отправления ~16 минут
      expect(await d.refusal(startSql, {'t': trip}), 'TOO_EARLY');
      await w.advance(const Duration(minutes: 2)); // ~14 минут
      expect(await d.refusal(startSql, {'t': trip}), isNull);
      expect(await tStatus(trip), 'started');
      expect(await w.scalar('select started_at is not null from trips where id = @t::uuid', {'t': trip}), true);
      expect(await d.refusal(startSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      await toDeparture(trip);
      await d.q(finishSql, {'t': trip});
    });

    test('финиш до старта и второй финиш — отказ', () async {
      final d = await drv('Л2');
      final trip = await d.createTrip(route, await inMinutes(20));
      expect(await d.refusal(finishSql, {'t': trip}), 'TRIP_NOT_STARTED');
      await w.advance(const Duration(minutes: 6));
      expect(await d.refusal(finishSql, {'t': trip}), 'TRIP_NOT_STARTED', reason: 'окно старта открыто, но рейс не начат');
      await d.q(startSql, {'t': trip});
      expect(await d.refusal(finishSql, {'t': trip}), 'TOO_EARLY', reason: 'ПРАВИЛО: до времени отправления рейс завершить нельзя');
      expect(await tStatus(trip), 'started');
      await toDeparture(trip);
      await d.q(finishSql, {'t': trip});
      expect(await d.refusal(finishSql, {'t': trip}), 'TRIP_NOT_STARTED');
      expect(await d.refusal(startSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await tStatus(trip), 'finished');
    });

    test('чужой водитель, пассажир и поддержка не управляют рейсом; несуществующий рейс', () async {
      final d = await drv('Л3');
      final other = await drv('Л3-чужой');
      final p = crowd[0];
      final trip = await d.createTrip(route, await inMinutes(20));
      await p.book(trip, ['front']);
      await w.advance(const Duration(minutes: 6));
      for (final a in [other, p, w.support, w.moderator]) {
        expect(await a.refusal(startSql, {'t': trip}), 'FORBIDDEN');
        expect(await a.refusal(markSql, {'t': trip, 's': 'front', 'm': 'boarded'}), 'FORBIDDEN');
        expect(await a.refusal(finishSql, {'t': trip}), 'FORBIDDEN');
      }
      expect(await other.refusal(cancelTripSql, {'t': trip}), 'FORBIDDEN');
      expect(await p.refusal(cancelTripSql, {'t': trip}), 'FORBIDDEN');
      expect(await w.moderator.refusal(cancelTripSql, {'t': trip}), 'FORBIDDEN');
      expect(await other.refusal('select * from trip_passengers(@t::uuid)', {'t': trip}), 'FORBIDDEN');

      expect(await d.refusal(startSql, {'t': nobody}), 'TRIP_NOT_FOUND');
      expect(await d.refusal(finishSql, {'t': nobody}), 'TRIP_NOT_FOUND');
      expect(await d.refusal(cancelTripSql, {'t': nobody}), 'TRIP_NOT_FOUND');
      expect(await d.refusal(markSql, {'t': nobody, 's': 'front', 'm': 'boarded'}), 'TRIP_NOT_FOUND');
      expect(await p.refusal(bookSql, bookArgs(p, nobody, '{front}')), 'TRIP_NOT_FOUND');
      expect(await p.refusal(cancelSql, {'b': nobody}), 'BOOKING_NOT_FOUND');
      expect(await p.refusal(rateSql, {'b': nobody, 's': '5'}), 'BOOKING_NOT_FOUND');
      expect(await tStatus(trip), 'planned');
      await d.q(cancelTripSql, {'t': trip});
    });

    test('отметки посадки: рано, в окне до старта, неверная отметка, свободное место, снятие, после финиша', () async {
      final d = await drv('Л4');
      final trip = await d.createTrip(route, await inMinutes(22), seats: fourSeats);
      final b = await sell(trip, [crowd[0], crowd[1]]);
      expect(await d.refusal(markSql, {'t': trip, 's': 'front', 'm': 'boarded'}), 'TOO_EARLY');
      await w.advance(const Duration(minutes: 6)); // ~16 минут
      expect(await d.refusal(markSql, {'t': trip, 's': 'front', 'm': 'boarded'}), 'TOO_EARLY');
      await w.advance(const Duration(minutes: 2)); // ~14 минут: рейс ещё не начат, отмечать уже можно
      expect(await d.refusal(markSql, {'t': trip, 's': 'front', 'm': 'boarded'}), isNull);
      expect(await d.refusal(markSql, {'t': trip, 's': 'front', 'm': 'sat'}), 'BAD_MARK');
      expect(await d.refusal(markSql, {'t': trip, 's': 'rr', 'm': 'boarded'}), 'SEAT_NOT_BOOKED');
      expect(await d.refusal(markSql, {'t': trip, 's': 'trunk', 'm': 'boarded'}), 'SEAT_NOT_BOOKED');
      await d.q(startSql, {'t': trip});
      expect(await d.refusal(markSql, {'t': trip, 's': 'rl', 'm': 'no_show'}), isNull);
      expect(await d.refusal(markSql, {'t': trip, 's': 'rl', 'm': null}), isNull, reason: 'отметку можно снять');
      expect(await w.scalar("select boarding from trip_seats where trip_id = @t::uuid and seat_id = 'rl'", {'t': trip}), isNull);
      expect(await d.refusal(markSql, {'t': trip, 's': 'rl', 'm': 'no_show'}), isNull);
      await toDeparture(trip);
      await d.q(finishSql, {'t': trip});
      expect(await d.refusal(markSql, {'t': trip, 's': 'front', 'm': 'no_show'}), 'TRIP_CLOSED');
      expect(await d.refusal(markSql, {'t': trip, 's': 'rl', 'm': null}), 'TRIP_CLOSED');
      expect(await w.scalar("select boarding from trip_seats where trip_id = @t::uuid and seat_id = 'front'", {'t': trip}), 'boarded');
      expect(await bStatus(b[1]), 'done', reason: 'не пришедший пассажир платит: бронь завершена');
    });

    test('отменённый рейс не принимает ничего', () async {
      final d = await drv('Л5');
      final p = crowd[0];
      final trip = await d.createTrip(route, await inMinutes(20));
      final b = (await sell(trip, [p])).single;
      await w.advance(const Duration(minutes: 6));
      expect(await d.one(cancelTripSql, {'t': trip}), 1);
      expect(await d.refusal(cancelTripSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await w.support.refusal(cancelTripSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await d.refusal(startSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await d.refusal(finishSql, {'t': trip}), 'TRIP_NOT_STARTED');
      expect(await d.refusal(markSql, {'t': trip, 's': 'front', 'm': 'boarded'}), 'TRIP_CLOSED');
      expect(await crowd[1].refusal(bookSql, bookArgs(crowd[1], trip, '{rl}')), 'TRIP_CLOSED');
      expect(await p.refusal(cancelSql, {'b': b}), 'NOT_CANCELLABLE');
      expect(await p.refusal(rateSql, {'b': b, 's': '5'}), 'TRIP_NOT_FINISHED');
      expect(await num("select count(*)::int from ledger where booking_id = @b::uuid and kind = 'refund'", {'b': b}), 1);
      // Через сутки по отменённому рейсу ничего не начисляется и он не «завершается» сам.
      await w.advance(const Duration(hours: 30));
      await w.finance.one('select accrue_due()');
      expect(await tStatus(trip), 'cancelled');
      expect(await num("select count(*)::int from ledger where trip_id = @t::uuid and kind = 'driver_accrual'", {'t': trip}), 0);
    });

    test('начатый рейс: нельзя отменить ни водителю, ни поддержке, ни пассажиру; купить тоже нельзя', () async {
      final d = await drv('Л6');
      final p = crowd[0];
      final trip = await d.createTrip(route, await inMinutes(20));
      final b = (await sell(trip, [p])).single;
      await w.advance(const Duration(minutes: 6));
      await d.q(startSql, {'t': trip});
      expect(await d.refusal(cancelTripSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await w.support.refusal(cancelTripSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await p.refusal(cancelSql, {'b': b}), 'TRIP_ALREADY_STARTED');
      expect(await w.support.refusal(cancelSql, {'b': b}), 'TRIP_ALREADY_STARTED');
      expect(await crowd[1].refusal(bookSql, bookArgs(crowd[1], trip, '{rl}')), 'TRIP_CLOSED');
      expect(await p.refusal(rateSql, {'b': b, 's': '5'}), 'TRIP_NOT_FINISHED');
      expect(await bStatus(b), 'paid');
      await toDeparture(trip);
      expect(await p.refusal(cancelSql, {'b': b}), 'TRIP_ALREADY_STARTED', reason: 'и после времени отправления тоже');
      await d.q(finishSql, {'t': trip});
    });

    test('завершённый рейс не принимает ничего, кроме одной оценки', () async {
      final d = await drv('Л7');
      final p = crowd[0];
      final trip = await d.createTrip(route, await inMinutes(20));
      final b = (await sell(trip, [p])).single;
      await w.advance(const Duration(minutes: 6));
      await d.q(startSql, {'t': trip});
      await toDeparture(trip);
      await d.q(finishSql, {'t': trip});
      expect(await crowd[1].refusal(bookSql, bookArgs(crowd[1], trip, '{rl}')), 'TRIP_CLOSED');
      expect(await p.refusal(cancelSql, {'b': b}), 'NOT_CANCELLABLE');
      expect(await w.support.refusal(cancelSql, {'b': b}), 'NOT_CANCELLABLE');
      expect(await d.refusal(cancelTripSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await w.support.refusal(cancelTripSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await d.refusal(startSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await p.refusal(rateSql, {'b': b, 's': '0'}), 'BAD_RATING');
      expect(await p.refusal(rateSql, {'b': b, 's': '6'}), 'BAD_RATING');
      expect(await crowd[1].refusal(rateSql, {'b': b, 's': '5'}), 'BOOKING_NOT_FOUND', reason: 'чужую поездку оценить нельзя');
      expect(await d.refusal(rateSql, {'b': b, 's': '5'}), 'BOOKING_NOT_FOUND', reason: 'водитель сам себя не оценивает');
      expect(await p.refusal(rateSql, {'b': b, 's': '3'}), isNull);
      expect(await p.refusal(rateSql, {'b': b, 's': '5'}), 'ALREADY_RATED');
      expect(await w.scalar('select rating::text from drivers where user_id = @d::uuid', {'d': d.id}), '3.0');
    });

    test('оценка: до финиша, отменённая бронь, неудачная оплата — нельзя', () async {
      final d = await drv('Л8');
      final paid = crowd[0], early = crowd[1], late = crowd[2];
      final declined = await pas('Отказ банка', card: '4111111111110002');
      final trip = await d.createTrip(route, await inMinutes(70), seats: fourSeats);
      final b = await sell(trip, [paid, early, late]);
      final f = await declined.book(trip, ['rm']);
      expect(f['status'], 'failed');
      expect((await early.cancel(b[1]))['refund'], 500, reason: 'за 70 минут — полный возврат');
      await w.advance(const Duration(minutes: 30));
      expect((await late.cancel(b[2]))['refund'], 0, reason: 'за 40 минут — без возврата');
      for (final x in [b[0], b[1], b[2], f['booking_id']]) {
        final who = x == b[0] ? paid : (x == b[1] ? early : (x == b[2] ? late : declined));
        expect(await who.refusal(rateSql, {'b': x, 's': '5'}), 'TRIP_NOT_FINISHED');
      }
      await w.advance(const Duration(minutes: 30)); // до отправления ~10 минут
      await d.q(startSql, {'t': trip});
      await toDeparture(trip);
      await d.q(finishSql, {'t': trip});
      expect(await bStatus(b[0]), 'done');
      expect(await bStatus(b[1]), 'cancelled');
      expect(await bStatus(b[2]), 'cancelled');
      expect(await bStatus(f['booking_id'] as String), 'failed');
      expect(await early.refusal(rateSql, {'b': b[1], 's': '5'}), 'TRIP_NOT_FINISHED');
      expect(await late.refusal(rateSql, {'b': b[2], 's': '1'}), 'TRIP_NOT_FINISHED');
      expect(await declined.refusal(rateSql, {'b': f['booking_id'], 's': '1'}), 'TRIP_NOT_FINISHED');
      expect(await declined.refusal(cancelSql, {'b': f['booking_id']}), 'NOT_CANCELLABLE');
      // Через сутки: водителю начислено за оплаченную и за поздно отменённую бронь, за рано отменённую — нет.
      await w.advance(const Duration(hours: 25));
      await w.finance.one('select accrue_due()');
      expect(await num("select count(*)::int from ledger where trip_id = @t::uuid and kind = 'driver_accrual'", {'t': trip}), 2);
      expect(await num("select count(*)::int from ledger where booking_id = @b::uuid and kind = 'driver_accrual'", {'b': b[1]}), 0);
    });

    test('рейсы встык разрешены, пересечение хотя бы на минуту — нет', () async {
      final d = await drv('Л9');
      final dep = await inMinutes(100);
      Future<String?> at(int shift) =>
          d.refusal(createSql, {'r': route, 'd': dep.add(Duration(minutes: shift)).toUtc().toIso8601String(), 'm': '0', 's': '[{"id":"front","price":600}]'});
      expect(await at(0), isNull); // 100..125
      expect(await at(25), isNull, reason: 'следующий рейс ровно в момент конца предыдущего');
      expect(await at(-25), isNull, reason: 'предыдущий рейс кончается ровно в момент начала следующего');
      expect(await at(24), 'TRIP_OVERLAP');
      expect(await at(-24), 'TRIP_OVERLAP');
      expect(await at(49), 'TRIP_OVERLAP');
      expect(await at(1), 'TRIP_OVERLAP');
      expect(await at(0), 'TRIP_OVERLAP', reason: 'тот же рейс второй раз');
      expect(await at(50), isNull);
      expect(await num("select count(*)::int from trips where driver_id = @d::uuid and status = 'planned'", {'d': d.id}), 4);
    });

    test('рейсы на двух разных маршрутах не пересекаются по времени', () async {
      final long = await newRoute(minutes: 60);
      final d = await drv('Л10');
      final dep = await inMinutes(120);
      Future<String?> at(String r, int shift) =>
          d.refusal(createSql, {'r': r, 'd': dep.add(Duration(minutes: shift)).toUtc().toIso8601String(), 'm': '0', 's': '[{"id":"front","price":600}]'});
      expect(await at(long, 0), isNull); // 120..180 по длинному маршруту
      expect(await at(route, 30), 'TRIP_OVERLAP', reason: 'внутри длинного рейса');
      expect(await at(route, 59), 'TRIP_OVERLAP');
      expect(await at(route, -20), 'TRIP_OVERLAP', reason: 'короткий рейс не успевает закончиться');
      expect(await at(route, -25), isNull);
      expect(await at(route, 60), isNull);
      expect(await at(long, 61), 'TRIP_OVERLAP', reason: 'длинный рейс пересекается с коротким, стоящим встык');
      expect(await at(long, 85), isNull);
    });

    test('отменённый рейс освобождает время водителя, начатый — нет', () async {
      final d = await drv('Л11');
      final dep = await inMinutes(20);
      final a = await d.createTrip(route, dep);
      expect(await d.refusal(createSql, {'r': route, 'd': dep.add(const Duration(minutes: 5)).toUtc().toIso8601String(), 'm': '0', 's': '[{"id":"front","price":600}]'}),
          'TRIP_OVERLAP');
      await d.q(cancelTripSql, {'t': a});
      final b = await d.createTrip(route, dep.add(const Duration(minutes: 5)));
      await w.advance(const Duration(minutes: 11));
      await d.q(startSql, {'t': b});
      expect(await d.refusal(createSql, {'r': route, 'd': dep.add(const Duration(minutes: 28)).toUtc().toIso8601String(), 'm': '0', 's': '[{"id":"front","price":600}]'}),
          'TRIP_OVERLAP', reason: 'начатый рейс занимает время до своего конца по расписанию');
      await toDeparture(b);
      await d.q(finishSql, {'t': b});
    });

    test('водитель не может вести два начатых рейса одновременно', () async {
      // ИСПРАВЛЕНО: раньше driver_start_trip не смотрел на другие рейсы водителя, и рейсы встык оказывались начатыми оба.
      // ПРАВИЛО: окно старта второго рейса (за 15 минут до отправления) открывается, пока первый ещё идёт, но начать
      // его нельзя, пока первый не завершён: ANOTHER_TRIP_STARTED.
      final d = await drv('Л12');
      final dep = await inMinutes(20);
      final a = await d.createTrip(route, dep); // dep .. dep+25
      final b = await d.createTrip(route, dep.add(const Duration(minutes: 25))); // встык
      addTearDown(() async {
        for (final t in [a, b]) {
          if (await tStatus(t) == 'started') await d.q(finishSql, {'t': t});
        }
      });
      await w.advance(const Duration(minutes: 31)); // первый рейс 11 минут в пути, до второго 14 минут
      await d.q(startSql, {'t': a});
      final second = await d.refusal(startSql, {'t': b});
      final startedNow = await num("select count(*)::int from trips where driver_id = @d::uuid and status = 'started'", {'d': d.id});
      expect(startedNow, 1, reason: 'два начатых рейса у одного водителя (второй старт: ${second ?? 'принят'})');
      expect(second, 'ANOTHER_TRIP_STARTED');
      expect(await tStatus(b), 'planned');
      // Первый завершён — второй начинается.
      await d.q(finishSql, {'t': a});
      expect(await d.refusal(startSql, {'t': b}), isNull);
      expect(await d.refusal(startSql, {'t': a}), 'TRIP_NOT_PLANNED');
      await toDeparture(b);
      await d.q(finishSql, {'t': b});
    });

    test('покупка: 4 места одной бронью, пятое — нельзя; за 6 минут можно, за 4 — закрыто', () async {
      final d = await drv('Л13');
      final d2 = await drv('Л13-2');
      final p = crowd[0], q = crowd[1];
      final trip = await d.createTrip(route, await inMinutes(30), seats: fourSeats);
      final trip2 = await d2.createTrip(route, await inMinutes(30), seats: fourSeats);
      expect(await p.refusal(bookSql, bookArgs(p, trip, '{front,rl,rr,rm,front}')), 'BAD_SEATS');
      final r = await p.book(trip, ['front', 'rl', 'rr', 'rm']);
      expect(r['status'], 'paid');
      expect(r['amount'], 2000);
      expect(await q.refusal(bookSql, bookArgs(q, trip, '{rm}')), 'SEAT_TAKEN');
      await w.advance(const Duration(minutes: 24)); // ~6 минут
      expect((await q.book(trip2, ['front']))['status'], 'paid');
      await w.advance(const Duration(minutes: 2)); // ~4 минуты
      expect(await q.refusal(bookSql, bookArgs(q, trip2, '{rl}')), 'TRIP_CLOSED');
      await w.advance(const Duration(minutes: 10)); // отправление прошло, рейс не начат
      expect(await q.refusal(bookSql, bookArgs(q, trip2, '{rl}')), 'TRIP_CLOSED');
      await d.q(startSql, {'t': trip});
      await d.q(finishSql, {'t': trip});
      await d2.q(startSql, {'t': trip2});
      await d2.q(finishSql, {'t': trip2});
    });

    test('после времени отправления, пока рейс не начат: отмена пассажира без возврата, отмена водителя — полный возврат', () async {
      // GAP: правила не говорят, до какого момента водитель может отменить рейс. Сейчас — в любой момент до нажатия
      // «начать», даже после времени отправления и после отметок посадки; все получают полный возврат.
      final d = await drv('Л14');
      final p = crowd[0], q = crowd[1];
      final trip = await d.createTrip(route, await inMinutes(20));
      final b = await sell(trip, [p, q]);
      await w.advance(const Duration(minutes: 30)); // отправление было 10 минут назад
      await d.q(markSql, {'t': trip, 's': 'front', 'm': 'boarded'});
      expect((await q.cancel(b[1]))['refund'], 0);
      expect(await d.one(cancelTripSql, {'t': trip}), 2);
      expect(await num('select refund from bookings where id = @b::uuid', {'b': b[0]}), 600);
      expect(await num('select refund from bookings where id = @b::uuid', {'b': b[1]}), 500);
      expect(await num('select count(*)::int from trip_seats where trip_id = @t::uuid and (booking_id is not null or boarding is not null)', {'t': trip}), 0);
    });

    test('трёхместная машина: три места, среднего нет, все три одной бронью', () async {
      final d = await drv('Л15', seats: 3);
      final dep = (await inMinutes(60)).toUtc().toIso8601String();
      expect(await d.refusal(createSql, {'r': route, 'd': dep, 'm': '0', 's': '[{"id":"front","price":600},{"id":"rl","price":500},{"id":"rm","price":400},{"id":"rr","price":500}]'}),
          'BAD_SEATS');
      final trip = await d.createTrip(route, await inMinutes(60));
      expect(await num('select count(*)::int from trip_seats where trip_id = @t::uuid', {'t': trip}), 3);
      final p = crowd[0];
      expect(await p.refusal(bookSql, bookArgs(p, trip, '{front,rl,rr,rm}')), 'BAD_SEATS');
      final r = await p.book(trip, ['front', 'rl', 'rr']);
      expect(r['amount'], 1600);
      expect(await crowd[1].refusal(bookSql, bookArgs(crowd[1], trip, '{rm}')), 'BAD_SEATS');
      await d.q(cancelTripSql, {'t': trip});
    });

    test('число мест в машине меняется между рейсами: старый рейс цел, новый — по новой машине', () async {
      final d = await drv('Л16', seats: 4);
      final p = crowd[0];
      final t1 = await d.createTrip(route, await inMinutes(20), seats: fourSeats);
      final r = await p.book(t1, ['rm']);
      await w.advance(const Duration(minutes: 6));
      await d.q(startSql, {'t': t1});
      await toDeparture(t1);
      await d.q(finishSql, {'t': t1});
      expect(await d.refusal(applySql, applyArgs(3)), isNull, reason: 'рейсов впереди нет — машину менять можно');
      expect(await w.scalar('select status::text from drivers where user_id = @d::uuid', {'d': d.id}), 'pending');
      final dep = (await inMinutes(60)).toUtc().toIso8601String();
      expect(await d.refusal(createSql, {'r': route, 'd': dep, 'm': '0', 's': '[{"id":"front","price":600}]'}), 'DRIVER_NOT_APPROVED',
          reason: 'после повторной заявки нужен новый допуск');
      await w.verifier.q(reviewSql, {'d': d.id, 'a': 'true', 'r': null});
      expect(await d.refusal(createSql, {'r': route, 'd': dep, 'm': '0', 's': '[{"id":"rm","price":400}]'}), 'BAD_SEATS');
      expect(await d.refusal(createSql, {'r': route, 'd': dep, 'm': '0', 's': '[{"id":"front","price":600}]'}), isNull);
      expect(await bStatus(r['booking_id'] as String), 'done');
      expect(await num("select count(*)::int from trip_seats where trip_id = @t::uuid and seat_id = 'rm'", {'t': t1}), 1);
      expect(await p.refusal(rateSql, {'b': r['booking_id'], 's': '4'}), isNull, reason: 'оценка старой поездки после смены машины');
    });

    test('менять машину нельзя, пока есть предстоящий или начатый рейс; после финиша и после отмены — можно', () async {
      final d = await drv('Л17');
      final t1 = await d.createTrip(route, await inMinutes(20));
      final t2 = await d.createTrip(route, await inMinutes(120));
      expect(await d.refusal(applySql, applyArgs(3)), 'DRIVER_HAS_ACTIVE_TRIPS');
      await w.advance(const Duration(minutes: 6));
      await d.q(startSql, {'t': t1});
      await d.q(cancelTripSql, {'t': t2});
      expect(await d.refusal(applySql, applyArgs(3)), 'DRIVER_HAS_ACTIVE_TRIPS', reason: 'рейс идёт');
      expect(await d.refusal(applySql, applyArgs(5)), 'BAD_SEATS_TOTAL');
      expect(await d.refusal(applySql, {'c': ' ', 'k': 'серая', 'p': '35 AA 001', 's': '4', 't': '01234567'}), 'BAD_ARGUMENT');
      await toDeparture(t1);
      await d.q(finishSql, {'t': t1});
      expect(await d.refusal(applySql, applyArgs(3)), isNull);
      expect(await num('select seats_total from drivers where user_id = @d::uuid', {'d': d.id}), 3);
    });

    test('водителю отказали в допуске во время рейса: начатый рейс идёт дальше, машину менять нельзя, пока он не завершён', () async {
      // ИСПРАВЛЕНО: раньше apply_driver запрещал менять анкету при рейсах только в статусе approved, а отказ в допуске
      // оставлял проданные рейсы: отклонённый водитель подавал анкету с трёхместной машиной при проданном месте «rm».
      // ПРАВИЛО: отказ сразу отменяет не начатые рейсы с полным возвратом; начатый рейс идёт дальше, и пока у водителя
      // есть рейс, анкету менять нельзя (DRIVER_HAS_ACTIVE_TRIPS) — при любом его статусе.
      final d = await drv('Л18', seats: 4);
      final p = crowd[0], q = crowd[1];
      final running = await d.createTrip(route, await inMinutes(20), seats: fourSeats);
      final later = await d.createTrip(route, await inMinutes(200), seats: fourSeats);
      final rb = (await p.book(running, ['rm']))['booking_id'] as String;
      final lb = (await q.book(later, ['rm']))['booking_id'] as String;
      await w.advance(const Duration(minutes: 6));
      await d.q(startSql, {'t': running});
      await w.verifier.q(reviewSql, {'d': d.id, 'a': 'false', 'r': 'документы просрочены'});
      expect(await tStatus(later), 'cancelled', reason: 'не начатый рейс отклонённого водителя отменён');
      expect(await bStatus(lb), 'cancelled');
      expect(await refundOf(lb), 400);
      expect(await tStatus(running), 'started', reason: 'начатый рейс не трогаем: пассажиры уже едут');
      expect(await bStatus(rb), 'paid');
      final second = await d.refusal(applySql, applyArgs(3, car: 'Daewoo Matiz'));
      expect(await violations(w), isEmpty, reason: 'после повторной заявки отклонённого водителя (ответ сервера: ${second ?? 'принято'})');
      expect(second, 'DRIVER_HAS_ACTIVE_TRIPS');
      expect(await num('select seats_total from drivers where user_id = @d::uuid', {'d': d.id}), 4);
      await toDeparture(running);
      expect(await d.refusal(finishSql, {'t': running}), isNull, reason: 'начатый рейс водитель доводит до конца и без допуска');
      expect(await bStatus(rb), 'done');
      expect(await d.refusal(applySql, applyArgs(3, car: 'Daewoo Matiz')), isNull, reason: 'рейсов не осталось — анкету менять можно');
      expect(await w.scalar("select status::text || ' ' || seats_total from drivers where user_id = @d::uuid", {'d': d.id}), 'pending 3');
    });

    test('водителю отказали в допуске: его не начатые рейсы сразу отменяются, деньги возвращаются полностью', () async {
      // ПРАВИЛО (раньше — пробел в правилах: рейсы оставались в продаже, водитель без допуска их начинал и получал деньги):
      // отказ одобренному водителю сразу отменяет все его не начатые рейсы; возврат полный, в том числе тем, кто отменил
      // поздно и остался без возврата. Начать рейс без допуска нельзя: DRIVER_NOT_APPROVED.
      final d = await drv('Л19');
      final p = crowd[0], q = crowd[1], late = crowd[2];
      final trip = await d.createTrip(route, await inMinutes(20));
      final trip2 = await d.createTrip(route, await inMinutes(200));
      final b = await sell(trip, [p, late]);
      final b2 = await sell(trip2, [p, q]);
      expect((await late.cancel(b[1]))['refund'], 0, reason: 'за 20 минут — без возврата');
      await w.verifier.q(reviewSql, {'d': d.id, 'a': 'false', 'r': 'жалобы'});
      for (final t in [trip, trip2]) {
        expect(await tStatus(t), 'cancelled');
        expect(await num("select count(*)::int from audit_log where action = 'cancel_trip' and entity_id = @t and details ->> 'reason' = 'driver_rejected'", {'t': t}), 1);
      }
      expect(await heldSeats([trip, trip2]), 0);
      expect(await moneyKept([trip, trip2]), 0, reason: 'возвращено всё списанное');
      expect(await notRefundedOnce([trip, trip2]), 0);
      expect([await refundOf(b[0]), await refundOf(b[1]), await refundOf(b2[0]), await refundOf(b2[1])], [600, 500, 600, 500]);
      expect(await d.refusal(createSql, {'r': route, 'd': (await inMinutes(300)).toUtc().toIso8601String(), 'm': '0', 's': '[{"id":"front","price":600}]'}),
          'DRIVER_NOT_APPROVED');
      expect(await q.one('select count(*)::int from driver_public where user_id = @d::uuid', {'d': d.id}), 0,
          reason: 'пассажир уже не видит карточку этого водителя');
      expect(await q.refusal(bookSql, bookArgs(q, trip, '{rr}')), 'TRIP_CLOSED');
      expect(await q.refusal(bookSql, bookArgs(q, trip2, '{rr}')), 'TRIP_CLOSED');
      await w.advance(const Duration(minutes: 6));
      expect(await d.refusal(startSql, {'t': trip}), 'DRIVER_NOT_APPROVED');
      expect(await d.refusal(cancelTripSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      expect(await w.verifier.refusal(reviewSql, {'d': d.id, 'a': 'false', 'r': null}), 'REASON_REQUIRED');
      // Допуск вернули: отменённые рейсы не возвращаются, новые ставить можно.
      await w.verifier.q(reviewSql, {'d': d.id, 'a': 'true', 'r': null});
      expect(await tStatus(trip), 'cancelled');
      expect(await d.refusal(startSql, {'t': trip}), 'TRIP_NOT_PLANNED');
      final again = await d.createTrip(route, await inMinutes(300));
      await d.q(cancelTripSql, {'t': again});
    });

    test('заблокированный водитель ничего не может; его не начатые рейсы сразу отменяются с полным возвратом', () async {
      // ПРАВИЛО (раньше — пробел в правилах: рейс заблокированного водителя оставался в продаже, пока его не отменит
      // поддержка): блокировка водителя сразу отменяет его не начатые рейсы и возвращает деньги полностью.
      final d = await drv('Л20');
      final p = crowd[0], q = crowd[1];
      final trip = await d.createTrip(route, await inMinutes(20));
      final b = await sell(trip, [p, q]);
      expect((await q.cancel(b[1]))['refund'], 0, reason: 'за 20 минут — без возврата');
      await block(d, true);
      expect(await tStatus(trip), 'cancelled');
      expect(await num("select count(*)::int from audit_log where action = 'cancel_trip' and entity_id = @t and details ->> 'reason' = 'driver_blocked'", {'t': trip}), 1);
      expect([await refundOf(b[0]), await refundOf(b[1])], [600, 500], reason: 'полный возврат и поздно отменившему');
      expect(await notRefundedOnce([trip]), 0);
      expect(await heldSeats([trip]), 0);
      await w.advance(const Duration(minutes: 6));
      expect(await d.refusal(startSql, {'t': trip}), 'BLOCKED');
      expect(await d.refusal(markSql, {'t': trip, 's': 'front', 'm': 'boarded'}), 'BLOCKED');
      expect(await d.refusal(cancelTripSql, {'t': trip}), 'BLOCKED');
      expect(await d.refusal(finishSql, {'t': trip}), 'BLOCKED');
      expect(await d.refusal(applySql, applyArgs(3)), 'BLOCKED');
      expect(await d.refusal('select driver_earnings()'), 'BLOCKED');
      expect(await d.refusal('select * from trip_passengers(@t::uuid)', {'t': trip}), 'BLOCKED');
      expect(await d.refusal(createSql, {'r': route, 'd': (await inMinutes(300)).toUtc().toIso8601String(), 'm': '0', 's': '[{"id":"front","price":600}]'}),
          'BLOCKED');
      expect(await crowd[2].refusal(bookSql, bookArgs(crowd[2], trip, '{rr}')), 'TRIP_CLOSED');
      expect(await w.support.refusal(cancelTripSql, {'t': trip}), 'TRIP_NOT_PLANNED', reason: 'отменять уже нечего');
      expect(await w.support.refusal(blockSql, {'u': d.id, 'b': 'true'}), isNull, reason: 'повторная блокировка ничего не ломает');
      expect(await notRefundedOnce([trip]), 0);
      await block(d, false);
      expect(await tStatus(trip), 'cancelled', reason: 'снятие блокировки отменённый рейс не возвращает');
      final again = await d.createTrip(route, await inMinutes(300));
      expect(await tStatus(again), 'planned', reason: 'после снятия блокировки водитель работает дальше');
      await d.q(cancelTripSql, {'t': again});
    });

    test('рейс, который водитель так и не начал, не состоялся: через 2 часа после конца он отменяется с полным возвратом', () async {
      // ИСПРАВЛЕНО: раньше accrue_due «завершал» любой рейс через 2 часа после конца по расписанию, даже не начатый
      // (planned → finished в обход started): бронь становилась «поездка состоялась», а доля начислялась водителю.
      // ПРАВИЛО: не начатый рейс через 2 часа после конца по расписанию отменяется; возврат полный — и тем, кто
      // отменил поздно без возврата: поездки не было.
      final d = await drv('Л21');
      final p = crowd[0], q = crowd[1];
      final trip = await d.createTrip(route, await inMinutes(120)); // конец по расписанию — через 145 минут
      final b = await sell(trip, [p, q]);
      await w.advance(const Duration(minutes: 100));
      expect((await q.cancel(b[1]))['refund'], 0, reason: 'за 20 минут — без возврата');
      await w.advance(const Duration(minutes: 164)); // после конца прошёл 1 час 59 минут
      await w.finance.one(accrueSql);
      expect(await tStatus(trip), 'planned', reason: 'раньше чем через 2 часа после конца рейс не отменяется');
      expect(await bStatus(b[0]), 'paid');
      expect(await d.refusal(startSql, {'t': trip}), 'TOO_LATE');
      await w.advance(const Duration(minutes: 2)); // 2 часа 1 минута
      await w.finance.one(accrueSql);
      final st = await tStatus(trip);
      final bs = await bStatus(b[0]);
      final started = await w.scalar('select started_at is not null or finished_at is not null from trips where id = @t::uuid', {'t': trip});
      expect('$st / бронь $bs / начат: $started', 'cancelled / бронь cancelled / начат: false',
          reason: 'рейс, который никто не начинал, не должен закрываться как состоявшийся');
      expect([await refundOf(b[0]), await refundOf(b[1])], [600, 500]);
      expect(await notRefundedOnce([trip]), 0);
      expect(await heldSeats([trip]), 0);
      expect(await num("select count(*)::int from audit_log where action = 'cancel_trip' and entity_id = @t and details ->> 'reason' = 'never_started'", {'t': trip}), 1);
      expect(await p.refusal(rateSql, {'b': b[0], 's': '1'}), 'TRIP_NOT_FINISHED');
      await w.advance(const Duration(hours: 30));
      await w.finance.one(accrueSql);
      expect(await tStatus(trip), 'cancelled');
      expect(await num("select count(*)::int from ledger where trip_id = @t::uuid and kind in ('driver_accrual', 'commission', 'state_duty')", {'t': trip}), 0,
          reason: 'за несостоявшийся рейс никому ничего не начислено');
      expect(await notRefundedOnce([trip]), 0, reason: 'повторный запуск начисления не возвращает второй раз');
    });

    test('водителя заблокировали во время рейса: рейс закрывается сам, пассажир может оценить', () async {
      final d = await drv('Л22');
      final p = crowd[0];
      final trip = await d.createTrip(route, await inMinutes(20));
      final b = (await sell(trip, [p])).single;
      await w.advance(const Duration(minutes: 6));
      await d.q(startSql, {'t': trip});
      await block(d, true);
      expect(await d.refusal(finishSql, {'t': trip}), 'BLOCKED');
      expect(await w.moderator.refusal(routeStatusSql, {'r': route, 's': 'archived'}), 'ROUTE_HAS_ACTIVE_TRIPS');
      await w.advance(const Duration(hours: 3));
      await w.finance.one('select accrue_due()');
      expect(await tStatus(trip), 'finished');
      expect(await w.scalar('select finished_at = ends_at from trips where id = @t::uuid', {'t': trip}), true);
      expect(await bStatus(b), 'done');
      expect(await p.refusal(rateSql, {'b': b, 's': '2'}), isNull);
    });

    test('пассажира заблокировали после оплаты: сам ничего не может, поддержка отменяет бронь по обычным правилам', () async {
      final d = await drv('Л23');
      final p = await pas('Блок после оплаты');
      final p2 = await pas('Блок после оплаты 2');
      final trip = await d.createTrip(route, await inMinutes(200));
      final trip2 = await d.createTrip(route, await inMinutes(20));
      final b = (await p.book(trip, ['front', 'rl']))['booking_id'] as String;
      final b2 = (await p2.book(trip2, ['front']))['booking_id'] as String;
      await block(p, true);
      await block(p2, true);
      expect(await p.refusal(cancelSql, {'b': b}), 'BLOCKED');
      expect(await p.refusal(bookSql, bookArgs(p, trip, '{rr}')), 'BLOCKED');
      expect(await p.refusal('select bind_card_sim(@n)', {'n': '4111111111111111'}), 'BLOCKED');
      expect(await p.refusal('select remove_card(@c::uuid)', {'c': p.cardId}), 'BLOCKED');
      expect(await bStatus(b), 'paid', reason: 'бронь и места остаются за заблокированным пассажиром');
      expect(await crowd[0].refusal(bookSql, bookArgs(crowd[0], trip, '{front}')), 'SEAT_TAKEN');
      // Поддержка отменяет за него: за 200 минут — полный возврат, место снова в продаже.
      expect((Map<String, dynamic>.from(await w.support.one(cancelSql, {'b': b}) as Map))['refund'], 1100);
      expect((await crowd[0].book(trip, ['front']))['status'], 'paid');
      // Вторая бронь: поездка состоялась, заблокированный пассажир оценить не может; после разблокировки — может.
      await w.advance(const Duration(minutes: 6));
      await d.q(startSql, {'t': trip2});
      await d.q(markSql, {'t': trip2, 's': 'front', 'm': 'boarded'});
      await toDeparture(trip2);
      await d.q(finishSql, {'t': trip2});
      expect(await bStatus(b2), 'done');
      expect(await p2.refusal(rateSql, {'b': b2, 's': '5'}), 'BLOCKED');
      await block(p2, false);
      expect(await p2.refusal(rateSql, {'b': b2, 's': '5'}), isNull);
      await d.q(cancelTripSql, {'t': trip});
    });

    test('заблокированный пользователь не может менять даже свой профиль', () async {
      // ИСПРАВЛЕНО: раньше register_profile не проверял блокировку — заблокированный менял имя и язык.
      final p = await pas('Старое имя');
      await block(p, true);
      final res = await p.refusal('select register_profile(@n, @l)', {'n': 'Новое имя', 'l': 'en'});
      final name = await w.scalar('select name from profiles where id = @u::uuid', {'u': p.id});
      expect('$res / $name', 'BLOCKED / Старое имя');
    });

    test('маршрут с рейсами: цену и название менять можно, точки, длину и время в пути — нет; цены мест рейса прежние', () async {
      // ПРАВИЛО (раньше — пробел в правилах: время в пути менялось под проданными рейсами, и пересечение рейсов
      // считалось по старому времени): пока на маршруте есть предстоящий или начатый рейс, его точки, длину и время
      // в пути менять нельзя — ROUTE_HAS_ACTIVE_TRIPS. Цена, название и код меняются; у выставленных мест цена своя.
      final r = await newRoute(price: 500, minutes: 25);
      final code = 'F$routeSeq';
      final d = await drv('Л25');
      final p = crowd[0];
      final dep = await inMinutes(120);
      final trip = await d.createTrip(r, dep, seats: {'front': 600, 'rl': 1500});
      final ends = await w.scalar('select ends_at from trips where id = @t::uuid', {'t': trip});
      Future<String?> edit({int price = 100, int minutes = 25, int length = 9000, String fromLat = '40.2264', String name = 'Давташен'}) => w.moderator.refusal(
          'select staff_save_route(@id::uuid, @code, @fn, $fromLat, 44.4930, @tn, 40.1777, 44.5126, @p::int, @m::int, @l::int)',
          {'id': r, 'code': code, 'fn': name, 'tn': 'Площадь Республики', 'p': '$price', 'm': '$minutes', 'l': '$length'});
      expect(await edit(minutes: 60), 'ROUTE_HAS_ACTIVE_TRIPS');
      expect(await edit(length: 8999), 'ROUTE_HAS_ACTIVE_TRIPS');
      expect(await edit(fromLat: '40.2265'), 'ROUTE_HAS_ACTIVE_TRIPS');
      expect(await w.scalar("select base_price || ' ' || minutes || ' ' || length_m || ' ' || from_lat from routes where id = @r::uuid", {'r': r}), '500 25 9000 40.2264',
          reason: 'отказанная правка не меняет ничего, в том числе цену');
      expect(await edit(price: 0), 'BAD_ARGUMENT');
      expect(await edit(price: 1000001), 'BAD_ARGUMENT');
      expect(await edit(minutes: 601), 'BAD_ARGUMENT');
      expect(await edit(length: 99), 'BAD_ARGUMENT');
      expect(await edit(name: 'Давташен, 4-й квартал'), isNull, reason: 'цена и название меняются и при рейсах');
      expect(await w.scalar("select base_price || ' ' || from_name from routes where id = @r::uuid", {'r': r}), '100 Давташен, 4-й квартал');
      expect(await w.scalar('select ends_at from trips where id = @t::uuid', {'t': trip}), ends);
      expect(await num("select price from trip_seats where trip_id = @t::uuid and seat_id = 'rl'", {'t': trip}), 1500);
      final b = await p.book(trip, ['rl']);
      expect(b['amount'], 1500, reason: 'пассажир платит цену, выставленную водителем, а не новую базовую');
      // Новые рейсы — по новой цене маршрута.
      expect(await d.refusal(createSql, {'r': r, 'd': dep.add(const Duration(minutes: 200)).toUtc().toIso8601String(), 'm': '0', 's': '[{"id":"front","price":301}]'}),
          'BAD_PRICE', reason: 'потолок цены — три новые базовые');
      final t2 = await d.createTrip(r, dep.add(const Duration(minutes: 200)), seats: {'front': 300});
      expect(await w.scalar("select ends_at - departure = interval '25 minutes' from trips where id = @t::uuid", {'t': t2}), true);
      // Начатый рейс держит маршрут так же, как предстоящий.
      await d.q(cancelTripSql, {'t': t2});
      await w.advance(const Duration(minutes: 106));
      await d.q(startSql, {'t': trip});
      expect(await edit(minutes: 60), 'ROUTE_HAS_ACTIVE_TRIPS', reason: 'рейс идёт');
      await toDeparture(trip);
      await d.q(finishSql, {'t': trip});
      // Рейсов не осталось — меняется всё; новый рейс считается по новому времени в пути.
      expect(await edit(minutes: 60, length: 1000, fromLat: '40.2265'), isNull);
      final t3 = await d.createTrip(r, await inMinutes(60), meet: 1000, seats: {'front': 300});
      expect(await w.scalar("select ends_at - departure = interval '60 minutes' from trips where id = @t::uuid", {'t': t3}), true);
      expect(await d.refusal(createSql, {'r': r, 'd': (await inMinutes(200)).toUtc().toIso8601String(), 'm': '1001', 's': '[{"id":"front","price":300}]'}),
          'MEET_POINT_OUTSIDE_DISTRICT');
      expect(await w.scalar('select ends_at from trips where id = @t::uuid', {'t': trip}), ends, reason: 'завершённый рейс не пересчитывается');
      await d.q(cancelTripSql, {'t': t3});
    });

    test('маршрут укоротили: место посадки проданного рейса остаётся в пределах маршрута', () async {
      // ИСПРАВЛЕНО: раньше staff_save_route менял длину (и координаты начала) маршрута, не глядя на действующие рейсы:
      // рейс с местом посадки на 1400-м метре оставался в продаже на маршруте длиной 800 метров.
      // ПРАВИЛО: такая правка — отказ ROUTE_HAS_ACTIVE_TRIPS.
      final r = await newRoute(length: 9000);
      final code = 'F$routeSeq';
      final d = await drv('Л26');
      final trip = await d.createTrip(r, await inMinutes(120), meet: 1400);
      await sell(trip, [crowd[0]]);
      addTearDown(() => editRoute(r, code, price: 500, minutes: 25, length: 9000));
      final res = await w.moderator.refusal(
          saveRouteSql, {'id': r, 'code': code, 'fn': 'Давташен', 'tn': 'Площадь Республики', 'p': '500', 'm': '25', 'l': '800'});
      final bad = await num('''select count(*)::int from trips t join routes r on r.id = t.route_id
          where t.id = @t::uuid and t.status = 'planned' and t.meet_along > r.length_m''', {'t': trip});
      expect(bad, 0, reason: 'место посадки (1400 м) дальше конца маршрута (800 м); ответ сервера на правку: ${res ?? 'принято'}');
      expect(res, 'ROUTE_HAS_ACTIVE_TRIPS');
      expect(await num('select length_m from routes where id = @r::uuid', {'r': r}), 9000);
    });

    test('маршрут с начатым рейсом нельзя снять; после финиша — можно; архив и возврат в продажу', () async {
      final r = await newRoute();
      final d = await drv('Л27');
      final p = crowd[0];
      final trip = await d.createTrip(r, await inMinutes(20));
      final b = (await sell(trip, [p])).single;
      expect(await w.moderator.refusal(routeStatusSql, {'r': r, 's': 'draft'}), 'ROUTE_HAS_ACTIVE_TRIPS');
      await w.advance(const Duration(minutes: 6));
      await d.q(startSql, {'t': trip});
      expect(await w.moderator.refusal(routeStatusSql, {'r': r, 's': 'archived'}), 'ROUTE_HAS_ACTIVE_TRIPS');
      expect(await w.moderator.refusal(routeStatusSql, {'r': r, 's': 'draft'}), 'ROUTE_HAS_ACTIVE_TRIPS');
      await toDeparture(trip);
      await d.q(finishSql, {'t': trip});
      expect(await w.moderator.refusal(routeStatusSql, {'r': r, 's': 'archived'}), isNull);
      final dep = (await inMinutes(300)).toUtc().toIso8601String();
      expect(await d.refusal(createSql, {'r': r, 'd': dep, 'm': '0', 's': '[{"id":"front","price":600}]'}), 'ROUTE_NOT_AVAILABLE');
      // Завершённая поездка на архивном маршруте: оценка и начисление работают.
      expect(await p.refusal(rateSql, {'b': b, 's': '5'}), isNull);
      await w.advance(const Duration(hours: 25));
      await w.finance.one('select accrue_due()');
      expect(await num("select count(*)::int from ledger where booking_id = @b::uuid and kind = 'driver_accrual'", {'b': b}), 1);
      // Вернули в продажу: рейсы снова ставятся.
      expect(await w.moderator.refusal(routeStatusSql, {'r': r, 's': 'published'}), isNull);
      final t2 = await d.createTrip(r, await inMinutes(300));
      expect((await p.book(t2, ['front']))['status'], 'paid');
      expect(await w.moderator.refusal(routeStatusSql, {'r': r, 's': 'archived'}), 'ROUTE_HAS_ACTIVE_TRIPS');
      await d.q(cancelTripSql, {'t': t2});
      expect(await w.moderator.refusal(routeStatusSql, {'r': r, 's': 'draft'}), isNull);
      expect(await w.moderator.refusal(routeStatusSql, {'r': nobody, 's': 'published'}), 'ROUTE_NOT_FOUND');
    });

    test('границы постановки рейса: 14 минут рано, 16 — можно; 7 суток без минуты — можно, с минутой — нельзя', () async {
      final d = await drv('Л28');
      Future<String?> at(int m) async =>
          d.refusal(createSql, {'r': route, 'd': (await inMinutes(m)).toUtc().toIso8601String(), 'm': '0', 's': '[{"id":"front","price":600}]'});
      expect(await at(14), 'DEPARTURE_TOO_SOON');
      expect(await at(-60), 'DEPARTURE_TOO_SOON', reason: 'рейс в прошлом');
      expect(await at(16), isNull);
      expect(await at(7 * 24 * 60 + 1), 'DEPARTURE_TOO_FAR');
      expect(await at(7 * 24 * 60 - 1), isNull);
      expect(await d.refusal(createSql, {'r': route, 'd': null, 'm': '0', 's': '[{"id":"front","price":600}]'}), 'DEPARTURE_TOO_SOON');
    });

    test('место посадки: 1500 м — можно, 1501 — нет; на коротком маршруте — не дальше его конца', () async {
      final short = await newRoute(length: 1000);
      final d = await drv('Л29');
      var shift = 60;
      Future<String?> at(String r, int meet) async =>
          d.refusal(createSql, {'r': r, 'd': (await inMinutes(shift += 30)).toUtc().toIso8601String(), 'm': '$meet', 's': '[{"id":"front","price":600}]'});
      expect(await at(route, 1501), 'MEET_POINT_OUTSIDE_DISTRICT');
      expect(await at(route, 1500), isNull);
      expect(await at(short, 1001), 'MEET_POINT_OUTSIDE_DISTRICT');
      expect(await at(short, 1000), isNull);
      expect(await at(short, 0), isNull);
    });

    test('водитель забыл завершить начатый рейс: закрывается сам концом по расписанию', () async {
      final d = await drv('Л30');
      final p = crowd[0];
      final t1 = await d.createTrip(route, await inMinutes(20));
      final b1 = (await sell(t1, [p])).single;
      await w.advance(const Duration(minutes: 6));
      await d.q(startSql, {'t': t1});
      await w.advance(const Duration(minutes: 100)); // конец по расписанию прошёл, двух часов ещё нет
      await w.finance.one('select accrue_due()');
      expect(await tStatus(t1), 'started', reason: 'раньше чем через 2 часа после конца рейс сам не закрывается');
      await w.advance(const Duration(hours: 2));
      await w.finance.one('select accrue_due()');
      expect(await tStatus(t1), 'finished');
      expect(await w.scalar('select finished_at = ends_at from trips where id = @t::uuid', {'t': t1}), true);
      expect(await d.refusal(finishSql, {'t': t1}), 'TRIP_NOT_STARTED');
      expect(await bStatus(b1), 'done');
      expect(await num("select count(*)::int from ledger where trip_id = @t::uuid and kind = 'driver_accrual'", {'t': t1}), 0, reason: 'сутки после конца ещё не прошли');
      await w.advance(const Duration(hours: 22));
      await w.finance.one('select accrue_due()');
      expect(await num("select count(*)::int from ledger where trip_id = @t::uuid and kind = 'driver_accrual'", {'t': t1}), 1);
    });

    test('поздний старт: до конца по расписанию — можно, после — TOO_LATE; рейс не заканчивается раньше, чем начался', () async {
      // ИСПРАВЛЕНО: раньше у driver_start_trip не было верхней границы — рейс «начинали» через час после его конца
      // по расписанию, затем accrue_due закрывал его временем ends_at, и finished_at оказывался раньше started_at.
      // ПРАВИЛО: после конца по расписанию начать рейс нельзя (TOO_LATE); не начатый рейс отменяется с возвратом,
      // а начатый и забытый закрывается временем не раньше своего старта.
      final d = await drv('Л30-2');
      final d2 = await drv('Л30-3');
      final p = crowd[0], q = crowd[1];
      final dep = await inMinutes(20); // конец по расписанию — через 45 минут
      final t1 = await d.createTrip(route, dep);
      final t2 = await d2.createTrip(route, dep);
      final b1 = (await sell(t1, [p])).single;
      final b2 = (await sell(t2, [q])).single;
      await w.advance(const Duration(minutes: 44)); // до конца по расписанию меньше минуты
      expect(await d2.refusal(startSql, {'t': t2}), isNull, reason: 'до конца по расписанию начать ещё можно');
      await w.advance(const Duration(minutes: 2)); // минута после конца
      expect(await d.refusal(startSql, {'t': t1}), 'TOO_LATE');
      await w.advance(const Duration(minutes: 59)); // час после конца
      final late = await d.refusal(startSql, {'t': t1});
      expect(late, 'TOO_LATE');
      expect(await tStatus(t1), 'planned');
      await w.advance(const Duration(hours: 3));
      await w.finance.one(accrueSql);
      expect(await tStatus(t1), 'cancelled', reason: 'не начатый рейс не состоялся (поздний старт: ${late ?? 'принят'})');
      expect(await bStatus(b1), 'cancelled');
      expect(await refundOf(b1), 600);
      expect(await w.scalar('select started_at is null and finished_at is null from trips where id = @t::uuid', {'t': t1}), true);
      expect(await tStatus(t2), 'finished');
      expect(await bStatus(b2), 'done');
      expect(await w.scalar('select finished_at >= started_at and finished_at = ends_at from trips where id = @t::uuid', {'t': t2}), true,
          reason: 'забытый рейс закрыт концом по расписанию, и это не раньше его старта');
    });

    test('финиш до времени отправления — отказ TOO_EARLY; с момента отправления — можно', () async {
      // ПРАВИЛО (раньше — пробел в правилах: водитель за 14 минут до отправления нажимал «начать» и сразу «завершить»,
      // брони «состоялись», отменить их было нельзя, а время водителя освобождалось): раньше времени отправления
      // рейс завершить нельзя — TOO_EARLY.
      final d = await drv('Л31');
      final p = crowd[0];
      final dep = await inMinutes(20);
      final trip = await d.createTrip(route, dep);
      final b = (await sell(trip, [p])).single;
      await w.advance(const Duration(minutes: 6)); // до отправления ~14 минут
      await d.q(startSql, {'t': trip});
      expect(await d.refusal(finishSql, {'t': trip}), 'TOO_EARLY');
      expect(await tStatus(trip), 'started');
      expect(await bStatus(b), 'paid', reason: 'бронь не «состоялась» до отправления');
      expect(await w.scalar('select finished_at is null from trips where id = @t::uuid', {'t': trip}), true);
      expect(await d.refusal(createSql, {'r': route, 'd': dep.add(const Duration(minutes: 5)).toUtc().toIso8601String(), 'm': '0', 's': '[{"id":"front","price":600}]'}),
          'TRIP_OVERLAP', reason: 'время водителя занято: на то же время новый рейс не ставится');
      await w.advance(const Duration(minutes: 13)); // до отправления меньше минуты
      expect(await d.refusal(finishSql, {'t': trip}), 'TOO_EARLY');
      await w.advance(const Duration(minutes: 1)); // время отправления прошло
      expect(await d.refusal(finishSql, {'t': trip}), isNull);
      expect(await w.scalar('select finished_at >= departure from trips where id = @t::uuid', {'t': trip}), true);
      expect(await bStatus(b), 'done');
      expect(await p.refusal(cancelSql, {'b': b}), 'NOT_CANCELLABLE');
    });

    test('повтор номера операции: тот же запрос — та же бронь без списания; другой рейс или другие места — IDEM_KEY_REUSED', () async {
      // ПРАВИЛО (изменено: раньше тот же номер на другом рейсе молча возвращал первую бронь): повтор того же запроса
      // возвращает ту же бронь и не списывает; тот же номер с другим рейсом или другими местами — отказ IDEM_KEY_REUSED,
      // ничего не списано и не занято.
      final d = await drv('Л32');
      final d2 = await drv('Л32-2');
      final p = crowd[0];
      final t1 = await d.createTrip(route, await inMinutes(200), seats: fourSeats);
      final t2 = await d2.createTrip(route, await inMinutes(200));
      final key = 'flow-${w.nextKey()}';
      Future<String?> reuse(String trip, String seats) => p.refusal(bookSql, {'t': trip, 's': seats, 'c': p.cardId, 'k': key});
      final a = await p.book(t1, ['front'], idem: key);
      final b = await p.book(t1, ['front'], idem: key);
      expect(b['booking_id'], a['booking_id']);
      expect(b['repeat'], true);
      expect(b['status'], 'paid');
      expect(await reuse(t2, '{front}'), 'IDEM_KEY_REUSED', reason: 'тот же номер, другой рейс');
      expect(await reuse(t1, '{rl}'), 'IDEM_KEY_REUSED', reason: 'тот же номер, другое место');
      expect(await reuse(t1, '{front,rl}'), 'IDEM_KEY_REUSED', reason: 'тот же номер, мест больше');
      expect(await reuse(nobody, '{front}'), 'IDEM_KEY_REUSED', reason: 'тот же номер, несуществующий рейс');
      expect(await heldSeats([t2]), 0);
      expect(await heldSeats([t1]), 1);
      expect(await num('select count(*)::int from bookings where passenger_id = @u::uuid and idem_key = @k', {'u': p.id, 'k': key}), 1);
      expect(await num("select count(*)::int from payments where booking_id = @b::uuid and kind = 'charge'", {'b': a['booking_id']}), 1);
      // Порядок мест в повторе не важен: это тот же запрос.
      final key2 = 'flow-${w.nextKey()}';
      final two = await p.book(t1, ['rl', 'rr'], idem: key2);
      final twoAgain = await p.book(t1, ['rr', 'rl'], idem: key2);
      expect(twoAgain['booking_id'], two['booking_id']);
      expect(twoAgain['repeat'], true);
      expect(await num("select count(*)::int from ledger where booking_id = @b::uuid and kind = 'charge'", {'b': two['booking_id']}), 1);
      await p.cancel(a['booking_id'] as String);
      final c = await p.book(t1, ['front'], idem: key);
      expect(c['status'], 'cancelled', reason: 'повтор после отмены не покупает заново');
      expect(await num("select count(*)::int from ledger where booking_id = @b::uuid and kind = 'charge'", {'b': a['booking_id']}), 1);
      // Тот же номер у другого пассажира — отдельная операция.
      expect((await crowd[1].book(t1, ['front'], idem: key))['status'], 'paid');
      await d.q(cancelTripSql, {'t': t1});
      await d2.q(cancelTripSql, {'t': t2});
    });

    test('покупка: места, переданные вложенным массивом, не принимаются', () async {
      // ИСПРАВЛЕНО: раньше book_seats считал места через cardinality/unnest и принимал двумерный массив {{front,rl}}:
      // бронь оплачивалась, а в bookings.seat_ids лежал массив массивов — не тот вид данных, который читают приложения.
      final d = await drv('Л34');
      final p = crowd[0];
      final trip = await d.createTrip(route, await inMinutes(200));
      addTearDown(() => w.support.q(cancelTripSql, {'t': trip}));
      final res = await p.refusal(bookSql, bookArgs(p, trip, '{{front,rl}}'));
      final dims = await w.scalar('select max(array_ndims(seat_ids)) from bookings where trip_id = @t::uuid', {'t': trip});
      expect('ответ: ${res ?? 'оплачено'}, размерность seat_ids: ${dims ?? 'брони нет'}', 'ответ: BAD_SEATS, размерность seat_ids: брони нет');
    });

    test('повторная заявка до проверки и повторное решение проверяющего', () async {
      final d = await drv('Л33', approve: false);
      expect(await d.refusal(applySql, applyArgs(3, car: 'Вторая машина')), isNull);
      expect(await w.verifier.refusal(reviewSql, {'d': d.id, 'a': 'false', 'r': ' '}), 'REASON_REQUIRED');
      expect(await w.verifier.refusal(reviewSql, {'d': nobody, 'a': 'true', 'r': null}), 'DRIVER_NOT_FOUND');
      expect(await d.refusal(reviewSql, {'d': d.id, 'a': 'true', 'r': null}), 'FORBIDDEN', reason: 'сам себя не одобришь');
      await w.verifier.q(reviewSql, {'d': d.id, 'a': 'false', 'r': 'нет фото'});
      expect(await d.refusal(createSql, {'r': route, 'd': (await inMinutes(60)).toUtc().toIso8601String(), 'm': '0', 's': '[{"id":"front","price":600}]'}),
          'DRIVER_NOT_APPROVED');
      expect(await d.refusal(applySql, applyArgs(4, car: 'Третья машина')), isNull);
      expect(await w.scalar('select status::text || coalesce(reject_reason, \'\') from drivers where user_id = @d::uuid', {'d': d.id}), 'pending');
      await w.verifier.q(reviewSql, {'d': d.id, 'a': 'true', 'r': null});
      expect(await d.refusal(createSql, {'r': route, 'd': (await inMinutes(60)).toUtc().toIso8601String(), 'm': '0', 's': '[{"id":"rm","price":400}]'}),
          isNull);
    });
  });

  // =====================================================================================
  // ОДНОВРЕМЕННЫЕ ДЕЙСТВИЯ
  // =====================================================================================

  group('одновременно', () {
    test('старт рейса и отмены пассажиров в один момент (12 рейсов, 48 пассажиров, 3 круга)', () async {
      const n = 12;
      final rnd = Random(101);
      final drivers = [for (var i = 0; i < n; i++) await drv('Старт $i')];
      for (var round = 0; round < 3; round++) {
        final dep = await inMinutes(20);
        final trips = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
        final bookings = <String>[];
        for (var i = 0; i < n; i++) {
          bookings.addAll(await sell(trips[i], crowd.sublist(i * 4, i * 4 + 4)));
        }
        await w.advance(const Duration(minutes: 6)); // ~14 минут до отправления
        final actions = <(String, int, Future<Object?> Function())>[
          for (var i = 0; i < n; i++) ('start', i, () => drivers[i].q(startSql, {'t': trips[i]})),
          for (var j = 0; j < bookings.length; j++) ('cancel', j, () => crowd[j].cancel(bookings[j])),
        ]..shuffle(rnd);
        final res = await together(actions.map((a) => a.$3));
        expect(dbErrors(res), isEmpty);
        for (var k = 0; k < actions.length; k++) {
          final (kind, idx, _) = actions[k];
          final r = res[k];
          if (kind == 'start') {
            expect(r, isNot(isA<Refused>()), reason: 'старт в окне всегда проходит: $r');
          } else if (r is Refused) {
            expect(r.code, 'TRIP_ALREADY_STARTED');
            expect(await bStatus(bookings[idx]), 'paid');
          } else {
            expect((r as Map)['refund'], 0, reason: 'за 14 минут — без возврата');
            expect(await bStatus(bookings[idx]), 'cancelled');
          }
        }
        expect(await num("select count(*)::int from trips where id = any(@t::uuid[]) and status = 'started'", {'t': '{${trips.join(',')}}'}), n);
        expect(await num('select count(*)::int from trip_seats where trip_id = any(@t::uuid[]) and booking_id is not null', {'t': '{${trips.join(',')}}'}), n * 4,
            reason: 'поздняя отмена места не освобождает');
        // ПРАВИЛО: завершить рейс можно только с момента отправления — иначе у водителя остаётся начатый рейс
        // и следующий он начать не сможет (ANOTHER_TRIP_STARTED).
        final early = await together([for (var i = 0; i < n; i++) () => drivers[i].q(finishSql, {'t': trips[i]})]);
        expect(early.whereType<Refused>().map((e) => e.code).toList(), List.filled(n, 'TOO_EARLY'));
        await toDeparture(trips.first);
        final fin = await together([for (var i = 0; i < n; i++) () => drivers[i].q(finishSql, {'t': trips[i]})]);
        expect(fin.whereType<Refused>(), isEmpty, reason: 'финиш после времени отправления проходит всегда');
        expect(await violations(w), isEmpty, reason: 'круг $round');
        await w.advance(const Duration(minutes: 30));
      }
    });

    test('отмена рейса (водитель с двух телефонов и поддержка) против ранних отмен и новых покупок', () async {
      const n = 10;
      final drivers = [for (var i = 0; i < n; i++) await drv('Отмена $i')];
      final supportClone = clone(w.support);
      final dep = await inMinutes(200);
      final trips = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
      final first = <String>[];
      for (var i = 0; i < n; i++) {
        first.addAll(await sell(trips[i], crowd.sublist(i * 4, i * 4 + 2))); // front, rl
      }
      final dClones = [for (final d in drivers) clone(d)];
      final res = await together([
        for (var i = 0; i < n; i++) ...[
          () => crowd[i * 4].cancel(first[i * 2]),
          () => crowd[i * 4 + 2].book(trips[i], ['rr']),
          () => drivers[i].one(cancelTripSql, {'t': trips[i]}),
          () => crowd[i * 4 + 1].cancel(first[i * 2 + 1]),
          () => dClones[i].one(cancelTripSql, {'t': trips[i]}),
          () => crowd[i * 4 + 3].book(trips[i], ['rm']),
          if (i.isEven) () => supportClone.one(cancelTripSql, {'t': trips[i]}),
        ],
      ]);
      expect(dbErrors(res), isEmpty);
      final codes = res.whereType<Refused>().map((e) => e.code).toSet();
      expect(codes.difference({'TRIP_NOT_PLANNED', 'NOT_CANCELLABLE', 'TRIP_CLOSED'}), isEmpty);
      for (final t in trips) {
        expect(await tStatus(t), 'cancelled');
        expect(await num("select count(*)::int from audit_log where action = 'cancel_trip' and entity_id = @t", {'t': t}), 1, reason: 'рейс отменён ровно один раз');
        expect(await num('''select count(*)::int from (select booking_id from ledger where trip_id = @t::uuid and kind = 'refund'
            group by booking_id having count(*) > 1) x''', {'t': t}), 0, reason: 'возврат по брони — один раз');
        expect(
            await num("select coalesce(sum(amount) filter (where kind = 'charge'), 0)::int - coalesce(sum(amount) filter (where kind = 'refund'), 0)::int from ledger where trip_id = @t::uuid", {'t': t}),
            0,
            reason: 'по отменённому рейсу возвращено всё списанное');
      }
    });

    test('финиш рейса против отметок посадки с нескольких подключений водителя', () async {
      const n = 8;
      final drivers = [for (var i = 0; i < n; i++) await drv('Финиш $i')];
      final dep = await inMinutes(20);
      final trips = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
      for (var i = 0; i < n; i++) {
        await sell(trips[i], crowd.sublist(i * 4, i * 4 + 4));
      }
      await closeCrowd();
      await w.advance(const Duration(minutes: 6));
      await Future.wait([for (var i = 0; i < n; i++) drivers[i].q(startSql, {'t': trips[i]})]);
      await toDeparture(trips.first); // раньше времени отправления финиш не принимается
      final markers = [for (final d in drivers) [for (var k = 0; k < 5; k++) clone(d)]];
      final res = await together([
        for (var i = 0; i < n; i++) ...[
          () => markers[i][0].q(markSql, {'t': trips[i], 's': 'front', 'm': 'boarded'}),
          () => markers[i][1].q(markSql, {'t': trips[i], 's': 'rl', 'm': 'no_show'}),
          () => drivers[i].q(finishSql, {'t': trips[i]}),
          () => markers[i][2].q(markSql, {'t': trips[i], 's': 'rr', 'm': 'boarded'}),
          () => markers[i][3].q(markSql, {'t': trips[i], 's': 'rm', 'm': 'boarded'}),
          () => markers[i][4].q(markSql, {'t': trips[i], 's': 'front', 'm': null}),
        ],
      ]);
      expect(dbErrors(res), isEmpty);
      expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'TRIP_CLOSED'}), isEmpty);
      for (var i = 0; i < n; i++) {
        expect(res[i * 6 + 2], isNot(isA<Refused>()), reason: 'финиш начатого рейса проходит всегда');
        expect(await tStatus(trips[i]), 'finished');
        expect(await num("select count(*)::int from bookings where trip_id = @t::uuid and status = 'done'", {'t': trips[i]}), 4);
      }
    });

    test('один рейс отменяют 20 подключений водителя сразу: отмена и возвраты — один раз', () async {
      final d = await drv('Двадцать отмен');
      for (var round = 0; round < 4; round++) {
        final trip = await d.createTrip(route, await inMinutes(90), seats: fourSeats);
        final b = await sell(trip, crowd.sublist(round * 4, round * 4 + 3));
        await w.advance(const Duration(minutes: 40)); // ~50 минут: поздняя отмена без возврата
        expect((await crowd[round * 4].cancel(b[0]))['refund'], 0);
        final clones = [for (var i = 0; i < 20; i++) clone(d)];
        final res = await together(clones.map((c) => () => c.one(cancelTripSql, {'t': trip})));
        for (final c in clones) {
          await c.close();
        }
        expect(dbErrors(res), isEmpty);
        expect(res.where((r) => r is! Refused), [3], reason: 'ровно одна отмена, три возврата');
        expect(res.whereType<Refused>().map((e) => e.code).toSet(), {'TRIP_NOT_PLANNED'});
        expect(await num("select count(*)::int from ledger where trip_id = @t::uuid and kind = 'refund'", {'t': trip}), 3);
        expect(await num("select coalesce(sum(amount), 0)::int from ledger where trip_id = @t::uuid and kind = 'refund'", {'t': trip}), 1600);
      }
    });

    test('старт и отмена одного рейса с разных подключений водителя: побеждает ровно одно', () async {
      final d = await drv('Старт или отмена');
      var started = 0, cancelled = 0;
      for (var round = 0; round < 8; round++) {
        final trip = await d.createTrip(route, await inMinutes(20));
        final b = await sell(trip, crowd.sublist(round * 2, round * 2 + 2));
        await w.advance(const Duration(minutes: 6));
        final clones = [for (var i = 0; i < 12; i++) clone(d)];
        final res = await together([
          for (var i = 0; i < clones.length; i++)
            if ((i + round).isEven) () => clones[i].q(startSql, {'t': trip}) else () => clones[i].one(cancelTripSql, {'t': trip}),
        ]);
        for (final c in clones) {
          await c.close();
        }
        expect(dbErrors(res), isEmpty);
        expect(res.where((r) => r is! Refused), hasLength(1));
        expect(res.whereType<Refused>().map((e) => e.code).toSet(), {'TRIP_NOT_PLANNED'});
        final st = await tStatus(trip);
        if (st == 'started') {
          started++;
          expect(await bStatus(b[0]), 'paid');
          expect(await num("select count(*)::int from ledger where trip_id = @t::uuid and kind = 'refund'", {'t': trip}), 0);
          await toDeparture(trip);
          await d.q(finishSql, {'t': trip});
        } else {
          cancelled++;
          expect(st, 'cancelled');
          expect(await num("select count(*)::int from ledger where trip_id = @t::uuid and kind = 'refund'", {'t': trip}), 2);
        }
        await w.advance(const Duration(minutes: 30));
      }
      print('старт против отмены: старт победил $started раз, отмена — $cancelled');
    });

    test('водители ставят рейсы, а модератор в тот же момент снимает маршрут: на снятом маршруте нет рейсов', () async {
      // ИСПРАВЛЕНО: раньше в гонке driver_create_trip × staff_set_route_status обе функции читали друг друга без
      // блокировки, и предстоящий рейс оказывался на маршруте в архиве / черновике (и продавался).
      // ПРАВИЛО: обе функции идут по очереди через строку маршрута.
      const n = 20, rounds = 12;
      final drivers = [for (var i = 0; i < n; i++) await drv('Маршрут $i')];
      final routes = <String>[];
      addTearDown(() async {
        final left = await w.admin.execute("select id::text from trips where route_id = any('{${routes.join(',')}}'::uuid[]) and status = 'planned'");
        for (final row in left) {
          await w.support.q(cancelTripSql, {'t': row.first});
        }
      });
      var broken = 0, archivedRounds = 0, orphanTrips = 0;
      String? sample;
      for (var round = 0; round < rounds; round++) {
        final r = await newRoute();
        routes.add(r);
        final target = round.isEven ? 'archived' : 'draft';
        final dep = await inMinutes(30 + round * 30);
        final res = await together([
          for (var i = 0; i < n ~/ 2; i++) () => drivers[i].createTrip(r, dep),
          () => w.moderator.q(routeStatusSql, {'r': r, 's': target}),
          for (var i = n ~/ 2; i < n; i++) () => drivers[i].createTrip(r, dep),
        ]);
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'ROUTE_NOT_AVAILABLE', 'ROUTE_HAS_ACTIVE_TRIPS'}), isEmpty);
        final status = await w.scalar('select status::text from routes where id = @r::uuid', {'r': r}) as String;
        final planned = await num("select count(*)::int from trips where route_id = @r::uuid and status = 'planned'", {'r': r});
        if (status != 'published') archivedRounds++;
        if (status != 'published' && planned > 0) {
          broken++;
          orphanTrips += planned;
          sample ??= await w.scalar("select id::text from trips where route_id = @r::uuid and status = 'planned' limit 1", {'r': r}) as String;
        }
      }
      // На таком рейсе пассажир ещё и может купить место.
      String? sold;
      if (sample != null) {
        try {
          sold = (await crowd[0].book(sample, ['front']))['status'] as String;
        } on Refused catch (e) {
          sold = e.code;
        }
      }
      expect(broken, 0,
          reason: 'из $rounds кругов маршрут снят в $archivedRounds, и в $broken из них на снятом маршруте остались предстоящие рейсы '
              '(всего $orphanTrips); покупка места на таком рейсе: $sold');
    });

    test('покупки, отмена рейса водителем и снятие маршрута в один момент', () async {
      const rounds = 8;
      final d = await drv('Архив и покупки');
      final mods = [for (var i = 0; i < 3; i++) clone(w.moderator)];
      final rnd = Random(55);
      for (var round = 0; round < rounds; round++) {
        final r = await newRoute();
        final trip = await d.createTrip(r, await inMinutes(200 + round), seats: fourSeats);
        final buyers = (List.of(crowd)..shuffle(rnd)).take(24).toList();
        final res = await together([
          for (var i = 0; i < 8; i++) () => buyers[i].book(trip, [seatOrder[i % 4]]),
          () => mods[0].q(routeStatusSql, {'r': r, 's': 'archived'}),
          () => d.one(cancelTripSql, {'t': trip}),
          for (var i = 8; i < 16; i++) () => buyers[i].book(trip, [seatOrder[i % 4]]),
          () => mods[1].q(routeStatusSql, {'r': r, 's': 'archived'}),
          for (var i = 16; i < 24; i++) () => buyers[i].book(trip, [seatOrder[i % 4]]),
          () => mods[2].q(routeStatusSql, {'r': r, 's': 'draft'}),
        ]);
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'SEAT_TAKEN', 'TRIP_CLOSED', 'ROUTE_HAS_ACTIVE_TRIPS'}), isEmpty);
        expect(await tStatus(trip), 'cancelled');
        expect(await num("select coalesce(sum(amount) filter (where kind = 'charge'), 0)::int - coalesce(sum(amount) filter (where kind = 'refund'), 0)::int from ledger where trip_id = @t::uuid", {'t': trip}), 0);
      }
    });

    test('пассажир покупает, а поддержка в тот же момент его блокирует', () async {
      const n = 32;
      final d = await drv('Блок и покупка');
      final dep = await inMinutes(200);
      final trips = [for (var i = 0; i < n ~/ 4; i++) await d.createTrip(route, dep.add(Duration(minutes: 25 * i)), seats: fourSeats)];
      final fresh = [for (var i = 0; i < n; i++) await pas('Под блок $i')];
      final sup = [for (var i = 0; i < n; i++) clone(w.support)];
      await Future.wait([for (final a in [...fresh, ...sup]) a.q('select 1')]); // подключения открыты заранее
      // Покупка стартует на 0–105 мс позже блокировки: так встречаются оба порядка.
      final res = await together([
        for (var i = 0; i < n; i++) ...[
          () => sup[i].q(blockSql, {'u': fresh[i].id, 'b': 'true'}),
          () => Future<void>.delayed(Duration(milliseconds: (i % 8) * 15)).then((_) => fresh[i].book(trips[i ~/ 4], [seatOrder[i % 4]])),
        ],
      ]);
      expect(dbErrors(res), isEmpty);
      expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'BLOCKED'}), isEmpty);
      final paid = res.whereType<Map>().where((r) => r['status'] == 'paid').length;
      final refused = res.whereType<Refused>().length;
      expect(paid + refused, n);
      expect(await num("select count(*)::int from bookings where trip_id = any(@t::uuid[]) and status = 'paid'", {'t': '{${trips.join(',')}}'}), paid);
      expect(await num('select count(*)::int from bookings where passenger_id = any(@u::uuid[])', {'u': '{${fresh.map((p) => p.id).join(',')}}'}), paid,
          reason: 'у получивших отказ нет ни брони, ни списания');
      print('блокировка против покупки: успели купить $paid, отказано $refused');
      // После блокировки не проходит уже ничего.
      final again = await together([for (var i = 0; i < n; i++) () => fresh[i].book(trips[i ~/ 4], [seatOrder[i % 4]])]);
      expect(again.whereType<Refused>().map((e) => e.code).toSet(), {'BLOCKED'});
      expect(again.whereType<Map>(), isEmpty);
      for (final t in trips) {
        await d.q(cancelTripSql, {'t': t});
      }
    });

    test('старт рейса и покупки в один момент: после старта не продано ничего', () async {
      const n = 10;
      final drivers = [for (var i = 0; i < n; i++) await drv('Старт и покупка $i')];
      for (var round = 0; round < 3; round++) {
        final dep = await inMinutes(20);
        final trips = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
        await w.advance(const Duration(minutes: 6)); // ~14 минут: старт уже можно, продажа ещё открыта
        await Future.wait([for (final a in [...drivers, ...crowd.take(n * 4)]) a.q('select 1')]);
        // Функции «прогреты» заранее отказами, покупки разнесены на 0–3 мс вокруг старта: встречаются оба порядка.
        await together([
          for (var i = 0; i < n; i++) () => drivers[i].q(startSql, {'t': nobody}),
          for (var i = 0; i < n * 4; i++) () => crowd[i].book(nobody, ['front']),
        ]);
        final res = await together([
          for (var i = 0; i < n; i++) ...[
            () => crowd[i * 4].book(trips[i], ['front']),
            () => after(1, () => crowd[i * 4 + 1].book(trips[i], ['rl', 'rr'])),
            () => after(1 + i % 2, () => drivers[i].q(startSql, {'t': trips[i]})),
            () => after(2, () => crowd[i * 4 + 2].book(trips[i], ['rm'])),
            () => after(3, () => crowd[i * 4 + 3].book(trips[i], ['front', 'rm'])),
          ],
        ]);
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'TRIP_CLOSED', 'SEAT_TAKEN'}), isEmpty);
        for (var i = 0; i < n; i++) {
          expect(res[i * 5 + 2], isNot(isA<Refused>()));
          expect(await tStatus(trips[i]), 'started');
          final paidSeats = await num("select coalesce(sum(cardinality(seat_ids)), 0)::int from bookings where trip_id = @t::uuid and status = 'paid'", {'t': trips[i]});
          expect(await num('select count(*)::int from trip_seats where trip_id = @t::uuid and booking_id is not null', {'t': trips[i]}), paidSeats);
          // После старта купить нельзя.
          expect(await crowd[i * 4 + 2].refusal(bookSql, bookArgs(crowd[i * 4 + 2], trips[i], '{front}')), 'TRIP_CLOSED');
        }
        final sold = await num("select count(*)::int from bookings where trip_id = any(@t::uuid[]) and status = 'paid'", {'t': '{${trips.join(',')}}'});
        final closed = res.whereType<Refused>().where((e) => e.code == 'TRIP_CLOSED').length;
        print('старт против покупок, круг $round: до старта купили $sold броней, после старта отказано $closed');
        await toDeparture(trips.first);
        await Future.wait([for (var i = 0; i < n; i++) drivers[i].q(finishSql, {'t': trips[i]})]);
        await w.advance(const Duration(minutes: 30));
      }
    });

    test('accrue_due с 6 подключений, пока водители завершают рейсы, а пассажиры покупают', () async {
      const n = 10;
      final drivers = [for (var i = 0; i < n; i++) await drv('Начисление $i')];
      // Вчерашние рейсы: завершены, ждут начисления.
      var dep = await inMinutes(20);
      final old = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
      final oldBookings = <String>[];
      for (var i = 0; i < n; i++) {
        oldBookings.addAll(await sell(old[i], crowd.sublist(i * 4, i * 4 + 2)));
      }
      await w.advance(const Duration(minutes: 6));
      await Future.wait([for (var i = 0; i < n; i++) drivers[i].q(startSql, {'t': old[i]})]);
      await toDeparture(old.first);
      await Future.wait([for (var i = 0; i < n; i++) drivers[i].q(finishSql, {'t': old[i]})]);
      await w.advance(const Duration(hours: 25));
      // Сегодняшние: один в пути, один в продаже.
      dep = await inMinutes(20);
      final running = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
      final open = [for (final d in drivers) await d.createTrip(route, dep.add(const Duration(minutes: 200)), seats: fourSeats)];
      for (var i = 0; i < n; i++) {
        await sell(running[i], crowd.sublist(i * 4, i * 4 + 3));
      }
      await w.advance(const Duration(minutes: 6));
      await Future.wait([for (var i = 0; i < n; i++) drivers[i].q(startSql, {'t': running[i]})]);
      await toDeparture(running.first); // с этого момента рейсы в пути можно завершать

      final fin = [for (var i = 0; i < 6; i++) clone(w.finance)];
      final res = await together([
        for (var i = 0; i < n; i++) ...[
          () => drivers[i].q(finishSql, {'t': running[i]}),
          () => crowd[i * 4].book(open[i], ['front']),
          if (i < 6) () => fin[i].one('select accrue_due()'),
          () => crowd[i * 4 + 1].book(open[i], ['front', 'rl']),
          () => crowd[i * 4 + 2].book(open[i], ['rr']),
          // по одной оценке на водителя — без гонки оценок, она проверяется отдельно
          () => crowd[i * 4].q(rateSql, {'b': oldBookings[i * 2], 's': '5'}),
        ],
        () => w.finance.one('select finance_create_payouts()'),
      ]);
      expect(dbErrors(res), isEmpty);
      expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'SEAT_TAKEN'}), isEmpty);
      for (var i = 0; i < n; i++) {
        expect(await w.scalar('select accrued_at is not null from trips where id = @t::uuid', {'t': old[i]}), true);
        expect(await tStatus(running[i]), 'finished');
        expect(await w.scalar('select accrued_at is null from trips where id = @t::uuid', {'t': running[i]}), true, reason: 'сутки ещё не прошли');
      }
      for (final b in oldBookings) {
        expect(await num("select count(*)::int from ledger where booking_id = @b::uuid and kind = 'driver_accrual'", {'b': b}), 1, reason: 'доля начислена ровно один раз');
      }
      for (final t in open) {
        await w.support.q(cancelTripSql, {'t': t});
      }
    });

    test('автозакрытие забытого рейса против позднего старта, финиша и отмены водителем', () async {
      // ПРАВИЛО (изменено: раньше accrue_due «завершал» и не начатые рейсы, а поздний старт принимался): не начатый
      // рейс accrue_due отменяет с полным возвратом, поздний старт — отказ TOO_LATE; начатый и забытый — закрывает.
      // Рейсы 0, 3, 6, 9 начаты вовремя и забыты; остальные не начаты: чётные водитель пытается начать, нечётные — отменить.
      const n = 12;
      final drivers = [for (var i = 0; i < n; i++) await drv('Забытый $i')];
      final dep = await inMinutes(20);
      final trips = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
      final bookings = <String>[];
      for (var i = 0; i < n; i++) {
        bookings.addAll(await sell(trips[i], crowd.sublist(i * 4, i * 4 + 2)));
      }
      bool forgotten(int i) => i % 3 == 0;
      await w.advance(const Duration(minutes: 6));
      await Future.wait([for (var i = 0; i < n; i++) if (forgotten(i)) drivers[i].q(startSql, {'t': trips[i]})]);
      await w.advance(const Duration(hours: 3)); // конец по расписанию + 2 часа прошли: accrue_due закроет рейсы
      final fin = [for (var i = 0; i < 4; i++) clone(w.finance)];
      final dClones = [for (final d in drivers) clone(d)];
      final res = await together([
        for (var i = 0; i < n; i++) ...[
          () => i % 3 == 0 ? fin[i ~/ 3].one(accrueSql) : Future.value(),
          () => i.isEven ? drivers[i].q(startSql, {'t': trips[i]}) : drivers[i].one(cancelTripSql, {'t': trips[i]}),
          () => dClones[i].q(finishSql, {'t': trips[i]}),
        ],
      ]);
      expect(dbErrors(res), isEmpty);
      expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'TRIP_NOT_PLANNED', 'TRIP_NOT_STARTED', 'TOO_LATE'}), isEmpty);
      for (var i = 0; i < n; i++) {
        final second = res[i * 3 + 1], finish = res[i * 3 + 2];
        final st = await tStatus(trips[i]);
        final bs = {await bStatus(bookings[i * 2]), await bStatus(bookings[i * 2 + 1])};
        if (forgotten(i)) {
          // Забытый рейс закрыт ровно один раз: либо водителем (сейчас), либо сам (концом по расписанию).
          expect(st, 'finished');
          expect(bs, {'done'});
          expect(second, isA<Refused>().having((e) => e.code, 'code', 'TRIP_NOT_PLANNED'), reason: 'начатый рейс нельзя ни начать, ни отменить');
          expect(
              await w.scalar('select finished_at >= started_at and (finished_at = ends_at) = @auto::boolean from trips where id = @t::uuid',
                  {'t': trips[i], 'auto': '${finish is Refused}'}),
              true,
              reason: 'время конца: у закрытого водителем — сейчас, у закрытого автоматически — конец по расписанию');
          expect(await num("select count(*)::int from ledger where trip_id = @t::uuid and kind = 'refund'", {'t': trips[i]}), 0);
        } else {
          // Не начатый рейс отменён ровно один раз, деньги возвращены полностью и один раз.
          expect(st, 'cancelled');
          expect(bs, {'cancelled'});
          expect(finish, isA<Refused>().having((e) => e.code, 'code', 'TRIP_NOT_STARTED'));
          if (i.isEven) {
            expect(second, isA<Refused>().having((e) => e.code, 'code', isIn(['TOO_LATE', 'TRIP_NOT_PLANNED'])), reason: 'поздний старт не проходит никогда');
          }
          expect(await num("select count(*)::int from audit_log where action = 'cancel_trip' and entity_id = @t", {'t': trips[i]}), 1);
        }
      }
      final cancelled = [for (var i = 0; i < n; i++) if (!forgotten(i)) trips[i]];
      expect(await notRefundedOnce(cancelled), 0, reason: 'каждой брони — один полный возврат');
      expect(await heldSeats(cancelled), 0);
      await w.finance.one(accrueSql);
      expect(await num("select count(*)::int from trips where id = any(@t::uuid[]) and status in ('planned', 'started')", {'t': ids(trips)}), 0);
    });

    test('30 человек подают заявку одновременно; один человек — с 15 подключений; анкета при рейсах', () async {
      await closeCrowd();
      final people = [for (var i = 0; i < 30; i++) await w.newUser('Заявка $i')];
      temp.addAll(people);
      final res = await together([for (var i = 0; i < people.length; i++) () => people[i].q(applySql, applyArgs(i.isEven ? 4 : 3))]);
      expect(res.whereType<Refused>(), isEmpty);
      expect(await num("select count(*)::int from drivers where user_id = any(@u::uuid[]) and status = 'pending'", {'u': '{${people.map((p) => p.id).join(',')}}'}), 30);
      for (final p in people) {
        await p.close();
      }

      final one = await w.newUser('Заявка с 15 телефонов');
      temp.add(one);
      final clones = [for (var i = 0; i < 15; i++) clone(one)];
      final res2 = await together([for (var i = 0; i < clones.length; i++) () => clones[i].q(applySql, applyArgs(3 + i % 2, car: 'Машина $i'))]);
      expect(res2.whereType<Refused>().map((e) => '${e.code} ${e.message}'), isEmpty);
      expect(await num('select count(*)::int from drivers where user_id = @u::uuid', {'u': one.id}), 1);
      final row = (await w.admin.execute("select car, seats_total, status::text from drivers where user_id = '${one.id}'")).first;
      final idx = int.parse((row[0] as String).split(' ').last);
      expect(row[1], 3 + idx % 2, reason: 'в анкете машина и число мест из одной и той же заявки');
      expect(row[2], 'pending');
      for (final c in clones) {
        await c.close();
      }

      // Одобренный водитель с рейсом: все 15 одновременных заявок отклонены.
      final busy = await drv('Занятой');
      final trip = await busy.createTrip(route, await inMinutes(100));
      final bc = [for (var i = 0; i < 15; i++) clone(busy)];
      final res3 = await together([for (final c in bc) () => c.q(applySql, applyArgs(3))]);
      expect(res3.whereType<Refused>().map((e) => e.code).toList(), List.filled(15, 'DRIVER_HAS_ACTIVE_TRIPS'));
      await busy.q(cancelTripSql, {'t': trip});
    });

    test('новая анкета и постановка рейса одного водителя в один момент: проходит только одно', () async {
      final d = await drv('Анкета или рейс', seats: 4);
      final a = clone(d), b = clone(d);
      var applyWon = 0, tripWon = 0;
      for (var round = 0; round < 24; round++) {
        final dep = await inMinutes(60);
        await Future.wait([a.q('select 1'), b.q('select 1')]);
        // То анкета, то рейс стартуют на пару миллисекунд позже: так встречаются оба порядка.
        final res = await together([
          () => Future<void>.delayed(Duration(milliseconds: round % 4 == 1 ? 2 : 0)).then((_) => a.q(applySql, applyArgs(3))),
          () => Future<void>.delayed(Duration(milliseconds: round % 4 >= 2 ? round % 4 : 0)).then((_) => b.createTrip(route, dep, seats: {'rm': 400})),
        ]);
        expect(dbErrors(res), isEmpty);
        final applyRes = res[0], tripRes = res[1];
        if (tripRes is String) {
          tripWon++;
          expect(applyRes, isA<Refused>().having((e) => e.code, 'code', 'DRIVER_HAS_ACTIVE_TRIPS'));
          await d.q(cancelTripSql, {'t': tripRes});
        } else {
          applyWon++;
          expect(applyRes, isNot(isA<Refused>()));
          expect((tripRes as Refused).code, 'DRIVER_NOT_APPROVED');
          await d.q(applySql, applyArgs(4));
          await w.verifier.q(reviewSql, {'d': d.id, 'a': 'true', 'r': null});
        }
        expect(await violations(w), isEmpty, reason: 'круг $round');
      }
      print('анкета против рейса: анкета первой $applyWon раз, рейс первым — $tripWon');
      expect(applyWon * tripWon, greaterThan(0), reason: 'гонка должна проверить оба порядка');
    });

    test('30 водителей ставят рейсы на один маршрут сразу, каждый — с двух подключений', () async {
      await closeCrowd();
      const n = 30;
      final r = await newRoute();
      final drivers = [for (var i = 0; i < n; i++) await drv('Тридцать $i', seats: i.isEven ? 4 : 3)];
      final twins = [for (final d in drivers) clone(d)];
      final dep = await inMinutes(120);
      final res = await together([
        for (var i = 0; i < n; i++) ...[
          () => drivers[i].createTrip(r, dep, meet: i * 50),
          () => twins[i].createTrip(r, dep.add(const Duration(minutes: 10)), meet: i * 50),
        ],
      ]);
      expect(dbErrors(res), isEmpty);
      expect(res.whereType<String>(), hasLength(n), reason: 'у каждого водителя прошёл ровно один из двух пересекающихся рейсов');
      expect(res.whereType<Refused>().map((e) => e.code).toSet(), {'TRIP_OVERLAP'});
      expect(await num("select count(distinct driver_id)::int from trips where route_id = @r::uuid and status = 'planned'", {'r': r}), n);
      for (var i = 0; i < n; i++) {
        final mine = (await w.admin.execute("select id::text from trips where route_id = '$r' and driver_id = '${drivers[i].id}'")).single.first as String;
        await drivers[i].q(cancelTripSql, {'t': mine});
      }
    });

    test('водитель с 20 подключений ставит рейсы встык и внахлёст: пересечений нет', () async {
      final d = await drv('Встык');
      final dep = await inMinutes(120);
      final clones = [for (var i = 0; i < 20; i++) clone(d)];
      final res = await together([
        for (var i = 0; i < 10; i++) ...[
          () => clones[i * 2].createTrip(route, dep.add(Duration(minutes: 25 * i))), // встык
          () => clones[i * 2 + 1].createTrip(route, dep.add(Duration(minutes: 25 * i + 12))), // внахлёст с двумя соседями
        ],
      ]);
      expect(dbErrors(res), isEmpty);
      expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'TRIP_OVERLAP'}), isEmpty);
      final made = res.whereType<String>().length;
      expect(made, inInclusiveRange(5, 10));
      expect(await violations(w), isEmpty);
      // Остальные слоты встык теперь либо свободны, либо заняты рейсом внахлёст — повтор ничего не ломает.
      final res2 = await together([for (var i = 0; i < 10; i++) () => clones[i].createTrip(route, dep.add(Duration(minutes: 25 * i)))]);
      expect(dbErrors(res2), isEmpty);
      print('встык и внахлёст: сразу прошло $made из 20, при повторе ещё ${res2.whereType<String>().length}');
      for (final row in await w.admin.execute("select id::text from trips where driver_id = '${d.id}' and status = 'planned'")) {
        await d.q(cancelTripSql, {'t': row.first});
      }
    });

    test('39 пассажиров одновременно оценивают одного водителя: рейтинг равен среднему', () async {
      // ИСПРАВЛЕНО: раньше в rate_booking терялись обновления — среднее и число оценок считались по «снимку» на начало
      // оператора UPDATE drivers, и одновременные оценки записывали итог без оценок, зафиксированных за время ожидания.
      // ПРАВИЛО: оценки одного водителя считаются по очереди (блокировка строки водителя); рейтинг всегда равен среднему.
      const tripsCount = 10;
      final d = await drv('Рейтинг');
      final dep = await inMinutes(20);
      final trips = [for (var i = 0; i < tripsCount; i++) await d.createTrip(route, dep.add(Duration(minutes: 25 * i)), seats: fourSeats)];
      final bookings = <String>[];
      for (var i = 0; i < tripsCount; i++) {
        bookings.addAll(await sell(trips[i], crowd.sublist(i * 4, i * 4 + 4)));
      }
      // Десять рейсов встык проходят по одному: начать можно только в окне старта, завершить — с момента отправления,
      // и у водителя не больше одного начатого рейса.
      for (final t in trips) {
        await toDeparture(t);
        await d.q(startSql, {'t': t});
        await d.q(finishSql, {'t': t});
      }
      // Последняя оценка ставится отдельно: она пересчитывает рейтинг заново, чтобы расхождение (если оно вернётся)
      // не роняло следующие проверки.
      addTearDown(() => crowd[39].q(rateSql, {'b': bookings[39], 's': '5'}));
      // Оценки идут волнами по 8: карточка водителя сверяется после каждой волны, потому что следующая волна
      // может случайно «починить» расхождение (каждая оценка пересчитывает рейтинг целиком).
      final wrong = <String>[];
      for (var from = 0; from < 39; from += 8) {
        final res = await together([for (var i = from; i < min(from + 8, 39); i++) () => crowd[i].q(rateSql, {'b': bookings[i], 's': '${1 + i % 5}'})]);
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>(), isEmpty);
        final row = (await w.admin.execute('''select d.rating_count, d.rating::text,
            (select count(*)::int from bookings b join trips t on t.id = b.trip_id where t.driver_id = d.user_id and b.rating is not null),
            (select round(avg(b.rating), 1)::text from bookings b join trips t on t.id = b.trip_id where t.driver_id = d.user_id and b.rating is not null)
            from drivers d where d.user_id = '${d.id}' ''')).first;
        if (row[0] != row[2] || row[1] != row[3]) wrong.add('в карточке оценок ${row[0]}, рейтинг ${row[1]} — на деле оценок ${row[2]}, рейтинг ${row[3]}');
      }
      expect(wrong, isEmpty, reason: 'в карточке водителя — не то, что поставили пассажиры (расхождение после ${wrong.length} волн из 5)');
      // Приложению оценка в таблице броней не видна: пассажир читает свои оценки из my_ratings, водитель — не видит чужих.
      expect(await crowd[0].refusal('select rating from bookings where id = @b::uuid', {'b': bookings[0]}), '42501');
      expect(await crowd[0].one('select rating from my_ratings where booking_id = @b::uuid', {'b': bookings[0]}), 1);
      expect(await d.one('select count(*)::int from my_ratings'), 0);
    });

    test('оценки, начисление, выплаты, новые рейсы и анкета одного водителя в один момент: без взаимных блокировок', () async {
      // Цепочка блокировок: оценка держит бронь и ждёт строку водителя; начисление держит рейсы, ссылается на водителя
      // и на брони; постановка рейса и анкета держат строку водителя. Ни одна ошибка 40P01 не допускается.
      // ИСПРАВЛЕНО (раньше было так): взаимная блокировка accrue_due × rate_booking (40P01). Оценка берёт строку водителя (for update), затем
      // бронь (for update). Начисление, вставляя строку в журнал денег, берёт через внешние ключи сначала бронь
      // (key share), затем водителя (key share) — в обратном порядке. Отдельно от остальных действий эта пара
      // воспроизводится в проверке «начисление по рейсу и оценки его пассажиров в один момент».
      const tripsCount = 9;
      final d = await drv('Узел блокировок');
      final dep = await inMinutes(20);
      final trips = [for (var i = 0; i < tripsCount; i++) await d.createTrip(route, dep.add(Duration(minutes: 25 * i)), seats: fourSeats)];
      final bookings = <String>[];
      for (var i = 0; i < tripsCount; i++) {
        bookings.addAll(await sell(trips[i], crowd.sublist(i * 4, i * 4 + 4)));
      }
      for (final t in trips) {
        await toDeparture(t); // рейсы встык проходят по одному: окно старта, финиш не раньше отправления
        await d.q(startSql, {'t': t});
        await d.q(finishSql, {'t': t});
      }
      await w.advance(const Duration(hours: 25)); // по всем девяти рейсам пора начислять
      final fin = [for (var i = 0; i < 6; i++) clone(w.finance)];
      final dc = [for (var i = 0; i < 6; i++) clone(d)];
      final later = await inMinutes(120);
      final res = await together([
        for (var i = 0; i < 35; i++) () => after(i % 6, () => crowd[i].q(rateSql, {'b': bookings[i], 's': '${1 + i % 5}'})),
        for (var i = 0; i < 6; i++) () => after(i, () => fin[i].one('select accrue_due()')),
        for (var i = 0; i < 4; i++) () => after(i, () => dc[i].createTrip(route, later.add(Duration(minutes: 30 * i)))),
        () => after(2, () => dc[4].q(applySql, applyArgs(4))),
        () => after(3, () => dc[5].one('select driver_earnings()')),
        () => after(1, () => w.finance.one('select finance_create_payouts()')),
        () => after(4, () => w.verifier.q(reviewSql, {'d': d.id, 'a': 'true', 'r': null})),
      ]);
      // Рейтинг сверяется сразу после гонки, до последней оценки (она пересчитала бы его заново).
      final ratingOff = await num(invariants['рейтинг водителя равен среднему его оценок']!);
      // Уборка до проверок: новые рейсы снимаются.
      await crowd[35].q(rateSql, {'b': bookings[35], 's': '5'});
      for (final row in await w.admin.execute("select id::text from trips where driver_id = '${d.id}' and status = 'planned'")) {
        await w.support.q(cancelTripSql, {'t': row.first});
      }
      expect(dbErrors(res), isEmpty);
      expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'DRIVER_HAS_ACTIVE_TRIPS', 'DRIVER_NOT_APPROVED'}), isEmpty);
      expect(await num("select count(*)::int from trips where id = any(@t::uuid[]) and accrued_at is not null", {'t': '{${trips.join(',')}}'}), tripsCount);
      expect(await num("select count(*)::int from ledger where trip_id = any(@t::uuid[]) and kind = 'driver_accrual'", {'t': '{${trips.join(',')}}'}), tripsCount * 4,
          reason: 'по каждой брони начислено один раз');
      expect(await num('select count(*)::int from bookings where id = any(@b::uuid[]) and rating is not null', {'b': '{${bookings.join(',')}}'}), 36);
      expect(ratingOff, 0, reason: 'рейтинг сразу после 35 одновременных оценок равен среднему');
    });

    test('один номер операции одновременно на 12 разных рейсах: одна бронь, без ошибок базы', () async {
      // ИСПРАВЛЕНО: раньше повтор номера операции проверялся под блокировкой рейса, а рейсы разные — проверки шли
      // параллельно, и одна покупка падала на уникальном индексе (23505) уже после списания.
      // ПРАВИЛО: операция одного пассажира выполняется строго один раз; тот же номер на другом рейсе — IDEM_KEY_REUSED,
      // до банка доходит только первый запрос.
      final d = await drv('Один номер');
      final p = await pas('Двенадцать телефонов');
      final dep = await inMinutes(200);
      final trips = [for (var i = 0; i < 12; i++) await d.createTrip(route, dep.add(Duration(minutes: 25 * i)))];
      addTearDown(() async {
        for (final t in trips) {
          await d.q(cancelTripSql, {'t': t});
        }
      });
      final all = <Object?>[];
      for (var round = 0; round < 5; round++) {
        final clones = [for (var i = 0; i < 12; i++) clone(p)];
        final key = 'same-$round-${w.nextKey()}';
        final res = await together([for (var i = 0; i < 12; i++) () => clones[i].book(trips[i], ['front'], idem: key)]);
        for (final c in clones) {
          await c.close();
        }
        all.addAll(res);
        expect(await num('select count(*)::int from bookings where passenger_id = @u::uuid and idem_key = @k', {'u': p.id, 'k': key}), 1);
        final mine = await w.scalar('select id::text from bookings where passenger_id = @u::uuid and idem_key = @k', {'u': p.id, 'k': key}) as String;
        expect(res.whereType<Map>().map((r) => '${r['booking_id']} ${r['status']}').toList(), ['$mine paid'], reason: 'куплено ровно один раз');
        expect(res.whereType<Refused>().map((e) => e.code).toList(), List.filled(11, 'IDEM_KEY_REUSED'));
        expect(await num("select count(*)::int from payments p join bookings b on b.id = p.booking_id where b.passenger_id = @u::uuid and b.idem_key = @k and p.kind = 'charge'", {'u': p.id, 'k': key}), 1,
            reason: 'банк спрошен один раз');
        expect(await heldSeats(trips), 1);
        await p.cancel(mine);
      }
      expect(dbErrors(all).toSet(), isEmpty, reason: 'ошибки базы вместо ответа «повтор»: ${dbErrors(all).length} из ${all.length}');
    });

    test('бронь одновременно отменяют пассажир с двух телефонов и поддержка: возврат один', () async {
      const n = 5;
      final drivers = [for (var i = 0; i < n; i++) await drv('Тройная отмена $i')];
      final dep = await inMinutes(200);
      final trips = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
      final bookings = <String>[];
      for (var i = 0; i < n; i++) {
        bookings.addAll(await sell(trips[i], crowd.sublist(i * 4, i * 4 + 4)));
      }
      final twins = [for (var j = 0; j < bookings.length; j++) clone(crowd[j])];
      final sup = [for (var i = 0; i < 4; i++) clone(w.support)];
      final res = await together([
        for (var j = 0; j < bookings.length; j++) ...[
          () => crowd[j].cancel(bookings[j]),
          () => sup[j % 4].one(cancelSql, {'b': bookings[j]}),
          () => twins[j].cancel(bookings[j]),
        ],
      ]);
      expect(dbErrors(res), isEmpty);
      expect(res.whereType<Refused>().map((e) => e.code).toSet(), {'NOT_CANCELLABLE'});
      expect(res.where((r) => r is! Refused), hasLength(bookings.length));
      for (final b in bookings) {
        expect(await num("select count(*)::int from ledger where booking_id = @b::uuid and kind = 'refund'", {'b': b}), 1);
      }
      expect(await num('select count(*)::int from trip_seats where trip_id = any(@t::uuid[]) and booking_id is not null', {'t': '{${trips.join(',')}}'}), 0);
      for (var i = 0; i < n; i++) {
        await drivers[i].q(cancelTripSql, {'t': trips[i]});
      }
    });

    test('у человека 4 карты, с 12 подключений одновременно привязывают ещё: всего не больше пяти', () async {
      // ИСПРАВЛЕНО: раньше bind_card_sim сначала считал карты, потом вставлял — одновременные привязки обходили лимит.
      // ПРАВИЛО: привязки одного человека идут по очереди; действующих карт никогда не больше max_cards (5).
      var worst = 0;
      for (var round = 0; round < 6; round++) {
        final p = await w.newUser('Много карт $round');
        temp.add(p);
        for (var i = 0; i < 4; i++) {
          await p.bindCard('411111111111${1000 + i}');
        }
        final clones = [for (var i = 0; i < 12; i++) clone(p)];
        await Future.wait([for (final c in clones) c.q('select 1')]);
        final res = await together([for (var i = 0; i < clones.length; i++) () => clones[i].bindCard('41111111111${10000 + i}')]);
        for (final c in clones) {
          await c.close();
        }
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>().map((e) => e.code).toList(), List.filled(11, 'TOO_MANY_CARDS'), reason: 'из 12 привязок проходит одна');
        worst = max(worst, await num('select count(*)::int from cards where user_id = @u::uuid and removed_at is null', {'u': p.id}));
      }
      expect(worst, 5, reason: 'привязано карт: $worst при лимите 5');
    });

    test('проверяющий одобряет анкету, а водитель в этот момент подаёт другую', () async {
      // GAP: решение проверяющего не привязано к версии анкеты. Если новая анкета успела раньше, одобренной
      // оказывается машина, которую проверяющий не видел. Здесь закрепляется только согласованность итога.
      var unseenApproved = 0, pendingNew = 0;
      for (var round = 0; round < 16; round++) {
        final d = await drv('Версия анкеты $round', approve: false);
        final ver = clone(w.verifier);
        await Future.wait([d.q('select 1'), ver.q('select 1')]);
        await together([() => ver.q(reviewSql, {'d': nobody, 'a': 'true', 'r': null}), () => d.q(applySql, applyArgs(4))]); // прогрев
        final res = await together([
          () => Future<void>.delayed(Duration(milliseconds: round.isEven ? round % 3 : 0)).then((_) => ver.q(reviewSql, {'d': d.id, 'a': 'true', 'r': null})),
          () => Future<void>.delayed(Duration(milliseconds: round.isOdd ? 1 + round % 3 : 0)).then((_) => d.q(applySql, applyArgs(3, car: 'Не та машина'))),
        ]);
        await ver.close();
        expect(res.whereType<Refused>(), isEmpty);
        final row = (await w.admin.execute("select status::text, car from drivers where user_id = '${d.id}'")).first;
        expect(row[1], 'Не та машина');
        if (row[0] == 'approved') {
          unseenApproved++;
        } else {
          expect(row[0], 'pending');
          pendingNew++;
        }
        await d.close();
      }
      print('проверка против новой анкеты: одобрена невиданная анкета $unseenApproved раз, новая анкета ждёт проверки — $pendingNew');
    });

    test('неверные данные дают отказ по правилам, а не ошибку базы', () async {
      // ИСПРАВЛЕНО: раньше часть проверок была оставлена ограничениям таблиц — приложение получало сырую ошибку базы
      // (23514 / 23505) вместо кода отказа, который оно умеет показать.
      final u = await w.newUser('Кривая анкета');
      temp.add(u);
      final r = await newRoute();
      final d = await drv('Кривой рейс');
      final got = <String, String?>{
        'анкета: 5 мест': await u.refusal(applySql, applyArgs(5)),
        'анкета: пустая машина': await u.refusal(applySql, {'c': '  ', 'k': 'серая', 'p': '35 AA 001', 's': '4', 't': '01234567'}),
        'маршрут: код уже занят': await w.moderator.refusal(saveRouteSql, {'id': null, 'code': 'M1', 'fn': 'А', 'tn': 'Б', 'p': '500', 'm': '25', 'l': '9000'}),
        'маршрут: цена 0': await w.moderator.refusal(saveRouteSql, {'id': r, 'code': 'F$routeSeq', 'fn': 'А', 'tn': 'Б', 'p': '0', 'm': '25', 'l': '9000'}),
        'рейс: место не объект': await d.refusal(createSql, {'r': r, 'd': (await inMinutes(60)).toUtc().toIso8601String(), 'm': '0', 's': '["front"]'}),
      };
      final raw = {
        for (final e in got.entries)
          if (e.value != null && isDbError(e.value!)) e.key: e.value,
      };
      expect(raw, isEmpty, reason: 'все ответы: $got');
      expect(got.values, everyElement(isNotNull), reason: 'неверные данные должны быть отклонены: $got');
      expect(got.values.toList(), ['BAD_SEATS_TOTAL', 'BAD_ARGUMENT', 'ROUTE_CODE_TAKEN', 'BAD_ARGUMENT', 'BAD_SEATS']);
    });

    test('допуск отзывают и возвращают, пока водитель ставит рейсы и подаёт анкеты', () async {
      // Гонки заявка × проверка × рейс: ошибок базы нет, рейс ставится только одобренным водителем с его машиной.
      final d = await drv('Карусель допуска', seats: 4);
      final ver = [clone(w.verifier), clone(w.verifier)];
      final dc = [for (var i = 0; i < 4; i++) clone(d)];
      final all = <Object?>[];
      final dep = await inMinutes(120);
      for (var round = 0; round < 12; round++) {
        final res = await together([
          () => ver[0].q(reviewSql, {'d': d.id, 'a': 'true', 'r': null}),
          () => dc[0].createTrip(route, dep.add(Duration(minutes: 30 * round)), seats: {'front': 600}),
          () => dc[1].q(applySql, applyArgs(4)),
          () => ver[1].q(reviewSql, {'d': d.id, 'a': 'true', 'r': null}),
          () => dc[2].createTrip(route, dep.add(Duration(minutes: 30 * round + 5)), seats: {'rl': 500}),
          () => dc[3].one(cancelTripSql, {'t': nobody}),
        ]);
        all.addAll(res);
        for (final row in await w.admin.execute("select id::text from trips where driver_id = '${d.id}' and status = 'planned'")) {
          await w.support.q(cancelTripSql, {'t': row.first});
        }
        await w.verifier.q(reviewSql, {'d': d.id, 'a': 'true', 'r': null});
      }
      expect(dbErrors(all), isEmpty);
      expect(all.whereType<Refused>().map((e) => e.code).toSet().difference({'DRIVER_NOT_APPROVED', 'TRIP_OVERLAP', 'DRIVER_HAS_ACTIVE_TRIPS', 'TRIP_NOT_FOUND'}), isEmpty);
    });

    // ---------- новые правила сервера под одновременной нагрузкой ----------

    test('водителя блокируют, а пассажиры в тот же момент покупают и отменяют места на его рейсах', () async {
      // ПРАВИЛО: блокировка водителя сразу отменяет его не начатые рейсы с полным возвратом. Покупка, успевшая раньше,
      // возвращается этой же отменой; опоздавшая получает TRIP_CLOSED. После блокировки у водителя нет рейсов в продаже,
      // нет занятых мест, и всё списанное возвращено.
      const n = 6, rounds = 4;
      final drivers = [for (var i = 0; i < n; i++) await drv('Блок-водитель $i')];
      final sup = [for (var i = 0; i < n; i++) clone(w.support)];
      var inTime = 0, tooLate = 0;
      for (var round = 0; round < rounds; round++) {
        final dep = await inMinutes(200);
        final a = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
        final b = [for (final d in drivers) await d.createTrip(route, dep.add(const Duration(minutes: 30)), seats: fourSeats)];
        final first = [for (var i = 0; i < n; i++) await sell(a[i], [crowd[i * 8], crowd[i * 8 + 1]])]; // front, rl
        await Future.wait([for (final x in [...sup, ...crowd]) x.q('select 1')]); // подключения открыты заранее
        final res = await together([
          for (var i = 0; i < n; i++) ...[
            () => crowd[i * 8 + 2].book(a[i], ['rr']),
            () => crowd[i * 8].cancel(first[i][0]), // ранняя отмена: возврат и место снова в продаже
            () => after((i + round) % 4, () => sup[i].q(blockSql, {'u': drivers[i].id, 'b': 'true'})),
            () => after(1, () => crowd[i * 8 + 3].book(a[i], ['rm'])),
            () => after(1, () => crowd[i * 8 + 4].book(b[i], ['front', 'rl'])),
            () => after(2, () => crowd[i * 8 + 5].book(b[i], ['rr'])),
            () => after(3, () => crowd[i * 8 + 6].book(b[i], ['rm'])),
            () => after(4, () => crowd[i * 8 + 7].book(a[i], ['front'])),
          ],
        ]);
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'TRIP_CLOSED', 'SEAT_TAKEN', 'NOT_CANCELLABLE'}), isEmpty);
        for (var i = 0; i < n; i++) {
          expect(res[i * 8 + 2], isNot(isA<Refused>()), reason: 'блокировка проходит всегда');
        }
        final all = [...a, ...b];
        inTime += await num("select count(*)::int from bookings where trip_id = any(@t::uuid[]) and status <> 'failed'", {'t': ids(all)}) - n * 2;
        tooLate += res.whereType<Refused>().where((e) => e.code == 'TRIP_CLOSED').length;
        expect(await num("select count(*)::int from trips where id = any(@t::uuid[]) and status <> 'cancelled'", {'t': ids(all)}), 0,
            reason: 'все рейсы заблокированных водителей отменены');
        expect(await num("select count(*)::int from trips where driver_id = any(@d::uuid[]) and status = 'planned'", {'d': ids(drivers.map((d) => d.id))}), 0);
        expect(await heldSeats(all), 0);
        expect(await moneyKept(all), 0, reason: 'возвращено всё списанное');
        expect(await notRefundedOnce(all), 0, reason: 'каждой брони — один полный возврат');
        // После блокировки не продаётся ничего.
        final again = await together([for (var i = 0; i < n; i++) () => crowd[i * 8 + 2].book(b[i], ['front'])]);
        expect(again.map((r) => r is Refused ? r.code : r).toList(), List.filled(n, 'TRIP_CLOSED'));
        expect(await violations(w), isEmpty, reason: 'круг $round');
        for (final d in drivers) {
          await block(d, false);
        }
      }
      print('блокировка водителя против покупок: успели купить (и получили возврат) $inTime, опоздали $tooLate');
    });

    test('водителя блокируют, а он в тот же момент ставит рейсы: у заблокированного не остаётся рейсов в продаже', () async {
      // ПРАВИЛО: у заблокированного водителя нет не начатых рейсов (блокировка их отменяет, а новый рейс он поставить
      // не может). Рейс, поставленный «одновременно» с блокировкой, должен быть либо отменён ею, либо не поставлен.
      // ИСПРАВЛЕНО (раньше было так): гонка staff_block_user × driver_create_trip. Постановка рейса проверяет блокировку один раз, на входе
      // (_uid), ещё до блокировки строки водителя, и после ожидания не перепроверяет; staff_block_user строку водителя
      // не блокирует и отменяет только уже зафиксированные рейсы. Рейс, который ставился в этот момент, остаётся
      // «в продаже» у заблокированного водителя (купить место на нём нельзя — TRIP_CLOSED, но он виден в расписании
      // и оживёт при снятии блокировки). Нарушается проверка целостности «не начатые рейсы есть только у одобренных
      // и не заблокированных водителей»; из-за этого же время от времени падает «шторм».
      const n = 8, rounds = 6;
      final drivers = [for (var i = 0; i < n; i++) await drv('Блок и рейс $i')];
      final phones = [for (final d in drivers) [for (var k = 0; k < 3; k++) clone(d)]];
      final sup = [for (var i = 0; i < n; i++) clone(w.support)];
      final mine = ids(drivers.map((d) => d.id));
      Future<void> cleanup() async {
        for (final row in await w.admin.execute("select id::text from trips where driver_id = any('$mine'::uuid[]) and status = 'planned'")) {
          await w.support.q(cancelTripSql, {'t': row.first});
        }
        for (final d in drivers) {
          await block(d, false);
        }
      }

      addTearDown(cleanup);
      var leftover = 0, badRounds = 0, made = 0, refused = 0;
      for (var round = 0; round < rounds; round++) {
        final dep = await inMinutes(120);
        await Future.wait([for (final x in [...sup, ...phones.expand((p) => p)]) x.q('select 1')]);
        final res = await together([
          for (var i = 0; i < n; i++) ...[
            () => after((i + round) % 3, () => sup[i].q(blockSql, {'u': drivers[i].id, 'b': 'true'})),
            () => phones[i][0].createTrip(route, dep),
            () => after(1, () => phones[i][1].createTrip(route, dep.add(const Duration(minutes: 30)))),
            () => after(2, () => phones[i][2].createTrip(route, dep.add(const Duration(minutes: 60)))),
          ],
        ]);
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'BLOCKED'}), isEmpty);
        made += res.whereType<String>().length;
        refused += res.whereType<Refused>().length;
        final left = await num(
            "select count(*)::int from trips t join profiles p on p.id = t.driver_id where t.driver_id = any(@d::uuid[]) and t.status = 'planned' and p.blocked",
            {'d': mine});
        leftover += left;
        if (left > 0) badRounds++;
        await cleanup();
      }
      expect(leftover, 0,
          reason: 'за $rounds кругов поставлено рейсов: $made, отказано (BLOCKED): $refused; у заблокированных водителей осталось '
              'в продаже рейсов: $leftover (в $badRounds кругах) — блокировка их не увидела');
    });

    test('водителю отзывают допуск, а он в тот же момент начинает рейс: рейс либо начат, либо отменён с возвратом', () async {
      // ПРАВИЛО: отказ в допуске отменяет не начатые рейсы; начать рейс и поставить новый без допуска нельзя
      // (DRIVER_NOT_APPROVED). Отказ, старт и постановка рейса идут по очереди через строку водителя: рейс не остаётся
      // «в продаже» у водителя без допуска. Со второго телефона водитель в тот же момент ставит ещё один рейс.
      const n = 10, rounds = 4;
      final drivers = [for (var i = 0; i < n; i++) await drv('Отзыв и старт $i')];
      final twins = [for (final d in drivers) clone(d)];
      final ver = [for (var i = 0; i < 5; i++) clone(w.verifier)];
      var startWon = 0, rejectWon = 0, createdThenCancelled = 0;
      for (var round = 0; round < rounds; round++) {
        final dep = await inMinutes(20);
        final now = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
        final later = [for (final d in drivers) await d.createTrip(route, dep.add(const Duration(minutes: 200)), seats: fourSeats)];
        for (var i = 0; i < n; i++) {
          await sell(now[i], [crowd[i * 4], crowd[i * 4 + 1]]);
          await sell(later[i], [crowd[i * 4 + 2], crowd[i * 4 + 3]]);
        }
        await w.advance(const Duration(minutes: 6)); // окно старта открыто
        await Future.wait([for (final x in [...ver, ...drivers, ...twins]) x.q('select 1')]);
        final res = await together([
          for (var i = 0; i < n; i++) ...[
            () => after((i + round) % 3, () => ver[i % 5].q(reviewSql, {'d': drivers[i].id, 'a': 'false', 'r': 'жалобы'})),
            () => after((i ~/ 3 + round) % 3, () => drivers[i].q(startSql, {'t': now[i]})),
            () => after((i ~/ 2 + round) % 3, () => twins[i].createTrip(route, dep.add(const Duration(minutes: 400)))),
          ],
        ]);
        expect(dbErrors(res), isEmpty);
        final cancelled = [...later];
        final started = <int>[];
        for (var i = 0; i < n; i++) {
          expect(res[i * 3], isNot(isA<Refused>()), reason: 'отказ в допуске проходит всегда');
          expect(await tStatus(later[i]), 'cancelled', reason: 'не начатый рейс отклонённого водителя отменён');
          final created = res[i * 3 + 2];
          if (created is Refused) {
            expect(created.code, 'DRIVER_NOT_APPROVED');
          } else {
            createdThenCancelled++;
            expect(await tStatus(created as String), 'cancelled', reason: 'рейс, поставленный перед самым отказом, отменён этим же отказом');
          }
          final start = res[i * 3 + 1];
          if (start is Refused) {
            rejectWon++;
            expect(start.code, 'DRIVER_NOT_APPROVED');
            expect(await tStatus(now[i]), 'cancelled');
            cancelled.add(now[i]);
          } else {
            startWon++;
            started.add(i);
            expect(await tStatus(now[i]), 'started');
            expect(await num("select count(*)::int from bookings where trip_id = @t::uuid and status = 'paid'", {'t': now[i]}), 2);
            expect(await moneyKept([now[i]]), 1100, reason: 'по начатому рейсу ничего не возвращено');
          }
        }
        expect(await notRefundedOnce(cancelled), 0, reason: 'каждой брони отменённых рейсов — один полный возврат');
        expect(await heldSeats(cancelled), 0);
        expect(await num("select count(*)::int from trips where driver_id = any(@d::uuid[]) and status = 'planned'", {'d': ids(drivers.map((d) => d.id))}), 0);
        expect(await violations(w), isEmpty, reason: 'круг $round');
        // Уборка: начатые рейсы водители доводят до конца, допуск возвращается.
        await toDeparture(now.first);
        for (final i in started) {
          await drivers[i].q(finishSql, {'t': now[i]});
        }
        for (final d in drivers) {
          await w.verifier.q(reviewSql, {'d': d.id, 'a': 'true', 'r': null});
        }
        await w.advance(const Duration(minutes: 30));
      }
      print('отзыв допуска против старта: старт успел $startWon раз, отказ в допуске — $rejectWon; '
          'новый рейс успел встать (и отменён отказом) $createdThenCancelled раз из ${n * rounds}');
    });

    test('водитель с шести телефонов одновременно начинает два рейса встык: начат ровно один', () async {
      // ПРАВИЛО: у водителя не больше одного начатого рейса — и когда оба «старта» приходят одновременно
      // (ANOTHER_TRIP_STARTED: старты одного водителя идут по очереди через его строку).
      const n = 6, rounds = 4;
      final drivers = [for (var i = 0; i < n; i++) await drv('Два старта $i')];
      final phones = [for (final d in drivers) [for (var k = 0; k < 6; k++) clone(d)]];
      var firstWon = 0, secondWon = 0;
      for (var round = 0; round < rounds; round++) {
        final dep = await inMinutes(20);
        final a = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
        final b = [for (final d in drivers) await d.createTrip(route, dep.add(const Duration(minutes: 25)), seats: fourSeats)]; // встык
        for (var i = 0; i < n; i++) {
          await sell(a[i], [crowd[i * 4], crowd[i * 4 + 1]]);
          await sell(b[i], [crowd[i * 4 + 2], crowd[i * 4 + 3]]);
        }
        await w.advance(const Duration(minutes: 31)); // первый рейс 11 минут как должен идти, до второго 14 минут: оба окна старта открыты
        await Future.wait([for (final x in phones.expand((p) => p)) x.q('select 1')]);
        final res = await together([
          for (var i = 0; i < n; i++)
            for (var k = 0; k < 6; k++) () => after((k + i + round) % 2, () => phones[i][k].q(startSql, {'t': k.isEven ? a[i] : b[i]})),
        ]);
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'ANOTHER_TRIP_STARTED', 'TRIP_NOT_PLANNED'}), isEmpty);
        final startedFirst = <bool>[];
        for (var i = 0; i < n; i++) {
          expect(res.sublist(i * 6, i * 6 + 6).where((r) => r is! Refused), hasLength(1), reason: 'из шести стартов принят ровно один');
          final sa = await tStatus(a[i]), sb = await tStatus(b[i]);
          expect([sa, sb]..sort(), ['planned', 'started']);
          startedFirst.add(sa == 'started');
          sa == 'started' ? firstWon++ : secondWon++;
          expect(await num("select count(*)::int from bookings where trip_id = any(@t::uuid[]) and status = 'paid'", {'t': ids([a[i], b[i]])}), 4);
        }
        expect(await violations(w), isEmpty, reason: 'круг $round');
        // Уборка заодно проверяет продолжение: после финиша первого второй начинается; опоздавший первый — TOO_LATE.
        await toDeparture(b.first); // время отправления второго рейса = конец первого по расписанию
        for (var i = 0; i < n; i++) {
          if (startedFirst[i]) {
            await drivers[i].q(finishSql, {'t': a[i]});
            expect(await drivers[i].refusal(startSql, {'t': b[i]}), isNull, reason: 'первый завершён — второй начинается');
            await drivers[i].q(finishSql, {'t': b[i]});
          } else {
            await drivers[i].q(finishSql, {'t': b[i]});
            expect(await drivers[i].refusal(startSql, {'t': a[i]}), 'TOO_LATE', reason: 'конец первого рейса по расписанию уже прошёл');
            expect(await drivers[i].one(cancelTripSql, {'t': a[i]}), 2);
          }
        }
        await w.advance(const Duration(minutes: 30));
      }
      print('два старта одного водителя: первым начат ранний рейс $firstWon раз, поздний — $secondWon');
    });

    test('возврат поддержкой и начисление в один момент: по каждой брони либо возврат, либо начисление', () async {
      // ПРАВИЛО: поддержка возвращает деньги по брони полностью, пока доли по рейсу не начислены; после начисления —
      // отказ ALREADY_ACCRUED. Одни и те же деньги не могут быть и возвращены пассажиру, и распределены.
      const n = 8, rounds = 3;
      final drivers = [for (var i = 0; i < n; i++) await drv('Возврат и начисление $i')];
      final sup = [for (var i = 0; i < 8; i++) clone(w.support)];
      final fin = [for (var i = 0; i < 4; i++) clone(w.finance)];
      var refunded = 0, accrued = 0;
      for (var round = 0; round < rounds; round++) {
        final dep = await inMinutes(20);
        final trips = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
        final bookings = <String>[];
        for (var i = 0; i < n; i++) {
          bookings.addAll(await sell(trips[i], crowd.sublist(i * 4, i * 4 + 4)));
        }
        await w.advance(const Duration(minutes: 6));
        // Одна бронь на рейс отменена поздно, без возврата: её деньги тоже либо возвращаются, либо распределяются.
        for (var i = 0; i < n; i++) {
          expect((await crowd[i * 4 + 3].cancel(bookings[i * 4 + 3]))['refund'], 0);
        }
        await Future.wait([for (var i = 0; i < n; i++) drivers[i].q(startSql, {'t': trips[i]})]);
        await toDeparture(trips.first);
        await Future.wait([for (var i = 0; i < n; i++) drivers[i].q(finishSql, {'t': trips[i]})]);
        await w.advance(const Duration(hours: 24)); // сутки после финиша истекли только что: момент начисления
        await Future.wait([for (final x in [...sup, ...fin]) x.q('select 1')]);
        final res = await together([
          for (var j = 0; j < bookings.length; j++) () => after((j + round) % 5, () => sup[j % 8].one(refundSql, {'b': bookings[j], 'r': 'жалоба пассажира'})),
          for (var k = 0; k < 4; k++) () => after(k + round, () => fin[k].one(accrueSql)),
        ]);
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'ALREADY_ACCRUED'}), isEmpty);
        await w.finance.one(accrueSql);
        expect(await num('select count(*)::int from trips where id = any(@t::uuid[]) and accrued_at is null', {'t': ids(trips)}), 0);
        for (var j = 0; j < bookings.length; j++) {
          final amount = fourSeats[seatOrder[j % 4]]!;
          final state = await w.scalar('''
              select b.refund || ' / ' || b.status || ' / распределено '
                || (select coalesce(sum(l.amount), 0) from ledger l where l.booking_id = b.id and l.kind in ('driver_accrual', 'commission', 'state_duty'))
                || ' / возвратов ' || (select count(*) from ledger l where l.booking_id = b.id and l.kind = 'refund')
                || ' / записей о возврате ' || (select count(*) from audit_log a where a.action = 'refund_booking' and a.entity_id = b.id::text)
              from bookings b where b.id = @b::uuid''', {'b': bookings[j]});
          final r = res[j];
          if (r is Refused) {
            accrued++;
            expect(state, '0 / ${j % 4 == 3 ? 'cancelled' : 'done'} / распределено $amount / возвратов 0 / записей о возврате 0', reason: 'бронь $j: отказ ${r.code}');
          } else {
            refunded++;
            expect(r, amount, reason: 'возвращена вся сумма брони');
            expect(state, '$amount / cancelled / распределено 0 / возвратов 1 / записей о возврате 1', reason: 'бронь $j: возврат принят');
          }
        }
        expect(await violations(w), isEmpty, reason: 'круг $round');
        await w.advance(const Duration(minutes: 30));
      }
      print('возврат поддержкой против начисления: возвращено $refunded броней, начислено по $accrued');
    });

    test('автоотмена не начатого рейса, отмена водителем и отмены пассажиров в один момент: каждой брони — один полный возврат', () async {
      // ПРАВИЛО: не начатый рейс через 2 часа после конца по расписанию отменяет accrue_due. Возврат полный и ровно один —
      // кто бы ни отменил рейс первым (сервер, водитель, поддержка) и что бы в этот момент ни делал пассажир;
      // тем, кто отменил поздно без возврата, деньги тоже возвращаются.
      const n = 12, rounds = 3;
      final drivers = [for (var i = 0; i < n; i++) await drv('Автоотмена $i')];
      final twins = [for (final d in drivers) clone(d)];
      final fin = [for (var i = 0; i < 4; i++) clone(w.finance)];
      final sup = [clone(w.support), clone(w.support)];
      for (var round = 0; round < rounds; round++) {
        final dep = await inMinutes(20);
        final trips = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
        final bookings = <String>[];
        for (var i = 0; i < n; i++) {
          bookings.addAll(await sell(trips[i], crowd.sublist(i * 4, i * 4 + 4)));
        }
        await w.advance(const Duration(minutes: 6));
        for (var i = 0; i < n; i++) {
          expect((await crowd[i * 4 + 3].cancel(bookings[i * 4 + 3]))['refund'], 0, reason: 'за 14 минут — без возврата');
        }
        await w.advance(const Duration(hours: 3)); // конец по расписанию + 2 часа прошли
        await Future.wait([for (final x in [...crowd, ...drivers, ...twins, ...fin, ...sup]) x.q('select 1')]);
        final res = await together([
          for (var i = 0; i < n; i++) ...[
            () => i % 3 == 0 ? after(round, () => fin[i ~/ 3].one(accrueSql)) : Future.value(),
            () => crowd[i * 4].cancel(bookings[i * 4]),
            () => i.isEven ? after(1, () => drivers[i].one(cancelTripSql, {'t': trips[i]})) : Future.value(),
            () => after(1, () => crowd[i * 4 + 1].cancel(bookings[i * 4 + 1])),
            () => i % 4 == 1 ? sup[(i ~/ 4) % 2].one(cancelTripSql, {'t': trips[i]}) : Future.value(),
            () => after(2, () => twins[i].q(startSql, {'t': trips[i]})),
            () => after(2, () => crowd[i * 4 + 2].cancel(bookings[i * 4 + 2])),
          ],
        ]);
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'NOT_CANCELLABLE', 'TRIP_NOT_PLANNED', 'TOO_LATE'}), isEmpty);
        for (var i = 0; i < n; i++) {
          expect(res[i * 7 + 5], isA<Refused>(), reason: 'поздний старт не проходит никогда');
          for (final k in [1, 3, 6]) {
            final r = res[i * 7 + k];
            if (r is! Refused) expect((r as Map)['refund'], 0, reason: 'отмена пассажира после отправления — без возврата (его вернёт отмена рейса)');
          }
          expect(await tStatus(trips[i]), 'cancelled');
          expect(await num("select count(*)::int from audit_log where action = 'cancel_trip' and entity_id = @t", {'t': trips[i]}), 1, reason: 'рейс отменён ровно один раз');
        }
        expect(await notRefundedOnce(trips), 0, reason: 'каждой брони — один полный возврат');
        expect(await num('select count(*)::int from bookings where trip_id = any(@t::uuid[])', {'t': ids(trips)}), n * 4);
        expect(await heldSeats(trips), 0);
        expect(await moneyKept(trips), 0);
        expect(await violations(w), isEmpty, reason: 'круг $round');
        await w.advance(const Duration(minutes: 30));
      }
    });

    test('модератор меняет длину и время в пути маршрута, а водители в тот же момент ставят на него рейсы', () async {
      // ПРАВИЛО: точки, длину и время в пути маршрута с рейсами менять нельзя (ROUTE_HAS_ACTIVE_TRIPS); правка и
      // постановка рейса идут по очереди через строку маршрута. Каждый рейс в продаже соответствует нынешнему маршруту:
      // место посадки — в его начальном районе, конец рейса — отправление плюс время в пути.
      const n = 16, rounds = 10;
      final drivers = [for (var i = 0; i < n; i++) await drv('Правка маршрута $i')];
      final mods = [clone(w.moderator), clone(w.moderator)];
      final routes = <String>[];
      addTearDown(() async {
        for (final row in await w.admin.execute("select id::text from trips where route_id = any('${ids(routes)}'::uuid[]) and status = 'planned'")) {
          await w.support.q(cancelTripSql, {'t': row.first});
        }
      });
      var editFirst = 0, tripsFirst = 0, wrongTotal = 0;
      for (var round = 0; round < rounds; round++) {
        final r = await newRoute(minutes: 25, length: 9000);
        final code = 'F$routeSeq';
        routes.add(r);
        final dep = await inMinutes(120);
        Map<String, Object?> edit(int minutes, int length) =>
            {'id': r, 'code': code, 'fn': 'Давташен', 'tn': 'Площадь Республики', 'p': '500', 'm': '$minutes', 'l': '$length'};
        await Future.wait([for (final x in [...mods, ...drivers]) x.q('select 1')]);
        // Половина рейсов — с местом посадки на 1400-м метре (на укороченном маршруте его нет), половина — в начале.
        // Правки приходят на 0–3 мс, рейсы — на 1–3 мс: встречаются оба порядка.
        final res = await together([
          for (var i = 0; i < n ~/ 2; i++) () => after(1 + i % 3, () => drivers[i].createTrip(r, dep, meet: i.isEven ? 1400 : 0)),
          () => after(round % 4, () => mods[0].q(saveRouteSql, edit(60, 800))),
          for (var i = n ~/ 2; i < n; i++) () => after(1 + i % 3, () => drivers[i].createTrip(r, dep, meet: i.isEven ? 1400 : 0)),
          () => after((round + 2) % 4, () => mods[1].q(saveRouteSql, edit(40, 1200))),
        ]);
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'ROUTE_HAS_ACTIVE_TRIPS', 'MEET_POINT_OUTSIDE_DISTRICT'}), isEmpty);
        final wrong = await num('''select count(*)::int from trips t join routes r on r.id = t.route_id
            where t.route_id = @r::uuid and t.status = 'planned'
              and (t.meet_along > least(1500, r.length_m) or t.ends_at - t.departure <> make_interval(mins => r.minutes))''', {'r': r});
        wrongTotal += wrong;
        final edited = [res[n ~/ 2], res[n + 1]].where((x) => x is! Refused).length;
        final made = res.whereType<String>().length;
        expect(wrong, 0, reason: 'круг $round: правок принято $edited, рейсов поставлено $made — и $wrong из них не соответствуют маршруту');
        if (edited == 0) {
          tripsFirst++;
          expect(made, n, reason: 'маршрут не изменился — все рейсы поставлены');
          expect(await w.scalar("select minutes || ' ' || length_m from routes where id = @r::uuid", {'r': r}), '25 9000');
        } else {
          editFirst++;
          expect(await num("select count(*)::int from trips where route_id = @r::uuid and status = 'planned' and meet_along > 0", {'r': r}), 0,
              reason: 'на укороченном маршруте нет рейсов с посадкой на 1400-м метре');
        }
        for (final row in await w.admin.execute("select id::text from trips where route_id = '$r' and status = 'planned'")) {
          await w.support.q(cancelTripSql, {'t': row.first});
        }
      }
      print('правка маршрута против постановки рейсов: правка первой $editFirst раз, рейсы первыми — $tripsFirst; несоответствий $wrongTotal');
    });

    test('одну бронь одновременно возвращают два сотрудника поддержки, отменяет пассажир, а рейс отменяет водитель: возврат один', () async {
      // ПРАВИЛО: staff_refund_booking возвращает всё, что ещё не возвращено, один раз; повтор — NOTHING_TO_REFUND.
      const n = 8, rounds = 3;
      final drivers = [for (var i = 0; i < n; i++) await drv('Двойной возврат $i')];
      final sup = [for (var i = 0; i < 16; i++) clone(w.support)];
      for (var round = 0; round < rounds; round++) {
        final dep = await inMinutes(200);
        final trips = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
        final bookings = <String>[];
        for (var i = 0; i < n; i++) {
          bookings.addAll(await sell(trips[i], crowd.sublist(i * 4, i * 4 + 4)));
        }
        await Future.wait([for (final x in [...sup, ...drivers, ...crowd.take(n * 4)]) x.q('select 1')]);
        final res = await together([
          for (var j = 0; j < bookings.length; j++) ...[
            () => sup[(j * 2) % 16].one(refundSql, {'b': bookings[j], 'r': 'жалоба'}),
            () => after((j + round) % 2, () => sup[(j * 2 + 1) % 16].one(refundSql, {'b': bookings[j], 'r': 'та же жалоба, второй сотрудник'})),
            () => j % 4 == 1 ? after(round % 2, () => crowd[j].cancel(bookings[j])) : Future.value(),
          ],
          for (var i = 0; i < n; i++) () => i.isOdd ? after(1, () => drivers[i].one(cancelTripSql, {'t': trips[i]})) : Future.value(),
        ]);
        expect(dbErrors(res), isEmpty);
        expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'NOTHING_TO_REFUND', 'NOT_CANCELLABLE'}), isEmpty);
        for (var j = 0; j < bookings.length; j++) {
          final accepted = [res[j * 3], res[j * 3 + 1]].where((r) => r is! Refused).toList();
          expect(accepted.length, lessThanOrEqualTo(1), reason: 'бронь $j: возврат поддержкой принят дважды');
          expect(accepted, everyElement(fourSeats[seatOrder[j % 4]]), reason: 'возвращается вся сумма брони');
          expect(await num("select count(*)::int from audit_log where action = 'refund_booking' and entity_id = @b", {'b': bookings[j]}), accepted.length);
        }
        expect(await notRefundedOnce(trips), 0, reason: 'каждой брони — один полный возврат');
        expect(await heldSeats(trips), 0);
        expect(await moneyKept(trips), 0);
        // Повтор и чужие: отказ, денег не движется.
        expect(await w.support.refusal(refundSql, {'b': bookings[0], 'r': 'ещё раз'}), 'NOTHING_TO_REFUND');
        expect(await w.support.refusal(refundSql, {'b': bookings[0], 'r': '  '}), 'REASON_REQUIRED');
        expect(await w.support.refusal(refundSql, {'b': nobody, 'r': 'нет такой брони'}), 'BOOKING_NOT_FOUND');
        expect(await crowd[0].refusal(refundSql, {'b': bookings[0], 'r': 'сам себе'}), 'FORBIDDEN');
        expect(await drivers[0].refusal(refundSql, {'b': bookings[0], 'r': 'водитель'}), 'FORBIDDEN');
        expect(await w.finance.refusal(refundSql, {'b': bookings[0], 'r': 'финансист'}), 'FORBIDDEN');
        expect(await notRefundedOnce(trips), 0);
        // На не отменённых рейсах места после возврата снова продаются.
        expect((await crowd[0].book(trips[0], ['front', 'rl', 'rr', 'rm']))['status'], 'paid');
        expect(await violations(w), isEmpty, reason: 'круг $round');
        for (var i = 0; i < n; i += 2) {
          await drivers[i].q(cancelTripSql, {'t': trips[i]});
        }
      }
    });

    test('начисление по рейсу и оценки его пассажиров в один момент: без взаимных блокировок', () async {
      // Порядок блокировок на сервере — водитель → маршрут → рейс → бронь. Оценка берёт строку водителя, затем бронь;
      // начисление держит рейс и пишет в журнал денег строки со ссылками на бронь и на водителя. Ни одна сторона
      // не должна получить ошибку базы 40P01 (взаимная блокировка): ни пассажир, ни начисление по расписанию.
      // Здесь только эти два действия: у двух водителей по шесть рейсов встык, все 48 пассажиров оценивают поездку
      // в тот момент, когда по этим рейсам идёт начисление.
      // ИСПРАВЛЕНО (раньше было так): взаимная блокировка accrue_due × rate_booking. Начисление вставляет строку журнала по первой брони
      // водителя: внешний ключ берёт бронь (key share), затем ждёт строку водителя, занятую очередью оценок. Оценка этой
      // же брони получает строку водителя и ждёт бронь, занятую начислением. Жертва — оценка пассажира или весь запуск
      // начисления (тогда доли не начислены никому до следующего запуска).
      const perDriver = 6, rounds = 2;
      final drivers = [await drv('Оценка и начисление 0'), await drv('Оценка и начисление 1')];
      final fin = [for (var i = 0; i < 3; i++) clone(w.finance)];
      for (var round = 0; round < rounds; round++) {
        final dep = await inMinutes(20);
        final byDriver = [
          for (final d in drivers) [for (var k = 0; k < perDriver; k++) await d.createTrip(route, dep.add(Duration(minutes: 25 * k)), seats: fourSeats)],
        ];
        final trips = byDriver.expand((t) => t).toList();
        final bookings = <String>[];
        for (var i = 0; i < trips.length; i++) {
          bookings.addAll(await sell(trips[i], crowd.sublist(i * 4, i * 4 + 4)));
        }
        for (var k = 0; k < perDriver; k++) {
          await toDeparture(byDriver[0][k]); // рейсы встык проходят по одному
          for (var x = 0; x < drivers.length; x++) {
            await drivers[x].q(startSql, {'t': byDriver[x][k]});
            await drivers[x].q(finishSql, {'t': byDriver[x][k]});
          }
        }
        await w.advance(const Duration(hours: 25)); // по всем рейсам пора начислять
        await Future.wait([for (final x in [...fin, ...crowd.take(bookings.length)]) x.q('select 1')]);
        final res = await together([
          for (var j = 0; j < bookings.length; j++) () => after((j + round) % 3, () => crowd[j].q(rateSql, {'b': bookings[j], 's': '${1 + j % 5}'})),
          for (var k = 0; k < 3; k++) () => after(1 + k, () => fin[k].one(accrueSql)),
        ]);
        final rateErrors = dbErrors(res.take(bookings.length)), accrueErrors = dbErrors(res.skip(bookings.length));
        await w.finance.one(accrueSql); // если начисление стало жертвой взаимной блокировки, доводим его до конца
        expect([...rateErrors, ...accrueErrors], isEmpty,
            reason: 'круг $round: ошибку базы получили оценки пассажиров — ${rateErrors.length} из ${bookings.length}, запуски начисления — ${accrueErrors.length} из 3');
        expect(res.whereType<Refused>(), isEmpty);
        expect(await num('select count(*)::int from trips where id = any(@t::uuid[]) and accrued_at is null', {'t': ids(trips)}), 0);
        expect(await num("select count(*)::int from ledger where trip_id = any(@t::uuid[]) and kind = 'driver_accrual'", {'t': ids(trips)}), bookings.length);
        expect(await num('select count(*)::int from bookings where id = any(@b::uuid[]) and rating is not null', {'b': ids(bookings)}), bookings.length);
        expect(await violations(w), isEmpty, reason: 'круг $round');
        await w.advance(const Duration(minutes: 30));
      }
    });

    test('начисление отменяет не начатый рейс и начисляет за вчерашний, а водитель жмёт «начать» или теряет допуск: без взаимных блокировок', () async {
      // У каждого водителя — вчерашний рейс, по которому пора начислять, и сегодняшний, который он так и не начал
      // (конец по расписанию + 2 часа прошли). accrue_due сначала отменяет сегодняшний (держит рейс), потом начисляет
      // за вчерашний (ссылка на водителя). Поздний старт и отказ в допуске берут строку водителя, затем рейс.
      // Порядок блокировок на сервере — водитель → рейс; ошибок базы 40P01 быть не должно.
      // ИСПРАВЛЕНО (раньше было так): взаимная блокировка accrue_due × staff_review_driver (отказ) и accrue_due × driver_start_trip.
      // Отказ в допуске (и поздний старт) держит строку водителя и ждёт рейс, который accrue_due уже отменяет;
      // accrue_due держит этот рейс и, начисляя за вчерашний рейс того же водителя, ждёт строку водителя (внешний ключ
      // ledger.driver_id). accrue_due берёт блокировки в порядке рейс → водитель — обратном принятому на сервере.
      const n = 10, rounds = 2;
      final drivers = [for (var i = 0; i < n; i++) await drv('Вчера и сегодня $i')];
      final fin = [for (var i = 0; i < 3; i++) clone(w.finance)];
      final ver = [for (var i = 0; i < 5; i++) clone(w.verifier)];
      for (var round = 0; round < rounds; round++) {
        var dep = await inMinutes(20);
        final old = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
        for (var i = 0; i < n; i++) {
          await sell(old[i], [crowd[i * 4], crowd[i * 4 + 1]]);
        }
        await w.advance(const Duration(minutes: 6));
        await Future.wait([for (var i = 0; i < n; i++) drivers[i].q(startSql, {'t': old[i]})]);
        await toDeparture(old.first);
        await Future.wait([for (var i = 0; i < n; i++) drivers[i].q(finishSql, {'t': old[i]})]);
        await w.advance(const Duration(hours: 22));
        dep = await inMinutes(20);
        final stale = [for (final d in drivers) await d.createTrip(route, dep, seats: fourSeats)];
        for (var i = 0; i < n; i++) {
          await sell(stale[i], [crowd[i * 4 + 2], crowd[i * 4 + 3]]);
        }
        await w.advance(const Duration(hours: 3)); // вчерашним рейсам больше суток; сегодняшние кончились больше 2 часов назад
        await Future.wait([for (final x in [...fin, ...ver, ...drivers]) x.q('select 1')]);
        final res = await together([
          for (var k = 0; k < 3; k++) () => after(k, () => fin[k].one(accrueSql)),
          for (var i = 0; i < n; i++)
            () => i.isEven
                ? after(2 + i % 5, () => drivers[i].q(startSql, {'t': stale[i]}))
                : after(i % 4, () => ver[i % 5].q(reviewSql, {'d': drivers[i].id, 'a': 'false', 'r': 'не выходит на рейсы'})),
        ]);
        final accrueErrors = dbErrors(res.take(3));
        final startErrors = dbErrors([for (var i = 0; i < n; i += 2) res[3 + i]]), rejectErrors = dbErrors([for (var i = 1; i < n; i += 2) res[3 + i]]);
        // Уборка до проверок: начисление доводится до конца, допуск возвращается (в том числе тем, кому отказ не дошёл).
        await w.finance.one(accrueSql);
        for (var i = 1; i < n; i += 2) {
          await w.verifier.q(reviewSql, {'d': drivers[i].id, 'a': 'true', 'r': null});
        }
        final startCodes = [for (var i = 0; i < n; i += 2) res[3 + i]].map((r) => r is Refused ? r.code : 'принят').toList();
        expect([...accrueErrors, ...startErrors, ...rejectErrors], isEmpty,
            reason: 'круг $round: ошибку базы получили запуски начисления — ${accrueErrors.length} из 3, '
                'поздние старты — ${startErrors.length} из ${n ~/ 2}, отказы в допуске — ${rejectErrors.length} из ${n ~/ 2}; '
                'ответы на поздний старт: $startCodes');
        expect(res.whereType<Refused>().map((e) => e.code).toSet().difference({'TOO_LATE', 'TRIP_NOT_PLANNED'}), isEmpty);
        expect(await num("select count(*)::int from trips where id = any(@t::uuid[]) and status <> 'cancelled'", {'t': ids(stale)}), 0);
        expect(await notRefundedOnce(stale), 0, reason: 'каждой брони не состоявшегося рейса — один полный возврат');
        expect(await num('select count(*)::int from trips where id = any(@t::uuid[]) and accrued_at is null', {'t': ids(old)}), 0);
        expect(await num("select count(*)::int from ledger where trip_id = any(@t::uuid[]) and kind = 'driver_accrual'", {'t': ids(old)}), n * 2);
        expect(await violations(w), isEmpty, reason: 'круг $round');
        await w.advance(const Duration(minutes: 30));
      }
    });

    // Шторм — последним: если он падает посреди пути, заблокированные им пользователи остаются заблокированными.
    // ИСПРАВЛЕНО (раньше было так): шторм падает не каждый раз — когда в нём случается гонка staff_block_user × driver_create_trip
    // (см. «водителя блокируют, а он в тот же момент ставит рейсы»): у заблокированного водителя остаётся рейс в продаже.
    test('шторм: рейсы, покупки, отмены, блокировки, правки и статусы маршрутов, заявки, начисления — без ошибок базы', () async {
      final rnd = Random(2026);
      await closeCrowd();
      final routes = [for (var i = 0; i < 3; i++) await newRoute(price: 400 + 100 * i, minutes: 15 + 10 * i, length: 4000 + 1000 * i)];
      final codes = [for (var i = 0; i < 3; i++) 'F${routeSeq - 2 + i}'];
      final drivers = [for (var i = 0; i < 8; i++) await drv('Шторм-водитель $i', seats: i.isEven ? 4 : 3)];
      final dTwins = [for (final d in drivers) clone(d)];
      final passengers = crowd.sublist(0, 28);
      final staff = {
        'mod': [clone(w.moderator), clone(w.moderator)],
        'sup': [clone(w.support), clone(w.support)],
        'ver': [clone(w.verifier)],
        'fin': [clone(w.finance), clone(w.finance)],
      };
      final blocked = <String>{};
      final outcomes = <String, int>{};
      void note(String k) => outcomes[k] = (outcomes[k] ?? 0) + 1;
      T pick<T>(List<T> l) => l[rnd.nextInt(l.length)];
      Future<void> act(String name, Future<Object?> Function() f) async {
        try {
          await f();
          note('$name: да');
        } on Refused catch (e) {
          note('$name: ${e.code}');
        }
      }

      Future<void> oneAction() async {
        final dice = rnd.nextInt(100);
        if (dice < 14) {
          final i = rnd.nextInt(drivers.length);
          final d = rnd.nextBool() ? drivers[i] : dTwins[i];
          final all = ['front', 'rl', 'rr', if (i.isEven) 'rm']..shuffle(rnd);
          final seats = {for (final s in all.take(1 + rnd.nextInt(all.length))) s: 100 * (2 + rnd.nextInt(6))};
          // Половина рейсов — на ближайшие полчаса-час: начать рейс можно только за 15 минут до отправления, а завершить —
          // с момента отправления, и далёкие рейсы до этого в шторме почти не доживают (их отменяют раньше).
          final dep = (await w.now()).add(Duration(minutes: 16 + rnd.nextInt(rnd.nextBool() ? 40 : 400)));
          await act('рейс', () => d.createTrip(pick(routes), dep, meet: rnd.nextInt(1500), seats: seats));
        } else if (dice < 46) {
          final trips = await w.admin.execute("select id::text from trips where status = 'planned' and route_id = any('{${routes.join(',')}}'::uuid[]) order by random() limit 4");
          if (trips.isEmpty) return;
          final p = pick(passengers);
          final seats = (['front', 'rl', 'rm', 'rr']..shuffle(rnd)).take(1 + rnd.nextInt(2)).toList();
          await act('бронь', () => p.book(pick(trips).first as String, seats));
        } else if (dice < 56) {
          final rows = await w.admin.execute(
              "select b.id::text, b.passenger_id::text from bookings b join trips t on t.id = b.trip_id where b.status = 'paid' and t.route_id = any('{${routes.join(',')}}'::uuid[]) order by random() limit 1");
          if (rows.isEmpty) return;
          final bySupport = rnd.nextInt(4) == 0;
          final who = bySupport ? pick(staff['sup']!) : passengers.firstWhere((x) => x.id == rows.first[1]);
          await act(bySupport ? 'отмена брони поддержкой' : 'отмена брони', () => who.one(cancelSql, {'b': rows.first[0]}));
        } else if (dice < 61) {
          final rows = await w.admin.execute(
              "select id::text, driver_id::text from trips where status = 'planned' and route_id = any('{${routes.join(',')}}'::uuid[]) order by random() limit 1");
          if (rows.isEmpty) return;
          final bySupport = rnd.nextInt(3) == 0;
          final i = drivers.indexWhere((x) => x.id == rows.first[1]);
          final who = bySupport ? pick(staff['sup']!) : (rnd.nextBool() ? drivers[i] : dTwins[i]);
          await act(bySupport ? 'отмена рейса поддержкой' : 'отмена рейса', () => who.one(cancelTripSql, {'t': rows.first[0]}));
        } else if (dice < 75) {
          // Сначала рейсы в пути и те, у кого открыто окно старта (за 15 минут до отправления — конец по расписанию):
          // иначе почти все старты получают TOO_EARLY и шторм не доходит до финишей.
          final rows = await w.admin.execute(
              "select id::text, driver_id::text, status::text from trips where status in ('planned', 'started') and route_id = any('{${routes.join(',')}}'::uuid[]) "
              "order by (status = 'started' or app_now() between departure - interval '15 minutes' and ends_at) desc, departure limit 4");
          if (rows.isEmpty) return;
          final row = pick(rows);
          final i = drivers.indexWhere((x) => x.id == row[1]);
          final d = rnd.nextBool() ? drivers[i] : dTwins[i];
          final t = row[0] as String;
          if (row[2] == 'planned') {
            await act('старт', () => d.q(startSql, {'t': t}));
          } else if (rnd.nextBool()) {
            await act('отметка', () => d.q(markSql, {'t': t, 's': pick(seatOrder), 'm': pick(['boarded', 'no_show', null])}));
          } else {
            await act('финиш', () => d.q(finishSql, {'t': t}));
          }
        } else if (dice < 79) {
          final i = rnd.nextInt(drivers.length);
          await act('анкета', () => dTwins[i].q(applySql, applyArgs(i.isEven ? 4 : 3)));
        } else if (dice < 85) {
          await act('допуск', () => staff['ver']!.first.q(reviewSql, {'d': pick(drivers).id, 'a': 'true', 'r': null}));
        } else if (dice < 91) {
          final a = rnd.nextInt(3) == 0 ? pick(drivers) : pick(passengers);
          final on = !blocked.contains(a.id);
          on ? blocked.add(a.id) : blocked.remove(a.id);
          await act(on ? 'блок' : 'разблок', () => pick(staff['sup']!).q(blockSql, {'u': a.id, 'b': '$on'}));
        } else if (dice < 95) {
          final i = rnd.nextInt(routes.length);
          await act('статус маршрута', () => pick(staff['mod']!).q(routeStatusSql, {'r': routes[i], 's': pick(['draft', 'archived', 'published', 'published'])}));
        } else if (dice < 97) {
          final i = rnd.nextInt(routes.length);
          await act(
              'правка маршрута',
              () => pick(staff['mod']!).q(saveRouteSql,
                  {'id': routes[i], 'code': codes[i], 'fn': 'А', 'tn': 'Б', 'p': '${300 + 100 * rnd.nextInt(6)}', 'm': '${10 + rnd.nextInt(40)}', 'l': '${4000 + 1000 * i}'}));
        } else {
          await act('начисление', () => pick(staff['fin']!).one('select accrue_due()'));
          await act('выплаты', () => pick(staff['fin']!).one('select finance_create_payouts()'));
        }
      }

      const batch = 24;
      for (var done = 0; done < 1920; done += batch) {
        await Future.wait([for (var i = 0; i < batch; i++) oneAction()]);
        if (rnd.nextInt(3) == 0) await w.advance(Duration(minutes: 3 + rnd.nextInt(25)));
        if ((done ~/ batch) % 10 == 0) {
          expect(await violations(w), isEmpty, reason: 'целостность после $done действий шторма');
          for (final r in routes) {
            await w.moderator.refusal(routeStatusSql, {'r': r, 's': 'published'});
          }
        }
      }
      for (final id in blocked) {
        await w.support.q(blockSql, {'u': id, 'b': 'false'});
      }
      await w.advance(const Duration(days: 3));
      await w.finance.one('select accrue_due()');
      await w.finance.one('select finance_create_payouts()');
      expect(await violations(w), isEmpty, reason: 'целостность в конце шторма');
      final table = (outcomes.keys.toList()..sort()).map((k) => '    $k = ${outcomes[k]}').join('\n');
      print('ШТОРМ: исходы действий\n$table');
      expect(outcomes.keys.where((k) => isDbError(k.split(': ').last)), isEmpty, reason: 'ошибки базы в шторме');
      expect(outcomes['бронь: да'] ?? 0, greaterThan(30));
      expect(outcomes['финиш: да'] ?? 0, greaterThan(0));
    });
  });
}
