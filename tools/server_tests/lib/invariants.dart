/// Проверки целостности: то, что должно быть верно всегда, после любых действий любых пользователей.
/// Каждая проверка — запрос, который считает нарушения. Ноль — всё в порядке.
library;

import 'harness.dart';

const _distributed = "('driver_accrual', 'commission', 'state_duty')";

/// Бронь удерживает свои места: оплачена, завершена или отменена поздно (без возврата).
const _holds = "(b.status in ('paid', 'done') or (b.status = 'cancelled' and b.refund = 0))";

const invariants = <String, String>{
  'занятое место принадлежит действующей брони этого же рейса': '''
    select count(*) from trip_seats s left join bookings b on b.id = s.booking_id
    where s.booking_id is not null
      and (b.id is null or b.trip_id <> s.trip_id or not (s.seat_id = any (b.seat_ids)) or not $_holds)''',
  'за действующей бронью числятся все её места': '''
    select count(*) from bookings b cross join lateral unnest(b.seat_ids) as x (seat)
    left join trip_seats s on s.trip_id = b.trip_id and s.seat_id = x.seat
    where $_holds and s.booking_id is distinct from b.id''',
  'сумма брони равна сумме цен её мест': '''
    select count(*) from bookings b
    where b.amount <> (select coalesce(sum(s.price), 0) from trip_seats s where s.trip_id = b.trip_id and s.seat_id = any (b.seat_ids))''',
  'по брони списана ровно её сумма (или ничего, если банк отказал)': '''
    select count(*) from bookings b
    where (select coalesce(sum(l.amount), 0) from ledger l where l.booking_id = b.id and l.kind = 'charge')
          <> case when b.status = 'failed' then 0 else b.amount end''',
  'по брони возвращено ровно столько, сколько в ней записано': '''
    select count(*) from bookings b
    where (select coalesce(sum(l.amount), 0) from ledger l where l.booking_id = b.id and l.kind = 'refund') <> b.refund''',
  'возврат бывает только у отменённой брони': '''
    select count(*) from bookings b
    where (b.refund > 0 and b.status <> 'cancelled') or ((b.status = 'cancelled') <> (b.cancelled_at is not null))''',
  'обращения к банку сходятся с журналом денег': '''
    select count(*) from (
      select (select coalesce(sum(amount), 0) from payments where ok and kind = 'charge')
             - (select coalesce(sum(amount), 0) from ledger where kind = 'charge') as d_charge,
             (select coalesce(sum(amount), 0) from payments where ok and kind = 'refund')
             - (select coalesce(sum(amount), 0) from ledger where kind = 'refund') as d_refund
    ) x where d_charge <> 0 or d_refund <> 0''',
  'после начисления всё оставшееся по брони распределено до драма': '''
    select count(*) from bookings b join trips t on t.id = b.trip_id
    where t.accrued_at is not null and b.status <> 'failed'
      and (b.amount - b.refund) <> (select coalesce(sum(l.amount), 0) from ledger l where l.booking_id = b.id and l.kind in $_distributed)''',
  'начислений нет там, где срок ещё не вышел': '''
    select count(*) from ledger l join trips t on t.id = l.trip_id
    where l.kind in $_distributed and (t.accrued_at is null or t.status <> 'finished')''',
  'деньги в целом сходятся: получено − возвращено = распределено + ждёт начисления': '''
    select count(*) from (
      select (select coalesce(sum(amount), 0) from ledger where kind = 'charge')
           - (select coalesce(sum(amount), 0) from ledger where kind = 'refund')
           - (select coalesce(sum(amount), 0) from ledger where kind in $_distributed)
           - (select coalesce(sum(b.amount - b.refund), 0) from bookings b join trips t on t.id = b.trip_id
              where b.status <> 'failed' and t.accrued_at is null) as diff
    ) x where diff <> 0''',
  'водителю выплачено не больше начисленного': '''
    select count(*) from (
      select driver_id from ledger where driver_id is not null and kind in ('driver_accrual', 'payout')
      group by driver_id
      having coalesce(sum(amount) filter (where kind = 'payout'), 0) > coalesce(sum(amount) filter (where kind = 'driver_accrual'), 0)
    ) x''',
  'каждая выплата записана в журнал денег той же суммой': '''
    select count(*) from payouts p
    where (select coalesce(sum(l.amount), 0) from ledger l where l.payout_id = p.id and l.kind = 'payout') <> p.amount''',
  'водитель не стоит в двух рейсах одновременно': '''
    select count(*) from trips a join trips b
      on a.driver_id = b.driver_id and a.id < b.id
     and a.status in ('planned', 'started') and b.status in ('planned', 'started')
     and a.departure < b.ends_at and b.departure < a.ends_at''',
  'в отменённом рейсе нет занятых мест и все деньги возвращены': '''
    select count(*) from trips t
    where t.status = 'cancelled' and (
      exists (select 1 from trip_seats s where s.trip_id = t.id and s.booking_id is not null)
      or exists (select 1 from bookings b where b.trip_id = t.id and b.status <> 'failed' and (b.status <> 'cancelled' or b.refund <> b.amount)))''',
  'в завершённом рейсе не осталось броней «оплачено»': '''
    select count(*) from bookings b join trips t on t.id = b.trip_id
    where t.status = 'finished' and b.status = 'paid' ''',
  'у водителя не больше одного начатого рейса': '''
    select count(*) from (select driver_id from trips where status = 'started' group by driver_id having count(*) > 1) x''',
  'рейс не завершён раньше, чем начат': '''
    select count(*) from trips where started_at is not null and finished_at is not null and finished_at < started_at''',
  'рейсы в продаже стоят только на опубликованных маршрутах': '''
    select count(*) from trips t join routes r on r.id = t.route_id
    where t.status in ('planned', 'started') and r.status <> 'published' ''',
  'не начатые рейсы есть только у одобренных и не заблокированных водителей': '''
    select count(*) from trips t join drivers d on d.user_id = t.driver_id join profiles p on p.id = d.user_id
    where t.status = 'planned' and (d.status <> 'approved' or p.blocked)''',
  'у человека не больше пяти действующих карт': '''
    select count(*) from (select user_id from cards where removed_at is null group by user_id having count(*) > 5) x''',
  'список мест в брони — простой список без вложений': '''
    select count(*) from bookings where array_ndims(seat_ids) <> 1''',
  'в системе есть действующий владелец': '''
    select case when exists (
      select 1 from staff s join profiles p on p.id = s.user_id where 'owner' = any (s.roles) and not p.blocked
    ) then 0 else 1 end''',
  'место рейса есть в машине водителя': '''
    select count(*) from trip_seats s join trips t on t.id = s.trip_id join drivers d on d.user_id = t.driver_id
    where s.seat_id = 'rm' and d.seats_total = 3 and t.status in ('planned', 'started')''',
  'место посадки — в начальном районе маршрута': '''
    select count(*) from trips t join routes r on r.id = t.route_id
    where t.meet_along < 0 or t.meet_along > least(1500, r.length_m)''',
  'рейтинг водителя равен среднему его оценок': '''
    select count(*) from drivers d
    where d.rating_count <> (select count(*) from bookings b join trips t on t.id = b.trip_id where t.driver_id = d.user_id and b.rating is not null)
       or (d.rating_count > 0 and d.rating <> (select round(avg(b.rating), 1) from bookings b join trips t on t.id = b.trip_id where t.driver_id = d.user_id and b.rating is not null))''',
};

/// Нарушенные проверки: название → число нарушений. Пусто — всё сходится.
Future<Map<String, int>> violations(World w) async {
  final out = <String, int>{};
  for (final e in invariants.entries) {
    final n = await w.scalar(e.value) as int;
    if (n != 0) out[e.key] = n;
  }
  return out;
}
