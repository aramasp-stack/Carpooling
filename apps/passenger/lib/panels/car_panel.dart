part of '../home.dart';

/// Машина: водитель, время посадки, схема салона с ценами мест, одна итоговая сумма, оплата привязанной картой.
class CarPanel extends StatefulWidget {
  const CarPanel({super.key, required this.home, required this.match, required this.trip});
  final HomeState home;
  final RouteMatch match;
  final Trip trip;

  @override
  State<CarPanel> createState() => _CarPanelState();
}

class _CarPanelState extends State<CarPanel> {
  final selected = <String>{};
  bool busy = false;

  /// Номер операции оплаты. Тот же номер при повторе (например, пропала связь) не спишет деньги дважды;
  /// новый номер — только для новой попытки после ответа сервера.
  String _opKey = ServerApi.newOperationKey();

  Seat _seat(String id) => widget.trip.seats.firstWhere((s) => s.id == id);
  int get total => selected.fold(0, (sum, id) => sum + _seat(id).price);
  List<String> get _ids => carSeatIds.where(selected.contains).toList();

  @override
  Widget build(BuildContext context) {
    final h = widget.home, m = widget.match, t = widget.trip;
    final dropAt = h.trips.timeAt(t, t.dropOn(m.geometry.length), m.geometry);
    final walk = h.walkTo(t, m.geometry);
    final order = _ids.map((id) => _seat(id).label).join(', ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('К водителям', onTap: h.pop),
      DriverCard(t.driver, color: Color(m.route.color)),
      TwoPoints(
        from: 'Место посадки (синяя точка на карте) · ${walk < 120 ? 'рядом с вами' : '${meters(walk)} пешком'}',
        fromTime: hhmm(t.departure),
        to: m.route.to.name,
        toTime: '≈ ${hhmm(dropAt)}',
      ),
      const SectionTitle('Выберите места'),
      SeatPlan(
        seats: t.seats,
        selected: selected,
        color: _accent,
        onToggle: (id) => setState(() {
          selected.contains(id) ? selected.remove(id) : selected.add(id);
          _opKey = ServerApi.newOperationKey();
        }),
      ),
      const NoteBox('Водитель ждёт в месте посадки и отправляется по расписанию — подойдите заранее. По пути водитель не останавливается: высадка в конце маршрута, в месте, которое указал водитель.'),
      PayBar(
        caption: selected.isEmpty ? 'Места не выбраны' : order,
        total: amd(total),
        button: busy ? 'Оплачиваем…' : 'Оплатить картой',
        onPressed: selected.isEmpty || busy ? null : _pay,
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('Бесплатная отмена — не позднее чем за 60 минут до отправления',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppColors.muted)),
      ),
    ]);
  }

  Future<void> _pay() async {
    final h = widget.home;
    final cardId = await chooseCard(context, h.repo, total: total);
    if (cardId == null || !mounted) return;
    setState(() => busy = true);
    try {
      final r = await h.repo.book(trip: widget.trip, seats: _ids, cardId: cardId, key: _opKey);
      if (!mounted) return;
      _opKey = ServerApi.newOperationKey();
      if (!r.paid) {
        toast(context, reasonText(r.reason ?? 'CARD_DECLINED'));
        return;
      }
      toast(context, 'Оплачено ${amd(r.amount)}. Места ваши. Напомним за 30 и за 5 минут до отправления.');
      // Разрешения на напоминания — после первой покупки: сначала уведомления, затем точное время.
      await _askReminderPermissions();
      if (!mounted) return;
      h.goTab(HomeTab.mine, open: TicketPane(r.bookingId));
      // Напоминания перестраиваются уже с полученными разрешениями.
      h.repo.refreshMine();
    } on ServerError catch (e) {
      if (!mounted) return;
      toast(context, e.text);
      // Связь пропала — ответ неизвестен: номер операции оставляем, повтор не спишет дважды.
      if (e.code != 'NETWORK') _opKey = ServerApi.newOperationKey();
      // Место уже купили или продажа закрыта — вернуться к свежему списку рейсов.
      if (e.code == 'SEAT_TAKEN' || e.code == 'TRIP_CLOSED' || e.code == 'TRIP_NOT_FOUND') {
        await h.repo.refreshTrips();
        h.pop();
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

extension on _CarPanelState {
  /// Уведомления и «точное время» для напоминаний. Системный экран открываем только после понятного объяснения.
  Future<void> _askReminderPermissions() async {
    await TripReminders.askNotifications();
    if (!await TripReminders.needsExactPermission() || !mounted) return;
    final open = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Напоминания вовремя'),
        content: const Text('Мы напомним о поездке за 30 и за 5 минут до отправления. Чтобы напоминание пришло '
            'точно в срок, разрешите приложению «Будильники и напоминания»: откроются настройки телефона — '
            'включите переключатель и вернитесь назад.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Не сейчас')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Открыть настройки')),
        ],
      ),
    );
    if (open == true) await TripReminders.openExactSettings();
  }
}

/// Выбор карты для оплаты (или привязка первой). Возвращает id карты; null — передумали.
Future<String?> chooseCard(BuildContext context, PassengerRepo repo, {required int total}) async {
  if (repo.cards.isEmpty) {
    final id = await addCardDialog(context, repo);
    if (id == null || !context.mounted) return null;
  }
  var chosen = repo.cards.first.id;
  return showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setDialog) => AlertDialog(
        title: const Text('Оплата картой'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('К оплате: ${amd(total)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: chosen,
            onChanged: (v) => setDialog(() => chosen = v ?? chosen),
            child: Column(children: [
              for (final card in repo.cards)
                RadioListTile<String>(
                  value: card.id,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(card.title),
                  secondary: const Icon(Icons.credit_card),
                ),
            ]),
          ),
          if (repo.cards.length < 5)
            TextButton.icon(
              onPressed: () async {
                final id = await addCardDialog(c, repo);
                if (id != null) setDialog(() => chosen = id);
              },
              icon: const Icon(Icons.add),
              label: const Text('Другая карта'),
            ),
          const Text('Пока банк не подключён, оплата — симуляция: деньги не списываются.',
              style: TextStyle(fontSize: 12, color: AppColors.muted)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, chosen), child: Text('Оплатить ${amd(total)}')),
        ],
      ),
    ),
  );
}

/// Привязать карту (симуляция банка). Возвращает id новой карты; null — передумали.
Future<String?> addCardDialog(BuildContext context, PassengerRepo repo) =>
    showDialog<String>(context: context, builder: (_) => _AddCardDialog(repo: repo));

/// Окно привязки карты. Поле ввода живёт, пока живёт окно (и закрывается вместе с ним).
class _AddCardDialog extends StatefulWidget {
  const _AddCardDialog({required this.repo});
  final PassengerRepo repo;

  @override
  State<_AddCardDialog> createState() => _AddCardDialogState();
}

class _AddCardDialogState extends State<_AddCardDialog> {
  final ctl = TextEditingController();
  String? error;
  bool busy = false;

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  Future<void> _bind() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final id = await widget.repo.bindCard(ctl.text);
      if (mounted) Navigator.pop(context, id);
    } on ServerError catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e.text;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Привязать карту'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: ctl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')), LengthLimitingTextInputFormatter(19)],
            decoration: InputDecoration(labelText: 'Номер карты', hintText: '4111 1111 1111 1111', errorText: error),
            onSubmitted: (_) => busy ? null : _bind(),
          ),
          const SizedBox(height: 8),
          const Text(
            'Тестовая карта: 4111 1111 1111 1111. Карта на …0002 — банк откажет, на …0119 — банк недоступен. '
            'Номер карты хранит банк; в приложении остаются только последние 4 цифры.',
            style: TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        ]),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(onPressed: busy ? null : _bind, child: const Text('Привязать')),
        ],
      );
}
