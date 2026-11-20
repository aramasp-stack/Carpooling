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

  /// Место высадки: сколько метров не доезжая до конца маршрута (0 — в самом конце).
  late double dropLeft;
  late List<_SeatOffer> seats;

  RouteDef get route => widget.route;
  DriverHomeState get h => widget.home;
  RouteGeometry get g => h.geoOf(route);

  /// Место посадки — только в начальном районе маршрута.
  double get meetMax => Demo.startDistrictMeters < g.length ? Demo.startDistrictMeters : g.length;

  /// Место высадки — только в конечном районе маршрута и дальше начального.
  double get dropMin {
    final a = g.length - Demo.endDistrictMeters, b = meetMax + 200;
    final m = a > b ? a : b;
    return m > g.length ? g.length : m;
  }

  double get drop => (g.length - dropLeft).clamp(dropMin, g.length).toDouble();

  @override
  void initState() {
    super.initState();
    final t = widget.template;
    day = 1;
    time = t == null ? const TimeOfDay(hour: 8, minute: 0) : TimeOfDay(hour: t.departure.hour, minute: t.departure.minute);
    meet = (t?.meetAlong ?? 0).clamp(0, meetMax).toDouble();
    dropLeft = t?.dropAlong == null ? 0 : (g.length - t!.dropAlong!).clamp(0, g.length - dropMin).toDouble();
    // Места — те, что водитель указал в анкете; в рейсе он выставляет все или часть.
    seats = [
      for (final s in seatsFor(route, h.me.application.seatIds))
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
    h.map.setSecondSegment(g.subLine(dropMin, g.length), color: _accent);
    h.map.setMarker('meet', g.pointAt(meet), MarkerKind.start, hint: 'Место посадки');
    h.map.setMarker('finish', g.pointAt(drop), MarkerKind.finish, hint: 'Место высадки');
    if (fit) h.map.fit(g.points);
  }

  /// Касание карты: в начальном районе — место посадки, в конечном — место высадки.
  void _onMapTap(GeoPoint p) {
    final n = g.nearest(p);
    final a = (n.along / 10).round() * 10.0;
    final nearStart = a <= meetMax + 100, nearEnd = a >= dropMin - 100;
    if (n.distance > 300 || (!nearStart && !nearEnd)) {
      toast(context, 'Посадка — в начале маршрута, высадка — в конце: нажмите на выделенную часть линии.');
      return;
    }
    setState(() {
      if (nearStart && (!nearEnd || (a - meet).abs() <= (a - drop).abs())) {
        meet = a.clamp(0, meetMax).toDouble();
      } else {
        dropLeft = g.length - a.clamp(dropMin, g.length);
      }
    });
    _showOnMap();
  }

  /// Показать точку крупно — чтобы поставить её точнее касанием карты.
  void _zoomTo(GeoPoint p) => h.map.showAround(p, meters: 300);

  /// Место посадки или высадки: описание, «крупно на карте», ползунок и шаги по 10 м.
  Widget _pointEditor({
    required String text,
    required GeoPoint point,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    void set(double v) {
      onChanged(v.clamp(min, max).toDouble());
      _showOnMap();
    }

    final can = max - min >= 10;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600))),
        TextButton.icon(onPressed: () => _zoomTo(point), icon: const Icon(Icons.zoom_in, size: 18), label: const Text('Крупно')),
      ]),
      if (can)
        Row(children: [
          IconButton(
            tooltip: '10 м назад',
            onPressed: value - 10 >= min - 0.1 ? () => set(value - 10) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              divisions: ((max - min) / 10).round().clamp(1, 1000),
              onChanged: set,
            ),
          ),
          IconButton(
            tooltip: '10 м вперёд',
            onPressed: value + 10 <= max + 0.1 ? () => set(value + 10) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ]),
    ]);
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
      _pointEditor(
        text: meet < 10 ? 'В начале маршрута, «${route.from.name}»' : 'В ${meters(meet)} от «${route.from.name}» по маршруту',
        point: g.pointAt(meet),
        value: meet,
        min: 0,
        max: meetMax,
        onChanged: (v) => setState(() => meet = v),
      ),
      const SectionTitle('Место высадки', top: 6),
      _pointEditor(
        text: dropLeft < 10 ? 'В конце маршрута, «${route.to.name}»' : 'За ${meters(dropLeft)} до «${route.to.name}»',
        point: g.pointAt(drop),
        value: drop,
        min: dropMin,
        max: g.length,
        onChanged: (v) => setState(() => dropLeft = g.length - v),
      ),
      const Text(
          'Нажмите «Крупно», потом — на нужное место выделенной части линии: в начале маршрута ставится посадка, в конце — высадка. '
          'Точнее — стрелками, по 10 м. Пассажиры сами приходят к месту посадки, все выходят на месте высадки.',
          style: TextStyle(fontSize: 12, color: AppColors.muted)),
      const SectionTitle('Места и цены'),
      const Text('Места вашей машины из анкеты. Выключите те, что в этом рейсе не продаёте.',
          style: TextStyle(fontSize: 13, color: AppColors.muted)),
      Text('Цена места: минимум ${amd(route.minPrice)} · обычно ${amd(route.price)} · не больше ${amd(route.maxPrice)}',
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
      dropAlong: dropLeft < 1 ? null : drop.roundToDouble(),
      seats: [for (final s in seats.where((s) => s.on)) Seat(id: s.seat.id, label: s.seat.label, price: s.price)],
    ));
    if (!mounted) return;
    toast(context, 'Рейс опубликован. В модели покупки пассажиров изображает кнопка «Демо: пассажиры покупают места».');
    h.onMapTapHandler = null;
    h.update(() {
      h.day = day;
      h.tab = DriverTab.trips;
      h.stack = [TripsPane(), TripPane(id)];
    });
    h.syncMap();
  }
}
