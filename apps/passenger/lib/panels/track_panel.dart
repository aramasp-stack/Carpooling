part of '../home.dart';

/// Слежение за машиной (симуляция: машина едет по линии маршрута без реального GPS).
extension TrackPanel on HomeState {
  Widget trackPanel(Trip trip, String? bookingId) {
    final g = geoms[trip.route.id];
    final b = bookingId == null ? null : bookingById(bookingId);
    if (g == null) return const SizedBox.shrink();
    double left(double d) => (d - simPos) / g.speed;
    final d = trip.driver;
    String eta, sub;
    if (b != null) {
      if (simPos < b.pickAlong - 10) {
        eta = 'Машина подъедет через ${minutesText(left(b.pickAlong))}';
        sub = '${d.car}, ${d.carColor}, ${d.plate}';
      } else if (simPos < b.dropAlong - 10) {
        eta = 'В пути: до места ${minutesText(left(b.dropAlong))}';
        sub = b.toName;
      } else {
        eta = 'Вы приехали';
        sub = b.toName;
      }
    } else {
      eta = simPos < g.length ? 'До «${trip.route.to.name}» ${minutesText(left(g.length))}' : 'Машина приехала: «${trip.route.to.name}»';
      sub = '${meters(simPos)} из ${meters(g.length)}';
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('Назад', onTap: pop),
      Text(trip.route.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const Text('Симуляция: машина едет по линии маршрута без реального GPS.', style: TextStyle(fontSize: 12, color: AppColors.muted)),
      const SizedBox(height: 10),
      Text(eta, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      Text(sub, style: const TextStyle(color: AppColors.muted)),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(value: simPos / g.length, minHeight: 6, color: _accent, backgroundColor: AppColors.surface),
      ),
      const SectionTitle('Скорость симуляции'),
      Wrap(spacing: 8, children: [
        for (final f in [1.0, 10.0, 30.0])
          ChoiceChip(label: Text('×${f.round()}'), selected: simFactor == f, onSelected: (_) => update(() => simFactor = f)),
      ]),
      if (simDone && b != null && b.status == BookingStatus.done) rating(b),
    ]);
  }
}
