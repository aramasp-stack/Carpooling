-- TransportApp, этап A: кто что видит.
-- Приложения работают от имени вошедшего пользователя (роль authenticated) и могут только читать,
-- и только разрешённые строки и столбцы. Без входа (роль anon) не видно ничего.

-- Есть ли у вошедшего сотрудника роль (владелец имеет все роли).
create function public.has_role(r text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from staff
    where user_id = auth.uid() and (r = any (roles) or 'owner' = any (roles))
  )
$$;

alter table public.app_settings enable row level security;
alter table public.profiles enable row level security;
alter table public.staff enable row level security;
alter table public.drivers enable row level security;
alter table public.routes enable row level security;
alter table public.trips enable row level security;
alter table public.trip_seats enable row level security;
alter table public.cards enable row level security;
alter table public.bookings enable row level security;
alter table public.payments enable row level security;
alter table public.payouts enable row level security;
alter table public.ledger enable row level security;
alter table public.audit_log enable row level security;

-- В облаке Supabase новым таблицам по умолчанию выдаются широкие права. Забираем всё и выдаём только чтение.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- Настройки (проценты, сроки) не секрет.
grant select on public.app_settings to authenticated;
create policy settings_read on public.app_settings for select to authenticated using (true);

-- Профиль: свой; поддержка видит всех.
grant select on public.profiles to authenticated;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.has_role('support'));

-- Роли сотрудников: свои; владелец видит всех.
grant select on public.staff to authenticated;
create policy staff_read on public.staff for select to authenticated
  using (user_id = auth.uid() or public.has_role('owner'));

-- Анкета водителя (с ИНН): сам водитель и проверяющий. Пассажирам — только витрина driver_public ниже.
grant select on public.drivers to authenticated;
create policy drivers_read on public.drivers for select to authenticated
  using (user_id = auth.uid() or public.has_role('verifier'));

-- Маршруты: опубликованные — всем вошедшим; черновики и архив — модератору.
grant select on public.routes to authenticated;
create policy routes_read on public.routes for select to authenticated
  using (status = 'published' or public.has_role('moderator'));

-- Рейсы и места: всем вошедшим (это расписание). Отметки посадки пассажирам не показываются.
grant select on public.trips to authenticated;
create policy trips_read on public.trips for select to authenticated using (true);

grant select (trip_id, seat_id, price, booking_id) on public.trip_seats to authenticated;
create policy trip_seats_read on public.trip_seats for select to authenticated using (true);

-- Карты: только свои, и только марка с последними четырьмя цифрами. Токен банка приложению не отдаётся.
grant select (id, user_id, brand, last4, created_at, removed_at) on public.cards to authenticated;
create policy cards_read on public.cards for select to authenticated
  using (user_id = auth.uid());

-- Брони: пассажир — свои; водитель — брони своих рейсов; поддержка и финансы — все.
grant select (id, trip_id, passenger_id, seat_ids, amount, status, refund, rating, created_at, cancelled_at)
  on public.bookings to authenticated;
create policy bookings_read on public.bookings for select to authenticated
  using (
    passenger_id = auth.uid()
    or public.has_role('support')
    or public.has_role('finance')
    or exists (select 1 from public.trips t where t.id = trip_id and t.driver_id = auth.uid())
  );

-- Деньги: финансы; поддержка видит обращения к банку (для разбора жалоб).
grant select on public.payments to authenticated;
create policy payments_read on public.payments for select to authenticated
  using (public.has_role('finance') or public.has_role('support'));

grant select on public.ledger to authenticated;
create policy ledger_read on public.ledger for select to authenticated
  using (public.has_role('finance'));

grant select on public.payouts to authenticated;
create policy payouts_read on public.payouts for select to authenticated
  using (driver_id = auth.uid() or public.has_role('finance'));

-- Журнал действий: только владелец.
grant select on public.audit_log to authenticated;
create policy audit_read on public.audit_log for select to authenticated
  using (public.has_role('owner'));

-- Витрина водителя для пассажиров: имя, рейтинг, машина. Без телефона, ИНН и статуса заявки.
-- Показываются только одобренные водители.
create view public.driver_public as
  select d.user_id, p.name, d.rating, d.rating_count, d.car, d.car_color, d.plate, d.seats_total
  from public.drivers d
  join public.profiles p on p.id = d.user_id
  where d.status = 'approved';

revoke all on public.driver_public from anon, authenticated;
grant select on public.driver_public to authenticated;
