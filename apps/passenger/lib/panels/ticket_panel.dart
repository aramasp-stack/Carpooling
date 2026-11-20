part of '../home.dart';

/// Короткий номер брони для человека: первые 8 знаков.
String bookingNo(String id) => id.replaceAll('-', '').substring(0, 8).toUpperCase();

/// Билет: бронь, водитель, слежение за машиной, отмена, оценка.
extension TicketPanel on HomeState {
  Widget statusChip(Booking b) => switch (b.status) {
        BookingStatus.paid => const StatusChip('Оплачено'),
        BookingStatus.done => const StatusChip('Завершена', kind: StatusKind.done),
        BookingStatus.cancelled => StatusChip(b.refund > 0 ? 'Возврат ${amd(b.refund)}' : 'Отменено без возврата', kind: StatusKind.off),
      };

  Widget ticketPanel(String bookingId) {
    final mb = repo.bookingById(bookingId);
    if (mb == null) {
      return Column(children: [
        BackLink('Мои поездки', onTap: () => goTab(HomeTab.mine)),
        const Padding(padding: EdgeInsets.all(18), child: Text('Бронь не найдена.')),
      ]);
    }
    final b = mb.booking, trip = mb.trip;
    final g = geoms[b.routeId];
    final pickAt = trip.departure;
    final dropAt = trips.timeAt(trip, g == null ? trip.meetAlong : trip.dropOn(g.length), g);
    final minsLeft = pickAt.difference(trips.now).inMinutes;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('Мои поездки', onTap: () => goTab(HomeTab.mine)),
      Row(children: [
        Expanded(child: Text('Бронь ${bookingNo(b.id)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
        statusChip(b),
      ]),
      const SizedBox(height: 8),
      TwoPoints(from: '${b.fromName}, место посадки', fromTime: hhmm(pickAt), to: b.toName, toTime: '≈ ${hhmm(dropAt)}'),
      const Text('Место посадки — синяя точка на карте. Водитель отправляется по расписанию.',
          style: TextStyle(fontSize: 13, color: AppColors.muted)),
      const SizedBox(height: 4),
      Text('${dayLabel(dayOffsetOf(trip.departure, now: trips.now), now: trips.now)} · ${b.seatLabels.join(', ')} · ${amd(b.amount)}',
          style: const TextStyle(fontSize: 13, color: AppColors.muted)),
      DriverCard(trip.driver, color: Color(trip.route.color)),
      if (b.status == BookingStatus.paid) ...[
        const NoteBox('Звонок водителю — внутри приложения, без показа номеров (появится позже).'),
        FilledButton(onPressed: () => startSim(trip, b.id), child: const Text('Показать путь машины')),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => _cancel(b, pickAt),
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
          child: const Text('Отменить бронь'),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            minsLeft >= 60 ? 'Сейчас отмена бесплатная — деньги вернутся на карту.' : 'До отправления меньше 60 минут — при отмене деньги не возвращаются.',
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
        content: Text(refund > 0 ? 'Вернём ${amd(refund)} на карту.' : 'До отправления меньше 60 минут. Деньги не вернутся.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Не отменять')),
          TextButton(onPressed: () => Navigator.pop(c, true), style: TextButton.styleFrom(foregroundColor: AppColors.danger), child: const Text('Отменить')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      // Сколько вернуть, решает сервер по своим часам.
      final returned = await repo.cancel(b.id);
      if (!mounted) return;
      toast(context, returned > 0 ? 'Бронь отменена. ${amd(returned)} вернутся на карту.' : 'Бронь отменена без возврата.');
    } on ServerError catch (e) {
      if (mounted) toast(context, e.text);
    }
    syncMap(refit: false);
  }

  /// Оценка водителя после поездки. Водитель не видит, кто какую оценку поставил.
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
              try {
                await repo.rate(b.id, n);
                if (mounted) toast(context, 'Спасибо за оценку!');
              } on ServerError catch (e) {
                if (mounted) toast(context, e.text);
              }
            },
          ),
      ]),
      const Text('Водитель не узнает, кто поставил оценку.', style: TextStyle(fontSize: 12, color: AppColors.muted)),
    ]);
  }
}
