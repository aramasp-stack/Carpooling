part of '../home.dart';

/// «Мои рейсы»: только рейсы, на которые водитель записался сам, по дням.
extension TripsPanel on DriverHomeState {
  Widget tripsPanel() {
    final list = myTrips(day);
    final any = [for (var d = -1; d < 7; d++) ...myTrips(d)].isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Expanded(child: Text('Мои рейсы', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700))),
        TextButton.icon(
          onPressed: () => goTab(DriverTab.routes),
          icon: const Icon(Icons.add),
          label: const Text('Новый рейс'),
        ),
      ]),
      const SizedBox(height: 6),
      if (!any)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _accent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('У вас пока нет рейсов.', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            const Text('Найдите маршрут рядом с собой и запишитесь на рейс: выберите время, место посадки и цены мест.',
                style: TextStyle(fontSize: 13, color: AppColors.muted)),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => goTab(DriverTab.routes),
              icon: const Icon(Icons.search),
              label: const Text('Найти маршрут'),
            ),
          ]),
        )
      else ...[
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (var d = -1; d < 7; d++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(d == -1 ? 'Вчера' : dayLabel(d)),
                  selected: day == d,
                  onSelected: (_) => update(() => day = d),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.all(18),
            child: Text('На этот день рейсов нет.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
          ),
        for (final t in list) _tripItem(t),
      ],
    ]);
  }

  /// «у начала маршрута» или «в 400 м от «Давташен»».
  String meetText(Trip t) => t.meetAlong < 50 ? 'в начале маршрута, «${t.route.from.name}»' : 'в ${meters(t.meetAlong)} от «${t.route.from.name}»';

  Widget _tripItem(Trip t) {
    final taken = t.seats.where((s) => s.taken).length;
    final status = statusOf(t);
    final gone = missed(t);
    return Opacity(
      opacity: gone ? 0.6 : 1,
      child: outlined(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Swatch(Color(t.route.color)),
            const SizedBox(width: 8),
            Text(hhmm(t.departure), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const Spacer(),
            StatusChip(tripLabel(t), kind: gone ? StatusKind.off : (status == TripStatus.finished ? StatusKind.done : StatusKind.ok)),
          ]),
          const SizedBox(height: 2),
          Text(t.route.title),
          const SizedBox(height: 8),
          if (gone)
            const Text('Вы не начали рейс вовремя. Пассажирам вернули деньги.', style: TextStyle(fontSize: 13, color: AppColors.muted))
          else
            Row(children: [
              for (final s in t.seats)
                Container(
                  width: 11,
                  height: 11,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(color: s.taken ? _accent : AppColors.line, borderRadius: BorderRadius.circular(3)),
                ),
              const SizedBox(width: 6),
              Text(taken == 0 ? 'мест пока не купили' : 'куплено $taken из ${t.seats.length}', style: const TextStyle(fontSize: 13)),
              const Spacer(),
              if (taken > 0) Text('вам ${amd(moneyOf(t).driver)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
        ]),
        onTap: () => push(TripPane(t.id)),
      ),
    );
  }
}
