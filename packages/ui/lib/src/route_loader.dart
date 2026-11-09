import 'dart:async';

import 'package:transport_core/transport_core.dart';
import 'package:yandex_maps_mapkit/directions.dart' as yd;
import 'package:yandex_maps_mapkit/mapkit.dart' as ym;
import 'package:yandex_maps_mapkit/runtime.dart' as yr;

import 'mapkit_setup.dart';

/// Строит линии маршрутов по дорогам через маршрутизатор Яндекса — с временем в пути и с пробками.
/// Без ключа MapKit или при ошибке берётся прямая линия между точками.
class RouteLoader {
  yd.DrivingRouter? _router;

  // Ссылки на сессии и слушателей держим, чтобы их не собрал сборщик мусора до ответа.
  final _sessions = <yd.DrivingSession>[];
  final _listeners = <yd.DrivingSessionRouteListener>[];

  Future<Map<String, RouteGeometry>> loadAll(List<RouteDef> routes) async {
    final out = <String, RouteGeometry>{};
    await Future.wait(routes.map((r) async => out[r.id] = await load(r)));
    return out;
  }

  Future<RouteGeometry> load(RouteDef r) {
    if (!hasMapkitKey) return Future.value(RouteGeometry.straight(r));
    _router ??= yd.DirectionsFactory.instance.createDrivingRouter(yd.DrivingRouterType.Combined);
    final done = Completer<RouteGeometry>();
    final listener = yd.DrivingSessionRouteListener(
      onDrivingRoutes: (routes) {
        if (done.isCompleted) return;
        if (routes.isEmpty) {
          done.complete(RouteGeometry.straight(r));
          return;
        }
        final route = routes.first;
        final points = route.geometry.points.map((p) => GeoPoint(p.latitude, p.longitude)).toList();
        final w = route.metadata.weight;
        done.complete(points.length < 2
            ? RouteGeometry.straight(r)
            : RouteGeometry(points, durationSec: w.time.value, trafficSec: w.timeWithTraffic.value, source: 'yandex'));
      },
      onDrivingRoutesError: (yr.Error error) {
        if (!done.isCompleted) done.complete(RouteGeometry.straight(r));
      },
    );
    _listeners.add(listener);
    _sessions.add(_router!.requestRoutes(
      const yd.DrivingOptions(routesCount: 1),
      const yd.DrivingVehicleOptions(),
      listener,
      points: [
        ym.RequestPoint(ym.Point(latitude: r.from.point.lat, longitude: r.from.point.lon), ym.RequestPointType.Waypoint, null, null, null),
        ym.RequestPoint(ym.Point(latitude: r.to.point.lat, longitude: r.to.point.lon), ym.RequestPointType.Waypoint, null, null, null),
      ],
    ));
    return done.future.timeout(const Duration(seconds: 15), onTimeout: () => RouteGeometry.straight(r));
  }
}
