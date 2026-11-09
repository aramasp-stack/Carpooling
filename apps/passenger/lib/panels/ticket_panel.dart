part of '../home.dart';

/// Билет: бронь, водитель, слежение за машиной, отмена, оценка.
extension TicketPanel on HomeState {
  Widget statusChip(Booking b) => switch (b.status) {
        BookingStatus.paid => const StatusChip('Оплачено'),
        BookingStatus.done => const StatusChip('Завершена', kind: StatusKind.done),
        BookingStatus.cancelled => StatusChip(b.refund > 0 ? 'Возврат ${amd(b.refund)}' : 'Отменено без возврата', kind: StatusKind.off),
      };

  Widget ticketPanel(String bookingId) {
    final b = bookingById(bookingId);
    final trip = b == null ? null : trips.tripById(b.tripId);
    if (b == null || trip == null) {
      return Column(children: [
        BackLink('Мои поездки', onTap: () => goTab(HomeTab.mine)),
        const Padding(padding: EdgeInsets.all(18), child: Text('Рейс больше не в расписании.')),
      ]);
    }
    final g = geoms[b.routeId];
    final pickAt = trips.timeAt(trip, b.pickAlong, g);
    final dropAt = trips.timeAt(trip, b.dropAlong, g);
    final minsLeft = pickAt.difference(trips.now).inMinutes;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('Мои поездки', onTap: () => goTab(HomeTab.mine)),
      Row(children: [
        Expanded(child: Text('Бронь ${b.id}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
        statusChip(b),
      ]),
      const SizedBox(height: 8),
      TwoPoints(from: b.fromName, fromTime: '≈ ${hhmm(pickAt)}', to: b.toName, toTime: '≈ ${hhmm(dropAt)}'),
      const SizedBox(height: 4),
      Text('${dayLabel(dayOffsetOf(trip.departure, now: trips.now))} · ${b.seatLabels.join(', ')} · ${amd(b.amount)}',
          style: const TextStyle(fontSize: 13, color: AppColors.muted)),
      DriverCard(trip.driver, color: Color(trip.route.color)),
      if (b.status == BookingStatus.paid) ...[
        const NoteBox('Телефон водителя появится в день поездки (в прототипе не показывается).'),
        FilledButton(onPressed: () => startSim(trip, b.id), child: const Text('Следить за машиной')),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => _cancel(b, pickAt),
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
          child: const Text('Отменить бронь'),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            minsLeft >= 60 ? 'Сейчас отмена бесплатная — деньги вернутся на карту.' : 'До посадки меньше 60 минут — при отмене деньги не возвращаются.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        ),
      ],
      if (b.status == BookingStatus.done) rating(b),
    ]);
  }

  Future<void> _cancel(Booking b, DateTime pickAt) async {
    final refund = refundFor(amount: b.amount, pickupTime: pickAt, now: trips.now);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Отменить бронь?'),
        content: Text(refund > 0 ? 'Вернём ${amd(refund)} на карту.' : 'До посадки меньше 60 минут. Деньги не вернутся.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Не отменять')),
          TextButton(onPressed: () => Navigator.pop(c, true), style: TextButton.styleFrom(foregroundColor: AppColors.danger), child: const Text('Отменить')),
        ],
      ),
    );
    if (ok != true) return;
    b
      ..status = BookingStatus.cancelled
      ..refund = refund;
    await data.updateBooking(b);
    if (!mounted) return;
    toast(context, refund > 0 ? 'Бронь отменена, деньги вернутся на карту (демо).' : 'Бронь отменена без возврата.');
    update(() {});
  }

  /// Оценка водителя после поездки. Водитель увидит её, когда тоже оценит поездку или через 14 дней.
  Widget rating(Booking b) {
    if (b.rating != null) {
      return Padding(padding: const EdgeInsets.only(top: 10), child: Text('Ваша оценка: ${'★' * b.rating!}', style: const TextStyle(color: AppColors.muted)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionTitle('Оцените водителя'),
      Row(children: [
        for (var n = 1; n <= 5; n++)
          IconButton(
            iconSize: 34,
            icon: const Icon(Icons.star_rounded, color: AppColors.star),
            onPressed: () async {
              b.rating = n;
              await data.updateBooking(b);
              if (mounted) toast(context, 'Спасибо за оценку!');
              update(() {});
            },
          ),
      ]),
      const Text('Водитель увидит оценку, когда тоже оценит поездку или через 14 дней.', style: TextStyle(fontSize: 12, color: AppColors.muted)),
    ]);
  }
}
