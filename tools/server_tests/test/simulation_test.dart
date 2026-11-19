// Большая случайная симуляция: десятки виртуальных пассажиров и водителей действуют одновременно
// в случайном порядке, часы сервера идут вперёд. После каждой порции действий проверяется целостность.
//
// Объём задаётся переменными окружения:
//   SIM_STEPS — сколько действий (по умолчанию 1500), SIM_SEED — зерно случайности (по умолчанию 1).
// Один и тот же SIM_SEED повторяет тот же сценарий.
import 'dart:io';
import 'dart:math';

import 'package:server_tests/harness.dart';
import 'package:server_tests/invariants.dart';
import 'package:test/test.dart';

void main() {
  final steps = int.parse(Platform.environment['SIM_STEPS'] ?? '1500');
  final seed = int.parse(Platform.environment['SIM_SEED'] ?? '1');

  test('симуляция: $steps действий, зерно $seed', () async {
    final rnd = Random(seed);
    final w = await World.create('tt_sim_$seed');
    addTearDown(w.close);

    final routes = [
      for (var i = 0; i < 6; i++) await w.newRoute('S$i', price: 300 + 100 * rnd.nextInt(8), minPrice: 300, minutes: 8 + rnd.nextInt(25), length: 2000 + rnd.nextInt(9000)),
    ];
    final drivers = [for (var i = 0; i < 10; i++) await w.newDriver('Водитель $i', seats: i.isEven ? 4 : 3)];
    final passengers = [
      for (var i = 0; i < 40; i++)
        await w.newPassenger('Пассажир $i', card: i % 13 == 0 ? '4111111111110002' : (i % 17 == 0 ? '4111111111110119' : '4111111111111111')),
    ];

    final outcomes = <String, int>{};
    void note(String k) => outcomes[k] = (outcomes[k] ?? 0) + 1;

    T pick<T>(List<T> list) => list[rnd.nextInt(list.length)];

    Future<List<String>> ids(String sql) async => (await w.admin.execute(sql)).map((r) => r.first as String).toList();

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
        // водитель ставит рейс
        final d = pick(drivers);
        final four = drivers.indexOf(d).isEven;
        final all = ['front', 'rl', 'rr', if (four || rnd.nextInt(10) == 0) 'rm']..shuffle(rnd);
        final seats = {for (final s in all.take(1 + rnd.nextInt(all.length))) s: 100 * (2 + rnd.nextInt(8))};
        final dep = (await w.now()).add(Duration(minutes: 10 + rnd.nextInt(900)));
        await act('рейс', () => d.createTrip(pick(routes), dep, meet: rnd.nextInt(1700), seats: seats));
      } else if (dice < 70) {
        // пассажир покупает места
        final trips = await ids("select id::text from trips where status = 'planned' order by random() limit 5");
        if (trips.isEmpty) return;
        final seats = (['front', 'rl', 'rm', 'rr']..shuffle(rnd)).take(1 + rnd.nextInt(2)).toList();
        final p = pick(passengers);
        await act('бронь', () async {
          final r = await p.book(pick(trips), seats);
          if (r['status'] != 'paid') throw Refused('CARD_DECLINED', '');
          return r;
        });
      } else if (dice < 84) {
        // пассажир отменяет свою бронь
        final rows = await w.admin.execute("select id::text, passenger_id::text from bookings where status = 'paid' order by random() limit 1");
        if (rows.isEmpty) return;
        final p = passengers.firstWhere((x) => x.id == rows.first[1]);
        await act('отмена', () async {
          final r = await p.cancel(rows.first[0] as String);
          note(r['refund'] == 0 ? 'отмена без возврата' : 'отмена с возвратом');
          return r;
        });
      } else if (dice < 88) {
        // водитель отменяет рейс
        final rows = await w.admin.execute("select id::text, driver_id::text from trips where status = 'planned' order by random() limit 1");
        if (rows.isEmpty) return;
        final d = drivers.firstWhere((x) => x.id == rows.first[1]);
        await act('отмена рейса', () => d.q('select driver_cancel_trip(@t::uuid)', {'t': rows.first[0]}));
      } else if (dice < 96) {
        // водитель ведёт рейс: начать, отметить пассажиров, завершить
        // Обычно водитель берёт рейс, который уже идёт или которому пора начаться; иногда — любой (сервер должен отказать).
        final due = rnd.nextInt(5) == 0
            ? "status in ('planned', 'started')"
            : "status = 'started' or (status = 'planned' and app_now() between departure - interval '15 minutes' and ends_at)";
        final rows = await w.admin.execute(
            'select id::text, driver_id::text, status::text from trips where $due order by random() limit 3');
        if (rows.isEmpty) return;
        final row = pick(rows);
        final d = drivers.firstWhere((x) => x.id == row[1]);
        final t = row[0] as String;
        if (row[2] == 'planned') {
          await act('старт рейса', () => d.q('select driver_start_trip(@t::uuid)', {'t': t}));
        } else {
          final seats = await ids("select seat_id from trip_seats where trip_id = '$t' and booking_id is not null");
          for (final s in seats) {
            await act('отметка', () => d.q('select driver_mark_boarding(@t::uuid, @s, @m)', {'t': t, 's': s, 'm': rnd.nextInt(5) == 0 ? 'no_show' : 'boarded'}));
          }
          await act('финиш рейса', () => d.q('select driver_finish_trip(@t::uuid)', {'t': t}));
        }
      } else if (dice < 97 && rnd.nextBool()) {
        // водитель блокирует или разблокирует пассажира, с которым ездил, либо меняет карту для выплат
        final d = pick(drivers);
        final rows = await w.admin.execute(
            "select b.passenger_id::text from bookings b join trips t on t.id = b.trip_id where t.driver_id = '${d.id}' and b.status <> 'failed' order by random() limit 1");
        if (rnd.nextInt(4) == 0) {
          await act('смена карты для выплат', () => d.setPayoutCard('555555555555${1000 + rnd.nextInt(9000)}'));
        } else if (rows.isNotEmpty) {
          final fn = rnd.nextInt(3) == 0 ? 'driver_unblock_passenger' : 'driver_block_passenger';
          await act(fn == 'driver_block_passenger' ? 'блокировка' : 'разблокировка', () => d.q('select $fn(@p::uuid)', {'p': rows.first.first}));
        }
      } else if (dice < 98) {
        // пассажир оценивает поездку
        final rows = await w.admin.execute("select id::text, passenger_id::text from bookings where status = 'done' and rating is null order by random() limit 1");
        if (rows.isEmpty) return;
        final p = passengers.firstWhere((x) => x.id == rows.first[1]);
        await act('оценка', () => p.q('select rate_booking(@b::uuid, @s::int)', {'b': rows.first[0], 's': '${1 + rnd.nextInt(5)}'}));
      } else {
        // финансы: начисления и выплаты
        await act('начисление', () => w.finance.one('select accrue_due()'));
        await act('выплаты', () => w.finance.one('select finance_create_payouts()'));
      }
    }

    const batch = 8; // столько действий идёт одновременно
    for (var done = 0; done < steps; done += batch) {
      await Future.wait([for (var i = 0; i < batch; i++) oneAction()]);
      if (rnd.nextInt(3) == 0) await w.advance(Duration(minutes: 3 + rnd.nextInt(25)));
      if ((done ~/ batch) % 20 == 0) {
        expect(await violations(w), isEmpty, reason: 'целостность после $done действий (зерно $seed)');
      }
    }

    // Конец: все рейсы проходят, все доли начисляются и выплачиваются.
    await w.advance(const Duration(days: 3));
    await w.finance.one('select accrue_due()');
    await w.finance.one('select finance_create_payouts()');
    expect(await violations(w), isEmpty, reason: 'целостность в конце (зерно $seed)');

    final money = (await w.admin.execute('''
      select coalesce(sum(amount) filter (where kind = 'charge'), 0)::int,
             coalesce(sum(amount) filter (where kind = 'refund'), 0)::int,
             coalesce(sum(amount) filter (where kind = 'driver_accrual'), 0)::int,
             coalesce(sum(amount) filter (where kind = 'commission'), 0)::int,
             coalesce(sum(amount) filter (where kind = 'state_duty'), 0)::int,
             coalesce(sum(amount) filter (where kind = 'payout'), 0)::int
      from ledger''')).first;
    final charge = money[0] as int, refund = money[1] as int, drv = money[2] as int, com = money[3] as int, duty = money[4] as int, paid = money[5] as int;
    expect(charge - refund, drv + com + duty, reason: 'всё полученное распределено до драма');
    expect(paid, drv, reason: 'всё начисленное выплачено');

    final summary = StringBuffer()
      ..writeln('СИМУЛЯЦИЯ зерно=$seed действий=$steps')
      ..writeln('  рейсов: ${await w.scalar('select count(*)::int from trips')}, броней: ${await w.scalar('select count(*)::int from bookings')}')
      ..writeln('  получено $charge, возвращено $refund, водителям $drv, комиссия $com, госпошлина $duty, выплачено $paid')
      ..writeln('  исходы действий:');
    for (final k in outcomes.keys.toList()..sort()) {
      summary.writeln('    $k = ${outcomes[k]}');
    }
    print(summary);

    // Симуляция должна реально что-то делать, а не только получать отказы.
    expect(outcomes['бронь: да'] ?? 0, greaterThan(steps ~/ 30));
    expect(outcomes['финиш рейса: да'] ?? 0, greaterThan(0));
    expect(outcomes.keys.where((k) => k.contains('ERROR') || RegExp(r': [0-9A-Z]{5}$').hasMatch(k) && !k.contains('_')), isEmpty,
        reason: 'неожиданные ошибки базы: $outcomes');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
