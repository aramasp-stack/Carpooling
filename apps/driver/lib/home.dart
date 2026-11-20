import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:transport_core/transport_core.dart';
import 'package:transport_ui/transport_ui.dart';
import 'package:url_launcher/url_launcher.dart';

part 'panels/onboarding.dart';
part 'panels/trips.dart';
part 'panels/route_pick.dart';
part 'panels/new_trip.dart';
part 'panels/trip.dart';
part 'panels/money.dart';
part 'panels/profile.dart';

const _accent = AppColors.driver;

/// Демо-водитель: его рейсы есть в демо-расписании.
final _demo = Demo.drivers[Demo.meIndex];

enum DriverTab { routes, trips, money, profile }

/// Что сейчас показано в панели.
sealed class Pane {}

/// «Мои рейсы»: только рейсы, которые водитель поставил сам.
class TripsPane extends Pane {}

/// Главный экран: поиск маршрута («Откуда» / «Куда»).
class RoutePickPane extends Pane {}

/// Новый рейс, шаг 2: день, время, место посадки, места и цены. [template] — «Повторить» прошлый рейс.
class NewTripPane extends Pane {
  NewTripPane(this.route, {this.template});
  final RouteDef route;
  final Trip? template;
}

class RouteRequestPane extends Pane {}

class TripPane extends Pane {
  TripPane(this.tripId);
  final String tripId;
}

class DrivePane extends Pane {
  DrivePane(this.tripId);
  final String tripId;
}

class MoneyPane extends Pane {}

class ProfilePane extends Pane {}

class DriverHome extends StatefulWidget {
  const DriverHome({super.key, required this.data, required this.driver});
  final DataStore data;
  final DriverStore driver;

  @override
  State<DriverHome> createState() => DriverHomeState();
}

class DriverHomeState extends State<DriverHome> {
  final map = TransportMapController();
  final loader = RouteLoader();
  late final trips = TripService(widget.data);
  DataStore get data => widget.data;
  DriverStore get me => widget.driver;
  Map<String, RouteGeometry> geoms = {};

  DriverTab tab = DriverTab.routes;
  List<Pane> stack = [RoutePickPane()];
  Pane get pane => stack.last;
  int day = 0;

  // Поиск маршрута: «откуда» и «куда»
  final fromCtl = TextEditingController();
  final toCtl = TextEditingController();
  Place? from;
  Place? to;

  /// Чей список подсказок открыт: 'from', 'to' или никакой.
  String? suggestFor;
  String suggestQuery = '';

  /// Какую точку выбирают касанием карты: 'from', 'to' или никакую.
  String? pickFor;
  bool showAllRoutes = false;

  // Анкета
  final carCtl = TextEditingController();
  final colorCtl = TextEditingController();
  final plateCtl = TextEditingController();
  final taxCtl = TextEditingController();
  final phoneCtl = TextEditingController(text: '+374 ');
  final codeCtl = TextEditingController();
  bool codeSent = false;
  bool offerAccepted = false;

  /// Касание карты на экране нового рейса: место посадки.
  ValueChanged<GeoPoint>? onMapTapHandler;

  // Поездка (симуляция)
  Timer? simTimer;
  double simPos = 0;
  double simFactor = 10;
  bool atMeet = false;

  @override
  void initState() {
    super.initState();
    final a = me.application;
    carCtl.text = a.car.isEmpty ? _demo.car : a.car;
    colorCtl.text = a.carColor.isEmpty ? _demo.carColor : a.carColor;
    plateCtl.text = a.plate.isEmpty ? _demo.plate : a.plate;
    taxCtl.text = a.taxId;
    offerAccepted = a.status != ApplicationStatus.none;
    loader.loadAll(Demo.routes).then((g) {
      if (!mounted) return;
      setState(() => geoms = g);
      syncMap();
    });
  }

  @override
  void dispose() {
    simTimer?.cancel();
    for (final c in [fromCtl, toCtl, carCtl, colorCtl, plateCtl, taxCtl, phoneCtl, codeCtl]) {
      c.dispose();
    }
    super.dispose();
  }

  void update(VoidCallback f) {
    if (mounted) setState(f);
  }

  void push(Pane p) {
    stopSim();
    onMapTapHandler = null;
    update(() => stack.add(p));
    syncMap();
  }

  void pop() {
    stopSim();
    onMapTapHandler = null;
    if (stack.length > 1) update(() => stack.removeLast());
    syncMap();
  }

  void goTab(DriverTab t, {Pane? open}) {
    stopSim();
    onMapTapHandler = null;
    update(() {
      tab = t;
      stack = [
        switch (t) {
          DriverTab.routes => RoutePickPane(),
          DriverTab.trips => TripsPane(),
          DriverTab.money => MoneyPane(),
          DriverTab.profile => ProfilePane(),
        },
        ?open,
      ];
    });
    syncMap();
  }

  /// Отказ правил — понятным текстом.
  void showError(Object e) => toast(context, e is DriverError ? driverErrorText(e.code) : 'Не получилось. Попробуйте ещё раз.');

  // ---------- данные ----------
  RouteGeometry geoOf(RouteDef r) => geoms[r.id] ?? RouteGeometry.straight(r);

  /// Водитель, как его видят пассажиры: машина из анкеты.
  Driver get meAsDriver {
    final a = me.application;
    return Driver(
      name: _demo.name,
      rating: _demo.rating,
      trips: _demo.trips,
      car: a.car.isEmpty ? _demo.car : a.car,
      carColor: a.carColor.isEmpty ? _demo.carColor : a.carColor,
      plate: a.plate.isEmpty ? _demo.plate : a.plate,
      verified: me.approved,
    );
  }

  /// Рейсы водителя на день: только те, что он сам поставил в приложении, без отменённых.
  /// (Демо-расписание для приложения пассажира водителю не показываем: это чужие рейсы.)
  List<Trip> myTrips(int dayOffset) {
    final cancelled = me.cancelledTrips;
    return trips
        .driverTrips(_demo, dayOffset)
        .where((t) => t.custom && !cancelled.contains(t.id))
        .map(_withDemoSales)
        .toList();
  }

  Trip? tripOf(String id) {
    final t = trips.tripById(id);
    return t == null ? null : _withDemoSales(t);
  }

  /// Места, которые в модели «купили» демо-пассажиры (пока приложения не связаны через сервер).
  Trip _withDemoSales(Trip t) {
    final sold = me.demoSales[t.id] ?? const {};
    for (final s in t.seats) {
      final name = sold[s.id];
      if (name != null && !s.taken) {
        s.taken = true;
        s.passenger = name;
      }
    }
    return t;
  }

  /// Демо: 1–2 свободных места рейса покупают пассажиры (заблокированные водителем — не покупают).
  Future<void> sellDemoSeats(Trip t) async {
    final free = t.seats.where((s) => !s.taken).toList()..shuffle();
    if (free.isEmpty) return;
    final taken = t.seats.where((s) => s.taken).map((s) => s.passenger).toSet();
    final names = Demo.demoPassengers.where((n) => !me.isBlocked(n) && !taken.contains(n)).toList()..shuffle();
    final n = free.length == 1 ? 1 : 2;
    await me.sellDemo(t.id, {for (var i = 0; i < n && i < names.length; i++) free[i].id: names[i]});
    update(() {});
  }

  TripStatus statusOf(Trip t) => trips.statusOf(t, geoOf(t.route));

  /// Рейс так и не начали, а его время прошло: он не состоялся.
  /// (На сервере такой рейс отменяется сам, пассажирам — полный возврат.) В заработок не входит.
  bool missed(Trip t) => data.tripStatus(t.id) == null && trips.now.isAfter(endOf(t));

  /// Состояние рейса словами, с учётом «не состоялся».
  String tripLabel(Trip t) => missed(t) ? 'Не состоялся' : statusText(statusOf(t));

  /// Убрать рейс совсем: отменённый или не состоявшийся.
  Future<void> removeTrip(Trip t) async {
    await me.cancelTrip(t.id);
    await data.removeCustomTrip(t.id);
  }

  DateTime endOf(Trip t) => trips.endOf(t, geoOf(t.route));

  /// Начать рейс можно за 15 минут до отправления и до конца по расписанию.
  bool canStart(Trip t) {
    final n = trips.now;
    return !n.isBefore(t.departure.subtract(const Duration(minutes: 15))) && !n.isAfter(endOf(t));
  }

  /// Завершить — не раньше времени отправления.
  bool canFinish(Trip t) => !trips.now.isBefore(t.departure);

  /// Деньги за рейс: по каждому проданному месту — как на сервере (доли считаются по каждой брони).
  ({int paid, int commission, int duty, int driver}) moneyOf(Trip t) {
    var paid = 0, commission = 0, duty = 0;
    for (final s in t.seats.where((s) => s.taken)) {
      final m = MoneySplit.of(s.price);
      paid += m.paid;
      commission += m.commission;
      duty += m.duty;
    }
    return (paid: paid, commission: commission, duty: duty, driver: paid - commission - duty);
  }

  String statusText(TripStatus s) => switch (s) {
        TripStatus.planned => 'Запланирован',
        TripStatus.started => 'В пути',
        TripStatus.finished => 'Завершён',
      };

  // ---------- карта ----------
  void syncMap() {
    map.clearAll();
    final p = pane;
    switch (p) {
      case TripPane(:final tripId) || DrivePane(:final tripId):
        final t = tripOf(tripId);
        if (t == null) return;
        final g = geoOf(t.route);
        map.showRoutes([MapRoute(t.route, g)]);
        map.setSegment(g.subLine(t.meetAlong, t.dropOn(g.length)), color: Color(t.route.color));
        map.setMarker('meet', g.pointAt(t.meetAlong), MarkerKind.start, hint: 'Место посадки');
        map.setMarker('finish', g.pointAt(t.dropOn(g.length)), MarkerKind.finish, hint: 'Место высадки');
        map.fit(g.points);
      case RoutePickPane():
        final list = routesFor(from?.point, to?.point).map((x) => x.route).toList();
        map.showRoutes([for (final r in list) MapRoute(r, geoOf(r))]);
        if (from != null) map.setMarker('from', from!.point, MarkerKind.from);
        if (to != null) map.setMarker('to', to!.point, MarkerKind.to);
        if (from != null && to == null) {
          map.showAround(from!.point, meters: 2500);
        } else {
          final pts = [for (final r in list) ...[r.from.point, r.to.point], ?from?.point, ?to?.point];
          map.fit(pts.isEmpty ? [for (final r in Demo.routes) ...[r.from.point, r.to.point]] : pts);
        }
      case NewTripPane():
        break; // карту ведёт сам экран нового рейса
      default:
        break;
    }
  }

  void onMapTap(GeoPoint p) {
    if (pickFor != null) {
      setPlace(pickFor!, Place('Точка на карте', p));
      return;
    }
    if (pane is RoutePickPane) {
      if (suggestFor != null) {
        update(() => suggestFor = null);
        FocusManager.instance.primaryFocus?.unfocus();
        return;
      }
      _tapRoute(p);
      return;
    }
    onMapTapHandler?.call(p);
  }

  /// Касание линии маршрута на карте выбирает этот маршрут: дальше — запись на рейс.
  void _tapRoute(GeoPoint p) {
    RouteDef? best;
    var bestDist = _routeTapMeters;
    for (final x in routesFor(from?.point, to?.point)) {
      final d = geoOf(x.route).nearest(p).distance;
      if (d < bestDist) {
        best = x.route;
        bestDist = d;
      }
    }
    if (best == null) {
      toast(context, 'Нажмите на линию маршрута — откроется запись на рейс.');
      return;
    }
    push(NewTripPane(best));
  }

  static const _routeTapMeters = 400.0;

  Future<GeoPoint?> position() async {
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

  // ---------- поездка (симуляция) ----------
  Future<void> startDrive(Trip t) async {
    if (statusOf(t) == TripStatus.planned) await data.setTripStatus(t.id, TripStatus.started);
    final g = geoOf(t.route);
    final end = t.dropOn(g.length);
    push(DrivePane(t.id));
    simPos = 0;
    simFactor = 10;
    atMeet = false;
    var last = DateTime.now();
    simTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = DateTime.now();
      final dt = (now.difference(last).inMilliseconds / 1000).clamp(0, 0.25);
      last = now;
      final prev = simPos;
      simPos = (simPos + g.speed * dt * simFactor).clamp(0, end);
      map.setCar(g.pointAt(simPos), color: Color(t.route.color), direction: bearingDeg(g.pointAt(prev), g.pointAt(simPos + 15)));
      if (!atMeet && simPos >= t.meetAlong - 20) {
        atMeet = true;
        if (mounted) toast(context, 'Вы на месте посадки: здесь вас ждут пассажиры.');
      }
      if (simPos >= end) {
        stopSim();
        if (mounted) toast(context, 'Вы на месте высадки. Завершите рейс.');
      }
      update(() {});
    });
  }

  Future<void> finishTrip(Trip t) async {
    stopSim();
    await data.setTripStatus(t.id, TripStatus.finished);
    if (!mounted) return;
    toast(context, 'Рейс завершён. ${amd(moneyOf(t).driver)} начислим через 24 часа. Оцените пассажиров.');
    update(() => stack = [...stack.where((p) => p is! DrivePane)]);
    syncMap();
  }

  void stopSim() {
    simTimer?.cancel();
    simTimer = null;
    map.setCar(null);
  }

  // ---------- экран ----------
  @override
  Widget build(BuildContext context) {
    // Пока водитель не вошёл и анкета не одобрена — только оформление.
    final onboarding = me.phone == null || !me.approved;
    return PopScope(
      canPop: onboarding || stack.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) pop();
      },
      child: MapSheetScaffold(
        map: TransportMap(controller: map, onTap: onMapTap, bottomCover: MapSheetScaffold.initialSize),
        panel: onboarding
            ? (me.phone == null ? signInPanel() : applyPanel())
            : switch (pane) {
                TripsPane() => tripsPanel(),
                RoutePickPane() => routePickPanel(),
                NewTripPane(:final route, :final template) => NewTripPanel(key: ValueKey(route.id), home: this, route: route, template: template),
                RouteRequestPane() => RouteRequestPanel(home: this),
                TripPane(:final tripId) => tripPanel(tripId),
                DrivePane(:final tripId) => drivePanel(tripId),
                MoneyPane() => moneyPanel(),
                ProfilePane() => profilePanel(),
              },
        bottomBar: onboarding
            ? const SizedBox.shrink()
            : NavigationBar(
                selectedIndex: tab.index,
                onDestinationSelected: (i) => goTab(DriverTab.values[i]),
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.search), label: 'Маршруты'),
                  NavigationDestination(icon: Icon(Icons.directions_car_outlined), label: 'Мои рейсы'),
                  NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), label: 'Заработок'),
                  NavigationDestination(icon: Icon(Icons.person_outline), label: 'Профиль'),
                ],
              ),
      ),
    );
  }
}

/// Строка «название — значение» в денежных блоках.
Widget moneyRow(String a, String b, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(a, style: TextStyle(color: bold ? AppColors.text : AppColors.muted, fontSize: 13))),
        Text(b, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400, fontSize: 13)),
      ]),
    );

/// Рамка-карточка, как в приложении пассажира.
Widget outlined(Widget child, {EdgeInsets padding = const EdgeInsets.all(14), VoidCallback? onTap}) => Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.line)),
      child: InkWell(borderRadius: BorderRadius.circular(16), onTap: onTap, child: Padding(padding: padding, child: child)),
    );
