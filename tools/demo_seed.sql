-- Демо-данные для тестового облака (и локальной копии): маршруты, водители, рейсы на 3 дня, часть мест уже куплена.
-- Это НЕ миграция и не правило сервера: в настоящую базу сервиса не применяется.
--
-- Файл можно запускать повторно (например, раз в день): уже созданное не дублируется, добавляются только
-- рейсы на дни вперёд, которых ещё нет. Всё создаётся через серверные функции — те же, что вызывают приложения:
-- так демо-данные проходят все правила (цены, районы посадки, места машины, оплата, журнал денег).
--
-- Демо-люди не могут войти в приложение: у их номеров (+374 99 …) нет кода входа.
-- Номера телефонов демо-людей в приложениях никому не показываются.

do $seed$
declare
  -- Демо-сотрудник: публикует маршруты и одобряет демо-водителей.
  v_staff uuid := '5eed0000-0000-4000-8000-000000000001';
  r record;
  d record;
  t_id uuid;
  v_route uuid;
  v_day int;
  v_time text;
  v_dep timestamptz;
  v_len int;
  v_meet int;
  v_seats jsonb;
  v_pass record;
  v_free text[];
  v_take int;
  v_new_trips int := 0;
  v_new_bookings int := 0;
  h int;
begin
  -- Вызов серверной функции от имени человека: как приложение после входа по SMS.
  create temp table if not exists _seed_people (id uuid primary key, phone text, name text, kind text) on commit drop;

  -- ---------- люди ----------
  insert into _seed_people values
    (v_staff, '37499000001', 'Демо-модератор', 'staff'),
    -- водители
    ('5eed0000-0000-4000-8000-000000000101', '37499000101', 'Арам', 'driver'),
    ('5eed0000-0000-4000-8000-000000000102', '37499000102', 'Гаяне', 'driver'),
    ('5eed0000-0000-4000-8000-000000000103', '37499000103', 'Давид', 'driver'),
    ('5eed0000-0000-4000-8000-000000000104', '37499000104', 'Нарек', 'driver'),
    ('5eed0000-0000-4000-8000-000000000105', '37499000105', 'Ани', 'driver'),
    ('5eed0000-0000-4000-8000-000000000106', '37499000106', 'Тигран', 'driver'),
    ('5eed0000-0000-4000-8000-000000000107', '37499000107', 'Карен', 'driver'),
    ('5eed0000-0000-4000-8000-000000000108', '37499000108', 'Лилит', 'driver'),
    ('5eed0000-0000-4000-8000-000000000109', '37499000109', 'Артур', 'driver'),
    ('5eed0000-0000-4000-8000-000000000110', '37499000110', 'Мариам', 'driver'),
    ('5eed0000-0000-4000-8000-000000000111', '37499000111', 'Сурен', 'driver'),
    ('5eed0000-0000-4000-8000-000000000112', '37499000112', 'Нарине', 'driver'),
    ('5eed0000-0000-4000-8000-000000000113', '37499000113', 'Гор', 'driver'),
    ('5eed0000-0000-4000-8000-000000000114', '37499000114', 'Ашот', 'driver'),
    ('5eed0000-0000-4000-8000-000000000115', '37499000115', 'Ануш', 'driver'),
    -- пассажиры, которые уже купили часть мест
    ('5eed0000-0000-4000-8000-000000000201', '37499000201', 'Сона', 'passenger'),
    ('5eed0000-0000-4000-8000-000000000202', '37499000202', 'Самвел', 'passenger'),
    ('5eed0000-0000-4000-8000-000000000203', '37499000203', 'Мари', 'passenger'),
    ('5eed0000-0000-4000-8000-000000000204', '37499000204', 'Ваге', 'passenger'),
    ('5eed0000-0000-4000-8000-000000000205', '37499000205', 'Астхик', 'passenger'),
    ('5eed0000-0000-4000-8000-000000000206', '37499000206', 'Овик', 'passenger')
  on conflict do nothing;

  for r in select * from _seed_people loop
    insert into auth.users (id, phone) values (r.id, r.phone) on conflict (id) do nothing;
    perform set_config('request.jwt.claims', json_build_object('sub', r.id, 'phone', r.phone, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method', 'otp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
    perform register_profile(r.name, 'ru');
  end loop;

  insert into staff (user_id, roles) values (v_staff, '{moderator,verifier}') on conflict (user_id) do nothing;

  -- ---------- маршруты (как в демо приложений: M1…M25) ----------
  create temp table _seed_routes (code text primary key, color bigint, price int, min_price int, minutes int,
    from_name text, from_lat float8, from_lon float8, to_name text, to_lat float8, to_lon float8) on commit drop;
  insert into _seed_routes values
    ('M1', 4283385573, 500, 400, 25, 'Давташен', 40.2264, 44.4930, 'Площадь Республики', 40.1777, 44.5126),
    ('M2', 4278556265, 400, 300, 22, 'Нор Норк', 40.1990, 44.5600, 'Площадь Республики', 40.1777, 44.5126),
    ('M3', 4292617766, 1200, 1100, 30, 'Аэропорт Звартноц', 40.1473, 44.3959, 'Площадь Республики', 40.1777, 44.5126),
    ('M4', 4287837162, 400, 300, 22, 'Эребуни', 40.1440, 44.5300, 'Каскад', 40.1913, 44.5155),
    ('M5', 4293548044, 500, 400, 25, 'Давташен', 40.2264, 44.4930, 'Ереван Молл', 40.1595, 44.4880),
    ('M6', 4278751666, 400, 300, 24, 'Нор Норк', 40.1990, 44.5600, 'Вокзал Сасунци Давид', 40.1563, 44.5163),
    ('M7', 4280640491, 500, 400, 25, 'Площадь Республики', 40.1777, 44.5126, 'Давташен', 40.2264, 44.4930),
    ('M8', 4279673674, 400, 300, 22, 'Площадь Республики', 40.1777, 44.5126, 'Нор Норк', 40.1990, 44.5600),
    ('M9', 4290321436, 1200, 1100, 30, 'Площадь Республики', 40.1777, 44.5126, 'Аэропорт Звартноц', 40.1473, 44.3959),
    ('M10', 4290782931, 400, 300, 22, 'Каскад', 40.1913, 44.5155, 'Эребуни', 40.1440, 44.5300),
    ('M11', 4292441862, 500, 400, 25, 'Ереван Молл', 40.1595, 44.4880, 'Давташен', 40.2264, 44.4930),
    ('M12', 4279080072, 400, 300, 24, 'Вокзал Сасунци Давид', 40.1563, 44.5163, 'Нор Норк', 40.1990, 44.5600),
    ('M13', 4286331629, 400, 300, 18, 'Ачапняк', 40.2050, 44.4600, 'Площадь Республики', 40.1777, 44.5126),
    ('M14', 4285343961, 400, 300, 18, 'Площадь Республики', 40.1777, 44.5126, 'Ачапняк', 40.2050, 44.4600),
    ('M15', 4278355143, 500, 400, 22, 'Аван', 40.2160, 44.5650, 'Площадь Республики', 40.1777, 44.5126),
    ('M16', 4278413729, 500, 400, 22, 'Площадь Республики', 40.1777, 44.5126, 'Аван', 40.2160, 44.5650),
    ('M17', 4284850957, 400, 300, 20, 'Бангладеш', 40.1630, 44.4430, 'Площадь Республики', 40.1777, 44.5126),
    ('M18', 4292552567, 300, 300, 8, 'Комитас', 40.2040, 44.5120, 'Каскад', 40.1913, 44.5155),
    ('M19', 4290648157, 300, 300, 8, 'Каскад', 40.1913, 44.5155, 'Комитас', 40.2040, 44.5120),
    ('M20', 4279137424, 300, 300, 10, 'Норк-Мараш', 40.1820, 44.5480, 'Площадь Республики', 40.1777, 44.5126),
    ('M21', 4283268111, 300, 300, 10, 'Канакер-Зейтун', 40.2090, 44.5330, 'Каскад', 40.1913, 44.5155),
    ('M22', 4292943176, 300, 300, 10, 'Далма Гарден Молл', 40.1800, 44.4890, 'Площадь Республики', 40.1777, 44.5126),
    ('M23', 4288295954, 300, 300, 8, 'Метро Гарегин Нжде', 40.1635, 44.4960, 'Вокзал Сасунци Давид', 40.1563, 44.5163),
    ('M24', 4280110808, 300, 300, 12, 'Арабкир', 40.2050, 44.5050, 'Площадь Республики', 40.1777, 44.5126),
    ('M25', 4280172719, 300, 300, 12, 'Площадь Республики', 40.1777, 44.5126, 'Арабкир', 40.2050, 44.5050);

  perform set_config('request.jwt.claims', json_build_object('sub', v_staff, 'phone', '37499000001', 'role', 'authenticated')::text, true);
  for r in select * from _seed_routes loop
    if exists (select 1 from routes where code = r.code) then continue; end if;
    -- Длина по дорогам: прямая × 1,35 (точную длину приложение получает от маршрутизатора Яндекса).
    v_len := greatest(1000, round(private._distance_m(r.from_lat, r.from_lon, r.to_lat, r.to_lon) * 1.35)::int);
    v_route := staff_save_route(null, r.code, r.from_name, r.from_lat, r.from_lon, r.to_name, r.to_lat, r.to_lon,
      r.price, r.minutes, v_len, r.color, r.min_price);
    perform staff_set_route_status(v_route, 'published');
  end loop;

  -- ---------- водители: машина, документы, карта для выплат, одобрение ----------
  -- Каждый водитель ездит по маршруту туда и (если есть) обратно.
  create temp table _seed_drivers (id uuid primary key, car text, car_color text, plate text, seats text[],
    route_there text, route_back text) on commit drop;
  insert into _seed_drivers values
    ('5eed0000-0000-4000-8000-000000000101', 'Toyota Camry', 'белая', '35 OO 123', '{front,rl,rr}', 'M1', 'M7'),
    ('5eed0000-0000-4000-8000-000000000102', 'Kia K5', 'серая', '01 LL 777', '{front,rl,rr}', 'M2', 'M8'),
    ('5eed0000-0000-4000-8000-000000000103', 'Hyundai Sonata', 'чёрная', '77 AA 450', '{front,rl,rr}', 'M3', 'M9'),
    ('5eed0000-0000-4000-8000-000000000104', 'Toyota Prius', 'синяя', '18 SS 902', '{rl,rr}', 'M4', 'M10'),
    ('5eed0000-0000-4000-8000-000000000105', 'Kia Optima', 'белая', '11 KK 315', '{front,rl,rr}', 'M5', 'M11'),
    ('5eed0000-0000-4000-8000-000000000106', 'Opel Astra', 'красная', '44 TT 208', '{front,rl,rr}', 'M6', 'M12'),
    ('5eed0000-0000-4000-8000-000000000107', 'Nissan Tiida', 'серебристая', '22 NN 610', '{front,rl,rr}', 'M13', 'M14'),
    ('5eed0000-0000-4000-8000-000000000108', 'Hyundai Elantra', 'белая', '05 EE 404', '{rl,rr}', 'M15', 'M16'),
    ('5eed0000-0000-4000-8000-000000000109', 'Lada Vesta', 'серая', '61 VV 115', '{front,rl,rr}', 'M18', 'M19'),
    ('5eed0000-0000-4000-8000-000000000110', 'Toyota Corolla', 'бежевая', '09 CC 230', '{front,rl,rr}', 'M24', 'M25'),
    ('5eed0000-0000-4000-8000-000000000111', 'Mitsubishi Lancer', 'чёрная', '70 MM 818', '{front,rl,rr}', 'M17', null),
    ('5eed0000-0000-4000-8000-000000000112', 'Kia Rio', 'голубая', '15 RR 342', '{rl,rr}', 'M20', null),
    ('5eed0000-0000-4000-8000-000000000113', 'Volkswagen Jetta', 'белая', '33 JJ 707', '{front,rl,rr}', 'M21', null),
    ('5eed0000-0000-4000-8000-000000000114', 'Chevrolet Cruze', 'серая', '48 HH 501', '{front,rl,rr}', 'M22', null),
    ('5eed0000-0000-4000-8000-000000000115', 'Skoda Octavia', 'зелёная', '27 OO 950', '{front,rl,rr}', 'M23', null);

  for d in select x.*, p.phone from _seed_drivers x join _seed_people p on p.id = x.id loop
    if exists (select 1 from drivers where user_id = d.id) then continue; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', d.id, 'phone', d.phone, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method', 'otp', 'timestamp', extract(epoch from now())::bigint)))::text, true);
    perform apply_driver(d.car, d.car_color, d.plate, d.seats, '0' || right(d.phone, 7));
    perform driver_save_document(k, d.id || '/' || k || '.jpg')
      from unnest(array['id_document', 'license', 'registration', 'car_photo', 'selfie']) k;
    perform driver_set_payout_card_sim('4111111111111111', (select name from _seed_people where id = d.id));
    perform set_config('request.jwt.claims', json_build_object('sub', v_staff, 'phone', '37499000001', 'role', 'authenticated')::text, true);
    perform staff_review_driver(d.id, true);
  end loop;

  -- Карта у демо-пассажиров (тестовый номер, в базе остаются только марка и 4 цифры).
  for r in select * from _seed_people where kind = 'passenger' loop
    if exists (select 1 from cards where user_id = r.id and removed_at is null) then continue; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', r.id, 'phone', r.phone, 'role', 'authenticated')::text, true);
    perform bind_card_sim('4111111111111111');
  end loop;

  -- ---------- рейсы на сегодня и два дня вперёд (время Еревана) ----------
  -- Туда — в 07:30, 09:30, 13:00, 17:30, 19:30; обратно — через час после каждого (машина успевает вернуться).
  for d in select x.*, p.phone from _seed_drivers x join _seed_people p on p.id = x.id loop
    for v_day in 0..2 loop
      for r in
        select x.code, x.t from (
          select d.route_there as code, unnest(array['07:30', '09:30', '13:00', '17:30', '19:30']) as t
          union all
          select d.route_back, unnest(array['08:30', '10:30', '14:00', '18:30', '20:30']) where d.route_back is not null
        ) x
      loop
        v_dep := (((app_now() at time zone 'Asia/Yerevan')::date + v_day) + r.t::time) at time zone 'Asia/Yerevan';
        if v_dep < app_now() + interval '20 minutes' then continue; end if;          -- рейс не ставят задним числом
        if exists (select 1 from trips where driver_id = d.id and departure = v_dep) then continue; end if;
        select id, length_m, base_price into v_route, v_len, h from routes where code = r.code;
        -- Место посадки: начало маршрута или чуть дальше по линии (у каждого рейса своё).
        v_meet := least((array[0, 400, 900])[1 + abs(hashtext(r.code || v_dep::text)) % 3], v_len - 1);
        select jsonb_agg(jsonb_build_object('id', s, 'price', case when s = 'front' then h + 100 else h end))
          into v_seats from unnest(d.seats) s;
        perform set_config('request.jwt.claims', json_build_object('sub', d.id, 'phone', d.phone, 'role', 'authenticated')::text, true);
        t_id := driver_create_trip(v_route, v_dep, v_meet, v_seats);
        v_new_trips := v_new_trips + 1;

        -- Часть мест уже куплена демо-пассажирами: 0, 1 или 2 места.
        v_take := abs(hashtext(t_id::text)) % 3;
        if v_take > 0 then
          select array_agg(seat_id order by seat_id) into v_free from trip_seats where trip_id = t_id;
          v_free := v_free[1:least(v_take, cardinality(v_free) - 1)];                 -- хотя бы одно место остаётся свободным
          if cardinality(v_free) > 0 then
            select p.id, p.phone into v_pass from _seed_people p
              where p.kind = 'passenger' order by md5(p.id::text || t_id::text) limit 1;
            perform set_config('request.jwt.claims', json_build_object('sub', v_pass.id, 'phone', v_pass.phone, 'role', 'authenticated')::text, true);
            perform book_seats(t_id, v_free, (select id from cards where user_id = v_pass.id and removed_at is null limit 1),
                               'seed-' || t_id);
            v_new_bookings := v_new_bookings + 1;
          end if;
        end if;
      end loop;
    end loop;
  end loop;

  perform set_config('request.jwt.claims', '', true);
  raise notice 'Демо-данные: новых рейсов %, новых броней %', v_new_trips, v_new_bookings;
end
$seed$;
