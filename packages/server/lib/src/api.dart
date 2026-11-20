/// Обращения к серверу. Приложения только читают таблицы (что видно — решают правила сервера),
/// а любое изменение — бронь, карта, отмена, оценка — делают через серверные функции.
library;

import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:transport_core/transport_core.dart';

import 'config.dart';
import 'errors.dart';
import 'yerevan_time.dart';

/// Маршрут с сервера: модель для приложений + код и длина по дорогам из базы.
class RouteInfo {
  RouteInfo(this.def, this.code, this.lengthM);
  final RouteDef def;
  final String code;
  final int lengthM;
}

/// Профиль вошедшего человека.
class Profile {
  Profile({required this.id, required this.name, required this.phone});
  final String id;
  final String name;
  final String phone;
}

/// Привязанная карта: в приложение приходят только марка и последние 4 цифры.
class CardInfo {
  CardInfo({required this.id, required this.brand, required this.last4});
  final String id;
  final String brand;
  final String last4;
  String get title => '$brand •• $last4';
}

/// Бронь пассажира вместе с её рейсом.
class MyBooking {
  MyBooking(this.booking, this.trip, this.createdAt);
  final Booking booking;
  final Trip trip;
  final DateTime createdAt;
}

/// Ответ на покупку мест.
class BookResult {
  BookResult({required this.bookingId, required this.paid, required this.amount, this.reason});
  final String bookingId;
  final bool paid;
  final int amount;

  /// Почему не оплачено (например CARD_DECLINED), если банк отказал.
  final String? reason;
}

const _tripColumns = 'id,route_id,driver_id,departure,meet_along,drop_along,meet_lat,meet_lon,drop_lat,drop_lon,status,'
    'trip_seats(seat_id,price,booking_id)';

class ServerApi {
  ServerApi._();
  static final instance = ServerApi._();

  static Future<void> init() => Supabase.initialize(url: serverUrl, publishableKey: serverPublishableKey);

  SupabaseClient get _db => Supabase.instance.client;

  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      throw serverError(e);
    }
  }

  // ---------- вход ----------

  bool get signedIn => _db.auth.currentSession != null;
  String? get userId => _db.auth.currentUser?.id;
  Stream<AuthState> get authChanges => _db.auth.onAuthStateChange;

  /// Отправить код по SMS. [phone] — в международном виде: +374XXXXXXXX.
  Future<void> sendCode(String phone) => _call(() => _db.auth.signInWithOtp(phone: phone));

  Future<void> verifyCode(String phone, String code) =>
      _call(() => _db.auth.verifyOTP(type: OtpType.sms, phone: phone, token: code));

  Future<void> signOut() => _call(() => _db.auth.signOut());

  /// Профиль вошедшего человека; null — имя ещё не указано.
  Future<Profile?> myProfile() => _call(() async {
        final id = userId;
        if (id == null) return null;
        final row = await _db.from('profiles').select('id,name,phone').eq('id', id).maybeSingle();
        if (row == null) return null;
        return Profile(id: row['id'] as String, name: row['name'] as String, phone: row['phone'] as String);
      });

  /// После входа по SMS: имя (и язык). Телефон сервер берёт из входа, а не от приложения.
  Future<void> register(String name, {String lang = 'ru'}) =>
      _call(() => _db.rpc('register_profile', params: {'p_name': name, 'p_lang': lang}));

  // ---------- маршруты, водители, рейсы ----------

  Future<List<RouteInfo>> routes() => _call(() async {
        final rows = await _db
            .from('routes')
            .select('id,code,from_name,from_lat,from_lon,to_name,to_lat,to_lon,base_price,min_price,minutes,length_m,color')
            .eq('status', 'published');
        final list = [
          for (final r in rows)
            RouteInfo(
              RouteDef(
                id: r['id'] as String,
                color: (r['color'] as num).toInt(),
                price: (r['base_price'] as num).toInt(),
                minPrice: (r['min_price'] as num).toInt(),
                minutes: (r['minutes'] as num).toInt(),
                from: Place(r['from_name'] as String, GeoPoint((r['from_lat'] as num).toDouble(), (r['from_lon'] as num).toDouble())),
                to: Place(r['to_name'] as String, GeoPoint((r['to_lat'] as num).toDouble(), (r['to_lon'] as num).toDouble())),
              ),
              r['code'] as String,
              (r['length_m'] as num).toInt(),
            ),
        ];
        list.sort((a, b) => _codeOrder(a.code).compareTo(_codeOrder(b.code)));
        return list;
      });

  static int _codeOrder(String code) => int.tryParse(code.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1 << 20;

  /// Одобренные водители (имя, рейтинг, машина) по id. Телефонов здесь нет.
  Future<Map<String, Driver>> drivers() => _call(() async {
        final rows = await _db.from('driver_public').select('user_id,name,rating,rating_count,car,car_color,plate');
        return {
          for (final r in rows)
            r['user_id'] as String: Driver(
              name: r['name'] as String,
              rating: (r['rating'] as num).toDouble(),
              trips: (r['rating_count'] as num).toInt(),
              car: r['car'] as String,
              carColor: r['car_color'] as String,
              plate: r['plate'] as String,
              verified: true,
            ),
        };
      });

  /// Рейсы в продаже с отправлением в промежутке [fromUtc, toUtc).
  Future<List<Trip>> trips({
    required Map<String, RouteDef> routes,
    required Map<String, Driver> drivers,
    required DateTime fromUtc,
    required DateTime toUtc,
  }) =>
      _call(() async {
        final rows = await _db
            .from('trips')
            .select(_tripColumns)
            .eq('status', 'planned')
            .gte('departure', fromUtc.toUtc().toIso8601String())
            .lt('departure', toUtc.toUtc().toIso8601String())
            .order('departure', ascending: true);
        return [
          for (final r in rows)
            if (routes[r['route_id']] != null && drivers[r['driver_id']] != null) _trip(r, routes, drivers),
        ];
      });

  static Trip _trip(Map<String, dynamic> r, Map<String, RouteDef> routes, Map<String, Driver> drivers) {
    final seatRows = (r['trip_seats'] as List? ?? const []).cast<Map<String, dynamic>>();
    final seats = [
      for (final id in carSeatIds)
        for (final s in seatRows)
          if (s['seat_id'] == id)
            Seat(id: id, label: seatLabel(id), price: (s['price'] as num).toInt())
              ..taken = s['booking_id'] != null
              ..bookingId = s['booking_id'] as String?,
    ];
    GeoPoint? point(String lat, String lon) =>
        r[lat] == null ? null : GeoPoint((r[lat] as num).toDouble(), (r[lon] as num).toDouble());
    return Trip(
      id: r['id'] as String,
      route: routes[r['route_id']]!,
      departure: toYerevan(DateTime.parse(r['departure'] as String)),
      driver: drivers[r['driver_id']] ??
          const Driver(name: 'Водитель', rating: 5, trips: 0, car: 'Машина', carColor: '', plate: '', verified: false),
      seats: seats,
      meetAlong: (r['meet_along'] as num).toDouble(),
      dropAlong: (r['drop_along'] as num?)?.toDouble(),
      meetPoint: point('meet_lat', 'meet_lon'),
      dropPoint: point('drop_lat', 'drop_lon'),
    );
  }

  // ---------- карты ----------

  Future<List<CardInfo>> cards() => _call(() async {
        final rows = await _db.from('cards').select('id,brand,last4').isFilter('removed_at', null).order('created_at', ascending: true);
        return [for (final r in rows) CardInfo(id: r['id'] as String, brand: r['brand'] as String, last4: r['last4'] as String)];
      });

  /// Привязать карту. Пока банк не подключён — симуляция: в базе остаются только марка и 4 цифры.
  Future<String> bindCard(String number) =>
      _call(() async => await _db.rpc('bind_card_sim', params: {'p_number': number}) as String);

  Future<void> removeCard(String cardId) => _call(() => _db.rpc('remove_card', params: {'p_card': cardId}));

  // ---------- брони ----------

  /// Номер операции: повтор покупки с тем же номером не спишет деньги дважды.
  static String newOperationKey() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<BookResult> book({required String tripId, required List<String> seats, required String cardId, required String key}) =>
      _call(() async {
        final res = Map<String, dynamic>.from(await _db.rpc('book_seats',
            params: {'p_trip': tripId, 'p_seats': seats, 'p_card': cardId, 'p_idem': key}) as Map);
        return BookResult(
          bookingId: res['booking_id'] as String,
          paid: res['status'] == 'paid' || res['status'] == 'done',
          amount: (res['amount'] as num).toInt(),
          reason: res['reason'] as String?,
        );
      });

  /// Брони вошедшего пассажира (без неудачных попыток оплаты), новые сверху.
  Future<List<MyBooking>> myBookings({
    required Map<String, RouteInfo> routes,
    required Map<String, Driver> drivers,
  }) =>
      _call(() async {
        final me = userId;
        if (me == null) return <MyBooking>[];
        final rows = await _db
            .from('bookings')
            .select('id,trip_id,seat_ids,amount,status,refund,created_at,trips($_tripColumns)')
            .eq('passenger_id', me)
            .neq('status', 'failed')
            .order('created_at', ascending: false)
            .limit(100);
        final ratings = {
          for (final r in await _db.from('my_ratings').select('booking_id,rating')) r['booking_id'] as String: (r['rating'] as num).toInt(),
        };
        final defs = {for (final e in routes.entries) e.key: e.value.def};
        final out = <MyBooking>[];
        for (final r in rows) {
          final t = r['trips'] as Map<String, dynamic>?;
          final route = t == null ? null : routes[t['route_id']];
          if (t == null || route == null) continue;
          final trip = _trip(t, defs, drivers);
          final ids = (r['seat_ids'] as List).cast<String>();
          out.add(MyBooking(
            Booking(
              id: r['id'] as String,
              tripId: trip.id,
              routeId: route.def.id,
              pickAlong: trip.meetAlong,
              dropAlong: trip.dropAlong ?? route.lengthM.toDouble(),
              fromName: route.def.from.name,
              toName: route.def.to.name,
              seatIds: ids,
              seatLabels: ids.map(seatLabel).toList(),
              amount: (r['amount'] as num).toInt(),
              status: switch (r['status']) {
                'done' => BookingStatus.done,
                'cancelled' => BookingStatus.cancelled,
                _ => BookingStatus.paid,
              },
              refund: (r['refund'] as num).toInt(),
              rating: ratings[r['id']],
            ),
            trip,
            toYerevan(DateTime.parse(r['created_at'] as String)),
          ));
        }
        return out;
      });

  /// Отменить бронь. Возвращает, сколько вернётся на карту (0 — отмена без возврата).
  Future<int> cancel(String bookingId) => _call(() async {
        final res = Map<String, dynamic>.from(await _db.rpc('cancel_booking', params: {'p_booking': bookingId}) as Map);
        return (res['refund'] as num).toInt();
      });

  Future<void> rate(String bookingId, int stars) =>
      _call(() => _db.rpc('rate_booking', params: {'p_booking': bookingId, 'p_stars': stars}));
}
