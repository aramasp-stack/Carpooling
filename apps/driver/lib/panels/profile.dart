part of '../home.dart';

/// Профиль: машина и документы, карта для выплат, заблокированные пассажиры, заявки на маршруты.
extension ProfileScreen on DriverHomeState {
  Widget profilePanel() {
    final a = me.application;
    final card = me.payoutCard;
    final blocked = me.blocked.entries.toList()..sort((x, y) => y.value.compareTo(x.value));
    final requests = me.routeRequests;
    final now = trips.now;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DriverCard(meAsDriver, color: _accent),
      Text('Телефон ${me.phone ?? ''} · вход по отпечатку пальца или лицу — в рабочей версии',
          style: const TextStyle(fontSize: 12, color: AppColors.muted)),
      const SectionTitle('Документы'),
      for (final e in driverDocuments.entries)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(a.docs.contains(e.key) ? Icons.check_circle : Icons.error_outline,
              color: a.docs.contains(e.key) ? AppColors.ok : AppColors.danger),
          title: Text(e.value),
          trailing: const Text('проверено', style: TextStyle(fontSize: 12, color: AppColors.muted)),
        ),
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.event_seat_outlined),
        title: Text('Места для пассажиров: ${a.seats}'),
        subtitle: Text([for (final id in carSeatIds) if (a.seatIds.contains(id)) seatLabel(id)].join(', ')),
      ),
      const Text('Сменить машину или места можно через новую анкету: её снова проверят.', style: TextStyle(fontSize: 12, color: AppColors.muted)),
      const SectionTitle('Карта для выплат'),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.credit_card),
        title: Text(card == null ? 'Не привязана' : '${card.brand} •••• ${card.last4}'),
        subtitle: card == null
            ? const Text('Без карты деньги за рейсы ждут.')
            : Text(card.activeFrom.isAfter(now)
                ? '${card.holder} · выплаты на неё — с ${dateLong(card.activeFrom)}, ${hhmm(card.activeFrom)}'
                : card.holder),
        trailing: TextButton(onPressed: () => showPayoutCardDialog(this), child: Text(card == null ? 'Привязать' : 'Сменить')),
      ),
      SectionTitle('Заблокированные пассажиры · ${blocked.length}'),
      if (blocked.isEmpty)
        const Text('Никого. Заблокировать можно в списке пассажиров рейса: «⋮» справа от имени.',
            style: TextStyle(fontSize: 13, color: AppColors.muted)),
      for (final b in blocked)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.block, color: AppColors.danger),
          title: Text(b.key),
          subtitle: Text('с ${dateLong(b.value)}'),
          trailing: TextButton(
            onPressed: () async {
              await me.unblock(b.key);
              update(() {});
            },
            child: const Text('Разблокировать'),
          ),
        ),
      SectionTitle('Предложенные маршруты · ${requests.length}'),
      if (requests.isEmpty)
        const Text('Нет нужного маршрута — предложите его при создании рейса.', style: TextStyle(fontSize: 13, color: AppColors.muted)),
      for (final r in requests)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            switch (r.status) { 'accepted' => Icons.check_circle, 'rejected' => Icons.cancel, _ => Icons.hourglass_top },
            color: switch (r.status) { 'accepted' => AppColors.ok, 'rejected' => AppColors.danger, _ => AppColors.muted },
          ),
          title: Text('${r.from} → ${r.to}'),
          subtitle: Text(switch (r.status) {
            'accepted' => 'принят: маршрут появится в списке',
            'rejected' => 'отклонён: ${r.reason ?? ''}',
            _ => 'на рассмотрении у модератора',
          }),
        ),
      const SectionTitle('Договор'),
      const ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.check_circle, color: AppColors.ok),
        title: Text('Оферта принята: вы — перевозчик, платформа принимает оплату от вашего имени'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: () async {
          await me.reset();
          for (final c in data.customTrips()) {
            await data.removeCustomTrip(c.id);
          }
          update(() {
            codeSent = false;
            offerAccepted = false;
            stack = [RoutePickPane()];
            tab = DriverTab.routes;
          });
        },
        child: const Text('Демо: начать заново с анкеты'),
      ),
    ]);
  }
}

/// Привязать или сменить карту для выплат. Нужен код из SMS: это защита, если телефон попал в чужие руки.
Future<void> showPayoutCardDialog(DriverHomeState h) async {
  final had = h.me.payoutCard != null;
  // Иначе после закрытия окна клавиатура снова откроется на последнем поле анкеты.
  FocusManager.instance.primaryFocus?.unfocus();
  final form = await showDialog<({String number, String holder, String code})>(
    context: h.context,
    builder: (c) => _PayoutCardDialog(had: had),
  );
  if (form == null) return;
  try {
    final card = await h.me.setPayoutCard(number: form.number, holder: form.holder, smsCode: form.code);
    h.update(() {});
    if (h.mounted) toast(h.context, '${card.brand} •••• ${card.last4} привязана${had ? ': выплаты на неё — через 24 часа' : ''}.');
  } catch (e) {
    h.showError(e);
  }
}

/// Окно с полями карты. Поля живут вместе с окном: их нельзя убирать, пока окно закрывается
/// (иначе при закрытии кнопкой «Назад» приложение обращается к уже удалённым полям).
class _PayoutCardDialog extends StatefulWidget {
  const _PayoutCardDialog({required this.had});
  final bool had;

  @override
  State<_PayoutCardDialog> createState() => _PayoutCardDialogState();
}

class _PayoutCardDialogState extends State<_PayoutCardDialog> {
  final numberCtl = TextEditingController();
  final holderCtl = TextEditingController();
  final codeCtl = TextEditingController();

  @override
  void dispose() {
    numberCtl.dispose();
    holderCtl.dispose();
    codeCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.had ? 'Другая карта для выплат' : 'Карта для выплат'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: numberCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Номер карты', hintText: '16 цифр'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: holderCtl,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Имя владельца, как на карте'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: codeCtl,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: const InputDecoration(labelText: 'Код из SMS', counterText: ''),
            ),
            const SizedBox(height: 6),
            Text(
              widget.had
                  ? 'Выплаты на новую карту начнутся через 24 часа. В модели код из SMS — любые 4 цифры.'
                  : 'Имя на карте должно совпадать с паспортом. В модели код из SMS — любые 4 цифры.',
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(context, (number: numberCtl.text, holder: holderCtl.text, code: codeCtl.text)),
            child: const Text('Привязать'),
          ),
        ],
      );
}
