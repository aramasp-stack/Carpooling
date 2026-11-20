part of '../home.dart';

/// Новый рейс, шаг 2: день и время, место посадки, какие места продаются и по какой цене.
class NewTripPanel extends StatefulWidget {
  const NewTripPanel({super.key, required this.home, required this.route, this.template});
  final DriverHomeState home;
  final RouteDef route;
  final Trip? template;

  @override
  State<NewTripPanel> createState() => _NewTripPanelState();
}

class _SeatOffer {
  _SeatOffer(this.seat, this.on, this.price);
  final Seat seat;
  bool on;
  int price;
}

class _NewTripPanelState extends State<NewTripPanel> {
  static const _step = 50;

  late int day;
  late TimeOfDay time;
  late double meet;
  late List<_SeatOffer> seats;

  RouteDef get route => widget.route;
  DriverHomeState get h => widget.home;
  RouteGeometry get g => h.geoOf(route);

  /// Место посадки — только в начальном районе маршрута.
  double get meetMax => Demo.startDistrictMeters < g.length ? Demo.startDistrictMeters : g.length;

  @override
  void initState() {
    super.initState();
    final t = widget.template;
    final total = h.me.application.seats;
    day = 1;
    time = t == null ? const TimeOfDay(hour: 8, minute: 0) : TimeOfDay(hour: t.departure.hour, minute: t.departure.minute);
    meet = (t?.meetAlong ?? 0).clamp(0, meetMax).toDouble();
    seats = [
      for (final s in seatsFor(route, total))
        () {
          Seat? old;
          for (final x in t?.seats ?? const <Seat>[]) {
            if (x.id == s.id) old = x;
          }
          final price = (old?.price ?? s.price).clamp(route.minPrice, route.maxPrice);
          return _SeatOffer(s, t == null || old != null, price);
        }(),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showOnMap(fit: true);
      h.onMapTapHandler = _onMapTap;
    });
  }

  void _showOnMap({bool fit = false}) {
    h.map.clearAll();
    h.map.showRoutes([MapRoute(route, g)]);
    h.map.setSegment(g.subLine(0, meetMax), color: _accent);
    h.map.setMarker('meet', g.pointAt(meet), MarkerKind.start, hint: 'Место посадки');
    h.map.setMarker('finish', route.to.point, MarkerKind.finish);
    if (fit) h.map.fit(g.points);
  }

  /// Касание карты: ближайшая точка начального района.
  void _onMapTap(GeoPoint p) {
    final n = g.nearest(p);
    if (n.distance > 300) {
      toast(context, 'Место посадки — на линии маршрута в начальном районе (выделен цветом).');
      return;
    }
    setState(() => meet = (n.along / 10).round() * 10.0 > meetMax ? meetMax : (n.along / 10).round() * 10.0);
    _showOnMap();
  }

  DateTime get departure {
    final d = dayStart(day, now: h.trips.now);
    return DateTime(d.year, d.month, d.day, time.hour, time.minute);
  }

  @override
  Widget build(BuildContext context) {
    final on = seats.where((s) => s.on).toList();
    final paid = on.fold(0, (sum, s) => sum + s.price);
    final yours = on.fold(0, (sum, s) => sum + MoneySplit.of(s.price).driver);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('К маршрутам', onTap: h.pop),
      Row(children: [
        Swatch(Color(route.color)),
        const SizedBox(width: 8),
        Expanded(child: Text(route.title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700))),
      ]),
      if (widget.template != null)
        const Padding(padding: EdgeInsets.only(top: 4), child: Text('Повтор прошлого рейса: проверьте день и время.', style: TextStyle(color: AppColors.muted))),
      const SectionTitle('Когда'),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (var d = 0; d < 7; d++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(label: Text(dayLabel(d)), selected: day == d, onSelected: (_) => setState(() => day = d)),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.schedule),
        label: Text('Выезд в ${hhmm(departure)}', style: const TextStyle(fontSize: 16)),
        onPressed: () async {
          final t = await showTimePicker(context: context, initialTime: time);
          if (t != null) setState(() => time = t);
        },
      ),
      const SectionTitle('Место посадки'),
      Text(
        meet < 50 ? 'В начале маршрута, «${route.from.name}»' : 'В ${meters(meet)} от «${route.from.name}» по маршруту',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      Slider(
        value: meet,
        min: 0,
        max: meetMax,
        divisions: (meetMax / 50).round().clamp(1, 100),
        onChanged: (v) {
          setState(() => meet = v);
          _showOnMap();
        },
      ),
      const Text('Двигайте ползунок или нажмите на карту в выделенной части маршрута. Пассажиры сами придут к этой точке.',
          style: TextStyle(fontSize: 12, color: AppColors.muted)),
      const SectionTitle('Места и цены'),
      Text('Минимум ${amd(route.minPrice)} · обычно ${amd(route.price)} · не больше ${amd(route.maxPrice)}',
          style: const TextStyle(fontSize: 13, color: AppColors.muted)),
      const SizedBox(height: 8),
      for (final s in seats) _seatRow(s),
      Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          moneyRow('Если продадите все ${on.length} ${plural(on.length, 'место', 'места', 'мест')}', amd(paid)),
          moneyRow('Комиссия ${Demo.commissionPercent}% и госпошлина ${Demo.statePercent}%', '− ${amd(paid - yours)}'),
          moneyRow('Вы получите', amd(yours), bold: true),
        ]),
      ),
      FilledButton(
        onPressed: on.isEmpty ? null : _publish,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: const Text('Опубликовать рейс', style: TextStyle(fontSize: 16)),
      ),
    ]);
  }

  Widget _seatRow(_SeatOffer s) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        decoration: BoxDecoration(
          border: Border.all(color: s.on ? _accent : AppColors.line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          Switch(value: s.on, onChanged: (v) => setState(() => s.on = v)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.seat.label, style: TextStyle(fontWeight: FontWeight.w600, color: s.on ? AppColors.text : AppColors.muted)),
              Text(s.on ? 'вам ${amd(MoneySplit.of(s.price).driver)}' : 'не продаётся',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            ]),
          ),
          IconButton(
            onPressed: s.on && s.price - _step >= route.minPrice ? () => setState(() => s.price -= _step) : null,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 74,
            child: Text(amd(s.price),
                textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: s.on ? AppColors.text : AppColors.muted)),
          ),
          IconButton(
            onPressed: s.on && s.price + _step <= route.maxPrice ? () => setState(() => s.price += _step) : null,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ]),
      );

  Future<void> _publish() async {
    final now = h.trips.now;
    final dep = departure;
    if (dep.isBefore(now.add(const Duration(minutes: 15)))) {
      toast(context, 'Рейс можно поставить не раньше чем за 15 минут до выезда.');
      return;
    }
    final end = dep.add(Duration(seconds: g.durationSec.round()));
    for (final t in h.myTrips(day)) {
      if (h.statusOf(t) == TripStatus.finished) continue;
      if (t.departure.isBefore(end) && h.endOf(t).isAfter(dep)) {
        toast(context, 'В это время у вас уже есть рейс в ${hhmm(t.departure)}. Выберите другое время.');
        return;
      }
    }
    for (final s in seats.where((s) => s.on)) {
      if (s.price < route.minPrice) {
        toast(context, driverErrorText('PRICE_BELOW_MINIMUM'));
        return;
      }
    }
    final hm = hhmm(dep);
    final id = '${route.id}-${ymd(dep)}-$hm-c${now.millisecondsSinceEpoch.toRadixString(36)}';
    await h.data.addCustomTrip(CustomTrip(
      id: id,
      routeId: route.id,
      date: ymd(dep),
      time: hm,
      driverIndex: Demo.meIndex,
      meetAlong: meet,
      seats: [for (final s in seats.where((s) => s.on)) Seat(id: s.seat.id, label: s.seat.label, price: s.price)],
    ));
    if (!mounted) return;
    toast(context, 'Рейс опубликован. В модели покупки пассажиров изображает кнопка «Демо: пассажиры покупают места».');
    h.onMapTapHandler = null;
    h.update(() {
      h.day = day;
      h.stack = [TripsPane(), TripPane(id)];
    });
    h.syncMap();
  }
}
