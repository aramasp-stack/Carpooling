// Демо-данные для тестового облака (tools/demo_seed.sql): проходят все правила сервера,
// повторный запуск ничего не дублирует, а пассажир после входа находит рейсы и покупает место.
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:server_tests/harness.dart';
import 'package:server_tests/invariants.dart';
import 'package:test/test.dart';

void main() {
  late World w;
  late String seed;

  Future<void> runSeed() => w.admin.execute(seed, queryMode: QueryMode.simple);

  Future<int> count(String sql) async => await w.scalar(sql) as int;

  setUpAll(() async {
    w = await World.create('tt_seed');
    var dir = Directory.current.absolute;
    while (!File('${dir.path}/tools/demo_seed.sql').existsSync()) {
      dir = dir.parent;
    }
    seed = await File('${dir.path}/tools/demo_seed.sql').readAsString();
  });

  tearDownAll(() => w.close());

  test('демо-данные создаются по правилам сервера', () async {
    await runSeed();
    expect(await count("select count(*) from routes where status = 'published' and code ~ '^M[0-9]+\$'"), 25);
    expect(await count("select count(*) from drivers where status = 'approved'"), 15);
    expect(await count("select count(*) from trips where status = 'planned'"), greaterThan(100));
    expect(await count("select count(*) from bookings where status = 'paid'"), greaterThan(20));
    expect(await count('select count(*) from trip_seats s where not exists '
        '(select 1 from trip_seats f where f.trip_id = s.trip_id and f.booking_id is null)'), 0,
        reason: 'в каждом рейсе остаётся свободное место');
    expect(await violations(w), isEmpty);
  });

  test('повторный запуск ничего не дублирует', () async {
    final trips = await count('select count(*) from trips');
    final bookings = await count('select count(*) from bookings');
    final people = await count('select count(*) from profiles');
    await runSeed();
    expect(await count('select count(*) from trips'), trips);
    expect(await count('select count(*) from bookings'), bookings);
    expect(await count('select count(*) from profiles'), people);
    expect(await violations(w), isEmpty);
  });

  test('пассажир видит маршруты, рейсы и водителей и покупает место', () async {
    final p = await w.newPassenger('Новый пассажир');
    expect(await p.one("select count(*) from routes where code = 'M1'"), 1);
    final trip = await p.one('''
      select t.id from trips t join routes r on r.id = t.route_id
      where r.code = 'M1' and t.status = 'planned' and t.departure > app_now() + interval '10 minutes'
        and exists (select 1 from trip_seats s where s.trip_id = t.id and s.booking_id is null)
      order by t.departure limit 1''') as String;
    final driverName = await p.one(
        'select d.name from trips t join driver_public d on d.user_id = t.driver_id where t.id = @t::uuid', {'t': trip});
    expect(driverName, isNotNull, reason: 'имя и машина водителя видны пассажиру');
    final seat = await p.one('select seat_id from trip_seats where trip_id = @t::uuid and booking_id is null limit 1', {'t': trip}) as String;
    final r = await p.book(trip, [seat]);
    expect(r['status'], 'paid');
    expect(await violations(w), isEmpty);
  });
}
