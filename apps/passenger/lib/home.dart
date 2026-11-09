import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:transport_core/transport_core.dart';
import 'package:transport_ui/transport_ui.dart';

part 'panels/search_panel.dart';
part 'panels/car_panel.dart';
part 'panels/ticket_panel.dart';
part 'panels/track_panel.dart';
part 'panels/routes_panel.dart';
part 'panels/mine_panel.dart';

const _accent = AppColors.passenger;

enum HomeTab { search, routes, mine }

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

class RoutesPane extends Pane {}

class MinePane extends Pane {}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.data});
  final DataStore data;

  @override
  State<HomeScreen> createState() => HomeState();
}

class HomeState extends State<HomeScreen> {
  final map = TransportMapController();
  final loader = RouteLoader();
  late final trips = TripService(widget.data);
  DataStore get data => widget.data;

  Map<String, RouteGeometry> geoms = {};
  bool loading = true;

  // Поиск
  Place? from;
  Place? to;
  String? routeId; // маршрут, выбранный из списка, когда указано только «откуда»
  int day = 0;
  String? pick; // 'from' | 'to' — ждём нажатия на карту
  final fromCtl = TextEditingController();
  final toCtl = TextEditingController();
  String? suggestFor; // 'from' | 'to'
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
          HomeTab.routes => RoutesPane(),
          HomeTab.mine => MinePane(),
        },
        ?open,
      ];
    });
    syncMap();
  }

  // ---------- поиск ----------
  List<RouteMatch> get matches => from == null
      ? const []
      : matchRoutes(geometries: geoms, routes: Demo.routes, from: from!.point, to: to?.point, nearMeters: Demo.nearMeters);

  RouteMatch? activeOf(List<RouteMatch> m) {
    if (to != null) return m.isEmpty ? null : m.first;
    if (routeId == null) return null;
    for (final x in m) {
      if (x.route.id == routeId) return x;
    }
    return null;
  }

  void setPlace(String which, Place? p) {
    update(() {
      if (which == 'from') {
        from = p;
        fromCtl.text = p?.name ?? '';
      } else {
        to = p;
        toCtl.text = p?.name ?? '';
      }
      routeId = null;
      suggestions = [];
      suggestFor = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    syncMap();
  }

  void onMapTap(GeoPoint p) {
    final which = pick;
    if (which == null) return;
    update(() => pick = null);
    setPlace(which, Place('Точка на карте', p));
  }

  Future<void> locateMe() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (mounted) toast(context, 'Нет доступа к местоположению. Выберите точку на карте.');
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      final p = GeoPoint(pos.latitude, pos.longitude);
      if (distanceMeters(p, Demo.yerevanCenter) > 40000 && mounted) {
        toast(context, 'Вы далеко от Еревана — маршрутов рядом не будет. Выберите точку на карте.');
      }
      setPlace('from', Place('Моё местоположение', p));
    } catch (_) {
      if (mounted) toast(context, 'Не удалось определить местоположение. Выберите точку на карте.');
    }
  }

  List<({Trip trip, DateTime at})> driversFor(RouteMatch m) {
    final now = trips.now;
    return [
      for (final t in trips.tripsFor(m.route, day))
        (trip: t, at: trips.timeAt(t, m.pick.along, m.geometry)),
    ].where((x) => x.at.isAfter(now.add(const Duration(minutes: 5)))).toList();
  }

  Booking? bookingById(String id) {
    for (final b in data.bookings()) {
      if (b.id == id) return b;
    }
    return null;
  }

  // ---------- карта ----------
  void syncMap() {
    map.clearAll();
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
          map.setSegment(active.geometry.subLine(active.pick.along, active.dropAlong), color: Color(active.route.color));
          map.setMarker('pickup', active.geometry.pointAt(active.pick.along), MarkerKind.pickup);
          map.fit([...active.geometry.points, from!.point, if (to != null) to!.point]);
        } else {
          map.showRoutes([for (final x in m) MapRoute(x.route, x.geometry)]);
          map.fit([from!.point, if (to != null) to!.point, for (final x in m) ...x.geometry.points]);
        }
      case CarPane(:final match):
        final seg = match.geometry.subLine(match.pick.along, match.dropAlong);
        map.showRoutes([MapRoute(match.route, match.geometry)]);
        map.setSegment(seg, color: Color(match.route.color));
        map.setMarker('pickup', match.geometry.pointAt(match.pick.along), MarkerKind.pickup);
        if (from != null) map.setMarker('from', from!.point, MarkerKind.from);
        map.fit([...seg, if (from != null) from!.point]);
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
      case RoutesPane():
        map.showRoutes([for (final r in Demo.routes) if (geoms[r.id] != null) MapRoute(r, geoms[r.id]!)]);
        for (final r in Demo.routes) {
          map.setMarker('s-${r.from.name}', r.from.point, MarkerKind.start);
          map.setMarker('f-${r.to.name}', r.to.point, MarkerKind.finish);
        }
        map.fit([for (final g in geoms.values) ...g.points]);
      case MinePane():
        break;
    }
  }

  // ---------- симуляция ----------
  void startSim(Trip trip, String? bookingId) {
    stopSim();
    final g = geoms[trip.route.id];
    if (g == null) return;
    simPos = 0;
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
        RoutesPane() => routesPanel(),
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
        map: TransportMap(controller: map, onTap: onMapTap, bottomCover: MapSheetScaffold.initialSize),
        panel: _panel(),
        bottomBar: NavigationBar(
          selectedIndex: tab.index,
          onDestinationSelected: (i) => goTab(HomeTab.values[i]),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.search), label: 'Поиск'),
            NavigationDestination(icon: Icon(Icons.alt_route), label: 'Маршруты'),
            NavigationDestination(icon: Icon(Icons.confirmation_number_outlined), label: 'Мои поездки'),
          ],
        ),
      ),
    );
  }
}
