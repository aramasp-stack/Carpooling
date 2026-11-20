part of '../home.dart';

/// Рейс: пассажиры (сел / не пришёл, звонок, оценка, блокировка), деньги, начать / завершить / отменить / повторить.
extension TripScreen on DriverHomeState {
  Widget tripPanel(String id) {
    final t = tripOf(id);
    if (t == null || me.cancelledTrips.contains(id)) return BackLink('Мои рейсы', onTap: () => goTab(DriverTab.trips));
    if (missed(t)) return _missedPanel(t);
    final status = statusOf(t);
    final marks = data.boarding(t.id);
    final taken = t.seats.where((s) => s.taken).toList();
    final money = moneyOf(t);
    final early = status == TripStatus.planned && trips.now.isBefore(t.departure.subtract(const Duration(minutes: 15)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('Мои рейсы', onTap: pop),
      Row(children: [
        Expanded(
          child: Text('${hhmm(t.departure)} · ${dayLabel(dayOffsetOf(t.departure, now: trips.now))}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        ),
        StatusChip(statusText(status), kind: status == TripStatus.finished ? StatusKind.done : StatusKind.ok),
      ]),
      const SizedBox(height: 6),
      TwoPoints(from: t.route.from.name, fromTime: hhmm(t.departure), to: t.route.to.name, toTime: '≈ ${hhmm(endOf(t))}'),
      const SizedBox(height: 4),
      Row(children: [
        const Icon(Icons.place, size: 16, color: Color(0xFF2563EB)),
        const SizedBox(width: 4),
        Expanded(child: Text('Посадка ${meetText(t)}', style: const TextStyle(fontSize: 13))),
      ]),
      SectionTitle('Пассажиры · ${taken.length} из ${t.seats.length}'),
      if (taken.isEmpty) const Text('Пока никто не купил место.', style: TextStyle(color: AppColors.muted)),
      // Пока приложения не связаны через сервер, покупки пассажиров в модели изображает эта кнопка.
      if (status == TripStatus.planned && taken.length < t.seats.length)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => sellDemoSeats(t),
            icon: const Icon(Icons.person_add_alt, size: 18),
            label: const Text('Демо: пассажиры покупают места'),
          ),
        ),
      for (final s in taken) _paxRow(t, s, marks[s.id], status, early),
      for (final s in t.seats.where((s) => !s.taken))
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(14)),
          child: Text('${s.label} — свободно · ${amd(s.price)}', style: const TextStyle(color: AppColors.muted)),
        ),
      // Деньги — только когда места уже купили: нули ни о чём не говорят.
      if (taken.isNotEmpty) Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          moneyRow('Оплатили пассажиры', amd(money.paid), bold: true),
          moneyRow('Комиссия сервиса ${Demo.commissionPercent}%', '− ${amd(money.commission)}'),
          moneyRow('Госпошлина ${Demo.statePercent}%', '− ${amd(money.duty)}'),
          moneyRow(status == TripStatus.finished ? 'Вам (начислим через 24 часа)' : 'Вам', amd(money.driver), bold: true),
        ]),
      ),
      ..._actions(t, status),
    ]);
  }

  /// Рейс не начали до конца его времени: он не состоялся, деньги пассажирам вернули. Можно убрать из списка.
  Widget _missedPanel(Trip t) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        BackLink('Мои рейсы', onTap: pop),
        Row(children: [
          Expanded(
            child: Text('${hhmm(t.departure)} · ${dayLabel(dayOffsetOf(t.departure, now: trips.now))}',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ),
          const StatusChip('Не состоялся', kind: StatusKind.off),
        ]),
        const SizedBox(height: 6),
        Text(t.route.title),
        const SizedBox(height: 10),
        NoteBox('Рейс не начали до ${hhmm(endOf(t))} — он не состоялся. '
            '${t.seats.any((s) => s.taken) ? 'Пассажирам вернули деньги полностью, в заработок он не входит.' : 'Мест никто не купил.'}'),
        OutlinedButton.icon(
          onPressed: () async {
            await removeTrip(t);
            if (!mounted) return;
            toast(context, 'Рейс убран из списка.');
            goTab(DriverTab.trips);
          },
          icon: const Icon(Icons.delete_outline),
          label: const Text('Убрать из списка'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => push(NewTripPane(t.route, template: t)),
          icon: const Icon(Icons.replay),
          label: const Text('Поставить такой же рейс'),
        ),
      ]);

  List<Widget> _actions(Trip t, TripStatus status) => switch (status) {
        TripStatus.planned => [
            if (canStart(t))
              FilledButton(onPressed: () => startDrive(t), child: const Text('Начать рейс'))
            else ...[
              FilledButton(
                onPressed: null,
                child: Text(trips.now.isAfter(endOf(t)) ? 'Время рейса прошло' : 'Начать можно с ${hhmm(t.departure.subtract(const Duration(minutes: 15)))}'),
              ),
              TextButton(onPressed: () => startDrive(t), child: const Text('Демо: начать сейчас')),
            ],
            const SizedBox(height: 8),
            _navButton(t),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _confirmCancel(t),
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
              child: const Text('Отменить рейс'),
            ),
          ],
        TripStatus.started => [
            FilledButton(onPressed: () => startDrive(t), child: const Text('К поездке')),
            const SizedBox(height: 8),
            if (canFinish(t))
              OutlinedButton(onPressed: () => finishTrip(t), child: const Text('Завершить рейс'))
            else ...[
              OutlinedButton(onPressed: null, child: Text('Завершить можно с ${hhmm(t.departure)}')),
              TextButton(onPressed: () => finishTrip(t), child: const Text('Демо: завершить сейчас')),
            ],
            const SizedBox(height: 8),
            _navButton(t),
          ],
        TripStatus.finished => [
            const NoteBox('Рейс завершён. Оцените пассажиров: «⋮» справа от имени.'),
            OutlinedButton.icon(
              onPressed: () => push(NewTripPane(t.route, template: t)),
              icon: const Icon(Icons.replay),
              label: const Text('Повторить рейс'),
            ),
          ],
      };

  Widget _navButton(Trip t) {
    final g = geoOf(t.route);
    final meet = g.pointAt(t.meetAlong);
    return OutlinedButton.icon(
      onPressed: () => launchUrl(
        Uri.parse('https://yandex.ru/maps/?rtext=${meet.lat},${meet.lon}~${t.route.to.point.lat},${t.route.to.point.lon}&rtt=auto'),
        mode: LaunchMode.externalApplication,
      ),
      icon: const Icon(Icons.navigation_outlined),
      label: const Text('Маршрут в Яндекс Картах'),
    );
  }

  Widget _paxRow(Trip t, Seat s, Boarding? mark, TripStatus status, bool early) {
    final name = s.passenger ?? 'Пассажир';
    final blocked = me.isBlocked(name);
    final rated = me.ratingOf(t.id, s.id);
    final canMark = status == TripStatus.started || (status == TripStatus.planned && !early);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
      decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        CircleAvatar(radius: 18, backgroundColor: blocked ? AppColors.danger : AppColors.muted, child: Text(name[0], style: const TextStyle(color: Colors.white))),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(
              [
                s.label,
                if (rated != null) 'ваша оценка ${'★' * rated}',
                if (blocked) 'заблокирован',
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: blocked ? AppColors.danger : AppColors.muted),
            ),
          ]),
        ),
        if (status != TripStatus.finished) ...[
          _markButton(t.id, s.id, Boarding.boarded, 'Сел', mark, AppColors.ok, canMark),
          _markButton(t.id, s.id, Boarding.noShow, 'Нет', mark, AppColors.danger, canMark),
          IconButton(
            icon: const Icon(Icons.call_outlined),
            onPressed: () => toast(context, 'Звонок внутри приложения: ни вы, ни пассажир не видите номеров друг друга. В модели — без звонка.'),
          ),
        ] else if (mark != null)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(mark == Boarding.boarded ? 'сел' : 'не пришёл',
                style: TextStyle(fontSize: 12, color: mark == Boarding.boarded ? AppColors.ok : AppColors.danger)),
          ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (v) => switch (v) {
            'rate' => _rateDialog(t, s, name),
            'block' => _blockDialog(name),
            'unblock' => _unblock(name),
            _ => null,
          },
          itemBuilder: (_) => [
            if (status == TripStatus.finished && rated == null) const PopupMenuItem(value: 'rate', child: Text('Оценить пассажира')),
            if (!blocked) const PopupMenuItem(value: 'block', child: Text('Заблокировать')) else const PopupMenuItem(value: 'unblock', child: Text('Разблокировать')),
          ],
        ),
      ]),
    );
  }

  Widget _markButton(String tripId, String seatId, Boarding value, String label, Boarding? current, Color color, bool enabled) {
    final on = current == value;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: OutlinedButton(
        onPressed: !enabled
            ? null
            : () async {
                await data.setBoarding(tripId, seatId, value);
                update(() {});
              },
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          backgroundColor: on ? color.withValues(alpha: 0.12) : null,
          foregroundColor: on ? color : AppColors.text,
          side: BorderSide(color: on ? color : AppColors.line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Future<void> _rateDialog(Trip t, Seat s, String name) async {
    final stars = await showDialog<int>(
      context: context,
      builder: (c) {
        var v = 5;
        return StatefulBuilder(
          builder: (c, set) => AlertDialog(
            title: Text('Оценка: $name'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    onPressed: () => set(() => v = i),
                    icon: Icon(i <= v ? Icons.star : Icons.star_border, color: AppColors.star, size: 32),
                  ),
              ]),
              const Text('Пассажир не узнает, кто какую оценку поставил: он видит только свой общий рейтинг.',
                  style: TextStyle(fontSize: 12, color: AppColors.muted)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
              FilledButton(onPressed: () => Navigator.pop(c, v), child: const Text('Оценить')),
            ],
          ),
        );
      },
    );
    if (stars == null) return;
    try {
      await me.rate(t.id, s.id, stars);
      update(() {});
    } catch (e) {
      showError(e);
    }
  }

  Future<void> _blockDialog(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Заблокировать: $name?'),
        content: const Text(
            'Пассажир больше не увидит ваших рейсов и не сможет их купить. Ему об этом не сообщается.\n\n'
            'Места, которые он уже оплатил, остаются за ним: отказать после оплаты можно только через поддержку.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Заблокировать'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await me.block(name);
    update(() {});
    if (mounted) toast(context, '$name заблокирован. Разблокировать можно в профиле.');
  }

  Future<void> _unblock(String name) async {
    await me.unblock(name);
    update(() {});
  }

  Future<void> _confirmCancel(Trip t) async {
    final n = t.seats.where((s) => s.taken).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Отменить рейс?'),
        content: Text(n == 0
            ? 'Место ещё никто не купил.'
            : 'У $n ${plural(n, 'пассажира', 'пассажиров', 'пассажиров')} будет полный возврат денег. Частые отмены видны поддержке.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Не отменять')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Отменить рейс'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await removeTrip(t);
    if (!mounted) return;
    toast(context, n == 0 ? 'Рейс отменён.' : 'Рейс отменён, пассажирам вернём деньги.');
    goTab(DriverTab.trips);
  }

  // ---------- поездка ----------
  Widget drivePanel(String id) {
    final t = tripOf(id);
    if (t == null) return const SizedBox.shrink();
    final g = geoOf(t.route);
    final toMeet = t.meetAlong - simPos;
    final eta = toMeet > 20 ? 'До места посадки ${minutesText(toMeet / g.speed)}' : 'До финиша ${minutesText((g.length - simPos) / g.speed)}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('К рейсу', onTap: pop),
      Text(t.route.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const Text('Симуляция: машина едет по маршруту без настоящего GPS.', style: TextStyle(fontSize: 12, color: AppColors.muted)),
      const SizedBox(height: 10),
      Text(eta, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      Text(toMeet > 20 ? 'Посадка ${meetText(t)}' : 'Высадка всех пассажиров: «${t.route.to.name}»', style: const TextStyle(color: AppColors.muted)),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(value: simPos / g.length, minHeight: 6, color: _accent, backgroundColor: AppColors.surface),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 8, children: [
        for (final f in [1.0, 10.0, 30.0])
          ChoiceChip(label: Text('×${f.round()}'), selected: simFactor == f, onSelected: (_) => update(() => simFactor = f)),
      ]),
      const SizedBox(height: 12),
      if (canFinish(t))
        FilledButton(onPressed: () => finishTrip(t), child: const Text('Завершить рейс'))
      else ...[
        FilledButton(onPressed: null, child: Text('Завершить можно с ${hhmm(t.departure)}')),
        TextButton(onPressed: () => finishTrip(t), child: const Text('Демо: завершить сейчас')),
      ],
    ]);
  }
}
