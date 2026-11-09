part of '../home.dart';

/// Мои поездки: все брони пассажира.
extension MinePanel on HomeState {
  Widget minePanel() {
    final list = data.bookings();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Мои поездки', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      if (list.isEmpty)
        const Padding(
          padding: EdgeInsets.all(18),
          child: Text('Пока нет броней. Найдите поездку на вкладке «Поиск».', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
        ),
      for (final b in list) _bookingItem(b),
    ]);
  }

  Widget _bookingItem(Booking b) {
    final trip = trips.tripById(b.tripId);
    final at = trip == null ? null : trips.timeAt(trip, b.pickAlong, geoms[b.routeId]);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => push(TicketPane(b.id)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(at == null ? 'Бронь ${b.id}' : '${hhmm(at)} · ${dateLong(at)}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              statusChip(b),
            ]),
            const SizedBox(height: 4),
            Text('${b.fromName} → ${b.toName}'),
            Text(
              '${trip == null ? '' : '${trip.driver.name}, ${trip.driver.car} · '}${b.seatLabels.join(', ')} · ${amd(b.amount)}',
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ]),
        ),
      ),
    );
  }
}
