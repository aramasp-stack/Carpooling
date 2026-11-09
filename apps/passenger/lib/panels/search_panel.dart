part of '../home.dart';

/// Поиск: «откуда» (обязательно) и «куда» (по желанию), маршруты рядом, водители на маршруте.
extension SearchPanel on HomeState {
  List<Place> localPlaces(String text) {
    final q = text.trim().toLowerCase();
    if (q.isEmpty) return Demo.places.take(5).toList();
    return Demo.places.where((p) => p.name.toLowerCase().contains(q)).take(6).toList();
  }

  Widget searchPanel() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _whereBox(),
          if (suggestions.isNotEmpty) _suggestBox(),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ActionChip(avatar: const Icon(Icons.my_location, size: 16), label: const Text('Я здесь'), onPressed: locateMe),
            _pickChip('from', 'Откуда на карте'),
            _pickChip('to', 'Куда на карте'),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (var d = 0; d < 3; d++)
              ChoiceChip(
                label: Text(dayLabel(d)),
                selected: day == d,
                onSelected: (_) => update(() => day = d),
              ),
          ]),
          const SizedBox(height: 6),
          _results(),
          if (!hasMapkitKey)
            const NoteBox('Ключ Яндекс MapKit не задан: карта не показывается, маршруты считаются по прямой. Остальное работает.'),
        ],
      );

  Widget _pickChip(String which, String label) => FilterChip(
        avatar: const Icon(Icons.place_outlined, size: 16),
        label: Text(label),
        selected: pick == which,
        showCheckmark: false,
        onSelected: (_) {
          update(() => pick = pick == which ? null : which);
          if (pick != null) toast(context, which == 'from' ? 'Нажмите на карту, откуда поедете' : 'Нажмите на карту, куда поедете');
        },
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
            hintText: which == 'from' ? 'Откуда поедете?' : 'Куда — можно не указывать',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            isDense: true,
          ),
          onTap: () => update(() {
            suggestFor = which;
            suggestions = localPlaces(ctl.text);
          }),
          onChanged: (t) => update(() {
            suggestFor = which;
            suggestions = localPlaces(t);
          }),
        ),
      ),
      if (value != null)
        IconButton(
          icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
          onPressed: () => setPlace(which, null),
          visualDensity: VisualDensity.compact,
        ),
    ]);
  }

  Widget _whereBox() => Container(
        padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
        decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Expanded(child: Column(children: [_whereRow('from'), const Divider(height: 1), _whereRow('to')])),
          IconButton(
            tooltip: 'Поменять местами',
            icon: const Icon(Icons.swap_vert, color: AppColors.muted),
            onPressed: () {
              final f = from, t = to;
              setPlace('from', t);
              setPlace('to', f);
            },
          ),
        ]),
      );

  Widget _suggestBox() => Container(
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(14)),
        child: Column(children: [
          for (final p in suggestions)
            ListTile(
              dense: true,
              leading: const Icon(Icons.place_outlined, size: 20),
              title: Text(p.name),
              onTap: () => setPlace(suggestFor ?? 'from', p),
            ),
        ]),
      );

  Widget _results() {
    if (from == null) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: _accent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
        child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.place, color: _accent),
          SizedBox(width: 10),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: 'Откуда поедете?\n', style: TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(
                text: 'Укажите место, точку на карте или нажмите «Я здесь» — покажем маршруты рядом. «Куда» можно добавить, чтобы остался один подходящий маршрут.',
                style: TextStyle(fontSize: 13, color: AppColors.muted),
              ),
            ])),
          ),
        ]),
      );
    }
    if (loading) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    final m = matches;
    final active = activeOf(m);
    if (active != null) return _drivers(active, m.length);
    if (m.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Text(
          'Рядом с этой точкой нет маршрутов${to != null ? ' в нужную сторону' : ''}. Попробуйте другую точку или посмотрите вкладку «Маршруты».',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.muted),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Маршруты рядом: ${m.length}', top: 10),
      for (final x in m) _routeCard(x),
    ]);
  }

  String _walk(RouteMatch m) => m.pick.distance < 120 ? 'начинается рядом' : 'до маршрута ${meters(m.pick.distance)} пешком';

  Widget _routeCard(RouteMatch m) {
    final n = driversFor(m).where((x) => x.trip.freeCount > 0).length;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.line)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Swatch(Color(m.route.color)),
        minLeadingWidth: 12,
        title: Text(m.route.title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${_walk(m)} · в пути ~${minutesText(m.geometry.durationSec)}\n'
            '${n > 0 ? '$n ${plural(n, 'водитель', 'водителя', 'водителей')} · ${dayLabel(day).toLowerCase()}' : 'свободных мест нет'}'),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          update(() => routeId = m.route.id);
          syncMap();
        },
      ),
    );
  }

  Widget _drivers(RouteMatch m, int total) {
    final list = driversFor(m);
    final g = m.geometry;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (to == null && total > 1)
        BackLink('Все маршруты рядом', onTap: () {
          update(() => routeId = null);
          syncMap();
        }),
      Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: Color(m.route.color), width: 4), top: const BorderSide(color: AppColors.line), right: const BorderSide(color: AppColors.line), bottom: const BorderSide(color: AppColors.line)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.route.title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(
            '${m.pick.distance < 120 ? 'маршрут начинается рядом' : 'до маршрута ${meters(m.pick.distance)} пешком'}'
            '${m.drop != null && m.drop!.distance >= 120 ? ' · от маршрута до места ${meters(m.drop!.distance)}' : ''}',
            style: const TextStyle(fontSize: 13, color: AppColors.muted),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 12, children: [
            Text('в пути ~${minutesText(g.durationSec)}', style: const TextStyle(fontSize: 13)),
            Text(meters(g.length), style: const TextStyle(fontSize: 13, color: AppColors.muted)),
            if (g.trafficSec != null)
              Text('сейчас с пробками ${minutesText(g.trafficSec!)}', style: const TextStyle(fontSize: 13, color: AppColors.traffic)),
          ]),
        ]),
      ),
      SectionTitle('Водители · ${dayLabel(day).toLowerCase()}'),
      if (list.isEmpty)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('На этот день рейсов больше нет. Выберите другой день.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
        ),
      for (final x in list) _driverRow(m, x.trip, x.at),
    ]);
  }

  Widget _driverRow(RouteMatch m, Trip trip, DateTime at) {
    final d = trip.driver;
    final free = trip.freeCount;
    return Opacity(
      opacity: free > 0 ? 1 : 0.5,
      child: Card(
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.line)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: free > 0 ? () => push(CarPane(m, trip)) : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              CircleAvatar(backgroundColor: Color(m.route.color), child: Text(d.name[0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(text: d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    TextSpan(text: '  ★ ${d.rating}', style: const TextStyle(fontSize: 13)),
                    if (d.verified) const TextSpan(text: '  ✓', style: TextStyle(color: _accent, fontWeight: FontWeight.w700)),
                  ])),
                  Text('${d.car}, ${d.carColor}', style: const TextStyle(fontSize: 13, color: AppColors.muted)),
                  Text(
                    free > 0 ? 'свободно $free ${plural(free, 'место', 'места', 'мест')}' : 'мест нет',
                    style: TextStyle(fontSize: 13, color: free > 0 ? AppColors.ok : AppColors.danger),
                  ),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(hhmm(at), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                if (trip.minPrice != null) Text('от ${amd(trip.minPrice!)}', style: const TextStyle(fontSize: 13)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
