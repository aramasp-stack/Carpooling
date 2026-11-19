-- TransportApp, этап A: таблицы.
-- Правило: приложения только читают таблицы (см. файл с правилами доступа).
-- Любое изменение идёт через серверные функции (см. файл с функциями), которые проверяют, кто просит и можно ли.

-- ---------- настройки ----------
create table public.app_settings (
  key text primary key,
  value jsonb not null
);

insert into public.app_settings (key, value) values
  ('commission_percent', '10'),       -- комиссия платформы, % (пример, не утверждено)
  ('state_percent', '4'),             -- госпошлина онлайн-платформы, %
  ('free_cancel_minutes', '60'),      -- бесплатная отмена не позже чем за столько минут до отправления
  ('accrual_delay_hours', '24'),      -- через сколько часов после рейса доля водителя доступна к выплате
  ('booking_close_minutes', '5'),     -- за сколько минут до отправления закрывается продажа
  ('max_seats_per_booking', '4'),
  ('trip_days_ahead', '7'),           -- на сколько дней вперёд водитель может поставить рейс
  ('trip_min_lead_minutes', '15'),    -- рейс нельзя поставить ближе чем за столько минут
  ('start_district_m', '1500'),       -- начальный район маршрута: место посадки не дальше стольких метров от начала
  ('max_cards', '5'),
  ('clock_offset_seconds', '0');      -- только для тестов: сдвиг «часов» сервера

create function public.setting_int(k text) returns int
language sql stable security definer set search_path = public as $$
  select (value #>> '{}')::int from app_settings where key = k
$$;

-- «Сейчас» для всех правил. В тестах часы сдвигаются настройкой clock_offset_seconds.
create function public.app_now() returns timestamptz
language sql stable security definer set search_path = public as $$
  select now() + make_interval(secs => coalesce((select (value #>> '{}')::double precision from app_settings where key = 'clock_offset_seconds'), 0))
$$;

-- ---------- люди ----------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  phone text not null unique,
  name text not null check (length(btrim(name)) between 1 and 60),
  lang text not null default 'ru' check (lang in ('hy', 'ru', 'en')),
  blocked boolean not null default false,
  created_at timestamptz not null default now()
);

-- Сотрудники и их роли: moderator (маршруты), verifier (проверка водителей),
-- support (поддержка), finance (деньги), owner (всё и назначение ролей).
create table public.staff (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  roles text[] not null check (roles <@ array['moderator', 'verifier', 'support', 'finance', 'owner']::text[])
);

create type public.driver_status as enum ('pending', 'approved', 'rejected', 'blocked');

create table public.drivers (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  status public.driver_status not null default 'pending',
  car text not null check (length(btrim(car)) between 1 and 60),
  car_color text not null check (length(btrim(car_color)) between 1 and 30),
  plate text not null check (length(btrim(plate)) between 1 and 20),
  seats_total int not null check (seats_total in (3, 4)),
  tax_id text not null check (length(btrim(tax_id)) between 1 and 20),
  rating numeric(2, 1) not null default 5.0,
  rating_count int not null default 0,
  reject_reason text,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------- маршруты (создаёт только модератор) ----------
create type public.route_status as enum ('draft', 'published', 'archived');

create table public.routes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9]{1,8}$'),
  from_name text not null,
  from_lat double precision not null,
  from_lon double precision not null,
  to_name text not null,
  to_lat double precision not null,
  to_lon double precision not null,
  base_price int not null check (base_price > 0),      -- базовая цена места, драм
  minutes int not null check (minutes > 0),            -- время в пути по расписанию
  length_m int not null check (length_m > 0),          -- длина по дорогам, метры
  color bigint not null default 4283388645,            -- цвет линии, 0xAARRGGBB
  status public.route_status not null default 'draft',
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- рейсы (ставит водитель на готовый маршрут) ----------
create type public.trip_status as enum ('planned', 'started', 'finished', 'cancelled');

create table public.trips (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.routes (id),
  driver_id uuid not null references public.drivers (user_id),
  departure timestamptz not null,                      -- отправление от места посадки
  ends_at timestamptz not null,                        -- отправление + время в пути по расписанию
  meet_along int not null check (meet_along >= 0),     -- место посадки: метры от начала маршрута
  status public.trip_status not null default 'planned',
  started_at timestamptz,
  finished_at timestamptz,
  accrued_at timestamptz,                              -- когда начислили доли по этому рейсу
  created_at timestamptz not null default now(),
  check (ends_at > departure)
);

create index trips_route_departure on public.trips (route_id, departure);
create index trips_driver_departure on public.trips (driver_id, departure);

-- ---------- карты (в базе только токен банка, номера карты нет) ----------
create table public.cards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  token text not null unique,
  brand text not null,
  last4 text not null check (last4 ~ '^[0-9]{4}$'),
  created_at timestamptz not null default now(),
  removed_at timestamptz
);

-- ---------- брони ----------
create type public.booking_status as enum ('failed', 'paid', 'cancelled', 'done');

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id),
  passenger_id uuid not null references public.profiles (id),
  seat_ids text[] not null check (cardinality(seat_ids) between 1 and 4),
  amount int not null check (amount > 0),
  status public.booking_status not null,
  refund int not null default 0 check (refund >= 0),
  card_id uuid references public.cards (id),
  idem_key text not null,                              -- номер операции от приложения: повтор не спишет дважды
  rating int check (rating between 1 and 5),
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  unique (passenger_id, idem_key),
  check (refund <= amount)
);

create index bookings_trip on public.bookings (trip_id);
create index bookings_passenger on public.bookings (passenger_id, created_at desc);

-- Места рейса. Место занято, когда booking_id не пустой. Первичный ключ не даёт завести одно место дважды.
create table public.trip_seats (
  trip_id uuid not null references public.trips (id) on delete cascade,
  seat_id text not null check (seat_id in ('front', 'rl', 'rm', 'rr')),
  price int not null check (price > 0),
  booking_id uuid references public.bookings (id),
  boarding text check (boarding in ('boarded', 'no_show')),
  primary key (trip_id, seat_id)
);

create index trip_seats_booking on public.trip_seats (booking_id) where booking_id is not null;

-- ---------- деньги ----------
-- Обращения к банку: списания и возвраты, удачные и нет.
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id),
  kind text not null check (kind in ('charge', 'refund')),
  amount int not null check (amount > 0),
  ok boolean not null,
  bank_ref text,
  created_at timestamptz not null default now()
);

create index payments_booking on public.payments (booking_id);

create table public.payouts (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers (user_id),
  amount int not null check (amount > 0),
  status text not null default 'created' check (status in ('created', 'paid')),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

-- Журнал денег: только дополняется. Ошибка исправляется новой записью, а не правкой старой.
--   charge          пассажир заплатил
--   refund          пассажиру вернули
--   driver_accrual  начислено водителю
--   commission      комиссия платформы
--   state_duty      госпошлина
--   payout          выплачено водителю
create table public.ledger (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  kind text not null check (kind in ('charge', 'refund', 'driver_accrual', 'commission', 'state_duty', 'payout')),
  amount int not null check (amount > 0),
  booking_id uuid references public.bookings (id),
  trip_id uuid references public.trips (id),
  driver_id uuid references public.drivers (user_id),
  payout_id uuid references public.payouts (id)
);

create index ledger_booking on public.ledger (booking_id);
create index ledger_driver on public.ledger (driver_id, kind);

-- Журнал действий сотрудников и важных событий: тоже только дополняется.
create table public.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor uuid,
  action text not null,
  entity text,
  entity_id text,
  details jsonb
);

create function public._forbid_change() returns trigger language plpgsql as $$
begin
  raise exception 'APPEND_ONLY: записи в % нельзя менять и удалять', tg_table_name;
end $$;

create trigger ledger_append_only before update or delete on public.ledger
  for each row execute function public._forbid_change();
create trigger ledger_no_truncate before truncate on public.ledger
  for each statement execute function public._forbid_change();
create trigger audit_append_only before update or delete on public.audit_log
  for each row execute function public._forbid_change();
create trigger audit_no_truncate before truncate on public.audit_log
  for each statement execute function public._forbid_change();
