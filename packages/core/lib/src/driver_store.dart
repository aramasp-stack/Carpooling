/// Данные водителя в приложении: анкета, документы, карта для выплат, блокировки, оценки, заявки на маршруты.
/// Правила те же, что на сервере (supabase/migrations/…_driver.sql); пока сервер не подключён,
/// данные лежат на телефоне, а проверку анкеты можно «пройти» демо-кнопкой.
library;

import 'dart:convert';

import 'schedule.dart';
import 'store.dart';

/// Отказ: код как у сервера (BAD_CARD_NUMBER, DOCUMENTS_MISSING, …).
class DriverError implements Exception {
  const DriverError(this.code);
  final String code;
  @override
  String toString() => 'DriverError($code)';
}

enum ApplicationStatus { none, pending, approved, rejected }

/// Документы, без которых анкету не одобрят.
const driverDocuments = <String, String>{
  'id_document': 'Паспорт или ID-карта',
  'license': 'Водительские права',
  'registration': 'Техпаспорт машины',
  'car_photo': 'Машина, номер виден',
  'selfie': 'Селфи с паспортом в руке',
};

class DriverApplication {
  DriverApplication({
    this.status = ApplicationStatus.none,
    this.car = '',
    this.carColor = '',
    this.plate = '',
    Set<String>? seatIds,
    this.taxId = '',
    Set<String>? docs,
    this.rejectReason,
  })  : seatIds = seatIds ?? carSeatIds.toSet(),
        docs = docs ?? {};

  ApplicationStatus status;
  String car;
  String carColor;
  String plate;

  /// Пассажирские места машины, которые водитель вообще продаёт: front, rl, rr.
  /// В каждом рейсе он выставляет все или часть из них.
  Set<String> seatIds;
  int get seats => seatIds.length;
  String taxId;
  final Set<String> docs;
  String? rejectReason;

  bool get carFilled => car.trim().isNotEmpty && carColor.trim().isNotEmpty && plate.trim().isNotEmpty && taxId.trim().isNotEmpty;
  bool get docsComplete => driverDocuments.keys.every(docs.contains);

  Map<String, dynamic> toJson() => {
        'status': status.name,
        'car': car,
        'carColor': carColor,
        'plate': plate,
        'seatIds': [for (final id in carSeatIds) if (seatIds.contains(id)) id],
        'taxId': taxId,
        'docs': docs.toList(),
        'rejectReason': rejectReason,
      };

  factory DriverApplication.fromJson(Map<String, dynamic> j) => DriverApplication(
        status: ApplicationStatus.values.byName(j['status'] as String? ?? 'none'),
        car: j['car'] as String? ?? '',
        carColor: j['carColor'] as String? ?? '',
        plate: j['plate'] as String? ?? '',
        // Старые анкеты хранили только число мест (3 или 4) — это все три места легковой машины.
        seatIds: (j['seatIds'] as List?)?.cast<String>().where(carSeatIds.contains).toSet(),
        taxId: j['taxId'] as String? ?? '',
        docs: ((j['docs'] as List?) ?? const []).cast<String>().toSet(),
        rejectReason: j['rejectReason'] as String?,
      );
}

/// Карта для выплат: в приложении только платёжная система и последние 4 цифры.
class PayoutCard {
  const PayoutCard({required this.brand, required this.last4, required this.holder, required this.activeFrom});
  final String brand;
  final String last4;
  final String holder;

  /// С этого момента на карту идут выплаты (новая карта вместо старой — через 24 часа).
  final DateTime activeFrom;

  Map<String, dynamic> toJson() => {'brand': brand, 'last4': last4, 'holder': holder, 'activeFrom': activeFrom.toIso8601String()};
  factory PayoutCard.fromJson(Map<String, dynamic> j) => PayoutCard(
        brand: j['brand'] as String,
        last4: j['last4'] as String,
        holder: j['holder'] as String,
        activeFrom: DateTime.parse(j['activeFrom'] as String),
      );
}

class RouteRequest {
  RouteRequest({required this.id, required this.from, required this.to, this.comment, this.status = 'pending', this.reason, required this.at});
  final String id;
  final String from;
  final String to;
  final String? comment;
  String status; // pending, accepted, rejected
  String? reason;
  final DateTime at;

  Map<String, dynamic> toJson() =>
      {'id': id, 'from': from, 'to': to, 'comment': comment, 'status': status, 'reason': reason, 'at': at.toIso8601String()};
  factory RouteRequest.fromJson(Map<String, dynamic> j) => RouteRequest(
        id: j['id'] as String,
        from: j['from'] as String,
        to: j['to'] as String,
        comment: j['comment'] as String?,
        status: j['status'] as String? ?? 'pending',
        reason: j['reason'] as String?,
        at: DateTime.parse(j['at'] as String),
      );
}

class DriverStore {
  DriverStore(this.kv, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final KeyValueStore kv;
  final DateTime Function() _clock;
  DateTime get now => _clock();

  static const _key = 'driver.v1';
  static const maxOpenRequests = 5;

  Map<String, dynamic> _all() {
    final s = kv.read(_key);
    return s == null ? {} : Map<String, dynamic>.from(jsonDecode(s) as Map);
  }

  Future<void> _put(String field, Object? value) {
    final all = _all();
    all[field] = value;
    return kv.write(_key, jsonEncode(all));
  }

  // ---------- вход ----------
  String? get phone => _all()['phone'] as String?;

  /// Вход по номеру и коду из SMS. В модели SMS не отправляется: подходит любой код из 4 цифр.
  Future<void> signIn(String phone, String code) async {
    final p = phone.replaceAll(RegExp(r'[\s\-()]'), '');
    if (!RegExp(r'^\+?[0-9]{8,15}$').hasMatch(p)) throw const DriverError('BAD_PHONE');
    if (!RegExp(r'^[0-9]{4}$').hasMatch(code.trim())) throw const DriverError('BAD_CODE');
    await _put('phone', p);
  }

  // ---------- анкета ----------
  DriverApplication get application {
    final j = _all()['application'];
    return j == null ? DriverApplication() : DriverApplication.fromJson(Map<String, dynamic>.from(j as Map));
  }

  Future<void> saveApplication(DriverApplication a) => _put('application', a.toJson());

  /// Документ загружен (в рабочей версии — фото уходит в закрытое хранилище).
  Future<void> setDocument(String kind) async {
    final a = application;
    if (!driverDocuments.containsKey(kind)) throw const DriverError('BAD_DOCUMENT_KIND');
    if (a.status == ApplicationStatus.approved) throw const DriverError('DRIVER_ALREADY_APPROVED');
    a.docs.add(kind);
    await saveApplication(a);
  }

  /// Отправить анкету на проверку.
  Future<void> submit() async {
    final a = application;
    if (!a.carFilled) throw const DriverError('BAD_ARGUMENT');
    if (a.seatIds.isEmpty || !a.seatIds.every(carSeatIds.contains)) throw const DriverError('BAD_SEATS_TOTAL');
    if (!a.docsComplete) throw const DriverError('DOCUMENTS_MISSING');
    a
      ..status = ApplicationStatus.pending
      ..rejectReason = null;
    await saveApplication(a);
  }

  /// Решение проверяющего. В модели его можно принять демо-кнопкой, пока нет веб-панели.
  Future<void> review({required bool approve, String? reason}) async {
    final a = application;
    if (a.status != ApplicationStatus.pending) throw const DriverError('NOT_PENDING');
    if (approve && !a.docsComplete) throw const DriverError('DOCUMENTS_MISSING');
    if (!approve && (reason == null || reason.trim().isEmpty)) throw const DriverError('REASON_REQUIRED');
    a
      ..status = approve ? ApplicationStatus.approved : ApplicationStatus.rejected
      ..rejectReason = approve ? null : reason!.trim();
    await saveApplication(a);
  }

  bool get approved => application.status == ApplicationStatus.approved;

  // ---------- карта для выплат ----------
  PayoutCard? get payoutCard {
    final j = _all()['payoutCard'];
    return j == null ? null : PayoutCard.fromJson(Map<String, dynamic>.from(j as Map));
  }

  /// Привязать карту. Нужен свежий код из SMS ([smsCode], в модели — любые 4 цифры).
  /// Первая карта действует сразу, новая вместо старой — через 24 часа.
  Future<PayoutCard> setPayoutCard({required String number, required String holder, required String smsCode}) async {
    final n = number.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^[0-9]{16}$').hasMatch(n)) throw const DriverError('BAD_CARD_NUMBER');
    final h = holder.trim().toUpperCase();
    if (h.length < 2 || h.length > 60) throw const DriverError('BAD_HOLDER_NAME');
    if (!RegExp(r'^[0-9]{4}$').hasMatch(smsCode.trim())) throw const DriverError('REAUTH_REQUIRED');
    final had = payoutCard != null;
    final card = PayoutCard(
      brand: switch (n[0]) { '4' => 'Visa', '5' => 'Mastercard', '9' => 'ArCa', _ => 'Карта' },
      last4: n.substring(12),
      holder: h,
      activeFrom: had ? now.add(const Duration(hours: 24)) : now,
    );
    await _put('payoutCard', card.toJson());
    return card;
  }

  // ---------- блокировка пассажиров ----------
  Map<String, DateTime> get blocked => {
        for (final e in ((_all()['blocked'] as Map?) ?? const {}).entries) e.key as String: DateTime.parse(e.value as String),
      };

  bool isBlocked(String passenger) => blocked.containsKey(passenger);

  Future<void> block(String passenger) => _put('blocked', {
        for (final e in blocked.entries) e.key: e.value.toIso8601String(),
        passenger: (blocked[passenger] ?? now).toIso8601String(),
      });

  Future<void> unblock(String passenger) => _put('blocked', {
        for (final e in blocked.entries)
          if (e.key != passenger) e.key: e.value.toIso8601String(),
      });

  // ---------- оценки пассажиров ----------
  Map<String, int> get ratings => {
        for (final e in ((_all()['ratings'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt(),
      };

  /// Оценка пассажира за место в рейсе: один раз.
  Future<void> rate(String tripId, String seatId, int stars) async {
    if (stars < 1 || stars > 5) throw const DriverError('BAD_RATING');
    final key = '$tripId|$seatId';
    final all = ratings;
    if (all.containsKey(key)) throw const DriverError('ALREADY_RATED');
    all[key] = stars;
    await _put('ratings', all);
  }

  int? ratingOf(String tripId, String seatId) => ratings['$tripId|$seatId'];

  // ---------- заявки на маршруты ----------
  List<RouteRequest> get routeRequests => [
        for (final j in ((_all()['routeRequests'] as List?) ?? const [])) RouteRequest.fromJson(Map<String, dynamic>.from(j as Map)),
      ];

  Future<RouteRequest> requestRoute({required String from, required String to, String? comment}) async {
    final f = from.trim(), t = to.trim(), c = comment?.trim();
    if (f.length < 2 || f.length > 100 || t.length < 2 || t.length > 100 || (c != null && c.length > 500)) {
      throw const DriverError('BAD_ARGUMENT');
    }
    final list = routeRequests;
    if (list.where((r) => r.status == 'pending').length >= maxOpenRequests) throw const DriverError('TOO_MANY_REQUESTS');
    final r = RouteRequest(id: 'rr${now.microsecondsSinceEpoch}', from: f, to: t, comment: (c == null || c.isEmpty) ? null : c, at: now);
    await _put('routeRequests', [r, ...list].map((x) => x.toJson()).toList());
    return r;
  }

  // ---------- демо-продажи ----------
  /// Места, «купленные» демо-пассажирами: рейс → место → имя. Только для модели, пока приложения не связаны сервером.
  Map<String, Map<String, String>> get demoSales => {
        for (final e in ((_all()['demoSales'] as Map?) ?? const {}).entries)
          e.key as String: Map<String, String>.from(e.value as Map),
      };

  Future<void> sellDemo(String tripId, Map<String, String> seats) {
    final all = demoSales;
    all[tripId] = {...?all[tripId], ...seats};
    return _put('demoSales', all);
  }

  // ---------- отменённые рейсы ----------
  Set<String> get cancelledTrips => ((_all()['cancelled'] as List?) ?? const []).cast<String>().toSet();

  /// Рейс отменён: запоминаем это и забываем демо-продажи (пассажирам — полный возврат).
  Future<void> cancelTrip(String tripId) async {
    await _put('cancelled', {...cancelledTrips, tripId}.toList());
    await _put('demoSales', demoSales..remove(tripId));
  }

  /// Начать заново (демо): забыть всё о водителе.
  Future<void> reset() => kv.write(_key, jsonEncode({}));
}

/// Понятный текст отказа для водителя.
String driverErrorText(String code) => switch (code) {
      'BAD_PHONE' => 'Проверьте номер телефона.',
      'BAD_CODE' => 'Код из SMS — 4 цифры.',
      'BAD_ARGUMENT' => 'Заполните все поля.',
      'BAD_SEATS_TOTAL' => 'Отметьте хотя бы одно место для пассажиров.',
      'DOCUMENTS_MISSING' => 'Загрузите все пять документов.',
      'DRIVER_ALREADY_APPROVED' => 'Анкета уже одобрена: документы меняются через новую анкету.',
      'BAD_CARD_NUMBER' => 'Номер карты — 16 цифр.',
      'BAD_HOLDER_NAME' => 'Укажите имя владельца карты, как на карте.',
      'REAUTH_REQUIRED' => 'Подтвердите кодом из SMS.',
      'BAD_RATING' => 'Оценка — от 1 до 5.',
      'ALREADY_RATED' => 'Вы уже оценили этого пассажира.',
      'TOO_MANY_REQUESTS' => 'У вас уже 5 заявок на рассмотрении. Дождитесь ответа модератора.',
      'PRICE_BELOW_MINIMUM' => 'Цена ниже минимальной для этого маршрута.',
      'BAD_PRICE' => 'Цена места — не больше трёх базовых цен маршрута.',
      'REASON_REQUIRED' => 'Укажите причину.',
      _ => 'Не получилось. Попробуйте ещё раз.',
    };
