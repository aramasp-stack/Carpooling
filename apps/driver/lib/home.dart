import 'dart:async';

import 'package:flutter/material.dart';
import 'package:transport_core/transport_core.dart';
import 'package:transport_ui/transport_ui.dart';
import 'package:url_launcher/url_launcher.dart';

const _accent = AppColors.driver;
final _me = Demo.drivers[Demo.meIndex];

enum DriverTab { trips, money, profile }

sealed class Pane {}

class TripsPane extends Pane {}

class NewTripPane extends Pane {}

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

/// Пассажир в рейсе: где он ждёт водителя.
class Pax {
  const Pax(this.seat, this.name, this.along, this.where);
  final Seat seat;
  final String name;
  final double along;
  final String where;
}

class DriverHome extends StatefulWidget {
  const DriverHome({super.key, required this.data});
  final DataStore data;

  @override
  State<DriverHome> createState() => DriverHomeState();
}

class DriverHomeState extends State<DriverHome> {
  final map = TransportMapController();
  final loader = RouteLoader();
  late final trips = TripService(widget.data);
  DataStore get data => widget.data;
  Map<String, RouteGeometry> geoms = {};

  DriverTab tab = DriverTab.trips;
  List<Pane> stack = [TripsPane()];
  Pane get pane => stack.last;
  int day = 0;

  // Поездка (симуляция)
  Timer? simTimer;
  double simPos = 0;
  double simFactor = 10;
  final metSeats = <String>{};

  @override
  void initState() {
    super.initState();
    loader.loadAll(Demo.routes).then((g) {
      if (!mounted) return;
      setState(() => geoms = g);
      syncMap();
    });
  }

  @override
  void dispose() {
    simTimer?.cancel();
    super.dispose();
  }

  void update(VoidCallback f) {
    if (mounted) setState(f);
  }

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

  void goTab(DriverTab t) {
    stopSim();
    update(() {
      tab = t;
      stack = [
        switch (t) {
          DriverTab.trips => TripsPane(),
          DriverTab.money => MoneyPane(),
          DriverTab.profile => ProfilePane(),
        }
      ];
    });
    syncMap();
  }

  // ---------- данные ----------
  RouteGeometry? geoOf(Trip t) => geoms[t.route.id];

  List<Pax> paxOf(Trip t) {
    final g = geoOf(t) ?? RouteGeometry.straight(t.route);
    final bookings = data.bookings();
    final list = <Pax>[];
    for (final s in t.seats.where((s) => s.taken)) {
      Booking? b;
      for (final x in bookings) {
        if (x.id == s.bookingId) b = x;
      }
      final along = b?.pickAlong ?? (djb2(t.id + s.id) % 5) / 10 * g.length; // демо: где ждёт пассажир
      final where = b?.fromName ?? (along < 50 ? 'у старта «${t.route.from.name}»' : 'по пути, ${meters(along)} от старта');
      list.add(Pax(s, s.passenger ?? 'Пассажир', along, where));
    }
    list.sort((a, b) => a.along.compareTo(b.along));
    return list;
  }

  String statusText(TripStatus s) => switch (s) {
        TripStatus.planned => 'Запланирован',
        TripStatus.started => 'В пути',
        TripStatus.finished => 'Завершён',
      };

  // ---------- карта ----------
  void syncMap() {
    map.clearAll();
    switch (pane) {
      case TripPane(:final tripId) || DrivePane(:final tripId):
        final t = trips.tripById(tripId);
        final g = t == null ? null : geoOf(t);
        if (t == null || g == null) return;
        map.showRoutes([MapRoute(t.route, g)]);
        map.setMarker('start', t.route.from.point, MarkerKind.start);
        map.setMarker('finish', t.route.to.point, MarkerKind.finish);
        for (final p in paxOf(t)) {
          map.setMarker('pax-${p.seat.id}', g.pointAt(p.along), MarkerKind.passenger);
        }
        map.fit(g.points);
      case NewTripPane():
        break;
      default:
        break;
    }
  }

  void showRoutePreview(String routeId) {
    final r = Demo.routeById(routeId);
    final g = geoms[routeId];
    map.clearAll();
    if (r == null || g == null) return;
    map.showRoutes([MapRoute(r, g)]);
    map.setMarker('start', r.from.point, MarkerKind.start);
    map.setMarker('finish', r.to.point, MarkerKind.finish);
    map.fit(g.points);
  }

  // ---------- поездка ----------
  Future<void> startDrive(Trip t) async {
    await data.setTripStatus(t.id, TripStatus.started);
    final g = geoOf(t);
    if (g == null) return;
    push(DrivePane(t.id));
    simPos = 0;
    simFactor = 10;
    metSeats.clear();
    final pax = paxOf(t);
    var last = DateTime.now();
    simTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = DateTime.now();
      final dt = (now.difference(last).inMilliseconds / 1000).clamp(0, 0.25);
      last = now;
      final prev = simPos;
      simPos = (simPos + g.speed * dt * simFactor).clamp(0, g.length);
      map.setCar(g.pointAt(simPos), color: Color(t.route.color), direction: bearingDeg(g.pointAt(prev), g.pointAt(simPos + 15)));
      for (final p in pax) {
        if (!metSeats.contains(p.seat.id) && simPos >= p.along - 20) {
          metSeats.add(p.seat.id);
          if (mounted) toast(context, 'Подберите пассажира: ${p.name}, ${p.seat.label}');
        }
      }
      if (simPos >= g.length) finishDrive(t);
      update(() {});
    });
  }

  Future<void> finishDrive(Trip t) async {
    stopSim();
    await data.setTripStatus(t.id, TripStatus.finished);
    if (!mounted) return;
    toast(context, 'Рейс завершён. Вам начислено ${amd(MoneySplit.of(t.paidTotal).driver)}.');
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
    return PopScope(
      canPop: stack.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) pop();
      },
      child: MapSheetScaffold(
        map: TransportMap(controller: map, bottomCover: MapSheetScaffold.initialSize),
        panel: switch (pane) {
          TripsPane() => _tripsPanel(),
          NewTripPane() => NewTripPanel(home: this),
          TripPane(:final tripId) => _tripPanel(tripId),
          DrivePane(:final tripId) => _drivePanel(tripId),
          MoneyPane() => _moneyPanel(),
          ProfilePane() => _profilePanel(),
        },
        bottomBar: NavigationBar(
          selectedIndex: tab.index,
          onDestinationSelected: (i) => goTab(DriverTab.values[i]),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.directions_car_outlined), label: 'Рейсы'),
            NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), label: 'Заработок'),
            NavigationDestination(icon: Icon(Icons.person_outline), label: 'Профиль'),
          ],
        ),
      ),
    );
  }

  // ---------- Рейсы ----------
  Widget _tripsPanel() {
    final list = trips.driverTrips(_me, day);
    final next = trips.driverTrips(_me, 0).where((t) => trips.statusOf(t, geoOf(t)) != TripStatus.finished).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: _accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Здравствуйте, ${_me.name}!', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(
            next == null ? 'На сегодня рейсов больше нет' : 'Ближайший рейс в ${hhmm(next.departure)} · ${next.route.title}',
            style: const TextStyle(fontSize: 13, color: AppColors.muted),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: () => push(NewTripPane()), icon: const Icon(Icons.add), label: const Text('Новый рейс')),
      const SizedBox(height: 12),
      Wrap(spacing: 8, children: [
        for (var d = 0; d < 3; d++) ChoiceChip(label: Text(dayLabel(d)), selected: day == d, onSelected: (_) => update(() => day = d)),
      ]),
      const SizedBox(height: 10),
      if (list.isEmpty)
        const Padding(
          padding: EdgeInsets.all(18),
          child: Text('На этот день рейсов нет. Нажмите «Новый рейс».', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
        ),
      for (final t in list) _tripItem(t),
    ]);
  }

  Widget _tripItem(Trip t) {
    final taken = t.seats.where((s) => s.taken).length;
    final status = trips.statusOf(t, geoOf(t));
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => push(TripPane(t.id)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Swatch(Color(t.route.color)),
              const SizedBox(width: 8),
              Text(hhmm(t.departure), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const Spacer(),
              StatusChip(statusText(status), kind: status == TripStatus.finished ? StatusKind.done : StatusKind.ok),
            ]),
            const SizedBox(height: 2),
            Text('${t.route.title}${t.custom ? ' · создан вами' : ''}'),
            const SizedBox(height: 8),
            Row(children: [
              for (final s in t.seats)
                Container(
                  width: 11,
                  height: 11,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(color: s.taken ? _accent : AppColors.line, borderRadius: BorderRadius.circular(3)),
                ),
              const SizedBox(width: 6),
              Text('занято $taken из ${t.seats.length}', style: const TextStyle(fontSize: 13)),
              const Spacer(),
              Text('вам ${amd(MoneySplit.of(t.paidTotal).driver)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
          ]),
        ),
      ),
    );
  }

  // ---------- Рейс: пассажиры ----------
  Widget _tripPanel(String id) {
    final t = trips.tripById(id);
    if (t == null) return BackLink('Мои рейсы', onTap: () => goTab(DriverTab.trips));
    final g = geoOf(t);
    final status = trips.statusOf(t, g);
    final marks = data.boarding(t.id);
    final pax = paxOf(t);
    final money = MoneySplit.of(t.paidTotal);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('Мои рейсы', onTap: pop),
      Row(children: [
        Expanded(
          child: Text('${hhmm(t.departure)} · ${dayLabel(dayOffsetOf(t.departure, now: trips.now))}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        ),
        StatusChip(statusText(status), kind: status == TripStatus.finished ? StatusKind.done : StatusKind.ok),
      ]),
      const SizedBox(height: 6),
      TwoPoints(from: t.route.from.name, fromTime: hhmm(t.departure), to: t.route.to.name, toTime: '≈ ${hhmm(trips.endOf(t, g))}'),
      SectionTitle('Пассажиры · ${pax.length} из ${t.seats.length}'),
      for (final p in pax)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
          decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            CircleAvatar(radius: 18, backgroundColor: AppColors.muted, child: Text(p.name[0], style: const TextStyle(color: Colors.white))),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p.name} · ${p.seat.label}', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('ждёт: ${p.where}', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              ]),
            ),
            _markButton(t.id, p.seat.id, Boarding.boarded, 'Сел', marks[p.seat.id], AppColors.ok),
            _markButton(t.id, p.seat.id, Boarding.noShow, 'Нет', marks[p.seat.id], AppColors.danger),
            IconButton(
              icon: const Icon(Icons.call_outlined),
              onPressed: () => toast(context, 'В рабочей версии — звонок через подменный номер: свой телефон вы не раскрываете.'),
            ),
          ]),
        ),
      for (final s in t.seats.where((s) => !s.taken))
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(14)),
          child: Text('${s.label} — свободно · ${amd(s.price)}', style: const TextStyle(color: AppColors.muted)),
        ),
      Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          _moneyRow('Оплатили пассажиры', amd(money.paid), bold: true),
          _moneyRow('Комиссия сервиса ${Demo.commissionPercent}%', '− ${amd(money.commission)}'),
          _moneyRow('Госпошлина ${Demo.statePercent}%', '− ${amd(money.duty)}'),
          _moneyRow('Вам', amd(money.driver), bold: true),
        ]),
      ),
      if (status == TripStatus.finished)
        const NoteBox('Рейс завершён. Деньги будут в ближайшей выплате.')
      else ...[
        FilledButton(onPressed: () => startDrive(t), child: Text(status == TripStatus.started ? 'Продолжить рейс' : 'Начать рейс')),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => launchUrl(
            Uri.parse('https://yandex.ru/maps/?rtext=${t.route.from.point.lat},${t.route.from.point.lon}~${t.route.to.point.lat},${t.route.to.point.lon}&rtt=auto'),
            mode: LaunchMode.externalApplication,
          ),
          icon: const Icon(Icons.navigation_outlined),
          label: const Text('Открыть в Яндекс Картах'),
        ),
      ],
    ]);
  }

  Widget _markButton(String tripId, String seatId, Boarding value, String label, Boarding? current, Color color) {
    final on = current == value;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: OutlinedButton(
        onPressed: () async {
          await data.setBoarding(tripId, seatId, value);
          update(() {});
        },
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          backgroundColor: on ? color.withValues(alpha: 0.12) : null,
          foregroundColor: on ? color : AppColors.text,
          side: BorderSide(color: on ? color : AppColors.line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _moneyRow(String a, String b, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(a, style: TextStyle(color: bold ? AppColors.text : AppColors.muted, fontSize: 13))),
          Text(b, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400, fontSize: 13)),
        ]),
      );

  // ---------- Поездка ----------
  Widget _drivePanel(String id) {
    final t = trips.tripById(id);
    final g = t == null ? null : geoOf(t);
    if (t == null || g == null) return const SizedBox.shrink();
    final pax = paxOf(t);
    Pax? next;
    for (final p in pax) {
      if (p.along > simPos + 20) {
        next = p;
        break;
      }
    }
    final eta = next == null
        ? 'До финиша ${minutesText((g.length - simPos) / g.speed)}'
        : 'Пассажир ${next.name} через ${minutesText((next.along - simPos) / g.speed)}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('К рейсу', onTap: pop),
      Text(t.route.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const Text('Симуляция: машина едет по маршруту без реального GPS.', style: TextStyle(fontSize: 12, color: AppColors.muted)),
      const SizedBox(height: 10),
      Text(eta, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      Text(next == null ? t.route.to.name : 'ждёт: ${next.where}', style: const TextStyle(color: AppColors.muted)),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(value: simPos / g.length, minHeight: 6, color: _accent, backgroundColor: AppColors.surface),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 8, children: [
        for (final f in [1.0, 10.0, 30.0])
          ChoiceChip(label: Text('×${f.round()}'), selected: simFactor == f, onSelected: (_) => update(() => simFactor = f)),
      ]),
      const SizedBox(height: 12),
      OutlinedButton(
        onPressed: () => finishDrive(t),
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
        child: const Text('Завершить рейс'),
      ),
    ]);
  }

  // ---------- Заработок ----------
  DateTime _nextMonday() {
    final d = dayStart(0, now: trips.now);
    final add = (8 - d.weekday) % 7;
    return d.add(Duration(days: add == 0 ? 7 : add));
  }

  Widget _moneyPanel() {
    final done = <Trip>[
      for (var d = -6; d <= 0; d++)
        for (final t in trips.driverTrips(_me, d))
          if (trips.statusOf(t, geoOf(t)) == TripStatus.finished && t.paidTotal > 0) t,
    ]..sort((a, b) => b.departure.compareTo(a.departure));
    final total = done.fold(0, (s, t) => s + MoneySplit.of(t.paidTotal).driver);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.text, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('К выплате в понедельник, ${dateLong(_nextMonday())}', style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13)),
          Text(amd(total), style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700)),
          Text('на карту Visa •••• 4821 · рейсов за неделю: ${done.length}', style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13)),
        ]),
      ),
      const NoteBox('Деньги за рейс становятся доступными через 24 часа после него — это время на жалобы пассажиров. Выплаты раз в неделю.'),
      const SectionTitle('Завершённые рейсы', top: 4),
      if (done.isEmpty) const Text('Пока нет завершённых рейсов.', style: TextStyle(color: AppColors.muted)),
      for (final t in done)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${dateLong(t.departure)}, ${hhmm(t.departure)} · ${t.route.title}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                Text('оплачено ${amd(t.paidTotal)} − комиссия ${Demo.commissionPercent}% − госпошлина ${Demo.statePercent}%',
                    style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              ]),
            ),
            Text('+${amd(MoneySplit.of(t.paidTotal).driver)}', style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ),
    ]);
  }

  // ---------- Профиль ----------
  Widget _profilePanel() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DriverCard(_me, color: _accent),
        const SectionTitle('Документы'),
        for (final d in ['Водительское удостоверение', 'Техпаспорт машины', 'Фото машины (2)', 'Селфи с документом', 'ИНН (для госпошлины и чеков)'])
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.check_circle, color: AppColors.ok),
            title: Text(d),
            trailing: const Text('проверено', style: TextStyle(fontSize: 12, color: AppColors.muted)),
          ),
        const SectionTitle('Выплаты'),
        const ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.credit_card), title: Text('Visa •••• 4821'), trailing: Text('основная')),
        const SectionTitle('Договор'),
        const ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.check_circle, color: AppColors.ok),
          title: Text('Оферта платформы принята: вы — перевозчик, платформа принимает оплату от вашего имени'),
        ),
        Text('Демо: вы вошли как водитель ${_me.name}.', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
      ]);
}

/// Новый рейс: маршрут, день, время, какие места продавать и цена каждого места.
class NewTripPanel extends StatefulWidget {
  const NewTripPanel({super.key, required this.home});
  final DriverHomeState home;

  @override
  State<NewTripPanel> createState() => _NewTripPanelState();
}

class _NewTripPanelState extends State<NewTripPanel> {
  String routeId = Demo.routes.first.id;
  int day = 1;
  TimeOfDay time = const TimeOfDay(hour: 8, minute: 0);
  late List<({Seat seat, bool on, TextEditingController price})> seats = _seatsFor(routeId);

  List<({Seat seat, bool on, TextEditingController price})> _seatsFor(String id) => [
        for (final s in seatsFor(Demo.routeById(id)!, 4)) (seat: s, on: true, price: TextEditingController(text: '${s.price}')),
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.home.showRoutePreview(routeId));
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.home;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('Мои рейсы', onTap: h.pop),
      const Text('Новый рейс', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
      const SectionTitle('Маршрут'),
      RadioGroup<String>(
        groupValue: routeId,
        onChanged: (v) {
          if (v == null) return;
          setState(() {
            routeId = v;
            seats = _seatsFor(v);
          });
          h.showRoutePreview(v);
        },
        child: Column(children: [
          for (final r in Demo.routes)
            RadioListTile<String>(
              value: r.id,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Row(children: [Swatch(Color(r.color)), const SizedBox(width: 8), Expanded(child: Text(r.title))]),
            ),
        ]),
      ),
      const SectionTitle('Когда'),
      Wrap(spacing: 8, children: [
        for (var d = 0; d < 3; d++) ChoiceChip(label: Text(dayLabel(d)), selected: day == d, onSelected: (_) => setState(() => day = d)),
      ]),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.schedule),
        label: Text('Выезд в ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'),
        onPressed: () async {
          final t = await showTimePicker(context: context, initialTime: time);
          if (t != null) setState(() => time = t);
        },
      ),
      const SectionTitle('Места и цены'),
      for (var i = 0; i < seats.length; i++)
        Row(children: [
          Checkbox(value: seats[i].on, onChanged: (v) => setState(() => seats[i] = (seat: seats[i].seat, on: v ?? false, price: seats[i].price))),
          Expanded(child: Text(seats[i].seat.label)),
          SizedBox(
            width: 110,
            child: TextField(
              controller: seats[i].price,
              enabled: seats[i].on,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.right,
              decoration: const InputDecoration(suffixText: ' ֏', isDense: true),
            ),
          ),
        ]),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Снимите галочку, если место не продаёте. Пассажир видит цену каждого места.',
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
      ),
      FilledButton(onPressed: _publish, child: const Text('Опубликовать рейс')),
    ]);
  }

  Future<void> _publish() async {
    final h = widget.home;
    final chosen = [
      for (final s in seats)
        if (s.on) Seat(id: s.seat.id, label: s.seat.label, price: (int.tryParse(s.price.text) ?? s.seat.price).clamp(100, 100000)),
    ];
    if (chosen.isEmpty) {
      toast(context, 'Отметьте хотя бы одно место.');
      return;
    }
    final date = ymd(dayStart(day, now: h.trips.now));
    final hm = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final id = '$routeId-$date-$hm-c${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await h.data.addCustomTrip(CustomTrip(id: id, routeId: routeId, date: date, time: hm, driverIndex: Demo.meIndex, seats: chosen));
    if (!mounted) return;
    toast(context, 'Рейс опубликован — пассажиры увидят его в поиске.');
    h.update(() {
      h.day = day;
      h.stack = [TripsPane(), TripPane(id)];
    });
    h.syncMap();
  }
}
