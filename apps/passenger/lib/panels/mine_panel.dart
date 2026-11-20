part of '../home.dart';

/// Мои поездки: брони пассажира с сервера, профиль, карты, выход.
extension MinePanel on HomeState {
  Widget minePanel() {
    final now = trips.now;
    final list = repo.mine;
    final upcoming = [for (final m in list) if (m.booking.status == BookingStatus.paid && m.trip.departure.isAfter(now.subtract(const Duration(hours: 2)))) m]
      ..sort((a, b) => a.trip.departure.compareTo(b.trip.departure));
    final past = [for (final m in list) if (!upcoming.contains(m)) m];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Мои поездки', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      if (list.isEmpty)
        const Padding(
          padding: EdgeInsets.all(18),
          child: Text('Пока нет броней. Найдите поездку на вкладке «Поиск».', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
        ),
      if (upcoming.isNotEmpty) ...[
        const SectionTitle('Предстоящие', top: 4),
        for (final m in upcoming) _bookingItem(m),
      ],
      if (past.isNotEmpty) ...[
        const SectionTitle('История'),
        for (final m in past) _bookingItem(m),
      ],
      _profileBox(),
    ]);
  }

  Widget _bookingItem(MyBooking m) {
    final b = m.booking, at = m.trip.departure;
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
              Expanded(child: Text('${hhmm(at)} · ${dateLong(at)}', style: const TextStyle(fontWeight: FontWeight.w700))),
              statusChip(b),
            ]),
            const SizedBox(height: 4),
            Text('${b.fromName} → ${b.toName}'),
            Text(
              '${m.trip.driver.name}, ${m.trip.driver.car} · ${b.seatLabels.join(', ')} · ${amd(b.amount)}',
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ]),
        ),
      ),
    );
  }

  /// Профиль: имя, телефон, карты, выход.
  Widget _profileBox() {
    final p = repo.profile;
    return Container(
      margin: const EdgeInsets.only(top: 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.person_outline, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(p == null ? 'Профиль' : '${p.name} · +${p.phone.replaceAll('+', '')}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          TextButton(onPressed: widget.onSignOut, child: const Text('Выйти')),
        ]),
        const SizedBox(height: 6),
        const Text('Карты для оплаты', style: TextStyle(fontSize: 13, color: AppColors.muted)),
        for (final c in repo.cards)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              const Icon(Icons.credit_card, size: 18),
              const SizedBox(width: 8),
              Text(c.title),
            ]),
          ),
        if (repo.cards.length < 5)
          TextButton.icon(
            onPressed: () async {
              final id = await addCardDialog(context, repo);
              if (id != null && mounted) toast(context, 'Карта привязана.');
            },
            icon: const Icon(Icons.add),
            label: const Text('Привязать карту'),
          ),
      ]),
    );
  }
}
