-- Только для локальной копии сервера (обычный PostgreSQL на компьютере разработчика).
-- Повторяет то, что в облаке Supabase уже есть: роли anon / authenticated / service_role,
-- схему auth с пользователями и функции auth.uid() / auth.jwt().
-- В облако этот файл НЕ применяется.

do $$
begin
  if not exists (select from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  phone text unique,
  created_at timestamptz not null default now()
);

-- Кто сейчас обращается: в Supabase это приходит из токена входа, в тестах — из настройки запроса.
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;

create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant select on auth.users to service_role;
grant usage on schema public to anon, authenticated, service_role;
