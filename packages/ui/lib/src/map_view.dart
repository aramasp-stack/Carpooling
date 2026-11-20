import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:transport_core/transport_core.dart';
import 'package:yandex_maps_mapkit/image.dart' as yi;
import 'package:yandex_maps_mapkit/mapkit.dart' as ym;
import 'package:yandex_maps_mapkit/mapkit_factory.dart';
import 'package:yandex_maps_mapkit/yandex_map.dart';

import 'mapkit_setup.dart';
import 'theme.dart';

/// Маршрут на карте.
class MapRoute {
  const MapRoute(this.route, this.geometry, {this.dimmed = false});
  final RouteDef route;
  final RouteGeometry geometry;
  final bool dimmed;
}

/// Виды меток.
enum MarkerKind { from, to, pickup, pickupSelected, start, finish, passenger, me }

class _Marker {
  const _Marker(this.point, this.kind, this.hint);
  final GeoPoint point;
  final MarkerKind kind;
  final String? hint;
}

/// Управление картой из экранов: маршруты, выделенный отрезок, метки, машина, камера.
class TransportMapController {
  _TransportMapState? _state;

  List<MapRoute> _routes = const [];
  List<GeoPoint>? _segment;
  Color _segmentColor = AppColors.text;
  final Map<String, _Marker> _markers = {};
  GeoPoint? _car;
  Color _carColor = AppColors.passenger;
  double _carDirection = 0;

  void showRoutes(List<MapRoute> routes) {
    _routes = routes;
    _state?._renderRoutes();
  }

  void setSegment(List<GeoPoint>? points, {Color color = AppColors.text}) {
    _segment = points;
    _segmentColor = color;
    _state?._renderRoutes();
  }

  List<GeoPoint>? _segment2;
  Color _segment2Color = AppColors.text;

  /// Второй выделенный отрезок (например, конечный район маршрута рядом с начальным).
  void setSecondSegment(List<GeoPoint>? points, {Color color = AppColors.text}) {
    _segment2 = points;
    _segment2Color = color;
    _state?._renderRoutes();
  }

  List<List<GeoPoint>> _rings = const [];
  Color _ringColor = AppColors.text;

  /// Границы районов (замкнутые линии) — например, круги, где водитель может отметить место посадки и высадки.
  void setRings(List<List<GeoPoint>> rings, {Color color = AppColors.text}) {
    _rings = rings;
    _ringColor = color;
    _state?._renderRoutes();
  }

  void setMarker(String key, GeoPoint? point, MarkerKind kind, {String? hint}) {
    if (point == null) {
      _markers.remove(key);
    } else {
      _markers[key] = _Marker(point, kind, hint);
    }
    _state?._renderMarkers();
  }

  void clearMarkers() {
    _markers.clear();
    _state?._renderMarkers();
  }

  /// Машина на карте (null — убрать). Направление — в градусах от севера.
  void setCar(GeoPoint? point, {Color color = AppColors.passenger, double direction = 0}) {
    _car = point;
    _carColor = color;
    _carDirection = direction;
    _state?._renderCar();
  }

  /// Показать все точки, с учётом нижней панели, которая закрывает часть карты.
  void fit(List<GeoPoint> points) => _state?._fit(points);

  List<GeoPoint>? _startView;

  /// Показать окрестности точки (примерно [meters] в каждую сторону) в видимой части карты.
  /// Если карта ещё не создана, она откроется сразу на этом месте.
  void showAround(GeoPoint p, {double meters = 700}) {
    final dLat = meters / 111000, dLon = meters / (111000 * math.cos(p.lat * math.pi / 180));
    final box = [GeoPoint(p.lat - dLat, p.lon - dLon), GeoPoint(p.lat + dLat, p.lon + dLon)];
    if (_state?._window != null) {
      _state!._fit(box);
    } else {
      _startView = box;
    }
  }

  void clearAll() {
    _routes = const [];
    _segment = null;
    _segment2 = null;
    _rings = const [];
    _markers.clear();
    _car = null;
    _state?._renderRoutes();
    _state?._renderMarkers();
    _state?._renderCar();
  }
}

/// Яндекс Карта с пробками. Без ключа MapKit показывает заглушку.
class TransportMap extends StatefulWidget {
  const TransportMap({super.key, required this.controller, this.onTap, this.bottomCover = 0.55});
  final TransportMapController controller;
  final ValueChanged<GeoPoint>? onTap;

  /// Какую долю высоты карты закрывает нижняя панель (учитывается при показе маршрута).
  final double bottomCover;

  @override
  State<TransportMap> createState() => _TransportMapState();
}

class _TransportMapState extends State<TransportMap> implements ym.MapInputListener {
  ym.MapWindow? _window;
  // Слой пробок держим в поле, иначе его соберёт сборщик мусора и пробки пропадут.
  // ignore: unused_field
  ym.TrafficLayer? _traffic;
  ym.MapObjectCollection? _routesLayer;
  ym.MapObjectCollection? _markersLayer;
  ym.PlacemarkMapObject? _carMark;

  // Пульсирующий круг под меткой «я здесь».
  ym.PlacemarkMapObject? _meHalo;
  Timer? _pulse;
  late final AppLifecycleListener _lifecycle;
  bool _active = false;
  final Map<String, yi.ImageProvider> _icons = {};

  TransportMapController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c._state = this;
    if (hasMapkitKey) {
      _start();
      _lifecycle = AppLifecycleListener(onResume: _start, onInactive: _stop);
    }
  }

  @override
  void didUpdateWidget(TransportMap old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller._state = null;
      c._state = this;
    }
  }

  @override
  void dispose() {
    _pulse?.cancel();
    if (c._state == this) c._state = null;
    if (hasMapkitKey) {
      _window?.map.removeInputListener(this);
      _stop();
      _lifecycle.dispose();
    }
    super.dispose();
  }

  void _start() {
    if (_active) return;
    _active = true;
    mapkit.onStart();
  }

  void _stop() {
    if (!_active) return;
    _active = false;
    mapkit.onStop();
  }

  @override
  Widget build(BuildContext context) {
    if (!hasMapkitKey) return const _NoKeyPlaceholder();
    return YandexMap(onMapCreated: _onMapCreated, platformViewType: PlatformViewType.Hybrid);
  }

  void _onMapCreated(ym.MapWindow window) {
    _window = window;
    final map = window.map;
    map.move(ym.CameraPosition(_pt(Demo.yerevanCenter), zoom: 12, azimuth: 0, tilt: 0));
    map.addInputListener(this);
    map.logo.setAlignment(const ym.LogoAlignment(ym.LogoHorizontalAlignment.Left, ym.LogoVerticalAlignment.Top));
    _traffic = mapkit.createTrafficLayer(window)..setTrafficVisible(true);
    _routesLayer = map.mapObjects.addCollection();
    _markersLayer = map.mapObjects.addCollection();
    _renderRoutes();
    _renderMarkers();
    _renderCar();
    // Место, заданное заранее (например, где находится пассажир), иначе Ереван целиком над нижней панелью.
    _fit(c._startView ?? const [GeoPoint(40.12, 44.43), GeoPoint(40.23, 44.60)]);
  }

  // ---------- отрисовка ----------
  static ym.Point _pt(GeoPoint p) => ym.Point(latitude: p.lat, longitude: p.lon);

  void _renderRoutes() {
    final layer = _routesLayer;
    if (layer == null) return;
    layer.clear();
    for (final r in c._routes) {
      layer.addPolylineWithGeometry(ym.Polyline(r.geometry.points.map(_pt).toList()))
        ..setStrokeColor(Color(r.route.color).withValues(alpha: r.dimmed ? 0.25 : 0.95))
        ..style = const ym.LineStyle(strokeWidth: 5, outlineColor: Colors.white, outlineWidth: 1.5)
        ..zIndex = r.dimmed ? 5 : 10;
    }
    for (final ring in c._rings) {
      if (ring.length < 2) continue;
      layer.addPolylineWithGeometry(ym.Polyline(ring.map(_pt).toList()))
        ..setStrokeColor(c._ringColor.withValues(alpha: 0.85))
        ..style = const ym.LineStyle(strokeWidth: 3, outlineColor: Colors.white, outlineWidth: 1, dashLength: 8, gapLength: 6)
        ..zIndex = 15;
    }
    for (final (seg, color) in [(c._segment, c._segmentColor), (c._segment2, c._segment2Color)]) {
      if (seg == null || seg.length < 2) continue;
      layer.addPolylineWithGeometry(ym.Polyline(seg.map(_pt).toList()))
        ..setStrokeColor(color)
        ..style = const ym.LineStyle(strokeWidth: 7, outlineColor: Colors.white, outlineWidth: 2)
        ..zIndex = 20;
    }
  }

  void _renderMarkers() {
    final layer = _markersLayer;
    if (layer == null) return;
    layer.clear();
    _meHalo = null;
    for (final m in c._markers.values) {
      if (m.kind == MarkerKind.me) {
        // «Я здесь»: пульсирующий круг и капля, остриём ровно в точке.
        _meHalo = layer.addPlacemark()
          ..geometry = _pt(m.point)
          ..setIcon(_icons.putIfAbsent('me-halo', () => yi.ImageProvider(_drawHalo, id: 'me-halo')))
          ..setIconStyle(const ym.IconStyle(scale: 0.5, zIndex: 29));
        layer.addPlacemark()
          ..geometry = _pt(m.point)
          ..setIcon(_iconFor(m.kind))
          ..setIconStyle(const ym.IconStyle(anchor: math.Point(0.5, 1.0), zIndex: 35));
        continue;
      }
      layer.addPlacemark()
        ..geometry = _pt(m.point)
        ..setIcon(_iconFor(m.kind))
        ..setIconStyle(const ym.IconStyle(scale: 1, zIndex: 30));
    }
    _syncPulse();
  }

  /// Круг расходится от метки и тает — раз в 1,6 секунды, пока метка «я здесь» на карте.
  void _syncPulse() {
    if (_meHalo == null) {
      _pulse?.cancel();
      _pulse = null;
      return;
    }
    _pulse ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
      final halo = _meHalo;
      if (halo == null || !mounted) return;
      final t = (DateTime.now().millisecondsSinceEpoch % 1600) / 1600;
      halo
        ..setIconStyle(ym.IconStyle(scale: 0.35 + 1.0 * t, zIndex: 29))
        ..opacity = (1 - t) * 0.85;
    });
  }

  void _renderCar() {
    final layer = _markersLayer;
    if (layer == null) return;
    final p = c._car;
    if (p == null) {
      if (_carMark != null) {
        layer.remove(_carMark!);
        _carMark = null;
      }
      return;
    }
    _carMark ??= layer.addPlacemark()
        ..setIcon(_carIcon(c._carColor))
        ..setIconStyle(const ym.IconStyle(rotationType: ym.RotationType.Rotate, zIndex: 40, flat: true));
    _carMark!
      ..geometry = _pt(p)
      ..direction = c._carDirection;
  }

  void _fit(List<GeoPoint> points) {
    final window = _window;
    if (window == null || points.isEmpty) return;
    var minLat = points.first.lat, maxLat = minLat, minLon = points.first.lon, maxLon = minLon;
    for (final p in points) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    final w = window.width().toDouble(), h = window.height().toDouble();
    final pad = w * 0.08;
    final rect = ym.ScreenRect(
      ym.ScreenPoint(x: pad, y: pad * 1.5),
      ym.ScreenPoint(x: w - pad, y: math.max(pad * 3, h * (1 - widget.bottomCover) - pad)),
    );
    var pos = window.map.cameraPositionForGeometry(
      ym.Geometry.fromBoundingBox(ym.BoundingBox(
        ym.Point(latitude: minLat, longitude: minLon),
        ym.Point(latitude: maxLat, longitude: maxLon),
      )),
      focusRect: rect,
    );
    if (pos.zoom > 16) pos = ym.CameraPosition(pos.target, zoom: 16, azimuth: 0, tilt: 0);
    window.map.move(pos, animation: const ym.Animation(type: ym.AnimationType.Smooth, duration: 0.4));
  }

  // ---------- нажатия на карту ----------
  @override
  void onMapTap(ym.Map map, ym.Point point) => widget.onTap?.call(GeoPoint(point.latitude, point.longitude));

  @override
  void onMapLongTap(ym.Map map, ym.Point point) => widget.onTap?.call(GeoPoint(point.latitude, point.longitude));

  // ---------- значки ----------
  yi.ImageProvider _iconFor(MarkerKind kind) {
    if (kind == MarkerKind.me) {
      return _icons.putIfAbsent('me', () => yi.ImageProvider(_drawMe, id: 'me'));
    }
    if (kind == MarkerKind.pickupSelected) {
      // Выбранное место посадки: крупнее и темнее остальных.
      return _icons.putIfAbsent(
          'meet-selected', () => yi.ImageProvider(() => _drawDot(const Color(0xFF1E3A8A), Colors.white, size: 44), id: 'meet-selected'));
    }
    final (fill, ring) = switch (kind) {
      MarkerKind.from => (AppColors.from, Colors.white),
      MarkerKind.to => (AppColors.to, Colors.white),
      MarkerKind.pickup => (const Color(0xFF2563EB), Colors.white),
      MarkerKind.start => (AppColors.from, Colors.white),
      MarkerKind.finish => (AppColors.to, Colors.white),
      MarkerKind.passenger => (const Color(0xFF2563EB), Colors.white),
      MarkerKind.me => (const Color(0xFF0EA5E9), Colors.white),
      MarkerKind.pickupSelected => (const Color(0xFF1E3A8A), Colors.white),
    };
    return _icons.putIfAbsent('dot-${kind.name}', () => yi.ImageProvider(() => _drawDot(fill, ring), id: 'dot-${kind.name}'));
  }

  yi.ImageProvider _carIcon(Color color) =>
      _icons.putIfAbsent('car-${color.toARGB32()}', () => yi.ImageProvider(() => _drawCar(color), id: 'car-${color.toARGB32()}'));

  double get _dpr => View.of(context).devicePixelRatio;

  Future<ui.Image> _drawDot(Color fill, Color ring, {double size = 30}) {
    final s = size * _dpr;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final center = Offset(s / 2, s / 2);
    canvas.drawCircle(center, s / 2 - 1, Paint()..color = Colors.black.withValues(alpha: 0.18));
    canvas.drawCircle(center, s / 2 - 3 * _dpr, Paint()..color = ring);
    canvas.drawCircle(center, s / 2 - 7 * _dpr, Paint()..color = fill);
    return rec.endRecording().toImage(s.ceil(), s.ceil());
  }

  static const _meBlue = Color(0xFF1E88E5);

  /// «Я здесь»: капля с белой точкой внутри; острие — там, где пассажир (якорь внизу по центру).
  Future<ui.Image> _drawMe() {
    final d = _dpr;
    final w = 38 * d, h = 52 * d;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final r = w / 2 - 3 * d; // радиус «головы» капли
    final c = Offset(w / 2, r + 3 * d);
    final tip = Offset(w / 2, h - 1.5 * d);
    // Капля: круг и два касательных отрезка к острию.
    final a = math.asin(r / (tip.dy - c.dy));
    final drop = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(c.dx - r * math.cos(a), c.dy + r * math.sin(a))
      ..arcTo(Rect.fromCircle(center: c, radius: r), math.pi - a, math.pi + 2 * a, false)
      ..close();
    canvas.drawPath(drop.shift(Offset(0, 1.5 * d)), Paint()
      ..color = Colors.black.withValues(alpha: 0.25)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 * d));
    canvas.drawPath(drop, Paint()..color = _meBlue);
    canvas.drawPath(drop, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * d);
    canvas.drawCircle(c, r * 0.42, Paint()..color = Colors.white);
    return rec.endRecording().toImage(w.ceil(), h.ceil());
  }

  /// Круг под каплей; его размер и прозрачность меняет таймер — получается пульсация.
  Future<ui.Image> _drawHalo() {
    final s = 96 * _dpr;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final center = Offset(s / 2, s / 2);
    canvas.drawCircle(center, s / 2, Paint()..color = _meBlue.withValues(alpha: 0.30));
    canvas.drawCircle(center, s / 2 - 1.5 * _dpr, Paint()
      ..color = _meBlue.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * _dpr);
    return rec.endRecording().toImage(s.ceil(), s.ceil());
  }

  Future<ui.Image> _drawCar(Color color) {
    final s = 40 * _dpr;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final center = Offset(s / 2, s / 2);
    canvas.drawCircle(center, s / 2 - 1, Paint()..color = Colors.black.withValues(alpha: 0.2));
    canvas.drawCircle(center, s / 2 - 3 * _dpr, Paint()..color = Colors.white);
    canvas.drawCircle(center, s / 2 - 6 * _dpr, Paint()..color = color);
    final arrow = Path()
      ..moveTo(s / 2, s * 0.26)
      ..lineTo(s * 0.68, s * 0.68)
      ..lineTo(s / 2, s * 0.58)
      ..lineTo(s * 0.32, s * 0.68)
      ..close();
    canvas.drawPath(arrow, Paint()..color = Colors.white);
    return rec.endRecording().toImage(s.ceil(), s.ceil());
  }
}

class _NoKeyPlaceholder extends StatelessWidget {
  const _NoKeyPlaceholder();
  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFFE8ECF3),
        alignment: Alignment.topCenter,
        padding: EdgeInsets.fromLTRB(24, MediaQuery.paddingOf(context).top + 40, 24, 0),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 40, color: AppColors.muted),
            SizedBox(height: 8),
            Text('Здесь будет Яндекс Карта', style: TextStyle(fontWeight: FontWeight.w600)),
            SizedBox(height: 4),
            Text(
              'Нужен ключ «MapKit – мобильный SDK». Без него приложение работает, но карта не показывается, а маршруты считаются по прямой.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ],
        ),
      );
}
