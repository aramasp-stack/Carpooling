-- TransportApp: правки по проверке безопасности и скорости Supabase (советник базы).
-- Поведение не меняется — меняется только то, как это устроено внутри.

-- 1) Служебные функции триггеров ищут таблицы только в своей схеме.
alter function public._forbid_change() set search_path = public, pg_temp;
alter function public._check_settings() set search_path = public, pg_temp;

-- 2) Проверка «видит ли пассажир рейсы этого водителя» нужна только правилу видимости рейсов.
-- В схеме public её можно было вызвать напрямую через API и так узнать, что тебя заблокировали.
-- Схема private через API не открыта; правило видимости продолжает её вызывать.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;
alter function public._can_see_trip(uuid, uuid) set schema private;

-- 3) Правила видимости: кто вошёл, вычисляется один раз на запрос, а не для каждой строки.
drop policy profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.has_role('support'));

drop policy staff_read on public.staff;
create policy staff_read on public.staff for select to authenticated
  using (user_id = (select auth.uid()) or public.has_role('owner'));

drop policy drivers_read on public.drivers;
create policy drivers_read on public.drivers for select to authenticated
  using (user_id = (select auth.uid()) or public.has_role('verifier'));

drop policy cards_read on public.cards;
create policy cards_read on public.cards for select to authenticated
  using (user_id = (select auth.uid()));

drop policy bookings_read on public.bookings;
create policy bookings_read on public.bookings for select to authenticated
  using (
    passenger_id = (select auth.uid())
    or public.has_role('support')
    or public.has_role('finance')
    or (status <> 'failed' and exists (
          select 1 from public.trips t join public.profiles p on p.id = t.driver_id
          where t.id = trip_id and t.driver_id = (select auth.uid()) and not p.blocked))
  );

drop policy payouts_read on public.payouts;
create policy payouts_read on public.payouts for select to authenticated
  using (driver_id = (select auth.uid()) or public.has_role('finance'));

drop policy driver_documents_read on public.driver_documents;
create policy driver_documents_read on public.driver_documents for select to authenticated
  using (driver_id = (select auth.uid()) or public.has_role('verifier'));

drop policy payout_cards_read on public.payout_cards;
create policy payout_cards_read on public.payout_cards for select to authenticated
  using (driver_id = (select auth.uid()) or public.has_role('verifier') or public.has_role('finance'));

drop policy driver_blocks_read on public.driver_blocks;
create policy driver_blocks_read on public.driver_blocks for select to authenticated
  using (driver_id = (select auth.uid()) or public.has_role('support'));

drop policy route_requests_read on public.route_requests;
create policy route_requests_read on public.route_requests for select to authenticated
  using (driver_id = (select auth.uid()) or public.has_role('moderator'));

-- 4) Индексы для частых поисков: карты человека, выплаты и заявки водителя, записи журнала по рейсу.
create index cards_user on public.cards (user_id);
create index payouts_driver on public.payouts (driver_id);
create index route_requests_driver on public.route_requests (driver_id);
create index ledger_trip on public.ledger (trip_id);
