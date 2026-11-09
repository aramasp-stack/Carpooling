/// Хранение данных приложения: брони, созданные водителем рейсы, отметки о посадке, состояние рейсов.
/// Сейчас данные лежат на телефоне (через [KeyValueStore]); на этапе MVP их заменит сервер (Supabase).
library;

import 'dart:convert';

import 'models.dart';

/// Простое хранилище «ключ — строка». В приложениях его реализует SharedPreferences.
abstract class KeyValueStore {
  String? read(String key);
  Future<void> write(String key, String value);
}

/// Хранилище в памяти — для тестов.
class MemoryStore implements KeyValueStore {
  final _m = <String, String>{};
  @override
  String? read(String key) => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
}

class DataStore {
  DataStore(this.kv);
  final KeyValueStore kv;

  static const _bookings = 'bookings.v1';
  static const _custom = 'customTrips.v1';
  static const _boarding = 'boarding.v1';
  static const _tripState = 'tripState.v1';

  List<dynamic> _list(String key) {
    final s = kv.read(key);
    return s == null ? [] : jsonDecode(s) as List<dynamic>;
  }

  Map<String, dynamic> _map(String key) {
    final s = kv.read(key);
    return s == null ? {} : jsonDecode(s) as Map<String, dynamic>;
  }

  // ---------- брони ----------
  List<Booking> bookings() => _list(_bookings).map((e) => Booking.fromJson(e as Map<String, dynamic>)).toList();

  Future<void> _saveBookings(List<Booking> list) => kv.write(_bookings, jsonEncode(list.map((b) => b.toJson()).toList()));

  Future<void> addBooking(Booking b) => _saveBookings([b, ...bookings()]);

  Future<void> updateBooking(Booking b) {
    final list = bookings();
    final i = list.indexWhere((x) => x.id == b.id);
    if (i >= 0) list[i] = b;
    return _saveBookings(list);
  }

  // ---------- рейсы, созданные водителем ----------
  List<CustomTrip> customTrips() =>
      _list(_custom).map((e) => CustomTrip.fromJson(e as Map<String, dynamic>)).toList();

  Future<void> addCustomTrip(CustomTrip t) =>
      kv.write(_custom, jsonEncode([...customTrips(), t].map((x) => x.toJson()).toList()));

  // ---------- отметки водителя «сел / не пришёл» ----------
  Map<String, Boarding> boarding(String tripId) {
    final m = (_map(_boarding)[tripId] as Map<String, dynamic>?) ?? {};
    return m.map((k, v) => MapEntry(k, Boarding.values.byName(v as String)));
  }

  Future<void> setBoarding(String tripId, String seatId, Boarding? value) {
    final all = _map(_boarding);
    final m = Map<String, dynamic>.from((all[tripId] as Map<String, dynamic>?) ?? {});
    if (value == null || m[seatId] == value.name) {
      m.remove(seatId);
    } else {
      m[seatId] = value.name;
    }
    all[tripId] = m;
    return kv.write(_boarding, jsonEncode(all));
  }

  // ---------- состояние рейса ----------
  TripStatus? tripStatus(String tripId) {
    final v = _map(_tripState)[tripId] as String?;
    return v == null ? null : TripStatus.values.byName(v);
  }

  Future<void> setTripStatus(String tripId, TripStatus status) {
    final all = _map(_tripState);
    all[tripId] = status.name;
    return kv.write(_tripState, jsonEncode(all));
  }
}
