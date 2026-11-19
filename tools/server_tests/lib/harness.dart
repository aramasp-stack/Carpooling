/// Тестовый стенд: локальная копия сервера и виртуальные пользователи.
///
/// Каждый виртуальный пользователь ([Actor]) ходит в базу так же, как приложение через Supabase:
/// под ролью `authenticated` и со своим «токеном входа». Поэтому тесты проверяют те же правила доступа
/// и те же серверные функции, с которыми работают приложения.
library;

import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';

final int pgPort = int.parse(Platform.environment['TRANSPORT_PG_PORT'] ?? '54329');

Future<Connection> _open(String database) => Connection.open(
      Endpoint(host: 'localhost', port: pgPort, database: database, username: 'postgres'),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  while (!Directory('${dir.path}/supabase/migrations').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('Не найдена папка supabase/migrations');
    dir = parent;
  }
  return dir;
}

/// Создаёт чистую базу с именем [name] и применяет к ней все миграции.
Future<void> resetDatabase(String name) async {
  final root = await _open('postgres');
  await root.execute('drop database if exists "$name" with (force)');
  await root.execute('create database "$name"');
  await root.close();

  final repo = _repoRoot();
  final files = [
    File('${repo.path}/supabase/local/shim.sql'),
    ...Directory('${repo.path}/supabase/migrations').listSync().whereType<File>().where((f) => f.path.endsWith('.sql')).toList()
      ..sort((a, b) => a.path.compareTo(b.path)),
  ];
  final db = await _open(name);
  for (final f in files) {
    try {
      await db.execute(await f.readAsString(), queryMode: QueryMode.simple);
    } on ServerException catch (e) {
      await db.close();
      throw StateError('Ошибка в ${f.uri.pathSegments.last}: ${e.message} (позиция в файле: ${e.position ?? '?'})');
    }
  }
  await db.close();
}

/// Отказ сервера: [code] — код из исключения серверной функции или ошибка базы.
class Refused implements Exception {
  Refused(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'Refused($code)';
}

Refused _refused(ServerException e) {
  final m = e.message;
  final code = RegExp(r'^[A-Z][A-Z0-9_]+').stringMatch(m) ?? (e.code ?? 'ERROR');
  return Refused(code, m);
}

/// Виртуальный пользователь: пассажир, водитель или сотрудник.
class Actor {
  Actor(this.world, this.id, this.phone, this.name);
  final World world;
  final String id;
  final String phone;
  final String name;
  Connection? _conn;

  /// Карта, привязанная при создании (если просили).
  String? cardId;

  /// Сколько времени назад человек вводил код из SMS (для действий, где нужен свежий вход).
  Duration smsAge = Duration.zero;

  Future<Connection> _connection() async => _conn ??= await _open(world.database);

  /// Запрос от имени пользователя: роль authenticated + его токен входа.
  Future<Result> q(String sql, [Map<String, Object?> params = const {}]) async {
    final conn = await _connection();
    try {
      return await conn.runTx((s) async {
        await s.execute('set local role authenticated');
        await s.execute(
          Sql.named("select set_config('request.jwt.claims', @c, true)"),
          parameters: {
            'c': jsonEncode({
              'sub': id,
              'phone': phone,
              'role': 'authenticated',
              'amr': [
                {'method': 'otp', 'timestamp': DateTime.now().subtract(smsAge).millisecondsSinceEpoch ~/ 1000}
              ],
            })
          },
        );
        return s.execute(Sql.named(sql), parameters: params);
      });
    } on ServerException catch (e) {
      throw _refused(e);
    }
  }

  /// Первое значение первой строки.
  Future<Object?> one(String sql, [Map<String, Object?> params = const {}]) async {
    final r = await q(sql, params);
    return r.isEmpty ? null : r.first.first;
  }

  /// Код отказа, если сервер отказал; null — если запрос прошёл.
  Future<String?> refusal(String sql, [Map<String, Object?> params = const {}]) async {
    try {
      await q(sql, params);
      return null;
    } on Refused catch (e) {
      return e.code;
    }
  }

  // ---------- действия пассажира ----------

  Future<String> bindCard(String number) async =>
      cardId = await one('select bind_card_sim(@n)', {'n': number}) as String;

  /// Покупка мест. Возвращает ответ сервера: booking_id, status, amount.
  Future<Map<String, dynamic>> book(String tripId, List<String> seats, {String? card, String? idem}) async {
    final r = await one(
      'select book_seats(@t::uuid, @s::text[], @c::uuid, @k)',
      {'t': tripId, 's': '{${seats.join(',')}}', 'c': card ?? cardId, 'k': idem ?? world.nextKey()},
    );
    return Map<String, dynamic>.from(r as Map);
  }

  Future<Map<String, dynamic>> cancel(String bookingId) async =>
      Map<String, dynamic>.from(await one('select cancel_booking(@b::uuid)', {'b': bookingId}) as Map);

  // ---------- действия водителя ----------

  /// Загрузить все пять документов для проверки (в облаке файлы лежат в хранилище, здесь — только записи).
  Future<void> uploadDocuments() async {
    for (final k in const ['id_document', 'license', 'registration', 'car_photo', 'selfie']) {
      await q('select driver_save_document(@k, @p)', {'k': k, 'p': '$id/$k.jpg'});
    }
  }

  /// Привязать карту для выплат (симуляция банка).
  Future<String> setPayoutCard([String number = '4111111111111111']) async =>
      await one('select driver_set_payout_card_sim(@n, @h)', {'n': number, 'h': name}) as String;

  Future<String> createTrip(String routeId, DateTime departure, {int meet = 0, Map<String, int>? seats}) async {
    final list = (seats ?? {'front': 600, 'rl': 500, 'rr': 500}).entries.map((e) => {'id': e.key, 'price': e.value}).toList();
    return await one(
      'select driver_create_trip(@r::uuid, @d::timestamptz, @m::int, @s::jsonb)',
      {'r': routeId, 'd': departure.toUtc().toIso8601String(), 'm': '$meet', 's': jsonEncode(list)},
    ) as String;
  }

  Future<void> close() async {
    await _conn?.close();
    _conn = null;
  }
}

/// Тестовый мир: одна база, служебное подключение и набор виртуальных пользователей.
class World {
  World._(this.database, this.admin);
  final String database;

  /// Служебное подключение (как сервер): для подготовки данных и проверок целостности.
  final Connection admin;

  final List<Actor> _actors = [];
  int _seq = 0;

  late Actor owner, moderator, verifier, finance, support;

  static Future<World> create(String database) async {
    await resetDatabase(database);
    final w = World._(database, await _open(database));
    w.owner = await w.newUser('Владелец');
    await w.admin.execute(Sql.named("insert into staff (user_id, roles) values (@u::uuid, '{owner}')"), parameters: {'u': w.owner.id});
    w.moderator = await w.newStaff('Модератор', ['moderator']);
    w.verifier = await w.newStaff('Проверяющий', ['verifier']);
    w.finance = await w.newStaff('Финансист', ['finance']);
    w.support = await w.newStaff('Поддержка', ['support']);
    return w;
  }

  String nextKey() => 'k${++_seq}-${DateTime.now().microsecondsSinceEpoch}';

  /// Новый человек: «вошёл по SMS» и заполнил имя.
  Future<Actor> newUser(String name) async {
    final phone = '+3749${(1000000 + ++_seq).toString()}';
    final r = await admin.execute(Sql.named('insert into auth.users (phone) values (@p) returning id'), parameters: {'p': phone});
    final a = Actor(this, r.first.first as String, phone, name);
    _actors.add(a);
    await a.q('select register_profile(@n, @l)', {'n': name, 'l': 'ru'});
    return a;
  }

  Future<Actor> newStaff(String name, List<String> roles) async {
    final a = await newUser(name);
    await owner.q('select staff_set_roles(@u::uuid, @r::text[])', {'u': a.id, 'r': '{${roles.join(',')}}'});
    return a;
  }

  Future<Actor> newPassenger(String name, {String card = '4111111111111111'}) async {
    final a = await newUser(name);
    await a.bindCard(card);
    return a;
  }

  /// Новый водитель с одобренной заявкой.
  Future<Actor> newDriver(String name, {int seats = 4, bool approve = true}) async {
    final a = await newUser(name);
    await a.q('select apply_driver(@c, @k, @p, @s::int, @t)',
        {'c': 'Toyota Camry', 'k': 'белая', 'p': '35 OO ${100 + _seq}', 's': '$seats', 't': '0${1000000 + _seq}'});
    await a.uploadDocuments();
    await a.setPayoutCard();
    if (approve) await verifier.q('select staff_review_driver(@d::uuid, true)', {'d': a.id});
    return a;
  }

  /// Новый опубликованный маршрут. [minPrice] — минимальная цена места (по умолчанию 1, чтобы не мешать прочим проверкам).
  Future<String> newRoute(String code, {int price = 500, int minPrice = 1, int minutes = 25, int length = 9000, bool publish = true}) async {
    final id = await moderator.one(
      'select staff_save_route(null, @code, @fn, 40.2264, 44.4930, @tn, 40.1777, 44.5126, @p::int, @m::int, @l::int, 4283388645, @mn::int)',
      {'code': code, 'fn': 'Давташен', 'tn': 'Площадь Республики', 'p': '$price', 'mn': '$minPrice', 'm': '$minutes', 'l': '$length'},
    ) as String;
    if (publish) await moderator.q("select staff_set_route_status(@r::uuid, 'published')", {'r': id});
    return id;
  }

  // ---------- часы сервера ----------

  Future<DateTime> now() async => (await admin.execute('select app_now()')).first.first as DateTime;

  int _offsetSeconds = 0;

  /// Перевести часы сервера вперёд.
  Future<void> advance(Duration d) async {
    _offsetSeconds += d.inSeconds;
    await admin.execute(
      Sql.named("update app_settings set value = to_jsonb(@s::int) where key = 'clock_offset_seconds'"),
      parameters: {'s': '$_offsetSeconds'},
    );
  }

  /// Запрос от имени сервера: одно значение.
  Future<Object?> scalar(String sql, [Map<String, Object?> params = const {}]) async {
    final r = await admin.execute(Sql.named(sql), parameters: params);
    return r.isEmpty ? null : r.first.first;
  }

  Future<void> close() async {
    for (final a in _actors) {
      await a.close();
    }
    await admin.close();
  }
}
