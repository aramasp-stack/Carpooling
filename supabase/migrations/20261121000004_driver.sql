-- TransportApp: то, что нужно водителю (ТЗ, раздел 5).
-- Документы для проверки, карта для выплат, блокировка пассажиров, заявки на новые маршруты, оценка пассажиров.
-- Порядок блокировок прежний: водитель → маршрут → рейс → бронь.

-- ---------- документы водителя ----------
-- Сами фото лежат в закрытом хранилище файлов (в облаке — Supabase Storage, папка водителя <его id>/...).
-- В базе — какие документы загружены и где лежат.
create table public.driver_documents (
  driver_id uuid not null references public.drivers (user_id) on delete cascade,
  kind text not null check (kind in ('id_document', 'license', 'registration', 'car_photo', 'selfie')),
  storage_path text not null check (length(storage_path) between 3 and 300),
  uploaded_at timestamptz not null default now(),
  primary key (driver_id, kind)
);

-- ---------- карта для выплат ----------
-- Одна действующая карта. Номера карты нет — только метка банка и последние 4 цифры.
-- Новая карта вместо старой начинает получать выплаты через 24 часа (защита, если телефон украли).
create table public.payout_cards (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers (user_id) on delete cascade,
  token text not null unique,
  brand text not null,
  last4 text not null check (last4 ~ '^[0-9]{4}$'),
  holder_name text not null check (length(holder_name) between 2 and 60),
  created_at timestamptz not null default now(),
  active_from timestamptz not null,
  removed_at timestamptz
);

create unique index payout_cards_one_active on public.payout_cards (driver_id) where removed_at is null;

alter table public.payouts add column card_id uuid references public.payout_cards (id);

-- ---------- блокировка пассажиров водителем ----------
create table public.driver_blocks (
  driver_id uuid not null references public.drivers (user_id) on delete cascade,
  passenger_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (driver_id, passenger_id)
);

create index driver_blocks_passenger on public.driver_blocks (passenger_id);

-- ---------- заявки на новые маршруты ----------
create table public.route_requests (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers (user_id) on delete cascade,
  from_text text not null check (length(from_text) between 2 and 100),
  to_text text not null check (length(to_text) between 2 and 100),
  comment text check (length(comment) <= 500),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  reason text,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create index route_requests_status on public.route_requests (status, created_at);

-- ---------- оценка пассажиров водителем ----------
-- Оценка в брони приложениям не показывается: пассажир видит только свой общий рейтинг.
alter table public.bookings add column driver_rating int check (driver_rating between 1 and 5);
alter table public.profiles add column passenger_rating numeric(2, 1) not null default 5.0;
alter table public.profiles add column passenger_rating_count int not null default 0;

-- ---------- кто что видит ----------
alter table public.driver_documents enable row level security;
alter table public.payout_cards enable row level security;
alter table public.driver_blocks enable row level security;
alter table public.route_requests enable row level security;

revoke all on public.driver_documents, public.payout_cards, public.driver_blocks, public.route_requests from anon, authenticated;

-- Документы: сам водитель и проверяющий.
grant select on public.driver_documents to authenticated;
create policy driver_documents_read on public.driver_documents for select to authenticated
  using (driver_id = auth.uid() or public.has_role('verifier'));

-- Карта для выплат: водитель — свою (без метки банка); проверяющий сверяет имя; финансы — для реестра выплат.
grant select (id, driver_id, brand, last4, holder_name, created_at, active_from, removed_at) on public.payout_cards to authenticated;
create policy payout_cards_read on public.payout_cards for select to authenticated
  using (driver_id = auth.uid() or public.has_role('verifier') or public.has_role('finance'));

-- Блокировки: видит только водитель, который заблокировал. Пассажиру о блокировке не сообщается.
grant select on public.driver_blocks to authenticated;
create policy driver_blocks_read on public.driver_blocks for select to authenticated
  using (driver_id = auth.uid() or public.has_role('support'));

-- Заявки на маршруты: свои — водитель; все — модератор.
grant select on public.route_requests to authenticated;
create policy route_requests_read on public.route_requests for select to authenticated
  using (driver_id = auth.uid() or public.has_role('moderator'));

-- Заблокированный пассажир не видит рейсов этого водителя — кроме рейсов, на которые у него уже есть бронь (билет).
create function public._can_see_trip(p_driver uuid, p_trip uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select not exists (select 1 from driver_blocks where driver_id = p_driver and passenger_id = auth.uid())
      or exists (select 1 from bookings where trip_id = p_trip and passenger_id = auth.uid())
$$;

drop policy trips_read on public.trips;
create policy trips_read on public.trips for select to authenticated
  using (public._can_see_trip(driver_id, id));

drop policy trip_seats_read on public.trip_seats;
create policy trip_seats_read on public.trip_seats for select to authenticated
  using (exists (select 1 from public.trips t where t.id = trip_id));

-- Витрина водителей: заблокированный пассажир этого водителя не видит.
create or replace view public.driver_public with (security_barrier = true) as
  select d.user_id, p.name, d.rating, d.rating_count, d.car, d.car_color, d.plate, d.seats_total
  from public.drivers d
  join public.profiles p on p.id = d.user_id
  where d.status = 'approved' and not p.blocked
    and not exists (select 1 from public.driver_blocks b where b.driver_id = d.user_id and b.passenger_id = auth.uid());

-- ---------- служебное ----------

-- Код из SMS вводили недавно (не больше [minutes] минут назад). Supabase записывает время входа по коду
-- в токен (amr: [{"method": "otp", "timestamp": ...}]), и при обновлении токена оно не меняется.
create function public._recent_sms(p_minutes int) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) a
    where a ->> 'method' in ('otp', 'sms')
      and (a ->> 'timestamp') ~ '^[0-9]{1,12}$'
      and (a ->> 'timestamp')::bigint >= extract(epoch from now())::bigint - p_minutes * 60
  )
$$;

-- Водитель (любой статус заявки, кроме заблокированного). Возвращает статус.
create function public._driver_self() returns public.driver_status
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare st driver_status;
begin
  select status into st from drivers where user_id = _uid();
  if not found then raise exception 'NOT_A_DRIVER'; end if;
  if st = 'blocked' then raise exception 'DRIVER_BLOCKED'; end if;
  return st;
end $$;

-- ---------- документы ----------

-- Записать загруженный документ. Файл приложение кладёт в хранилище в папку водителя: <его id>/<вид>.jpg.
-- Пока заявка одобрена, документы не меняются: замена — через новую заявку (apply_driver).
create function public.driver_save_document(p_kind text, p_path text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  u uuid := _uid();
  st driver_status;
begin
  select status into st from drivers where user_id = u for no key update;
  if not found then raise exception 'NOT_A_DRIVER'; end if;
  if st = 'blocked' then raise exception 'DRIVER_BLOCKED'; end if;
  if st = 'approved' then raise exception 'DRIVER_ALREADY_APPROVED'; end if;
  if p_kind is null or p_kind not in ('id_document', 'license', 'registration', 'car_photo', 'selfie') then
    raise exception 'BAD_DOCUMENT_KIND';
  end if;
  if p_path is null or p_path not like u::text || '/%' or length(p_path) > 300 or p_path ~ '\.\.' then
    raise exception 'BAD_DOCUMENT_PATH';
  end if;
  insert into driver_documents (driver_id, kind, storage_path) values (u, p_kind, p_path)
  on conflict (driver_id, kind) do update set storage_path = excluded.storage_path, uploaded_at = now();
end $$;

-- ---------- карта для выплат ----------

-- Привязать карту для выплат (симуляция банка). Нужен свежий вход по SMS (не старше 10 минут).
-- Первая карта действует сразу, новая вместо старой — через 24 часа.
create function public.driver_set_payout_card_sim(p_number text, p_holder text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  u uuid := _uid();
  num text := regexp_replace(coalesce(p_number, ''), '\s', '', 'g');
  holder text := upper(_trim(p_holder));
  had_card boolean;
  cid uuid;
begin
  perform _driver_self();
  if num !~ '^[0-9]{16}$' then raise exception 'BAD_CARD_NUMBER'; end if;
  if holder is null or length(holder) not between 2 and 60 then raise exception 'BAD_HOLDER_NAME'; end if;
  if not _recent_sms(10) then raise exception 'REAUTH_REQUIRED'; end if;
  perform 1 from drivers where user_id = u for no key update;        -- смены карты одного водителя идут по очереди
  update payout_cards set removed_at = now() where driver_id = u and removed_at is null;
  had_card := found;
  insert into payout_cards (driver_id, token, brand, last4, holder_name, active_from)
  values (u, 'sim_' || replace(gen_random_uuid()::text, '-', ''),
    case left(num, 1) when '4' then 'Visa' when '5' then 'Mastercard' when '9' then 'ArCa' else 'Карта' end,
    right(num, 4), holder,
    case when had_card then app_now() + interval '24 hours' else app_now() end)
  returning id into cid;
  perform _audit('set_payout_card', 'driver', u::text, jsonb_build_object('last4', right(num, 4), 'replaced', had_card));
  return cid;
end $$;

-- ---------- блокировка пассажиров ----------

-- Заблокировать пассажира, с которым водитель ездил (или который купил место в его рейсе).
create function public.driver_block_passenger(p_passenger uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid := _uid();
begin
  perform _driver_self();
  if p_passenger is null then raise exception 'BAD_ARGUMENT'; end if;
  if p_passenger = u then raise exception 'FORBIDDEN'; end if;
  -- Чужих людей блокировать нельзя: только тех, кто покупал места в рейсах этого водителя.
  if not exists (
    select 1 from bookings b join trips t on t.id = b.trip_id
    where t.driver_id = u and b.passenger_id = p_passenger and b.status <> 'failed'
  ) then
    raise exception 'PASSENGER_NOT_FOUND';
  end if;
  insert into driver_blocks (driver_id, passenger_id) values (u, p_passenger) on conflict do nothing;
end $$;

create function public.driver_unblock_passenger(p_passenger uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid := _uid();
begin
  perform _driver_self();
  delete from driver_blocks where driver_id = u and passenger_id = p_passenger;
end $$;

-- Список заблокированных для профиля водителя: имя и когда.
create function public.driver_blocked_passengers()
returns table (passenger_id uuid, passenger_name text, blocked_at timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  select b.passenger_id, p.name, b.created_at
  from driver_blocks b join profiles p on p.id = b.passenger_id
  where b.driver_id = public._uid()
  order by b.created_at desc
$$;

-- ---------- заявки на маршруты ----------

create function public.driver_request_route(p_from text, p_to text, p_comment text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  u uuid := _uid();
  rid uuid;
begin
  perform _driver_self();
  if coalesce(length(_trim(p_from)), 0) not between 2 and 100 or coalesce(length(_trim(p_to)), 0) not between 2 and 100
     or length(p_comment) > 500 then
    raise exception 'BAD_ARGUMENT';
  end if;
  perform 1 from drivers where user_id = u for no key update;
  if (select count(*) from route_requests where driver_id = u and status = 'pending') >= 5 then
    raise exception 'TOO_MANY_REQUESTS';
  end if;
  insert into route_requests (driver_id, from_text, to_text, comment)
  values (u, _trim(p_from), _trim(p_to), nullif(_trim(p_comment), ''))
  returning id into rid;
  return rid;
end $$;

create function public.staff_review_route_request(p_request uuid, p_accept boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u uuid := _require_role('moderator');
begin
  if p_accept is null then raise exception 'BAD_ARGUMENT'; end if;
  if not p_accept and coalesce(_trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED'; end if;
  update route_requests
  set status = case when p_accept then 'accepted' else 'rejected' end,
      reason = nullif(_trim(p_reason), ''), reviewed_by = u, reviewed_at = now()
  where id = p_request and status = 'pending';
  if not found then
    if exists (select 1 from route_requests where id = p_request) then raise exception 'ALREADY_REVIEWED'; end if;
    raise exception 'REQUEST_NOT_FOUND';
  end if;
  perform _audit(case when p_accept then 'accept_route_request' else 'reject_route_request' end,
    'route_request', p_request::text, jsonb_build_object('reason', p_reason));
end $$;

-- ---------- оценка пассажиров ----------

create function public.driver_rate_passenger(p_booking uuid, p_stars int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  u uuid := _uid();
  v_trip uuid;
  v_pass uuid;
  b bookings;
begin
  if p_stars is null or p_stars not between 1 and 5 then raise exception 'BAD_RATING'; end if;
  select bk.trip_id, bk.passenger_id into v_trip, v_pass
  from bookings bk join trips t on t.id = bk.trip_id
  where bk.id = p_booking and t.driver_id = u;
  if not found then raise exception 'BOOKING_NOT_FOUND'; end if;
  perform 1 from drivers where user_id = u for no key update;
  perform 1 from profiles where id = v_pass for no key update;       -- оценки одного пассажира считаются по очереди
  select * into b from bookings where id = p_booking for no key update;
  if b.status <> 'done' then raise exception 'TRIP_NOT_FINISHED'; end if;
  if b.driver_rating is not null then raise exception 'ALREADY_RATED'; end if;
  update bookings set driver_rating = p_stars where id = b.id;
  update profiles p set passenger_rating_count = s.cnt, passenger_rating = round(s.avg, 1)
  from (select count(*) as cnt, avg(driver_rating) as avg from bookings where passenger_id = v_pass and driver_rating is not null) s
  where p.id = v_pass;
end $$;

-- ---------- кто что может вызывать ----------
revoke execute on function
  public._can_see_trip(uuid, uuid), public._recent_sms(int), public._driver_self(),
  public.driver_save_document(text, text), public.driver_set_payout_card_sim(text, text),
  public.driver_block_passenger(uuid), public.driver_unblock_passenger(uuid), public.driver_blocked_passengers(),
  public.driver_request_route(text, text, text), public.staff_review_route_request(uuid, boolean, text),
  public.driver_rate_passenger(uuid, int)
from public, anon, authenticated;

-- _can_see_trip вызывается из правила видимости рейсов, поэтому вошедшим она нужна.
grant execute on function
  public._can_see_trip(uuid, uuid),
  public.driver_save_document(text, text), public.driver_set_payout_card_sim(text, text),
  public.driver_block_passenger(uuid), public.driver_unblock_passenger(uuid), public.driver_blocked_passengers(),
  public.driver_request_route(text, text, text), public.staff_review_route_request(uuid, boolean, text),
  public.driver_rate_passenger(uuid, int)
to authenticated;

grant execute on all functions in schema public to service_role;
grant all on public.driver_documents, public.payout_cards, public.driver_blocks, public.route_requests to service_role;
