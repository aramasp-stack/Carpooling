part of '../home.dart';

/// Заработок: ждёт начисления (первые 24 часа после рейса), к выплате, выплачено; по каждому рейсу — разбивка.
extension MoneyScreen on DriverHomeState {
  /// Понедельник этой недели: выплата за всё, что начислено до него.
  DateTime _weekStart() {
    final d = dayStart(0, now: trips.now);
    return d.subtract(Duration(days: d.weekday - 1));
  }

  Widget moneyPanel() {
    final now = trips.now;
    final done = <Trip>[
      for (var d = -20; d <= 0; d++)
        for (final t in myTrips(d))
          if (statusOf(t) == TripStatus.finished && moneyOf(t).paid > 0) t,
    ]..sort((a, b) => b.departure.compareTo(a.departure));
    final week = _weekStart();
    var pending = 0, toPay = 0, paidOut = 0;
    for (final t in done) {
      final accrual = endOf(t).add(const Duration(hours: 24));
      final v = moneyOf(t).driver;
      if (accrual.isAfter(now)) {
        pending += v;
      } else if (accrual.isBefore(week)) {
        paidOut += v;
      } else {
        toPay += v;
      }
    }
    final card = me.payoutCard;
    final nextMonday = week.add(const Duration(days: 7));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.text, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('К выплате в понедельник, ${dateLong(nextMonday)}', style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13)),
          Text(amd(toPay), style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800)),
          Text(
            card == null
                ? 'Карта для выплат не привязана — деньги ждут'
                : '${card.brand} •••• ${card.last4}${card.activeFrom.isAfter(now) ? ' · заработает ${dateLong(card.activeFrom)} в ${hhmm(card.activeFrom)}' : ''}',
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _tile('Ждёт начисления', pending, 'первые 24 часа после рейса')),
        const SizedBox(width: 10),
        Expanded(child: _tile('Выплачено', paidOut, 'за прошлые недели')),
      ]),
      const NoteBox('Сутки после рейса — время на жалобы пассажиров. Потом доля начисляется, и раз в неделю приходит на карту.'),
      const SectionTitle('Рейсы', top: 4),
      if (done.isEmpty) const Text('Пока нет завершённых рейсов.', style: TextStyle(color: AppColors.muted)),
      for (final t in done) _tripMoney(t),
    ]);
  }

  Widget _tile(String title, int value, String note) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
          Text(amd(value), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          Text(note, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
        ]),
      );

  Widget _tripMoney(Trip t) {
    final m = moneyOf(t);
    final sold = t.seats.where((s) => s.taken).length;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text('${dateLong(t.departure)}, ${hhmm(t.departure)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(t.route.title, style: const TextStyle(fontSize: 12)),
      trailing: Text('+${amd(m.driver)}', style: const TextStyle(fontWeight: FontWeight.w700)),
      children: [
        moneyRow('Продано $sold ${plural(sold, 'место', 'места', 'мест')}', amd(m.paid)),
        moneyRow('Комиссия ${Demo.commissionPercent}%', '− ${amd(m.commission)}'),
        moneyRow('Госпошлина ${Demo.statePercent}%', '− ${amd(m.duty)}'),
        moneyRow('Вам', amd(m.driver), bold: true),
      ],
    );
  }
}
