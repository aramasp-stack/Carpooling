/// Модели данных. Координаты — широта и долгота.
library;

class GeoPoint {
  const GeoPoint(this.lat, this.lon);
  final double lat;
  final double lon;

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon};
  factory GeoPoint.fromJson(Map<String, dynamic> j) =>
      GeoPoint((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble());

  @override
  bool operator ==(Object other) => other is GeoPoint && other.lat == lat && other.lon == lon;
  @override
  int get hashCode => Object.hash(lat, lon);
  @override
  String toString() => 'GeoPoint($lat, $lon)';
}

/// Место на карте с названием (точка маршрута, адрес, выбранная пользователем точка).
class Place {
  const Place(this.name, this.point);
  final String name;
  final GeoPoint point;

  Map<String, dynamic> toJson() => {'name': name, 'point': point.toJson()};
  factory Place.fromJson(Map<String, dynamic> j) =>
      Place(j['name'] as String, GeoPoint.fromJson(j['point'] as Map<String, dynamic>));
}

/// Маршрут: только начальная и конечная точки, без промежуточных остановок.
class RouteDef {
  const RouteDef({
    required this.id,
    required this.color,
    required this.price,
    required this.minutes,
    required this.from,
    required this.to,
  });
  final String id;

  /// Цвет линии маршрута в формате 0xAARRGGBB.
  final int color;

  /// Базовая цена места, драм.
  final int price;

  /// Время в пути по расписанию, минуты (без учёта пробок).
  final int minutes;
  final Place from;
  final Place to;

  String get title => '${from.name} → ${to.name}';
}

class Driver {
  const Driver({
    required this.name,
    required this.rating,
    required this.trips,
    required this.car,
    required this.carColor,
    required this.plate,
    required this.verified,
  });
  final String name;
  final double rating;
  final int trips;
  final String car;
  final String carColor;
  final String plate;
  final bool verified;
}

/// Место в салоне. У каждого места своя цена.
class Seat {
  Seat({required this.id, required this.label, required this.price});
  final String id; // front, rl, rm, rr
  final String label;
  final int price;
  bool taken = false;
  String? bookingId;
  String? passenger;

  Seat copy() => Seat(id: id, label: label, price: price);
  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'price': price};
  factory Seat.fromJson(Map<String, dynamic> j) =>
      Seat(id: j['id'] as String, label: j['label'] as String, price: (j['price'] as num).toInt());
}

/// Рейс: конкретная поездка водителя по маршруту в конкретное время.
class Trip {
  Trip({
    required this.id,
    required this.route,
    required this.departure,
    required this.driver,
    required this.seats,
    this.custom = false,
  });
  final String id;
  final RouteDef route;
  final DateTime departure;
  final Driver driver;
  final List<Seat> seats;

  /// Рейс создан водителем в приложении (а не взят из демо-расписания).
  final bool custom;

  List<Seat> get freeSeats => seats.where((s) => !s.taken).toList();
  int get freeCount => freeSeats.length;
  int? get minPrice => freeSeats.isEmpty ? null : freeSeats.map((s) => s.price).reduce((a, b) => a < b ? a : b);
  int get paidTotal => seats.where((s) => s.taken).fold(0, (sum, s) => sum + s.price);
}

/// Рейс, созданный водителем в приложении водителя.
class CustomTrip {
  CustomTrip({
    required this.id,
    required this.routeId,
    required this.date,
    required this.time,
    required this.driverIndex,
    required this.seats,
  });
  final String id;
  final String routeId;
  final String date; // ГГГГ-ММ-ДД
  final String time; // ЧЧ:ММ
  final int driverIndex;
  final List<Seat> seats;

  Map<String, dynamic> toJson() => {
        'id': id,
        'routeId': routeId,
        'date': date,
        'time': time,
        'driverIndex': driverIndex,
        'seats': seats.map((s) => s.toJson()).toList(),
      };
  factory CustomTrip.fromJson(Map<String, dynamic> j) => CustomTrip(
        id: j['id'] as String,
        routeId: j['routeId'] as String,
        date: j['date'] as String,
        time: j['time'] as String,
        driverIndex: (j['driverIndex'] as num?)?.toInt() ?? 0,
        seats: (j['seats'] as List).map((e) => Seat.fromJson(e as Map<String, dynamic>)).toList(),
      );
}

enum BookingStatus { paid, done, cancelled }

/// Бронь пассажира: конкретные места в конкретном рейсе.
class Booking {
  Booking({
    required this.id,
    required this.tripId,
    required this.routeId,
    required this.pickAlong,
    required this.dropAlong,
    required this.fromName,
    required this.toName,
    required this.seatIds,
    required this.seatLabels,
    required this.amount,
    this.status = BookingStatus.paid,
    this.refund = 0,
    this.rating,
  });
  final String id;
  final String tripId;
  final String routeId;

  /// Где пассажир садится и выходит: метры от начала маршрута.
  final double pickAlong;
  final double dropAlong;
  final String fromName;
  final String toName;
  final List<String> seatIds;
  final List<String> seatLabels;
  final int amount;
  BookingStatus status;
  int refund;
  int? rating;

  Map<String, dynamic> toJson() => {
        'id': id,
        'tripId': tripId,
        'routeId': routeId,
        'pickAlong': pickAlong,
        'dropAlong': dropAlong,
        'fromName': fromName,
        'toName': toName,
        'seatIds': seatIds,
        'seatLabels': seatLabels,
        'amount': amount,
        'status': status.name,
        'refund': refund,
        'rating': rating,
      };
  factory Booking.fromJson(Map<String, dynamic> j) => Booking(
        id: j['id'] as String,
        tripId: j['tripId'] as String,
        routeId: j['routeId'] as String,
        pickAlong: (j['pickAlong'] as num).toDouble(),
        dropAlong: (j['dropAlong'] as num).toDouble(),
        fromName: j['fromName'] as String,
        toName: j['toName'] as String,
        seatIds: (j['seatIds'] as List).cast<String>(),
        seatLabels: (j['seatLabels'] as List).cast<String>(),
        amount: (j['amount'] as num).toInt(),
        status: BookingStatus.values.byName(j['status'] as String),
        refund: (j['refund'] as num?)?.toInt() ?? 0,
        rating: (j['rating'] as num?)?.toInt(),
      );
}

/// Отметка водителя о пассажире.
enum Boarding { boarded, noShow }

/// Состояние рейса для водителя.
enum TripStatus { planned, started, finished }
