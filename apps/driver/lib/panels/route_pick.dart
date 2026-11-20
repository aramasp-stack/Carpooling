part of '../home.dart';

/// Главный экран водителя: найти маршрут, как поиск у пассажира.
/// «Откуда начинаете» и «Куда» (можно не указывать) → маршруты рядом → выбрать и записаться на рейс (время, место, цены).
/// Свои рейсы — на вкладке «Мои рейсы»; здесь только короткое напоминание о ближайшем.
extension RoutePick on DriverHomeState {
  /// Маршруты, у которых начало рядом с «откуда» (если указано) и которые проходят рядом с «куда» (если указано).
  /// Ближние к «откуда» — первыми. Без «откуда» и «куда» — все маршруты.
  List<({RouteDef route, double? distance})> routesFor(GeoPoint? fromP, GeoPoint? toP) {
    final out = <({RouteDef route, double? distance})>[];
    for (final r in Demo.routes) {
      double? d;
      if (fromP != null) {
        d = distanceMeters(fromP, r.from.point);
        if (d > Demo.startDistrictMeters + 500) continue;
      }
      if (toP != null && !_goesTo(r, toP)) continue;
      out.add((route: r, distance: d));
    }
    if (fromP != null) out.sort((a, b) => a.distance!.compareTo(b.distance!));
    return out;
  }

  /// Маршрут ведёт к месту: конечная рядом или линия проходит рядом (дальше начального района).
  bool _goesTo(RouteDef r, GeoPoint p) {
    if (distanceMeters(p, r.to.point) <= 1500) return true;
    final n = geoOf(r).nearest(p);
    return n.distance <= 1000 && n.along > Demo.startDistrictMeters;
  }

  /// Маршруты, по которым водитель уже ставил рейсы.
  List<RouteDef> myRoutes() {
    final ids = <String>{};
    for (var d = 6; d >= -14 && ids.length < 3; d--) {
      for (final t in myTrips(d)) {
        if (ids.length < 3) ids.add(t.route.id);
      }
    }
    return [for (final id in ids) Demo.routeById(id)!];
  }

  /// Ближайший свой рейс (сегодня или в следующие дни), который ещё не прошёл.
  Trip? nextOwnTrip() {
    for (var d = 0; d < 7; d++) {
      for (final t in myTrips(d)) {
        if (statusOf(t) != TripStatus.finished) return t;
      }
    }
    return null;
  }

  Widget routePickPanel() {
    final next = nextOwnTrip();
    final mine = myRoutes();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (next != null) _nextTripStrip(next),
      const Text('Где будете возить?', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      const Text('Укажите, откуда начинаете, — покажем маршруты рядом. Выберите маршрут и запишитесь на рейс.',
          style: TextStyle(fontSize: 13, color: AppColors.muted)),
      const SizedBox(height: 10),
      if (pickFor != null) _pickHint(),
      _whereBox(),
      if (suggestFor == 'to') _suggestBox(),
      if (mine.isNotEmpty && from == null && to == null && suggestFor == null) ...[
        const SectionTitle('Мои маршруты', top: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final r in mine)
            ActionChip(
              avatar: Icon(Icons.history, size: 16, color: Color(r.color)),
              label: Text(r.title),
              onPressed: () => push(NewTripPane(r)),
            ),
        ]),
      ],
      ..._routeList(),
      const SizedBox(height: 14),
      OutlinedButton.icon(
        onPressed: () => push(RouteRequestPane()),
        icon: const Icon(Icons.add_road),
        label: const Text('Нет нужного маршрута? Предложить'),
      ),
    ]);
  }

  /// Короткое напоминание о своём ближайшем рейсе — без сумм; подробности на «Мои рейсы».
  Widget _nextTripStrip(Trip t) {
    final started = statusOf(t) == TripStatus.started;
    final d = dayOffsetOf(t.departure, now: trips.now);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: _accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => goTab(DriverTab.trips, open: TripPane(t.id)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(children: [
              Icon(started ? Icons.directions_car : Icons.event_available, color: _accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                    text: started ? 'Вы в пути\n' : 'Ваш рейс: ${dayLabel(d).toLowerCase()} в ${hhmm(t.departure)}\n',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: t.route.title, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
                ])),
              ),
              const Icon(Icons.chevron_right, color: _accent),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _pickHint() => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        decoration: BoxDecoration(color: _accent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          const Icon(Icons.touch_app_outlined, color: _accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(pickFor == 'from' ? 'Нажмите на карту, откуда начинаете' : 'Нажмите на карту, куда едете',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          TextButton(onPressed: () => update(() => pickFor = null), child: const Text('Отмена')),
        ]),
      );

  Widget _whereRow(String which) {
    final ctl = which == 'from' ? fromCtl : toCtl;
    final value = which == 'from' ? from : to;
    return Row(children: [
      Swatch(which == 'from' ? AppColors.from : AppColors.to, size: 10),
      const SizedBox(width: 10),
      Expanded(
        child: TextField(
          controller: ctl,
          decoration: InputDecoration(
            hintText: which == 'from' ? 'Откуда начинаете?' : 'Куда — можно не указывать',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            isDense: true,
          ),
          onTap: () {
            // Повторное касание складывает открытый список.
            if (suggestFor == which) {
              update(() => suggestFor = null);
              return;
            }
            update(() {
              suggestFor = which;
              suggestQuery = value != null ? '' : ctl.text;
              if (value != null) ctl.selection = TextSelection(baseOffset: 0, extentOffset: ctl.text.length);
            });
          },
          onChanged: (t) => update(() {
            suggestFor = which;
            suggestQuery = t;
          }),
        ),
      ),
      if (value != null)
        IconButton(
          icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
          visualDensity: VisualDensity.compact,
          onPressed: () => setPlace(which, null),
        ),
      if (which == 'from')
        IconButton(
          tooltip: 'Я здесь',
          icon: const Icon(Icons.my_location, size: 22, color: _accent),
          visualDensity: VisualDensity.compact,
          onPressed: () async {
            update(() => suggestFor = null);
            final p = await position();
            if (!mounted) return;
            if (p == null || distanceMeters(p, Demo.yerevanCenter) > 40000) {
              toast(context, 'Местоположение недоступно или вы далеко от Еревана. Выберите место из списка или на карте.');
              return;
            }
            setPlace('from', Place('Я здесь', p));
          },
        ),
      IconButton(
        tooltip: 'Выбрать на карте',
        icon: const Icon(Icons.map_outlined, size: 22, color: _accent),
        visualDensity: VisualDensity.compact,
        onPressed: () {
          FocusManager.instance.primaryFocus?.unfocus();
          update(() {
            pickFor = which;
            suggestFor = null;
          });
        },
      ),
    ]);
  }

  Widget _whereBox() => Container(
        padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
        decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(16)),
        child: Column(children: [
          _whereRow('from'),
          // Список для «Откуда» раскрывается сразу под этим полем, над «Куда».
          if (suggestFor == 'from') Padding(padding: const EdgeInsets.fromLTRB(0, 0, 10, 10), child: _suggestBox()),
          const Divider(height: 1),
          _whereRow('to'),
        ]),
      );

  List<Place> _places(String text) {
    final q = text.trim().toLowerCase();
    if (q.isEmpty) return Demo.places.take(6).toList();
    return Demo.places.where((p) => p.name.toLowerCase().contains(q)).take(6).toList();
  }

  Widget _suggestBox() {
    final q = suggestQuery.trim().toLowerCase();
    // «Куда», когда «откуда» уже есть: только те места, куда ведут маршруты отсюда.
    if (suggestFor == 'to' && from != null) {
      final all = routesFor(from!.point, null);
      final list = q.isEmpty ? all : all.where((x) => x.route.to.name.toLowerCase().contains(q)).toList();
      return _box([
        if (all.isEmpty)
          const ListTile(dense: true, title: Text('Отсюда маршрутов нет', style: TextStyle(color: AppColors.muted))),
        for (final x in list)
          ListTile(
            dense: true,
            leading: Swatch(Color(x.route.color)),
            title: Text(x.route.to.name),
            subtitle: Text('из «${x.route.from.name}»'),
            onTap: () => setPlace('to', x.route.to),
          ),
        if (all.isNotEmpty && list.isEmpty)
          const ListTile(dense: true, title: Text('Нет маршрутов с таким названием', style: TextStyle(color: AppColors.muted))),
      ]);
    }
    final places = _places(suggestQuery);
    return _box([
      if (places.isEmpty) const ListTile(dense: true, title: Text('Ничего не найдено', style: TextStyle(color: AppColors.muted))),
      for (final p in places)
        ListTile(
          dense: true,
          leading: const Icon(Icons.place_outlined, size: 20),
          title: Text(p.name),
          onTap: () => setPlace(suggestFor ?? 'from', p),
        ),
    ]);
  }

  Widget _box(List<Widget> children) => Container(
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(14)),
        child: Column(children: children),
      );

  void setPlace(String which, Place? p) {
    update(() {
      if (which == 'from') {
        from = p;
        fromCtl.text = p?.name ?? '';
      } else {
        to = p;
        toCtl.text = p?.name ?? '';
      }
      suggestFor = null;
      suggestQuery = '';
      pickFor = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    syncMap();
  }

  List<Widget> _routeList() {
    if (from == null && to == null) {
      return [
        const SizedBox(height: 10),
        if (!showAllRoutes)
          TextButton.icon(
            onPressed: () => update(() => showAllRoutes = true),
            icon: const Icon(Icons.list),
            label: Text('Показать все маршруты (${Demo.routes.length})'),
          )
        else ...[
          const SectionTitle('Все маршруты'),
          for (final r in Demo.routes) _routeCard(r, null),
        ],
      ];
    }
    final list = routesFor(from?.point, to?.point);
    if (list.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            from != null && to != null
                ? 'Отсюда туда маршрутов нет. Уберите «Куда», выберите другое место или предложите маршрут.'
                : 'Рядом маршрутов нет. Выберите другое место или предложите новый маршрут.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted),
          ),
        ),
      ];
    }
    return [
      SectionTitle(from != null ? 'Начинаются рядом: ${list.length}' : 'Идут туда: ${list.length}'),
      const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text('Выберите маршрут — дальше укажете день, время, место посадки и цены.',
            style: TextStyle(fontSize: 13, color: AppColors.muted)),
      ),
      for (final x in list) _routeCard(x.route, x.distance),
    ];
  }

  Widget _routeCard(RouteDef r, double? distance) => outlined(
        Row(children: [
          Swatch(Color(r.color)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.title, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                [
                  if (distance != null) distance < 150 ? 'начало рядом' : 'начало в ${meters(distance)}',
                  '~${r.minutes} мин',
                  'место от ${amd(r.minPrice)}',
                ].join(' · '),
                style: const TextStyle(fontSize: 13, color: AppColors.muted),
              ),
            ]),
          ),
          const Icon(Icons.chevron_right),
        ]),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        onTap: () => push(NewTripPane(r)),
      );
}

/// «Предложить маршрут»: заявка модератору.
class RouteRequestPanel extends StatefulWidget {
  const RouteRequestPanel({super.key, required this.home});
  final DriverHomeState home;

  @override
  State<RouteRequestPanel> createState() => _RouteRequestPanelState();
}

class _RouteRequestPanelState extends State<RouteRequestPanel> {
  final fromCtl = TextEditingController();
  final toCtl = TextEditingController();
  final commentCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    bool named(Place? p) => p != null && p.name != 'Точка на карте' && p.name != 'Я здесь';
    final f = widget.home.from, t = widget.home.to;
    if (named(f)) fromCtl.text = f!.name;
    if (named(t)) toCtl.text = t!.name;
  }

  @override
  void dispose() {
    fromCtl.dispose();
    toCtl.dispose();
    commentCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.home;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('К маршрутам', onTap: h.pop),
      const Text('Предложить маршрут', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text('Модератор проверит, есть ли спрос, построит маршрут и задаст цены. Ответ придёт в профиль.',
          style: TextStyle(color: AppColors.muted)),
      const SizedBox(height: 14),
      TextField(controller: fromCtl, decoration: const InputDecoration(labelText: 'Откуда: район или место')),
      const SizedBox(height: 8),
      TextField(controller: toCtl, decoration: const InputDecoration(labelText: 'Куда')),
      const SizedBox(height: 8),
      TextField(
        controller: commentCtl,
        maxLines: 3,
        maxLength: 500,
        decoration: const InputDecoration(labelText: 'Комментарий — например, когда там много людей'),
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: () async {
          try {
            await h.me.requestRoute(from: fromCtl.text, to: toCtl.text, comment: commentCtl.text);
            if (!context.mounted) return;
            toast(context, 'Заявка отправлена модератору.');
            h.pop();
          } catch (e) {
            h.showError(e);
          }
        },
        child: const Text('Отправить'),
      ),
    ]);
  }
}
