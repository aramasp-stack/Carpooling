part of '../home.dart';

/// Все маршруты: начальная и конечная точки, время в пути, пробки.
extension RoutesPanel on HomeState {
  Widget routesPanel() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Все маршруты', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
        const Text('Маршрут — это начальная и конечная точки. Где подсесть по пути, пассажир договаривается с водителем.',
            style: TextStyle(fontSize: 13, color: AppColors.muted)),
        const SizedBox(height: 10),
        for (final r in Demo.routes) _routeItem(r),
      ]);

  Widget _routeItem(RouteDef r) {
    final g = geoms[r.id];
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.line)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Swatch(Color(r.color)),
            const SizedBox(width: 10),
            Expanded(child: TwoPoints(from: r.from.name, to: r.to.name)),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 12, children: [
            if (g != null) ...[
              Text('${g.trafficSec != null ? 'обычно' : 'в пути'} ~${minutesText(g.durationSec)}', style: const TextStyle(fontSize: 13)),
              Text(meters(g.length), style: const TextStyle(fontSize: 13, color: AppColors.muted)),
              if (g.trafficSec != null)
                Text('сейчас с пробками ${minutesText(g.trafficSec!)}', style: const TextStyle(fontSize: 13, color: AppColors.traffic)),
            ] else
              const Text('загрузка…', style: TextStyle(fontSize: 13, color: AppColors.muted)),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ActionChip(
              label: const Text('Ехать по этому маршруту'),
              onPressed: () {
                goTab(HomeTab.search);
                setPlace('from', r.from);
                setPlace('to', r.to);
              },
            ),
            ActionChip(
              label: const Text('Показать движение машины'),
              onPressed: g == null ? null : () => startSim(trips.tripsFor(r, 0).first, null),
            ),
          ]),
        ]),
      ),
    );
  }
}
