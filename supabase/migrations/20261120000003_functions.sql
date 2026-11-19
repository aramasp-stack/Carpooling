-- TransportApp, этап A: серверные функции — единственный способ что-то изменить.
-- Каждая функция сама проверяет, кто просит и можно ли. Отказ — исключение с кодом ЗАГЛАВНЫМИ буквами
-- (например SEAT_TAKEN); приложение переводит код в понятный текст.

-- ---------- служебное ----------

-- Вошедший пользователь с профилем и без блокировки.
create function public._uid() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare
  u uuid := auth.uid();
  is_blocked boolean;
begin
  if u is null then raise exception 'NOT_SIGNED_IN'; end if;
  select blocked into is_blocked from profiles where id = u;
  if not found then raise exception 'NO_PROFILE'; end if;
  if is_blocked then raise exception 'BLOCKED'; end if;
  return u;
end $$;

create function public._require_role(r text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare u uuid := _uid();
begin
  if not has_role(r) then raise exception 'FORBIDDEN'; end if;
  return u;
end $$;

create function public._audit(p_action text, p_entity text, p_entity_id text, p_details jsonb default null) returns void
language sql security definer set search_path = public as $$
  insert into audit_log (actor, action, entity, entity_id, details)
  values (auth.uid(), p_action, p_entity, p_entity_id, p_details)
$$;

-- ---------- симулятор банка ----------
-- Единственное место, где «работает банк». Когда появится настоящий банк, заменяется только оно.
-- Тестовые карты: номер заканчивается на 0002 — банк отказывает; на 0119 — банк недоступен.

create function public._bank_charge(p_last4 text, p_amount int) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_last4 = '0119' then raise exception 'BANK_UNAVAILABLE'; end if;
  return p_last4 <> '0002';
end $$;

-- Возврат на карту. В симуляции всегда проходит.
create function public._refund(p_booking uuid, p_amount int) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking;
  insert into payments (booking_id, kind, amount, ok, bank_ref)
  values (p_booking, 'refund', p_amount, true, 'sim-' || gen_random_uuid());
  insert into ledger (kind, amount, booking_id, trip_id) values ('refund', p_amount, p_booking, b.trip_id);
end $$;

-- ---------- профиль ----------

-- После входа по SMS: имя и язык. Телефон берётся из токена входа, а не от приложения.
create function public.register_profile(p_name text, p_lang text default 'ru') returns void
language plpgsql security definer set search_path = public as $$
declare
  u uuid := auth.uid();
  ph text;
begin
  if u is null then raise exception 'NOT_SIGNED_IN'; end if;
  ph := coalesce(nullif(auth.jwt() ->> 'phone', ''), (select phone from auth.users where id = u));
  if ph is null then raise exception 'NO_PHONE'; end if;
  insert into profiles (id, phone, name, lang) values (u, ph, btrim(p_name), p_lang)
  on conflict (id) do update set name = excluded.name, lang = excluded.lang;
end $$;

-- ---------- сотрудники ----------

create function public.staff_set_roles(p_user uuid, p_roles text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_role('owner');
  if p_roles is null or cardinality(p_roles) = 0 then
    delete from staff where user_id = p_user;
  else
    insert into staff (user_id, roles) values (p_user, p_roles)
    on conflict (user_id) do update set roles = excluded.roles;
  end if;
  perform _audit('staff_set_roles', 'profile', p_user::text, jsonb_build_object('roles', p_roles));
end $$;

create function public.staff_block_user(p_user uuid, p_blocked boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_role('support');
  update profiles set blocked = p_blocked where id = p_user;
  if not found then raise exception 'USER_NOT_FOUND'; end if;
  perform _audit(case when p_blocked then 'block_user' else 'unblock_user' end, 'profile', p_user::text);
end $$;

-- ---------- маршруты (модератор) ----------

create function public.staff_save_route(
  p_id uuid, p_code text,
  p_from_name text, p_from_lat double precision, p_from_lon double precision,
  p_to_name text, p_to_lat double precision, p_to_lon double precision,
  p_base_price int, p_minutes int, p_length_m int, p_color bigint default 4283388645
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _require_role('moderator');
  rid uuid;
begin
  if p_id is null then
    insert into routes (code, from_name, from_lat, from_lon, to_name, to_lat, to_lon, base_price, minutes, length_m, color, created_by)
    values (p_code, p_from_name, p_from_lat, p_from_lon, p_to_name, p_to_lat, p_to_lon, p_base_price, p_minutes, p_length_m, p_color, u)
    returning id into rid;
  else
    update routes set code = p_code, from_name = p_from_name, from_lat = p_from_lat, from_lon = p_from_lon,
      to_name = p_to_name, to_lat = p_to_lat, to_lon = p_to_lon,
      base_price = p_base_price, minutes = p_minutes, length_m = p_length_m, color = p_color, updated_at = now()
    where id = p_id
    returning id into rid;
    if rid is null then raise exception 'ROUTE_NOT_FOUND'; end if;
  end if;
  perform _audit('save_route', 'route', rid::text, jsonb_build_object('code', p_code, 'base_price', p_base_price));
  return rid;
end $$;

create function public.staff_set_route_status(p_route uuid, p_status public.route_status) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_role('moderator');
  -- Маршрут нельзя убрать, пока на нём есть будущие рейсы: пассажиры уже купили места.
  if p_status <> 'published' and exists (
    select 1 from trips where route_id = p_route and status in ('planned', 'started')
  ) then
    raise exception 'ROUTE_HAS_ACTIVE_TRIPS';
  end if;
  update routes set status = p_status, updated_at = now() where id = p_route;
  if not found then raise exception 'ROUTE_NOT_FOUND'; end if;
  perform _audit('set_route_status', 'route', p_route::text, jsonb_build_object('status', p_status));
end $$;

-- ---------- водитель: заявка и проверка ----------

create function public.apply_driver(p_car text, p_car_color text, p_plate text, p_seats_total int, p_tax_id text) returns void
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _uid();
  st driver_status;
begin
  select status into st from drivers where user_id = u for update;
  if st = 'blocked' then raise exception 'DRIVER_BLOCKED'; end if;
  if st = 'approved' and exists (select 1 from trips where driver_id = u and status in ('planned', 'started')) then
    raise exception 'DRIVER_HAS_ACTIVE_TRIPS';   -- менять машину можно, когда нет предстоящих рейсов
  end if;
  insert into drivers (user_id, car, car_color, plate, seats_total, tax_id)
  values (u, btrim(p_car), btrim(p_car_color), btrim(p_plate), p_seats_total, btrim(p_tax_id))
  on conflict (user_id) do update set car = excluded.car, car_color = excluded.car_color, plate = excluded.plate,
    seats_total = excluded.seats_total, tax_id = excluded.tax_id,
    status = 'pending', reject_reason = null, reviewed_by = null, reviewed_at = null;
  perform _audit('apply_driver', 'driver', u::text);
end $$;

create function public.staff_review_driver(p_driver uuid, p_approve boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := _require_role('verifier');
begin
  if not p_approve and coalesce(btrim(p_reason), '') = '' then raise exception 'REASON_REQUIRED'; end if;
  update drivers set status = case when p_approve then 'approved' else 'rejected' end::driver_status,
    reject_reason = case when p_approve then null else btrim(p_reason) end,
    reviewed_by = u, reviewed_at = now()
  where user_id = p_driver and status in ('pending', 'rejected', 'approved');
  if not found then raise exception 'DRIVER_NOT_FOUND'; end if;
  perform _audit(case when p_approve then 'approve_driver' else 'reject_driver' end, 'driver', p_driver::text,
    jsonb_build_object('reason', p_reason));
end $$;

-- ---------- водитель: рейсы ----------

-- Поставить рейс на готовый маршрут. p_seats — места, которые продаются, с ценами:
--   [{"id": "front", "price": 600}, {"id": "rl", "price": 500}]
create function public.driver_create_trip(p_route uuid, p_departure timestamptz, p_meet_along int, p_seats jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _uid();
  d drivers;
  r routes;
  n timestamptz := app_now();
  v_end timestamptz;
  tid uuid;
  cnt int;
begin
  select * into d from drivers where user_id = u for update;   -- рейсы одного водителя ставятся по очереди
  if not found or d.status <> 'approved' then raise exception 'DRIVER_NOT_APPROVED'; end if;
  select * into r from routes where id = p_route;
  if not found or r.status <> 'published' then raise exception 'ROUTE_NOT_AVAILABLE'; end if;

  if p_departure is null or p_departure < n + make_interval(mins => setting_int('trip_min_lead_minutes')) then
    raise exception 'DEPARTURE_TOO_SOON';
  end if;
  if p_departure > n + make_interval(days => setting_int('trip_days_ahead')) then raise exception 'DEPARTURE_TOO_FAR'; end if;

  -- Место посадки — только в начальном районе маршрута.
  if p_meet_along is null or p_meet_along < 0 or p_meet_along > least(setting_int('start_district_m'), r.length_m) then
    raise exception 'MEET_POINT_OUTSIDE_DISTRICT';
  end if;

  if p_seats is null or jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) = 0 then raise exception 'BAD_SEATS'; end if;
  select count(*) into cnt from jsonb_array_elements(p_seats) s
  where (s ->> 'id') in ('front', 'rl', 'rr') or ((s ->> 'id') = 'rm' and d.seats_total = 4);
  if cnt <> jsonb_array_length(p_seats)
     or cnt <> (select count(distinct s ->> 'id') from jsonb_array_elements(p_seats) s) then
    raise exception 'BAD_SEATS';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_seats) s
    where (s ->> 'price') is null or (s ->> 'price') !~ '^[0-9]{1,7}$'
       or (s ->> 'price')::int < 1 or (s ->> 'price')::int > r.base_price * 3
  ) then
    raise exception 'BAD_PRICE';
  end if;

  -- Один водитель не может быть в двух рейсах одновременно.
  v_end := p_departure + make_interval(mins => r.minutes);
  if exists (
    select 1 from trips t
    where t.driver_id = u and t.status in ('planned', 'started')
      and t.departure < v_end and t.ends_at > p_departure
  ) then
    raise exception 'TRIP_OVERLAP';
  end if;

  insert into trips (route_id, driver_id, departure, ends_at, meet_along)
  values (p_route, u, p_departure, v_end, p_meet_along)
  returning id into tid;
  insert into trip_seats (trip_id, seat_id, price)
  select tid, s ->> 'id', (s ->> 'price')::int from jsonb_array_elements(p_seats) s;
  return tid;
end $$;

-- Отмена рейса водителем: всем пассажирам полный возврат.
create function public.driver_cancel_trip(p_trip uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _uid();
  t trips;
  b bookings;
  refunded int := 0;
begin
  select * into t from trips where id = p_trip for update;
  if not found then raise exception 'TRIP_NOT_FOUND'; end if;
  if t.driver_id <> u and not has_role('support') then raise exception 'FORBIDDEN'; end if;
  if t.status <> 'planned' then raise exception 'TRIP_NOT_PLANNED'; end if;

  for b in select * from bookings where trip_id = p_trip and status in ('paid', 'cancelled') for update loop
    -- оплаченным — полный возврат; тем, кто отменил поздно и остался без возврата, тоже: рейса не было
    if b.amount - b.refund > 0 then
      perform _refund(b.id, b.amount - b.refund);
      refunded := refunded + 1;
    end if;
    update bookings set status = 'cancelled', refund = amount, cancelled_at = coalesce(cancelled_at, app_now()) where id = b.id;
  end loop;
  update trip_seats set booking_id = null, boarding = null where trip_id = p_trip;
  update trips set status = 'cancelled' where id = p_trip;
  perform _audit('cancel_trip', 'trip', p_trip::text, jsonb_build_object('refunded_bookings', refunded));
  return refunded;
end $$;

create function public.driver_start_trip(p_trip uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _uid();
  t trips;
begin
  select * into t from trips where id = p_trip for update;
  if not found then raise exception 'TRIP_NOT_FOUND'; end if;
  if t.driver_id <> u then raise exception 'FORBIDDEN'; end if;
  if t.status <> 'planned' then raise exception 'TRIP_NOT_PLANNED'; end if;
  if app_now() < t.departure - interval '15 minutes' then raise exception 'TOO_EARLY'; end if;
  update trips set status = 'started', started_at = app_now() where id = p_trip;
end $$;

-- Отметка у места: 'boarded' (сел), 'no_show' (не пришёл) или null (снять отметку).
create function public.driver_mark_boarding(p_trip uuid, p_seat text, p_mark text) returns void
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _uid();
  t trips;
begin
  select * into t from trips where id = p_trip for update;
  if not found then raise exception 'TRIP_NOT_FOUND'; end if;
  if t.driver_id <> u then raise exception 'FORBIDDEN'; end if;
  if t.status not in ('planned', 'started') then raise exception 'TRIP_CLOSED'; end if;
  if t.status = 'planned' and app_now() < t.departure - interval '15 minutes' then raise exception 'TOO_EARLY'; end if;
  if p_mark is not null and p_mark not in ('boarded', 'no_show') then raise exception 'BAD_MARK'; end if;
  update trip_seats set boarding = p_mark where trip_id = p_trip and seat_id = p_seat and booking_id is not null;
  if not found then raise exception 'SEAT_NOT_BOOKED'; end if;
end $$;

create function public._finish_trip(p_trip uuid, p_at timestamptz) returns void
language plpgsql security definer set search_path = public as $$
begin
  update trips set status = 'finished', finished_at = p_at where id = p_trip;
  update bookings set status = 'done' where trip_id = p_trip and status = 'paid';
end $$;

create function public.driver_finish_trip(p_trip uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _uid();
  t trips;
begin
  select * into t from trips where id = p_trip for update;
  if not found then raise exception 'TRIP_NOT_FOUND'; end if;
  if t.driver_id <> u then raise exception 'FORBIDDEN'; end if;
  if t.status <> 'started' then raise exception 'TRIP_NOT_STARTED'; end if;
  perform _finish_trip(p_trip, app_now());
end $$;

-- Пассажиры рейса для водителя: место, имя, отметка. Без телефонов.
create function public.trip_passengers(p_trip uuid)
returns table (seat_id text, passenger_name text, booking_id uuid, boarding text)
language plpgsql stable security definer set search_path = public as $$
declare u uuid := _uid();
begin
  if not exists (select 1 from trips where id = p_trip and driver_id = u) and not has_role('support') then
    raise exception 'FORBIDDEN';
  end if;
  return query
    select s.seat_id, p.name, s.booking_id, s.boarding
    from trip_seats s
    join bookings b on b.id = s.booking_id
    join profiles p on p.id = b.passenger_id
    where s.trip_id = p_trip
    order by s.seat_id;
end $$;

-- ---------- пассажир: карты ----------

-- Симуляция формы банка: номер карты нужен только чтобы «банк» выдал токен; в базу попадают
-- марка и последние четыре цифры. С настоящим банком номер вообще не дойдёт до нашего сервера.
create function public.bind_card_sim(p_number text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _uid();
  num text := regexp_replace(coalesce(p_number, ''), '\s', '', 'g');
  cid uuid;
begin
  if num !~ '^[0-9]{16}$' then raise exception 'BAD_CARD_NUMBER'; end if;
  if (select count(*) from cards where user_id = u and removed_at is null) >= setting_int('max_cards') then
    raise exception 'TOO_MANY_CARDS';
  end if;
  insert into cards (user_id, token, brand, last4)
  values (u, 'sim_' || replace(gen_random_uuid()::text, '-', ''),
    case left(num, 1) when '4' then 'Visa' when '5' then 'Mastercard' when '9' then 'ArCa' else 'Карта' end,
    right(num, 4))
  returning id into cid;
  return cid;
end $$;

create function public.remove_card(p_card uuid) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := _uid();
begin
  update cards set removed_at = now() where id = p_card and user_id = u and removed_at is null;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;
end $$;

-- ---------- пассажир: бронь ----------

-- Купить места. Всё или ничего: места свободны → списание → места заняты.
-- p_idem — номер операции от приложения: повторный вызов с тем же номером вернёт ту же бронь и не спишет снова.
-- Ответ: {"booking_id": ..., "status": "paid" | "failed", "amount": ...}
create function public.book_seats(p_trip uuid, p_seats text[], p_card uuid, p_idem text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _uid();
  t trips;
  c cards;
  b bookings;
  v_count int;
  v_taken int;
  v_amount int;
  bid uuid;
  charged boolean;
begin
  if coalesce(btrim(p_idem), '') = '' then raise exception 'IDEM_KEY_REQUIRED'; end if;

  -- Блокируем рейс: две покупки на один рейс выполняются строго по очереди.
  select * into t from trips where id = p_trip for update;
  if not found then raise exception 'TRIP_NOT_FOUND'; end if;

  select * into b from bookings where passenger_id = u and idem_key = p_idem;
  if found then
    return jsonb_build_object('booking_id', b.id, 'status', b.status, 'amount', b.amount, 'repeat', true);
  end if;

  if t.status <> 'planned' or t.departure <= app_now() + make_interval(mins => setting_int('booking_close_minutes')) then
    raise exception 'TRIP_CLOSED';
  end if;
  if t.driver_id = u then raise exception 'OWN_TRIP'; end if;

  if p_seats is null or cardinality(p_seats) = 0 or cardinality(p_seats) > setting_int('max_seats_per_booking')
     or cardinality(p_seats) <> (select count(distinct x) from unnest(p_seats) x) then
    raise exception 'BAD_SEATS';
  end if;
  select count(*), count(booking_id), coalesce(sum(price), 0) into v_count, v_taken, v_amount
  from trip_seats where trip_id = p_trip and seat_id = any (p_seats);
  if v_count <> cardinality(p_seats) then raise exception 'BAD_SEATS'; end if;
  if v_taken > 0 then raise exception 'SEAT_TAKEN'; end if;

  select * into c from cards where id = p_card and user_id = u and removed_at is null;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;

  charged := _bank_charge(c.last4, v_amount);
  bid := gen_random_uuid();

  if not charged then
    insert into bookings (id, trip_id, passenger_id, seat_ids, amount, status, card_id, idem_key)
    values (bid, p_trip, u, p_seats, v_amount, 'failed', c.id, p_idem);
    insert into payments (booking_id, kind, amount, ok) values (bid, 'charge', v_amount, false);
    return jsonb_build_object('booking_id', bid, 'status', 'failed', 'amount', v_amount, 'reason', 'CARD_DECLINED');
  end if;

  insert into bookings (id, trip_id, passenger_id, seat_ids, amount, status, card_id, idem_key)
  values (bid, p_trip, u, p_seats, v_amount, 'paid', c.id, p_idem);
  -- Вторая защита от двойной продажи, независимая от блокировки рейса: место занимается, только если оно свободно.
  update trip_seats set booking_id = bid where trip_id = p_trip and seat_id = any (p_seats) and booking_id is null;
  get diagnostics v_count = row_count;
  if v_count <> cardinality(p_seats) then raise exception 'SEAT_TAKEN'; end if;
  insert into payments (booking_id, kind, amount, ok, bank_ref) values (bid, 'charge', v_amount, true, 'sim-' || gen_random_uuid());
  insert into ledger (kind, amount, booking_id, trip_id) values ('charge', v_amount, bid, p_trip);
  return jsonb_build_object('booking_id', bid, 'status', 'paid', 'amount', v_amount);
end $$;

-- Отмена брони пассажиром. Не позже чем за 60 минут до отправления — полный возврат и места снова в продаже.
-- Позже — без возврата, места остаются за пассажиром, водитель получает свою долю.
create function public.cancel_booking(p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _uid();
  v_trip uuid;
  t trips;
  b bookings;
  v_refund int := 0;
begin
  select trip_id into v_trip from bookings where id = p_booking;
  if not found then raise exception 'BOOKING_NOT_FOUND'; end if;
  select * into t from trips where id = v_trip for update;          -- сначала рейс, потом бронь: порядок как в покупке
  select * into b from bookings where id = p_booking for update;
  if b.passenger_id <> u and not has_role('support') then raise exception 'BOOKING_NOT_FOUND'; end if;
  if b.status <> 'paid' then raise exception 'NOT_CANCELLABLE'; end if;
  if t.status <> 'planned' then raise exception 'TRIP_ALREADY_STARTED'; end if;

  if extract(epoch from t.departure - app_now()) >= setting_int('free_cancel_minutes') * 60 then
    v_refund := b.amount;
    perform _refund(b.id, v_refund);
    update trip_seats set booking_id = null, boarding = null where trip_id = t.id and booking_id = b.id;
  end if;
  update bookings set status = 'cancelled', refund = v_refund, cancelled_at = app_now() where id = b.id;
  return jsonb_build_object('booking_id', b.id, 'refund', v_refund);
end $$;

-- Оценка водителя после поездки.
create function public.rate_booking(p_booking uuid, p_stars int) returns void
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _uid();
  b bookings;
  v_driver uuid;
begin
  if p_stars is null or p_stars not between 1 and 5 then raise exception 'BAD_RATING'; end if;
  select * into b from bookings where id = p_booking and passenger_id = u for update;
  if not found then raise exception 'BOOKING_NOT_FOUND'; end if;
  if b.status <> 'done' then raise exception 'TRIP_NOT_FINISHED'; end if;
  if b.rating is not null then raise exception 'ALREADY_RATED'; end if;
  update bookings set rating = p_stars where id = b.id;
  select driver_id into v_driver from trips where id = b.trip_id;
  update drivers d set
    rating_count = s.cnt,
    rating = round(s.avg, 1)
  from (
    select count(*) as cnt, avg(bk.rating) as avg
    from bookings bk join trips tr on tr.id = bk.trip_id
    where tr.driver_id = v_driver and bk.rating is not null
  ) s
  where d.user_id = v_driver;
end $$;

-- ---------- деньги: начисления и выплаты ----------

-- Запускается по расписанию (и вручную финансистом).
-- 1) Закрывает рейсы, которые водитель забыл завершить. 2) Начисляет доли по рейсам, после которых прошло 24 часа.
-- Доля водителя = оплачено − комиссия − госпошлина; округление в пользу водителя (как в приложении).
create function public.accrue_due() returns int
language plpgsql security definer set search_path = public as $$
declare
  n timestamptz := app_now();
  cp int := setting_int('commission_percent');
  sp int := setting_int('state_percent');
  t trips;
  b bookings;
  kept int;
  v_commission int;
  v_duty int;
  done_trips int := 0;
begin
  if auth.uid() is not null then perform _require_role('finance'); end if;   -- без входа вызывает только расписание сервера

  for t in select * from trips where status in ('planned', 'started') and ends_at + interval '2 hours' < n for update loop
    perform _finish_trip(t.id, t.ends_at);
  end loop;

  for t in
    select * from trips
    where status = 'finished' and accrued_at is null
      and finished_at + make_interval(hours => setting_int('accrual_delay_hours')) <= n
    for update
  loop
    for b in select * from bookings where trip_id = t.id and status in ('done', 'cancelled') loop
      kept := b.amount - b.refund;                       -- что осталось у платформы после возвратов
      if kept > 0 then
        v_commission := (kept * cp) / 100;
        v_duty := (kept * sp) / 100;
        insert into ledger (kind, amount, booking_id, trip_id, driver_id)
        values ('driver_accrual', kept - v_commission - v_duty, b.id, t.id, t.driver_id);
        if v_commission > 0 then
          insert into ledger (kind, amount, booking_id, trip_id, driver_id) values ('commission', v_commission, b.id, t.id, t.driver_id);
        end if;
        if v_duty > 0 then
          insert into ledger (kind, amount, booking_id, trip_id, driver_id) values ('state_duty', v_duty, b.id, t.id, t.driver_id);
        end if;
      end if;
    end loop;
    update trips set accrued_at = n where id = t.id;
    done_trips := done_trips + 1;
  end loop;
  return done_trips;
end $$;

-- Сформировать выплаты: каждому водителю всё начисленное и ещё не выплаченное.
create function public.finance_create_payouts() returns int
language plpgsql security definer set search_path = public as $$
declare
  u uuid := _require_role('finance');
  r record;
  pid uuid;
  made int := 0;
begin
  lock table payouts in share row exclusive mode;     -- два финансиста не создадут выплаты дважды
  for r in
    select driver_id,
      sum(amount) filter (where kind = 'driver_accrual') - coalesce(sum(amount) filter (where kind = 'payout'), 0) as due
    from ledger where driver_id is not null and kind in ('driver_accrual', 'payout')
    group by driver_id
  loop
    if r.due > 0 then
      insert into payouts (driver_id, amount, created_by) values (r.driver_id, r.due, u) returning id into pid;
      insert into ledger (kind, amount, driver_id, payout_id) values ('payout', r.due, r.driver_id, pid);
      made := made + 1;
    end if;
  end loop;
  perform _audit('create_payouts', 'payout', null, jsonb_build_object('count', made));
  return made;
end $$;

create function public.finance_mark_paid(p_payout uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_role('finance');
  update payouts set status = 'paid', paid_at = now() where id = p_payout and status = 'created';
  if not found then raise exception 'PAYOUT_NOT_FOUND'; end if;
  perform _audit('mark_payout_paid', 'payout', p_payout::text);
end $$;

-- Заработок водителя: начислено, выплачено, к выплате.
create function public.driver_earnings() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'accrued', coalesce(sum(amount) filter (where kind = 'driver_accrual'), 0),
    'paid_out', coalesce(sum(amount) filter (where kind = 'payout'), 0),
    'to_pay', coalesce(sum(amount) filter (where kind = 'driver_accrual'), 0) - coalesce(sum(amount) filter (where kind = 'payout'), 0)
  )
  from ledger where driver_id = public._uid() and kind in ('driver_accrual', 'payout')
$$;

-- ---------- кто что может вызывать ----------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.setting_int(text), public.app_now(), public.has_role(text),
  public.register_profile(text, text),
  public.staff_set_roles(uuid, text[]), public.staff_block_user(uuid, boolean),
  public.staff_save_route(uuid, text, text, double precision, double precision, text, double precision, double precision, int, int, int, bigint),
  public.staff_set_route_status(uuid, public.route_status),
  public.apply_driver(text, text, text, int, text), public.staff_review_driver(uuid, boolean, text),
  public.driver_create_trip(uuid, timestamptz, int, jsonb), public.driver_cancel_trip(uuid),
  public.driver_start_trip(uuid), public.driver_mark_boarding(uuid, text, text), public.driver_finish_trip(uuid),
  public.trip_passengers(uuid),
  public.bind_card_sim(text), public.remove_card(uuid),
  public.book_seats(uuid, text[], uuid, text), public.cancel_booking(uuid), public.rate_booking(uuid, int),
  public.accrue_due(), public.finance_create_payouts(), public.finance_mark_paid(uuid), public.driver_earnings()
to authenticated;

grant execute on all functions in schema public to service_role;
