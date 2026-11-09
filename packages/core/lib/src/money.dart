/// Деньги: доля водителя после комиссии платформы и госпошлины.
library;

import 'demo_data.dart';

class MoneySplit {
  const MoneySplit({required this.paid, required this.commission, required this.duty});

  /// Сколько заплатили пассажиры, драм.
  final int paid;
  final int commission;
  final int duty;
  int get driver => paid - commission - duty;

  /// Расчёт по проценту комиссии и госпошлины. Округление в пользу водителя.
  factory MoneySplit.of(int paid, {int commissionPercent = Demo.commissionPercent, int statePercent = Demo.statePercent}) {
    final commission = (paid * commissionPercent) ~/ 100;
    final duty = (paid * statePercent) ~/ 100;
    return MoneySplit(paid: paid, commission: commission, duty: duty);
  }
}

/// Правило отмены: раньше чем за 60 минут до посадки — полный возврат, позже — без возврата.
int refundFor({required int amount, required DateTime pickupTime, required DateTime now}) =>
    pickupTime.difference(now).inMinutes >= 60 ? amount : 0;
