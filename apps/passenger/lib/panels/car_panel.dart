part of '../home.dart';

/// Машина: водитель, время посадки, схема салона с ценами мест, одна итоговая сумма, оплата.
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

  Seat _seat(String id) => widget.trip.seats.firstWhere((s) => s.id == id);
  int get total => selected.fold(0, (sum, id) => sum + _seat(id).price);

  @override
  Widget build(BuildContext context) {
    final h = widget.home, m = widget.match, t = widget.trip;
    final pickAt = h.trips.timeAt(t, m.pick.along, m.geometry);
    final dropAt = h.trips.timeAt(t, m.dropAlong, m.geometry);
    final order = ['front', 'rl', 'rm', 'rr'].where(selected.contains).map((id) => _seat(id).label).join(', ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      BackLink('К водителям', onTap: h.pop),
      DriverCard(t.driver, color: Color(m.route.color)),
      TwoPoints(
        from: 'Посадка рядом с вами${m.pick.distance >= 120 ? ' · ${meters(m.pick.distance)} пешком' : ''}',
        fromTime: '≈ ${hhmm(pickAt)}',
        to: m.drop != null ? 'Высадка рядом с «${h.to?.name ?? m.route.to.name}»' : m.route.to.name,
        toTime: '≈ ${hhmm(dropAt)}',
      ),
      const SectionTitle('Выберите места'),
      SeatPlan(
        seats: t.seats,
        selected: selected,
        color: _accent,
        onToggle: (id) => setState(() => selected.contains(id) ? selected.remove(id) : selected.add(id)),
      ),
      const NoteBox('Где именно вас подобрать и высадить, договоритесь с водителем: его телефон появится в брони в день поездки.'),
      PayBar(
        caption: selected.isEmpty ? 'Места не выбраны' : order,
        total: amd(total),
        button: 'Оплатить картой',
        onPressed: selected.isEmpty ? null : _pay,
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('Бесплатная отмена — не позднее чем за 60 минут до посадки',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppColors.muted)),
      ),
    ]);
  }

  Future<void> _pay() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Оплата картой'),
        content: Text('К оплате: ${amd(total)}\n\nЭто демо: деньги не списываются. В рабочей версии здесь откроется защищённая страница банка для карт ArCa, Visa и Mastercard.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: const Text('Оплатить (демо)'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final h = widget.home, m = widget.match, t = widget.trip;
    final ids = ['front', 'rl', 'rm', 'rr'].where(selected.contains).toList();
    final b = Booking(
      id: 'B${DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase()}',
      tripId: t.id,
      routeId: m.route.id,
      pickAlong: m.pick.along,
      dropAlong: m.dropAlong,
      fromName: h.from?.name ?? m.route.from.name,
      toName: h.to?.name ?? m.route.to.name,
      seatIds: ids,
      seatLabels: ids.map((id) => _seat(id).label).toList(),
      amount: total,
    );
    await h.data.addBooking(b);
    if (!mounted) return;
    toast(context, 'Оплата прошла (демо). Места забронированы.');
    h.goTab(HomeTab.mine, open: TicketPane(b.id));
  }
}
