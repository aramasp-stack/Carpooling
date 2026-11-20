-- Места машины и место высадки.
-- 1) В легковой машине сзади не больше двух пассажиров: мест для продажи — переднее (front) и два сзади (rl, rr),
--    среднего места (rm) больше нет. В анкете водитель отмечает, какие из этих мест вообще продаёт (seat_ids);
--    в каждом рейсе он выставляет все эти места или часть из них.
-- 2) Место высадки: водитель может указать его в конечном районе маршрута (drop_along, метры от начала линии).
--    Не указано — конец маршрута. Все пассажиры выходят там.
-- 3) Точные места посадки и высадки: водитель отмечает на карте любую точку — дом, двор, остановку — внутри круга
--    радиусом area_radius_m вокруг начальной (конечной) точки маршрута, а не только на линии. Так машины не обязаны
--    стоять в одной точке, а пассажир выбирает удобное место. meet_along / drop_along остаются: это ближайшие
--    к точкам места на линии, по ним считается время в пути.

insert into public.app_settings (key, value) values
  ('end_district_m', '1500'),       -- конечный район маршрута: место высадки не дальше стольких метров от конца
  ('area_radius_m', '1500')         -- точное место посадки (высадки) — не дальше стольких метров от начала (конца) маршрута
on conflict (key) do nothing;
update public.app_settings set value = '3' where key = 'max_seats_per_booking';

-- ---------- анкета: какие места машины продаются ----------
alter table public.drivers add column seat_ids text[] not null default '{front,rl,rr}';
alter table public.drivers alter column seat_ids drop default;
alter table public.drivers add constraint drivers_seat_ids_check check (
  array_ndims(seat_ids) = 1 and cardinality(seat_ids) between 1 and 3 and seat_ids <@ array['front', 'rl', 'rr']);
alter table public.drivers drop constraint drivers_seats_total_check;
update public.drivers set seats_total = cardinality(seat_ids);
alter table public.drivers add constraint drivers_seats_total_check check (seats_total = cardinality(seat_ids));

alter table public.trip_seats drop constraint trip_seats_seat_id_check;
alter table public.trip_seats add constraint trip_seats_seat_id_check check (seat_id in ('front', 'rl', 'rr'));
alter table public.bookings drop constraint bookings_seat_ids_check;
alter table public.bookings add constraint bookings_seat_ids_check check (array_ndims(seat_ids) = 1 and cardinality(seat_ids) between 1 and 3);

-- ---------- рейс: место высадки и точные места на карте ----------
alter table public.trips add column drop_along int check (drop_along >= 0);   -- null — конец маршрута
alter table public.trips
  add column meet_lat double precision, add column meet_lon double precision,   -- null — место на линии (meet_along)
  add column drop_lat double precision, add column drop_lon double precision,   -- null — место на линии (drop_along)
  add constraint trips_meet_point_check check ((meet_lat is null) = (meet_lon is null)
    and coalesce(meet_lat between -90 and 90 and meet_lon between -180 and 180, true)),
  add constraint trips_drop_point_check check ((drop_lat is null) = (drop_lon is null)
    and coalesce(drop_lat between -90 and 90 and drop_lon between -180 and 180, true));

-- Расстояние между точками по поверхности Земли, метры (как в приложении).
create function private._distance_m(lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision)
returns double precision language sql immutable set search_path = public, pg_temp as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)))
$$;
revoke execute on function private._distance_m(double precision, double precision, double precision, double precision)
  from public, anon, authenticated;

-- ---------- анкета водителя ----------
drop function public.apply_driver(text, text, text, int, text);

-- p_seat_ids — места, которые водитель вообще продаёт: любые из front, rl, rr, хотя бы одно, без повторов.
create function public.apply_driver(p_car text, p_car_color text, p_plate text, p_seat_ids text[], p_tax_id text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  u uuid := _uid();
  st driver_status;
begin
  if coalesce(length(_trim(p_car)), 0) not between 1 and 60
     or coalesce(length(_trim(p_car_color)), 0) not between 1 and 30
     or coalesce(length(_trim(p_plate)), 0) not between 1 and 20
     or coalesce(length(_trim(p_tax_id)), 0) not between 1 and 20 then
    raise exception 'BAD_ARGUMENT';
  end if;
  if p_seat_ids is null or array_ndims(p_seat_ids) is distinct from 1 or cardinality(p_seat_ids) not between 1 and 3
     or not (p_seat_ids <@ array['front', 'rl', 'rr'])
     or cardinality(p_seat_ids) <> (select count(distinct x) from unnest(p_seat_ids) x) then
    raise exception 'BAD_SEATS_TOTAL';
  end if;

  select status into st from drivers where user_id = u for no key update;
  if st = 'blocked' then raise exception 'DRIVER_BLOCKED'; end if;
  -- Менять машину можно, только когда нет предстоящих рейсов: места в них уже выставлены и проданы.
  if exists (select 1 from trips where driver_id = u and status in ('planned', 'started')) then
    raise exception 'DRIVER_HAS_ACTIVE_TRIPS';
  end if;
  insert into drivers (user_id, car, car_color, plate, seat_ids, seats_total, tax_id)
  values (u, _trim(p_car), _trim(p_car_color), _trim(p_plate),
          array(select s from unnest(array['front', 'rl', 'rr']) with ordinality as a(s, n) where s = any(p_seat_ids) order by n),
          cardinality(p_seat_ids), _trim(p_tax_id))
  on conflict (user_id) do update set car = excluded.car, car_color = excluded.car_color, plate = excluded.plate,
    seat_ids = excluded.seat_ids, seats_total = excluded.seats_total, tax_id = excluded.tax_id,
    status = 'pending', reject_reason = null, reviewed_by = null, reviewed_at = null;
  perform _audit('apply_driver', 'driver', u::text);
end $$;

-- ---------- новый рейс ----------
drop function public.driver_create_trip(uuid, timestamptz, int, jsonb);

-- Поставить рейс на готовый маршрут. p_seats — места, которые продаются, с ценами (только из мест анкеты):
--   [{"id": "front", "price": 600}, {"id": "rl", "price": 500}]
-- p_drop_along — место высадки в конечном районе маршрута (null — конец маршрута).
-- p_meet_lat/lon, p_drop_lat/lon — точные места посадки и высадки на карте (null — места на линии).
create function public.driver_create_trip(p_route uuid, p_departure timestamptz, p_meet_along int, p_seats jsonb,
                                          p_drop_along int default null,
                                          p_meet_lat double precision default null, p_meet_lon double precision default null,
                                          p_drop_lat double precision default null, p_drop_lon double precision default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  u uuid := _uid();
  d drivers;
  r routes;
  n timestamptz := app_now();
  v_end timestamptz;
  tid uuid;
  cnt int;
begin
  select * into d from drivers where user_id = u for no key update;   -- рейсы одного водителя ставятся по очереди
  if not found or d.status <> 'approved' then raise exception 'DRIVER_NOT_APPROVED'; end if;
  if exists (select 1 from profiles where id = u and blocked) then raise exception 'BLOCKED'; end if;   -- заблокировали, пока ждали очереди
  -- Маршрут блокируется от изменений: модератор не снимет его, пока рейс ставится.
  select * into r from routes where id = p_route for share;
  if not found or r.status <> 'published' then raise exception 'ROUTE_NOT_AVAILABLE'; end if;

  if p_departure is null or p_departure < n + make_interval(mins => setting_int('trip_min_lead_minutes')) then
    raise exception 'DEPARTURE_TOO_SOON';
  end if;
  if p_departure > n + make_interval(days => setting_int('trip_days_ahead')) then raise exception 'DEPARTURE_TOO_FAR'; end if;

  -- Место посадки — только в начальном районе маршрута.
  if p_meet_along is null or p_meet_along < 0 or p_meet_along > least(setting_int('start_district_m'), r.length_m) then
    raise exception 'MEET_POINT_OUTSIDE_DISTRICT';
  end if;
  -- Место высадки — только в конечном районе маршрута и дальше места посадки.
  if p_drop_along is not null
     and (p_drop_along > r.length_m
          or p_drop_along < r.length_m - setting_int('end_district_m')
          or p_drop_along <= p_meet_along) then
    raise exception 'DROP_POINT_OUTSIDE_DISTRICT';
  end if;
  -- Точное место посадки — внутри круга у начала маршрута, высадки — внутри круга у конца.
  if (p_meet_lat is null) <> (p_meet_lon is null)
     or (p_meet_lat is not null and (p_meet_lat not between -90 and 90 or p_meet_lon not between -180 and 180
         or private._distance_m(p_meet_lat, p_meet_lon, r.from_lat, r.from_lon) > setting_int('area_radius_m'))) then
    raise exception 'MEET_POINT_OUTSIDE_DISTRICT';
  end if;
  if (p_drop_lat is null) <> (p_drop_lon is null)
     or (p_drop_lat is not null and (p_drop_lat not between -90 and 90 or p_drop_lon not between -180 and 180
         or private._distance_m(p_drop_lat, p_drop_lon, r.to_lat, r.to_lon) > setting_int('area_radius_m'))) then
    raise exception 'DROP_POINT_OUTSIDE_DISTRICT';
  end if;

  if p_seats is null or jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) = 0 then raise exception 'BAD_SEATS'; end if;
  if exists (select 1 from jsonb_array_elements(p_seats) s where jsonb_typeof(s) <> 'object') then raise exception 'BAD_SEATS'; end if;
  -- Продавать можно только места, отмеченные в анкете, и каждое — один раз.
  select count(*) into cnt from jsonb_array_elements(p_seats) s where (s ->> 'id') = any(d.seat_ids);
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
  -- Цену ставит водитель, но не ниже минимума маршрута: с неё платятся комиссия и госпошлина.
  if exists (select 1 from jsonb_array_elements(p_seats) s where (s ->> 'price')::int < r.min_price) then
    raise exception 'PRICE_BELOW_MINIMUM';
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

  insert into trips (route_id, driver_id, departure, ends_at, meet_along, drop_along, meet_lat, meet_lon, drop_lat, drop_lon)
  values (p_route, u, p_departure, v_end, p_meet_along, p_drop_along, p_meet_lat, p_meet_lon, p_drop_lat, p_drop_lon)
  returning id into tid;
  insert into trip_seats (trip_id, seat_id, price)
  select tid, s ->> 'id', (s ->> 'price')::int from jsonb_array_elements(p_seats) s;
  return tid;
end $$;

-- ---------- кто может вызывать ----------
revoke execute on function
  public.apply_driver(text, text, text, text[], text),
  public.driver_create_trip(uuid, timestamptz, int, jsonb, int, double precision, double precision, double precision, double precision)
from public, anon, authenticated;
grant execute on function
  public.apply_driver(text, text, text, text[], text),
  public.driver_create_trip(uuid, timestamptz, int, jsonb, int, double precision, double precision, double precision, double precision)
to authenticated, service_role;
