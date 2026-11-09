import 'package:flutter/material.dart';
import 'package:transport_core/transport_core.dart';

import 'theme.dart';

/// Экран «карта на весь экран + выдвижная панель снизу», как в такси-приложениях.
class MapSheetScaffold extends StatelessWidget {
  const MapSheetScaffold({
    super.key,
    required this.map,
    required this.panel,
    required this.bottomBar,
    this.sheetController,
  });
  final Widget map;
  final Widget panel;
  final Widget bottomBar;
  final DraggableScrollableController? sheetController;

  /// Доля экрана, которую панель занимает по умолчанию.
  static const initialSize = 0.52;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: map),
        DraggableScrollableSheet(
          controller: sheetController,
          initialChildSize: initialSize,
          minChildSize: 0.22,
          maxChildSize: 0.94,
          snap: true,
          snapSizes: const [0.22, initialSize, 0.94],
          builder: (context, scroll) => DecoratedBox(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
              boxShadow: [BoxShadow(color: Color(0x2E0F172A), blurRadius: 30, offset: Offset(0, -4))],
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
              child: PanelScroll(controller: scroll, child: panel),
            ),
          ),
        ),
      ]),
      bottomNavigationBar: bottomBar,
    );
  }
}

/// Прокрутка содержимого панели с «ручкой» сверху.
class PanelScroll extends StatelessWidget {
  const PanelScroll({super.key, required this.controller, required this.child});
  final ScrollController controller;
  final Widget child;
  @override
  Widget build(BuildContext context) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color: const Color(0xFFCBD5E1), borderRadius: BorderRadius.circular(4)),
            ),
          ),
          child,
        ],
      );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.top = 18});
  final String text;
  final double top;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: top, bottom: 8),
        child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      );
}

class NoteBox extends StatelessWidget {
  const NoteBox(this.text, {super.key, this.color = AppColors.surface});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
      );
}

class BackLink extends StatelessWidget {
  const BackLink(this.text, {super.key, required this.onTap});
  final String text;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onTap,
          style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
          icon: const Icon(Icons.arrow_back, size: 18),
          label: Text(text),
        ),
      );
}

/// Цветная точка маршрута.
class Swatch extends StatelessWidget {
  const Swatch(this.color, {super.key, this.size = 12});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) =>
      Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// Две строки «откуда / куда» с временем справа.
class TwoPoints extends StatelessWidget {
  const TwoPoints({super.key, required this.from, required this.to, this.fromTime, this.toTime});
  final String from;
  final String to;
  final String? fromTime;
  final String? toTime;

  Widget _row(Color c, String text, String? time) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Swatch(c, size: 10),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
          if (time != null) Text(time, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );

  @override
  Widget build(BuildContext context) =>
      Column(children: [_row(AppColors.from, from, fromTime), _row(AppColors.to, to, toTime)]);
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.text, {super.key, this.kind = StatusKind.ok});
  final String text;
  final StatusKind kind;
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      StatusKind.ok => (const Color(0xFFDCFCE7), AppColors.ok),
      StatusKind.off => (const Color(0xFFFEE2E2), AppColors.danger),
      StatusKind.done => (AppColors.surface, AppColors.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

enum StatusKind { ok, off, done }

/// Карточка водителя: аватар, рейтинг, машина, номер, проверка документов.
class DriverCard extends StatelessWidget {
  const DriverCard(this.driver, {super.key, required this.color});
  final Driver driver;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          CircleAvatar(radius: 23, backgroundColor: color, child: Text(driver.name[0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(driver.name, style: const TextStyle(fontWeight: FontWeight.w700))),
                Text('★ ${driver.rating} · ${driver.trips} поездок', style: const TextStyle(fontSize: 13)),
              ]),
              Text('${driver.car}, ${driver.carColor}', style: const TextStyle(fontSize: 13, color: AppColors.muted)),
              const SizedBox(height: 4),
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(border: Border.all(color: AppColors.text, width: 2), borderRadius: BorderRadius.circular(6)),
                  child: Text(driver.plate, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                ),
                const Spacer(),
                Text(
                  driver.verified ? '✓ документы проверены' : 'документы на проверке',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: driver.verified ? color : AppColors.muted),
                ),
              ]),
            ]),
          ),
        ]),
      );
}

/// Схема салона: водитель и переднее место, сзади 2 или 3 места. У каждого места своя цена.
class SeatPlan extends StatelessWidget {
  const SeatPlan({super.key, required this.seats, required this.selected, required this.onToggle, required this.color});
  final List<Seat> seats;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final Color color;

  Seat? _s(String id) {
    for (final s in seats) {
      if (s.id == id) return s;
    }
    return null;
  }

  Widget _seat(Seat? seat) {
    if (seat == null) return const SizedBox.shrink();
    final on = selected.contains(seat.id);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Material(
          color: seat.taken ? const Color(0xFFF1F5F9) : (on ? color.withValues(alpha: 0.1) : Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: on ? color : AppColors.line, width: 2),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: seat.taken ? null : () => onToggle(seat.id),
            child: SizedBox(
              height: 76,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(seat.label, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: on ? color : AppColors.muted)),
                const SizedBox(height: 2),
                Text(
                  seat.taken ? 'занято' : amd(seat.price),
                  style: TextStyle(
                    fontWeight: seat.taken ? FontWeight.w500 : FontWeight.w700,
                    fontSize: seat.taken ? 13 : 15,
                    color: seat.taken ? const Color(0xFF94A3B8) : AppColors.text,
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rear = ['rl', 'rm', 'rr'].map(_s).whereType<Seat>().toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 22, 9, 9),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.line, width: 2),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(34), bottom: Radius.circular(18)),
      ),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Container(
                height: 76,
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.line, width: 2),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.trip_origin, color: AppColors.muted, size: 20),
                  Text('Водитель', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                ]),
              ),
            ),
          ),
          _seat(_s('front')),
        ]),
        Row(children: rear.map(_seat).toList()),
      ]),
    );
  }
}

/// Нижняя панель с суммой и кнопкой.
class PayBar extends StatelessWidget {
  const PayBar({super.key, required this.caption, required this.total, required this.button, required this.onPressed});
  final String caption;
  final String total;
  final String button;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(caption, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              Text(total, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            ]),
          ),
          FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52), padding: const EdgeInsets.symmetric(horizontal: 20)),
            child: Text(button),
          ),
        ]),
      );
}

/// Простой показ сообщения внизу экрана.
void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
}
