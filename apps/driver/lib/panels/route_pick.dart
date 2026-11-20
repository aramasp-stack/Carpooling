part of '../home.dart';

/// Новый рейс, шаг 1: маршрут — как поиск у пассажира. Поле «Откуда», под ним маршруты, которые начинаются рядом.
/// Сверху — «Мои маршруты». Подходящего нет — «Предложить маршрут».
extension RoutePick on DriverHomeState {
  /// Маршруты, у которых начальный район рядом с точкой. Ближние — первыми.
  List<({RouteDef route, double distance})> routesNear(GeoPoint p) {
    final out = <({RouteDef route, double distance})>[];
    for (final r in Demo.routes) {
      final d = distanceMeters(p, r.from.point);
      if (d <= Demo.startDistrictMeters + 500) out.add((route: r, distance: d));
    }
    out.sort((a, b) => a.distance.compareTo(b.distance));
    return out;
  }

  /// Маршруты, по которым водитель уже ездил или ставил рейсы.
  List<RouteDef> myRoutes() {
    final ids = <String>{};
    for (var d = 0; d >= -14 && ids.length < 3; d--) {
      for (final t in myTrips(d)) {
        if (ids.length < 3) ids.add(t.route.id);
      }
    }
    return [for (final id in ids) Demo.routeById(id)!];
  }

  Widget routePickPanel() {
    final q = fromCtl.text.trim().toLowerCase();
    final suggestions = from != null && !fromSuggest
        ? const <Place>[]
        : (q.isEmpty ? Demo.places.take(6) : Demo.places.where((p) => p.name.toLowerCase().contains(q)).take(6)).toList();
    final mine = myRoutes();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('Мои рейсы', onTap: pop),
      const Text('Новый рейс: маршрут', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      if (pickOnMap)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          decoration: BoxDecoration(color: _accent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Icon(Icons.touch_app_outlined, color: _accent),
            const SizedBox(width: 10),
            const Expanded(child: Text('Нажмите на карту, откуда начинаете', style: TextStyle(fontWeight: FontWeight.w600))),
            TextButton(onPressed: () => update(() => pickOnMap = false), child: const Text('Отмена')),
          ]),
        ),
      Container(
        padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
        decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(16)),
        child: Column(children: [
          Row(children: [
            const Swatch(AppColors.from, size: 10),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: fromCtl,
                decoration: const InputDecoration(
                  hintText: 'Откуда начинаете? Район или место',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                ),
                onTap: () {
                  if (fromSuggest) {
                    update(() => fromSuggest = false);
                    return;
                  }
                  update(() {
                    fromSuggest = true;
                    if (from != null) fromCtl.selection = TextSelection(baseOffset: 0, extentOffset: fromCtl.text.length);
                  });
                },
                onChanged: (_) => update(() => fromSuggest = true),
              ),
            ),
            if (from != null)
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
                visualDensity: VisualDensity.compact,
                onPressed: () => _setFrom(null),
              ),
            IconButton(
              tooltip: 'Я здесь',
              icon: const Icon(Icons.my_location, size: 22, color: _accent),
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                final p = await position();
                if (!mounted) return;
                if (p == null || distanceMeters(p, Demo.yerevanCenter) > 40000) {
                  toast(context, 'Местоположение недоступно или вы далеко от Еревана. Выберите место из списка или на карте.');
                  return;
                }
                _setFrom(Place('Я здесь', p));
              },
            ),
            IconButton(
              tooltip: 'Выбрать на карте',
              icon: const Icon(Icons.map_outlined, size: 22, color: _accent),
              visualDensity: VisualDensity.compact,
              onPressed: () => update(() {
                pickOnMap = true;
                fromSuggest = false;
              }),
            ),
          ]),
          if (fromSuggest && suggestions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 10, 8),
              child: Column(children: [
                for (final p in suggestions)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.place_outlined, size: 20),
                    title: Text(p.name),
                    onTap: () => _setFrom(p),
                  ),
              ]),
            ),
        ]),
      ),
      if (mine.isNotEmpty) ...[
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

  void _setFrom(Place? p) {
    update(() {
      from = p;
      fromCtl.text = p?.name ?? '';
      fromSuggest = false;
      pickOnMap = false;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    syncMap();
  }

  List<Widget> _routeList() {
    if (from == null) {
      return [
        const SectionTitle('Все маршруты'),
        for (final r in Demo.routes) _routeCard(r, null),
      ];
    }
    final near = routesNear(from!.point);
    if (near.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.all(18),
          child: Text('Рядом маршрутов нет. Выберите другое место или предложите новый маршрут.',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
        ),
      ];
    }
    return [
      SectionTitle('Начинаются рядом: ${near.length}'),
      for (final x in near) _routeCard(x.route, x.distance),
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
                  'цена места от ${amd(r.minPrice)}',
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
    final f = widget.home.from;
    if (f != null && f.name != 'Точка на карте' && f.name != 'Я здесь') fromCtl.text = f.name;
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
