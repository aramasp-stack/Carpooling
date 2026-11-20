part of '../home.dart';

/// Главная: рейс на сегодня крупно, кнопка «Новый рейс», рейсы по дням.
extension TripsPanel on DriverHomeState {
  Widget tripsPanel() {
    final list = myTrips(day);
    final next = myTrips(0).where((t) => statusOf(t) != TripStatus.finished).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (next != null) _todayCard(next) else _noTripToday(),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: () => push(RoutePickPane()),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        icon: const Icon(Icons.add),
        label: const Text('Новый рейс', style: TextStyle(fontSize: 16)),
      ),
      const SizedBox(height: 12),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (var d = 0; d < 7; d++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(label: Text(dayLabel(d)), selected: day == d, onSelected: (_) => update(() => day = d)),
            ),
        ]),
      ),
      const SizedBox(height: 10),
      if (list.isEmpty)
        const Padding(
          padding: EdgeInsets.all(18),
          child: Text('На этот день рейсов нет. Нажмите «Новый рейс».', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
        ),
      for (final t in list) _tripItem(t),
    ]);
  }

  Widget _noTripToday() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: _accent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
        child: Text('Здравствуйте, ${_demo.name}! На сегодня рейсов больше нет.', style: const TextStyle(fontWeight: FontWeight.w600)),
      );

  /// Ближайший рейс сегодня: время, место посадки, сколько продано и на какую сумму.
  Widget _todayCard(Trip t) {
    final sold = t.seats.where((s) => s.taken).length;
    final status = statusOf(t);
    final money = moneyOf(t);
    return Material(
      color: _accent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => push(TripPane(t.id)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(status == TripStatus.started ? 'Сейчас в пути' : 'Ближайший рейс сегодня',
                style: const TextStyle(color: Color(0xFFCCFBF1), fontSize: 13)),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(hhmm(t.departure), style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800)),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(t.route.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
            Text('Посадка: ${meetText(t)}', style: const TextStyle(color: Color(0xFFCCFBF1), fontSize: 13)),
            const SizedBox(height: 8),
            Row(children: [
              Text('Продано $sold из ${t.seats.length} · ${amd(money.paid)}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (canStart(t) && status == TripStatus.planned)
                const Text('Можно начинать →', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))
              else
                const Icon(Icons.chevron_right, color: Colors.white),
            ]),
          ]),
        ),
      ),
    );
  }

  /// «у начала маршрута» или «в 400 м от «Давташен»».
  String meetText(Trip t) => t.meetAlong < 50 ? 'в начале маршрута, «${t.route.from.name}»' : 'в ${meters(t.meetAlong)} от «${t.route.from.name}»';

  Widget _tripItem(Trip t) {
    final taken = t.seats.where((s) => s.taken).length;
    final status = statusOf(t);
    return outlined(
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
          Text('продано $taken из ${t.seats.length}', style: const TextStyle(fontSize: 13)),
          const Spacer(),
          Text('вам ${amd(moneyOf(t).driver)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      ]),
      onTap: () => push(TripPane(t.id)),
    );
  }
}
