-- Отпечаток схемы сервера: по каждой категории (функции, права, правила видимости, столбцы, ограничения, индексы,
-- настройки) — число строк и md5. Запускается на облаке (Supabase execute_sql) и на чистой локальной базе
-- (все файлы supabase/migrations поверх supabase/local/shim.sql); результаты должны совпасть полностью.
with
f as (select 'fn' k, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' || md5(p.prosrc) || '|' || p.prosecdef || '|' || coalesce(array_to_string(p.proconfig, ','), '') || '|' || p.provolatile::text v
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public','private')),
fa as (select 'fnacl' k, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')>' || case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end v
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where n.nspname in ('public','private') and (a.grantee = 0 or a.grantee::regrole::text in ('anon', 'authenticated'))),
t as (select 'tacl' k, c.relname || '>' || a.grantee::regrole::text || ':' || a.privilege_type v
      from pg_class c join pg_namespace n on n.oid = c.relnamespace, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      where n.nspname = 'public' and c.relkind in ('r', 'v', 'S') and (a.grantee = 0 or a.grantee::regrole::text in ('anon', 'authenticated'))),
ca as (select 'colacl' k, c.relname || '.' || at.attname || '>' || a.grantee::regrole::text || ':' || a.privilege_type v
      from pg_attribute at join pg_class c on c.oid = at.attrelid join pg_namespace n on n.oid = c.relnamespace, aclexplode(at.attacl) a
      where n.nspname = 'public' and at.attacl is not null and (a.grantee = 0 or a.grantee::regrole::text in ('anon', 'authenticated'))),
po as (select 'pol' k, tablename || '.' || policyname || '|' || cmd || '|' || array_to_string(roles, ',') || '|' || md5(coalesce(qual, '')) v from pg_policies where schemaname = 'public'),
co as (select 'col' k, table_name || '.' || column_name || ':' || data_type || '|' || is_nullable || '|' || coalesce(column_default, '') v from information_schema.columns where table_schema = 'public'),
rl as (select 'rls' k, relname || ':' || relrowsecurity v from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and relkind = 'r'),
vw as (select 'view' k, viewname || '|' || md5(definition) v from pg_views where schemaname = 'public'),
cn as (select 'con' k, conrelid::regclass::text || '.' || conname || '|' || md5(pg_get_constraintdef(oid)) v from pg_constraint where connamespace = 'public'::regnamespace),
tg as (select 'trg' k, tgrelid::regclass::text || '.' || tgname v from pg_trigger where not tgisinternal and tgrelid::regclass::text not like 'auth.%' and tgrelid in (select oid from pg_class where relnamespace='public'::regnamespace)),
ix as (select 'idx' k, indexname || '|' || md5(indexdef) v from pg_indexes where schemaname = 'public'),
st as (select 'set' k, key || '=' || value::text v from public.app_settings),
al as (select * from f union all select * from fa union all select * from t union all select * from ca union all select * from po union all select * from co union all select * from rl union all select * from vw union all select * from cn union all select * from tg union all select * from ix union all select * from st)
select k, count(*) n, md5(string_agg(v, E'\n' order by v)) h from al group by k order by k;
