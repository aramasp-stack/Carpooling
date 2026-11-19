import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:transport_core/transport_core.dart';
import 'package:transport_ui/transport_ui.dart';

part 'panels/search_panel.dart';
part 'panels/car_panel.dart';
part 'panels/ticket_panel.dart';
part 'panels/track_panel.dart';
part 'panels/mine_panel.dart';

const _accent = AppColors.passenger;

enum HomeTab { search, mine }

/// Что сейчас показано в панели.
sealed class Pane {}

class SearchPane extends Pane {}

class CarPane extends Pane {
  CarPane(this.match, this.trip);
  final RouteMatch match;
  final Trip trip;
}

class TicketPane extends Pane {
  TicketPane(this.bookingId);
  final String bookingId;
}

class TrackPane extends Pane {
  TrackPane(this.trip, this.bookingId);
  final Trip trip;
  final String? bookingId;
}

class MinePane extends Pane {}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.data});
  final DataStore data;

  @override
  State<HomeScreen> createState() => HomeState();
}

class HomeState extends State<HomeScreen> {
  final map = TransportMapController();
  final sheet = DraggableScrollableController();
  final loader = RouteLoader();
  late final trips = TripService(widget.data);
  DataStore get data => widget.data;

  Map<String, RouteGeometry> geoms = {};
  bool loading = true;

  /// Где сейчас пассажир (если телефон разрешил определить и он в Ереване).
  GeoPoint? myPos;

  // Поиск
  Place? from;
  Place? to;
  String? routeId; // маршрут, выбранный из списка, когда указано только «откуда»
  int day = 0;
  int? hour; // час отправления; null — любой
  double? meetFilter; // выбранное на карте место посадки (метры от начала маршрута); null — все
  String? pick; // 'from' | 'to' — ждём нажатия на карту
  final fromCtl = TextEditingController();
  final toCtl = TextEditingController();
  String? suggestFor; // 'from' | 'to'
  String suggestQuery = ''; // что введено в поле, для которого открыт список
  List<Place> suggestions = [];

  // Навигация по панели
  HomeTab tab = HomeTab.search;
  List<Pane> stack = [SearchPane()];
  Pane get pane => stack.last;

  // Симуляция движения машины
  Timer? simTimer;
  double simPos = 0;
  double simFactor = 10;
  bool simBoarded = false;
  bool simDone = false;

  @override
  void initState() {
    super.initState();
    // Карта открывается там, где пассажир; если это неизвестно — на площади Республики.
    map.showAround(Demo.republicSquare.point);
    _locateOnStart();
    loader.loadAll(Demo.routes).then((g) {
      if (!mounted) return;
      setState(() {
        geoms = g;
        loading = false;
      });
      syncMap();
    });
  }

  @override
  void dispose() {
    simTimer?.cancel();
    sheet.dispose();
    fromCtl.dispose();
    toCtl.dispose();
    super.dispose();
  }

  void update(VoidCallback f) {
    if (mounted) setState(f);
  }

  // ---------- навигация ----------
  void push(Pane p) {
    stopSim();
    update(() => stack.add(p));
    syncMap();
  }

  void pop() {
    stopSim();
    if (stack.length > 1) update(() => stack.removeLast());
    syncMap();
  }

  void goTab(HomeTab t, {Pane? open}) {
    stopSim();
    update(() {
      tab = t;
      pick = null;
      stack = [
        switch (t) {
          HomeTab.search => SearchPane(),
          HomeTab.mine => MinePane(),
        },
        ?open,
      ];
    });
    syncMap();
  }

  // ---------- поиск ----------
  /// Маршруты, на которые можно сесть отсюда: только те, что начинаются рядом с «откуда».
  /// Маршрут, который здесь лишь проходит, не подходит: по пути водитель никого не подбирает.
  List<RouteMatch> get matches => _matchesTo(to?.point);

  /// Все направления из «откуда» — без учёта «куда» (для списка под полем «Куда»).
  List<RouteMatch> get routesFromHere => _matchesTo(null);

  List<RouteMatch> _matchesTo(GeoPoint? toPoint) => from == null
      ? const []
      : matchRoutes(geometries: geoms, routes: Demo.routes, from: from!.point, to: toPoint, nearMeters: Demo.nearMeters)
          .where((m) => meetWalk(m) <= meetLimit)
          .toList();

  /// Выбрать пункт назначения из списка под полем «Куда».
  void pickDestination(RouteDef r) {
    setPlace('to', null);
    chooseRoute(r.id);
  }

  /// Сколько идти от «откуда» до ближайшего места посадки на маршруте (по рейсам на 3 дня), метры.
  double meetWalk(RouteMatch m) {
    final alongs = {
      for (var d = 0; d < 3; d++)
        for (final t in trips.tripsFor(m.route, d)) t.meetAlong,
    };
    var best = double.infinity;
    for (final a in alongs) {
      final d = distanceMeters(from!.point, m.geometry.pointAt(a));
      if (d < best) best = d;
    }
    return best;
  }

  RouteMatch? activeOf(List<RouteMatch> m) {
    if (to != null) return m.isEmpty ? null : m.first;
    if (routeId == null) return null;
    for (final x in m) {
      if (x.route.id == routeId) return x;
    }
    return null;
  }

  /// «Откуда» выбрано точкой на карте — тогда места посадки ищем ближе (500 м вместо 1 км).
  bool fromOnMap = false;

  /// Насколько далеко от «откуда» может быть место посадки, метры.
  double get meetLimit => fromOnMap ? Demo.meetWalkMapPointMeters : Demo.meetWalkMeters;

  /// Тот же радиус словами: «500 м» или «1 км».
  String get meetLimitText => meetLimit >= 1000 ? '${(meetLimit / 1000).round()} км' : '${meetLimit.round()} м';

  void setPlace(String which, Place? p, {bool onMap = false}) {
    update(() {
      if (which == 'from') {
        from = p;
        fromOnMap = onMap && p != null;
        fromCtl.text = p?.name ?? '';
      } else {
        to = p;
        toCtl.text = p?.name ?? '';
      }
      routeId = null;
      hour = null;
      meetFilter = null;
      // В «Куда» могло стоять название маршрута, выбранного раньше; без выбора оно лишнее.
      if (to == null) toCtl.text = '';
      suggestions = [];
      suggestFor = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    syncMap();
  }

  /// Выбрать маршрут из найденных (из списка или касанием линии на карте).
  void chooseRoute(String id) {
    update(() {
      routeId = id;
      hour = null;
      meetFilter = null;
      if (to == null) toCtl.text = Demo.routeById(id)?.to.name ?? '';
    });
    syncMap();
  }

  /// Вернуться ко всем направлениям из «откуда».
  void clearRoute() {
    update(() {
      routeId = null;
      hour = null;
      meetFilter = null;
      if (to == null) toCtl.text = '';
    });
    syncMap();
  }

  void setDay(int d) {
    update(() {
      day = d;
      hour = null;
      meetFilter = null;
    });
    syncMap(refit: false);
  }

  void setHour(int? h) {
    update(() => hour = h);
    syncMap(refit: false);
  }

  /// Оставить рейсы только от выбранного места посадки (null — все места).
  void setMeet(double? along) {
    update(() => meetFilter = along);
    syncMap(refit: false);
  }

  /// Где водитель ждёт пассажиров.
  GeoPoint meetPoint(Trip t, RouteGeometry g) => g.pointAt(t.meetAlong);

  /// Сколько идти от «откуда» до места посадки, метры.
  double walkTo(Trip t, RouteGeometry g) => from == null ? 0 : distanceMeters(from!.point, meetPoint(t, g));

  /// Рейсы маршрута на выбранный день и час — до выбора места посадки.
  List<({Trip trip, DateTime at})> tripsOfHour(RouteMatch m) {
    final all = driversFor(m);
    return hour == null ? all : all.where((x) => x.at.hour == hour).toList();
  }

  /// Рейсы в списке: выбранные день, час и место посадки.
  List<({Trip trip, DateTime at})> visibleTrips(RouteMatch m) {
    final list = tripsOfHour(m);
    return meetFilter == null ? list : list.where((x) => x.trip.meetAlong == meetFilter).toList();
  }

  /// Касание синей точки выбирает это место посадки; повторное касание — снова все места.
  void _tapMeet(GeoPoint p, RouteMatch m) {
    double? best;
    var bestDist = _meetTapMeters;
    for (final along in {for (final x in tripsOfHour(m)) x.trip.meetAlong}) {
      final d = distanceMeters(p, m.geometry.pointAt(along));
      if (d < bestDist) {
        best = along;
        bestDist = d;
      }
    }
    if (best != null) setMeet(best == meetFilter ? null : best);
  }

  static const _meetTapMeters = 180.0;

  /// Закрыть список мест под полем «Откуда» / «Куда».
  void closeSuggest() {
    update(() {
      suggestFor = null;
      suggestions = [];
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// Выбор точки на карте: панель опускается, чтобы карта была видна.
  void startPick(String which) {
    closeSuggest();
    update(() => pick = which);
    _sheetTo(0.22);
  }

  void cancelPick() {
    update(() => pick = null);
    _sheetTo(MapSheetScaffold.initialSize);
  }

  void _sheetTo(double size) {
    if (sheet.isAttached) sheet.animateTo(size, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  void onMapTap(GeoPoint p) {
    final which = pick;
    if (which == null) {
      if (suggestFor != null) {
        closeSuggest();
        return;
      }
      final active = pane is SearchPane && from != null ? activeOf(matches) : null;
      if (active != null) {
        _tapMeet(p, active);
      } else {
        _tapRoute(p);
      }
      return;
    }
    update(() => pick = null);
    setPlace(which, Place('Точка на карте', p), onMap: true);
    _sheetTo(MapSheetScaffold.initialSize);
  }

  /// Касание линии маршрута на карте выбирает этот маршрут, когда показаны все маршруты рядом.
  void _tapRoute(GeoPoint p) {
    if (pane is! SearchPane || from == null || to != null || routeId != null) return;
    RouteMatch? best;
    var bestDist = _routeTapMeters;
    for (final m in matches) {
      final d = m.geometry.nearest(p).distance;
      if (d < bestDist) {
        best = m;
        bestDist = d;
      }
    }
    if (best != null) chooseRoute(best.route.id);
  }

  static const _routeTapMeters = 400.0;

  /// Последние маршруты пассажира (по его броням), не больше трёх.
  List<RouteDef> get recentRoutes {
    final out = <RouteDef>[];
    for (final b in data.bookings()) {
      final r = Demo.routeById(b.routeId);
      if (r != null && !out.any((x) => x.id == r.id)) out.add(r);
      if (out.length == 3) break;
    }
    return out;
  }

  /// Поиск по недавнему маршруту: «откуда» — начало маршрута, сразу список рейсов на нём.
  void repeatRoute(RouteDef r) {
    setPlace('to', null);
    setPlace('from', r.from);
    chooseRoute(r.id);
  }

  /// Местоположение телефона; null — нет разрешения или не удалось определить.
  Future<GeoPoint?> _position() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
      final pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 12));
      return GeoPoint(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  static bool _inYerevan(GeoPoint p) => distanceMeters(p, Demo.yerevanCenter) <= 40000;

  /// При открытии: карта по центру на пассажире и метка «я здесь».
  Future<void> _locateOnStart() async {
    final p = await _position();
    if (p == null || !_inYerevan(p) || !mounted) return;
    update(() => myPos = p);
    if (from == null && pane is SearchPane) map.showAround(p);
    syncMap();
  }

  /// «Поехать отсюда»: «откуда» — там, где сейчас пассажир.
  Future<void> locateMe() async {
    // Местоположение уже известно с открытия приложения — сразу, без ожидания.
    final known = myPos;
    if (known != null) {
      if (pane is! SearchPane) goTab(HomeTab.search);
      setPlace('from', Place('Я здесь', known));
      return;
    }
    toast(context, 'Определяем местоположение…');
    final p = await _position();
    if (!mounted) return;
    if (p == null) {
      toast(context, 'Местоположение недоступно: включите геоданные или выберите точку на карте.');
      return;
    }
    if (!_inYerevan(p)) {
      toast(context, 'Вы далеко от Еревана — маршрутов рядом не будет. Выберите точку на карте.');
      return;
    }
    update(() => myPos = p);
    if (pane is! SearchPane) goTab(HomeTab.search);
    setPlace('from', Place('Я здесь', p));
  }

  List<({Trip trip, DateTime at})> driversFor(RouteMatch m) {
    final now = trips.now;
    return [
      for (final t in trips.tripsFor(m.route, day)) (trip: t, at: t.departure),
    ].where((x) => x.at.isAfter(now.add(const Duration(minutes: 5)))).toList();
  }

  Booking? bookingById(String id) {
    for (final b in data.bookings()) {
      if (b.id == id) return b;
    }
    return null;
  }

  // ---------- карта ----------
  /// Перерисовать карту. [refit] — заново подобрать камеру (иначе остаётся приближение пассажира).
  void syncMap({bool refit = true}) {
    map.clearAll();
    if (myPos != null) map.setMarker('me', myPos, MarkerKind.me);
    final p = pane;
    switch (p) {
      case SearchPane():
        if (from != null) map.setMarker('from', from!.point, MarkerKind.from);
        if (to != null) map.setMarker('to', to!.point, MarkerKind.to);
        if (from == null || geoms.isEmpty) return;
        final m = matches;
        final active = activeOf(m);
        if (active != null) {
          map.showRoutes([MapRoute(active.route, active.geometry)]);
          // Места посадки рейсов выбранного дня и часа; выбранное — крупнее и темнее.
          final g = active.geometry;
          final meets = {for (final x in tripsOfHour(active)) x.trip.meetAlong};
          for (final a in meets) {
            map.setMarker('meet-$a', g.pointAt(a), a == meetFilter ? MarkerKind.pickupSelected : MarkerKind.pickup);
          }
          // Камера — на начальный район: там места посадки, из них пассажир и выбирает.
          if (refit) map.fit([from!.point, for (final a in meets) g.pointAt(a), g.pointAt(Demo.startDistrictMeters)]);
        } else {
          map.showRoutes([for (final x in m) MapRoute(x.route, x.geometry)]);
          if (refit) {
            if (m.isEmpty && to == null) {
              map.showAround(from!.point); // маршрутов нет — показать саму точку и окрестности
            } else {
              map.fit([from!.point, if (to != null) to!.point, for (final x in m) ...x.geometry.points]);
            }
          }
        }
      case CarPane(:final match, :final trip):
        final g = match.geometry;
        final meet = meetPoint(trip, g);
        map.showRoutes([MapRoute(match.route, g)]);
        map.setSegment(g.subLine(trip.meetAlong, g.length), color: Color(match.route.color));
        map.setMarker('pickup', meet, MarkerKind.pickup);
        if (from != null) map.setMarker('from', from!.point, MarkerKind.from);
        // Камера — на место посадки и путь до него: это главное при выборе водителя.
        map.fit([meet, if (from != null) from!.point, g.pointAt(trip.meetAlong + 600)]);
      case TicketPane(:final bookingId):
        final b = bookingById(bookingId);
        final g = b == null ? null : geoms[b.routeId];
        final r = b == null ? null : Demo.routeById(b.routeId);
        if (b == null || g == null || r == null) return;
        map.showRoutes([MapRoute(r, g)]);
        map.setSegment(g.subLine(b.pickAlong, b.dropAlong), color: Color(r.color));
        map.setMarker('pickup', g.pointAt(b.pickAlong), MarkerKind.pickup);
        map.fit(g.points);
      case TrackPane(:final trip, :final bookingId):
        final g = geoms[trip.route.id];
        if (g == null) return;
        map.showRoutes([MapRoute(trip.route, g)]);
        final b = bookingId == null ? null : bookingById(bookingId);
        if (b != null) {
          map.setSegment(g.subLine(b.pickAlong, b.dropAlong), color: Color(trip.route.color));
          map.setMarker('pickup', g.pointAt(b.pickAlong), MarkerKind.pickup);
        }
        map.fit(g.points);
      case MinePane():
        break;
    }
  }

  // ---------- симуляция ----------
  void startSim(Trip trip, String? bookingId) {
    stopSim();
    final g = geoms[trip.route.id];
    if (g == null) return;
    simPos = trip.meetAlong; // машина выезжает от места посадки
    simFactor = 10;
    simBoarded = false;
    simDone = false;
    push(TrackPane(trip, bookingId));
    var last = DateTime.now();
    simTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = DateTime.now();
      final dt = (now.difference(last).inMilliseconds / 1000).clamp(0, 0.25);
      last = now;
      final prev = simPos;
      simPos = (simPos + g.speed * dt * simFactor).clamp(0, g.length);
      final p = g.pointAt(simPos);
      map.setCar(p, color: Color(trip.route.color), direction: bearingDeg(g.pointAt(prev), g.pointAt(simPos + 15)));
      final b = bookingId == null ? null : bookingById(bookingId);
      if (b != null && !simBoarded && simPos >= b.pickAlong - 10) {
        simBoarded = true;
        if (mounted) toast(context, 'Водитель отметил: вы сели (демо).');
      }
      if (simPos >= g.length) {
        simTimer?.cancel();
        simDone = true;
        if (b != null && b.status == BookingStatus.paid) {
          b.status = BookingStatus.done;
          data.updateBooking(b);
          if (mounted) toast(context, 'Поездка завершена. Оцените водителя.');
        }
      }
      update(() {});
    });
  }

  void stopSim() {
    simTimer?.cancel();
    simTimer = null;
    map.setCar(null);
  }

  // ---------- экран ----------
  Widget _panel() => switch (pane) {
        SearchPane() => searchPanel(),
        CarPane(:final match, :final trip) => CarPanel(home: this, match: match, trip: trip),
        TicketPane(:final bookingId) => ticketPanel(bookingId),
        TrackPane(:final trip, :final bookingId) => trackPanel(trip, bookingId),
        MinePane() => minePanel(),
      };

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: stack.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) pop();
      },
      child: MapSheetScaffold(
        map: Stack(children: [
          Positioned.fill(child: TransportMap(controller: map, onTap: onMapTap, bottomCover: MapSheetScaffold.initialSize)),
          // «Поехать отсюда»: одно нажатие — и «откуда» там, где пассажир.
          Positioned(
            top: MediaQuery.paddingOf(context).top + 52,
            right: 14,
            child: FloatingActionButton.small(
              heroTag: 'me',
              tooltip: 'Поехать отсюда',
              backgroundColor: Colors.white,
              foregroundColor: _accent,
              onPressed: locateMe,
              child: const Icon(Icons.my_location),
            ),
          ),
        ]),
        sheetController: sheet,
        panel: _panel(),
        bottomBar: NavigationBar(
          selectedIndex: tab.index,
          onDestinationSelected: (i) => goTab(HomeTab.values[i]),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.search), label: 'Поиск'),
            NavigationDestination(icon: Icon(Icons.confirmation_number_outlined), label: 'Мои поездки'),
          ],
        ),
      ),
    );
  }
}
