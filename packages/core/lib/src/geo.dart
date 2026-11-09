/// Геометрия маршрута: длина, точка на линии, ближайшая точка к пассажиру.
library;

import 'dart:math' as math;

import 'models.dart';

double _rad(double x) => x * math.pi / 180;

/// Расстояние между точками по поверхности Земли, метры.
double distanceMeters(GeoPoint a, GeoPoint b) {
  final dLat = _rad(b.lat - a.lat), dLon = _rad(b.lon - a.lon);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * 6371000 * math.asin(math.sqrt(h));
}

/// Направление движения из точки a в точку b, градусы от севера по часовой стрелке.
double bearingDeg(GeoPoint a, GeoPoint b) {
  final y = math.sin(_rad(b.lon - a.lon)) * math.cos(_rad(b.lat));
  final x = math.cos(_rad(a.lat)) * math.sin(_rad(b.lat)) -
      math.sin(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.cos(_rad(b.lon - a.lon));
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Ближайшая к пассажиру позиция на маршруте.
class NearestPoint {
  const NearestPoint(this.distance, this.along);

  /// Сколько идти от пассажира до линии маршрута, метры.
  final double distance;

  /// Сколько проехать от начала маршрута до этой точки, метры.
  final double along;
}

/// Линия маршрута по дорогам с длительностью поездки.
class RouteGeometry {
  RouteGeometry(this.points, {required this.durationSec, this.trafficSec, this.source = 'line'})
      : assert(points.length >= 2) {
    _cum.add(0);
    for (var i = 1; i < points.length; i++) {
      _cum.add(_cum[i - 1] + distanceMeters(points[i - 1], points[i]));
    }
  }

  final List<GeoPoint> points;

  /// Время в пути без пробок, секунды.
  final double durationSec;

  /// Время в пути с учётом пробок, секунды (если известно).
  final double? trafficSec;

  /// Откуда взята линия: yandex, line.
  final String source;

  final List<double> _cum = [];

  double get length => _cum.last == 0 ? 1 : _cum.last;

  /// Скорость движения по маршруту, м/с (с учётом пробок, если они известны).
  double get speed => length / (trafficSec ?? durationSec);

  GeoPoint pointAt(double d) {
    if (d <= 0) return points.first;
    if (d >= length) return points.last;
    var i = 0;
    while (i < _cum.length - 2 && _cum[i + 1] < d) {
      i++;
    }
    final seg = _cum[i + 1] - _cum[i];
    final t = seg == 0 ? 0.0 : (d - _cum[i]) / seg;
    final a = points[i], b = points[i + 1];
    return GeoPoint(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t);
  }

  /// Часть маршрута между двумя расстояниями от начала.
  List<GeoPoint> subLine(double d1, double d2) {
    final out = <GeoPoint>[pointAt(d1)];
    for (var i = 0; i < points.length; i++) {
      if (_cum[i] > d1 && _cum[i] < d2) out.add(points[i]);
    }
    out.add(pointAt(d2));
    return out;
  }

  NearestPoint nearest(GeoPoint p) {
    final kx = 111320 * math.cos(_rad(p.lat)), ky = 110540.0;
    var best = const NearestPoint(double.infinity, 0);
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i], b = points[i + 1];
      final ax = (a.lon - p.lon) * kx, ay = (a.lat - p.lat) * ky;
      final bx = (b.lon - p.lon) * kx, by = (b.lat - p.lat) * ky;
      final dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
      final t = l2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / l2).clamp(0.0, 1.0);
      final x = ax + t * dx, y = ay + t * dy;
      final d = math.sqrt(x * x + y * y);
      if (d < best.distance) best = NearestPoint(d, _cum[i] + t * (_cum[i + 1] - _cum[i]));
    }
    return best;
  }

  /// Прямая линия между начальной и конечной точками — запасной вариант, пока нет линии по дорогам.
  factory RouteGeometry.straight(RouteDef r) => RouteGeometry(
        [r.from.point, r.to.point],
        durationSec: r.minutes * 60.0,
      );
}

/// Подходящий маршрут для пассажира.
class RouteMatch {
  const RouteMatch(this.route, this.geometry, this.pick, this.drop);
  final RouteDef route;
  final RouteGeometry geometry;
  final NearestPoint pick;
  final NearestPoint? drop;

  double get score => pick.distance + (drop?.distance ?? 0);
  double get dropAlong => drop?.along ?? geometry.length;
}

/// Маршруты, которые начинаются или проходят рядом с «откуда» (и с «куда», если оно указано).
/// Отсортированы: самый подходящий первый.
List<RouteMatch> matchRoutes({
  required Map<String, RouteGeometry> geometries,
  required List<RouteDef> routes,
  required GeoPoint from,
  GeoPoint? to,
  double nearMeters = 1500,
}) {
  final res = <RouteMatch>[];
  for (final r in routes) {
    final g = geometries[r.id];
    if (g == null) continue;
    final pick = g.nearest(from);
    if (pick.distance > nearMeters || pick.along > g.length - 300) continue;
    NearestPoint? drop;
    if (to != null) {
      drop = g.nearest(to);
      if (drop.distance > nearMeters || drop.along < pick.along + 300) continue;
    }
    res.add(RouteMatch(r, g, pick, drop));
  }
  res.sort((a, b) => a.score.compareTo(b.score));
  return res;
}
