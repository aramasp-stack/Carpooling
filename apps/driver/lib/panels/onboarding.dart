part of '../home.dart';

/// Оформление водителя: вход по SMS, анкета, документы, карта для выплат, проверка.
extension Onboarding on DriverHomeState {
  // ---------- вход ----------
  Widget signInPanel() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('TransportApp для водителей', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('Возите пассажиров по готовым маршрутам Еревана: сами выбираете время, место посадки и цены мест.',
            style: TextStyle(color: AppColors.muted)),
        const SectionTitle('Вход по номеру телефона'),
        TextField(
          controller: phoneCtl,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Номер телефона', prefixIcon: Icon(Icons.phone_outlined)),
        ),
        const SizedBox(height: 10),
        if (codeSent) ...[
          TextField(
            controller: codeCtl,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: const InputDecoration(labelText: 'Код из SMS', prefixIcon: Icon(Icons.sms_outlined), counterText: ''),
          ),
          const SizedBox(height: 4),
          const Text('В модели SMS не отправляется: подойдут любые 4 цифры.', style: TextStyle(fontSize: 12, color: AppColors.muted)),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: () async {
              try {
                await me.signIn(phoneCtl.text, codeCtl.text);
                update(() {});
              } catch (e) {
                showError(e);
              }
            },
            child: const Text('Войти'),
          ),
        ] else
          FilledButton(
            onPressed: () {
              final p = phoneCtl.text.replaceAll(RegExp(r'[\s\-()]'), '');
              if (!RegExp(r'^\+?[0-9]{8,15}$').hasMatch(p)) {
                toast(context, driverErrorText('BAD_PHONE'));
                return;
              }
              update(() => codeSent = true);
            },
            child: const Text('Получить код'),
          ),
        const SizedBox(height: 10),
        const Text('Если вы уже ездите пассажиром, войдите под тем же номером: учётная запись одна.',
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
      ]);

  // ---------- анкета ----------
  Widget applyPanel() {
    final a = me.application;
    final card = me.payoutCard;
    final status = a.status;
    final locked = status == ApplicationStatus.pending;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Анкета водителя', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text('Рейсы можно публиковать после проверки анкеты. Проверяет человек, обычно в течение дня.',
          style: TextStyle(color: AppColors.muted)),
      if (status == ApplicationStatus.pending) _pendingBox(),
      if (status == ApplicationStatus.rejected)
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(12)),
          child: Text('Анкета отклонена: ${a.rejectReason}. Исправьте и отправьте снова.', style: const TextStyle(color: AppColors.danger)),
        ),
      _stepTitle(1, 'Машина', a.carFilled),
      TextField(controller: carCtl, enabled: !locked, decoration: const InputDecoration(labelText: 'Марка и модель', isDense: true)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: TextField(controller: colorCtl, enabled: !locked, decoration: const InputDecoration(labelText: 'Цвет', isDense: true))),
        const SizedBox(width: 8),
        Expanded(child: TextField(controller: plateCtl, enabled: !locked, decoration: const InputDecoration(labelText: 'Номер', isDense: true))),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        const Text('Мест для пассажиров:'),
        const SizedBox(width: 10),
        for (final n in [3, 4])
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text('$n'),
              selected: a.seats == n,
              onSelected: locked
                  ? null
                  : (_) async {
                      await me.saveApplication(_formApplication()..seats = n);
                      update(() {});
                    },
            ),
          ),
      ]),
      const SizedBox(height: 8),
      TextField(
        controller: taxCtl,
        enabled: !locked,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'ИНН — для госпошлины и чеков', isDense: true),
      ),
      _stepTitle(2, 'Документы', a.docsComplete),
      for (final e in driverDocuments.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Icon(a.docs.contains(e.key) ? Icons.check_circle : Icons.radio_button_unchecked,
                color: a.docs.contains(e.key) ? AppColors.ok : AppColors.muted, size: 22),
            const SizedBox(width: 10),
            Expanded(child: Text(e.value)),
            TextButton.icon(
              onPressed: locked
                  ? null
                  : () async {
                      FocusManager.instance.primaryFocus?.unfocus();
                      await me.saveApplication(_formApplication());
                      await me.setDocument(e.key);
                      update(() {});
                      if (mounted) toast(context, 'Фото «${e.value}» загружено (в модели — без камеры).');
                    },
              icon: const Icon(Icons.photo_camera_outlined, size: 18),
              label: Text(a.docs.contains(e.key) ? 'Заменить' : 'Снять'),
            ),
          ]),
        ),
      _stepTitle(3, 'Карта для выплат', card != null),
      if (card != null)
        Text('${card.brand} •••• ${card.last4} · ${card.holder}')
      else
        const Text('Сюда раз в неделю приходят деньги за рейсы. Имя на карте должно совпадать с паспортом.',
            style: TextStyle(fontSize: 13, color: AppColors.muted)),
      const SizedBox(height: 6),
      OutlinedButton.icon(
        onPressed: locked ? null : () => showPayoutCardDialog(this),
        icon: const Icon(Icons.credit_card),
        label: Text(card == null ? 'Привязать карту' : 'Другая карта'),
      ),
      _stepTitle(4, 'Договор', offerAccepted),
      CheckboxListTile(
        value: offerAccepted,
        onChanged: locked ? null : (v) => update(() => offerAccepted = v ?? false),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('Принимаю оферту: я — перевозчик, платформа принимает оплату от моего имени и удерживает комиссию и госпошлину',
            style: TextStyle(fontSize: 13)),
      ),
      if (!locked) ...[
        const SizedBox(height: 8),
        FilledButton(onPressed: _submit, child: const Text('Отправить на проверку')),
      ],
      const SizedBox(height: 12),
      TextButton(
        onPressed: () async {
          await me.reset();
          update(() => codeSent = false);
        },
        child: const Text('Выйти'),
      ),
    ]);
  }

  Widget _stepTitle(int n, String title, bool done) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Row(children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: done ? AppColors.ok : AppColors.line,
            child: done ? const Icon(Icons.check, size: 15, color: Colors.white) : Text('$n', style: const TextStyle(fontSize: 12, color: AppColors.text)),
          ),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
      );

  /// Анкета из полей ввода (документы и статус — из сохранённой).
  DriverApplication _formApplication() {
    final a = me.application;
    return a
      ..car = carCtl.text.trim()
      ..carColor = colorCtl.text.trim()
      ..plate = plateCtl.text.trim()
      ..taxId = taxCtl.text.trim();
  }

  Future<void> _submit() async {
    try {
      await me.saveApplication(_formApplication());
      if (!mounted) return;
      if (me.payoutCard == null) {
        toast(context, 'Привяжите карту для выплат.');
        return;
      }
      if (!offerAccepted) {
        toast(context, 'Примите оферту.');
        return;
      }
      await me.submit();
      update(() {});
      if (mounted) toast(context, 'Анкета отправлена на проверку.');
    } catch (e) {
      showError(e);
    }
  }

  /// Анкета на проверке. Пока нет веб-панели проверяющего, решение можно принять демо-кнопками.
  Widget _pendingBox() => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: _accent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Row(children: [
            Icon(Icons.hourglass_top, color: _accent),
            SizedBox(width: 10),
            Expanded(child: Text('Анкета на проверке', style: TextStyle(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: 6),
          const Text('Мы сообщим, когда проверим документы. Пока анкета на проверке, её нельзя менять.',
              style: TextStyle(fontSize: 13, color: AppColors.muted)),
          const SizedBox(height: 10),
          const Text('Демо: решение проверяющего', style: TextStyle(fontSize: 12, color: AppColors.muted)),
          Row(children: [
            Expanded(
              child: FilledButton(
                onPressed: () async {
                  await me.review(approve: true);
                  goTab(DriverTab.trips);
                  if (mounted) toast(context, 'Анкета одобрена. Можно публиковать рейсы.');
                },
                child: const Text('Одобрить'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  await me.review(approve: false, reason: 'фото прав нечитаемо, переснимите');
                  update(() {});
                },
                child: const Text('Отклонить'),
              ),
            ),
          ]),
        ]),
      );
}
