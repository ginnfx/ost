-- Run only against the local competition Supabase database:
-- psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/security.sql
begin;

do $$ declare r record; begin
  if has_schema_privilege('anon','private','usage') then raise exception 'anon can use private schema'; end if;
  if has_schema_privilege('authenticated','private','usage') then raise exception 'authenticated can use private schema'; end if;
  if has_schema_privilege('ost_web_app','private','usage') is not true then raise exception 'web role cannot execute private DTO functions'; end if;
  for r in select c.relname,c.relrowsecurity,c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='private' and c.relkind='r' loop
    if not r.relrowsecurity or not r.relforcerowsecurity then raise exception 'RLS not forced for %',r.relname; end if;
    if has_table_privilege('anon',format('private.%I',r.relname),'select') then raise exception 'anon can read %',r.relname; end if;
    if has_table_privilege('authenticated',format('private.%I',r.relname),'select') then raise exception 'authenticated can read %',r.relname; end if;
    if has_table_privilege('ost_web_app',format('private.%I',r.relname),'select') then raise exception 'web role can directly read %',r.relname; end if;
  end loop;
end $$;

-- A participant-controlled metadata claim must never mint host privileges.
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","app_metadata":{"host":true},"user_metadata":{"host":true}}',true);
set local role ost_web_app;
do $$ begin
  if private.is_platform_host() then raise exception 'user metadata granted host status'; end if;
end $$;
reset role;

-- GraphQL is disabled by removing the optional pg_graphql extension.
do $$ begin
  if exists(select 1 from pg_extension where extname='pg_graphql') then
    raise exception 'pg_graphql extension is enabled';
  end if;
  if (select public from storage.buckets where id='competition-media') is distinct from false then
    raise exception 'competition media bucket is not private';
  end if;
  if exists(select 1 from pg_policies where schemaname='storage' and tablename='objects') then
    raise exception 'unexpected storage object policy grants access';
  end if;
end $$;

rollback;
