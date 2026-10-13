-- Run only against the local competition Supabase database:
-- psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/security.sql
begin;

do $$ declare r record; begin
  if has_schema_privilege('anon','private','usage') then raise exception 'anon can use private schema'; end if;
  if has_schema_privilege('authenticated','private','usage') is not true then raise exception 'authenticated cannot call the scoped Storage policy helper'; end if;
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='private' and p.proname<>'can_upload_competition_object'
      and has_function_privilege('authenticated',p.oid,'execute')) then
    raise exception 'authenticated can execute an unapproved private function';
  end if;
  if has_schema_privilege('ost_web_app','private','usage') is not true then raise exception 'web role cannot execute private DTO functions'; end if;
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='private' and p.prosecdef and not coalesce(p.proconfig,'{}') @> array['search_path=""']) then
    raise exception 'A private security-definer function lacks an empty search_path';
  end if;
  if exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='private' and c.relkind in ('v','m')
      and not coalesce(c.reloptions,'{}') @> array['security_invoker=true']) then
    raise exception 'A private view is not security_invoker';
  end if;
  for r in select c.relname,c.relrowsecurity,c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='private' and c.relkind='r' loop
    if not r.relrowsecurity or not r.relforcerowsecurity then raise exception 'RLS not forced for %',r.relname; end if;
    if has_table_privilege('anon',format('private.%I',r.relname),'select') then raise exception 'anon can read %',r.relname; end if;
    if has_table_privilege('authenticated',format('private.%I',r.relname),'select') then raise exception 'authenticated can read %',r.relname; end if;
    if has_table_privilege('ost_web_app',format('private.%I',r.relname),'select') then raise exception 'web role can directly read %',r.relname; end if;
  end loop;
  if has_function_privilege('anon','private.complete_host_bootstrap(bytea,text,bytea,bigint,text[],text,boolean,text)','execute') then raise exception 'anon can bootstrap host credentials'; end if;
  if has_function_privilege('authenticated','private.complete_host_recovery(bytea,text,bytea,bigint,text[],text,boolean,text)','execute') then raise exception 'authenticated can invoke host recovery directly'; end if;
  if has_function_privilege('ost_web_app','private.complete_host_bootstrap(bytea,text,bytea,bigint,text[],text,boolean,text)','execute') is not true then raise exception 'web role cannot complete a token-authorized bootstrap'; end if;
  if has_function_privilege('authenticated','private.consume_native_authorization_code(bytea)','execute') then raise exception 'participant can consume native login codes directly'; end if;
  if has_function_privilege('ost_web_app','private.consume_native_authorization_code(bytea)','execute') is not true then raise exception 'server cannot consume native login codes'; end if;
  if has_function_privilege('anon','private.start_submission_upload(uuid,smallint,text,bigint,text,bigint,numeric,text)','execute') then raise exception 'anon can start a private submission upload'; end if;
  if has_function_privilege('authenticated','private.finish_submission_processing(uuid,text,numeric,numeric,boolean)','execute') then raise exception 'authenticated can finish media processing'; end if;
  if has_function_privilege('ost_web_app','private.start_submission_upload(uuid,smallint,text,bigint,text,bigint,numeric,text)','execute') is not true then raise exception 'web role cannot start a participant upload'; end if;
  if has_function_privilege('ost_web_app','private.list_host_submission_reviews()','execute') is not true then raise exception 'web role cannot call host review DTO'; end if;
  if has_function_privilege('anon','private.media_worker_complete(uuid,text,numeric,numeric,boolean,integer)','execute') then raise exception 'anon can complete worker media jobs'; end if;
  if has_function_privilege('authenticated','private.media_worker_fail(uuid,text,integer)','execute') then raise exception 'participant can forge a media-worker failure'; end if;
  if has_function_privilege('ost_web_app','private.media_worker_complete(uuid,text,numeric,numeric,boolean,integer)','execute') is not true then raise exception 'web result callback cannot record media output'; end if;
  if has_function_privilege('anon','private.can_upload_competition_object(text)','execute') then raise exception 'anon can authorize Storage uploads'; end if;
  if has_function_privilege('authenticated','private.can_upload_competition_object(text)','execute') is not true then raise exception 'authenticated cannot check its pending Storage key'; end if;
end $$;

-- A participant-controlled metadata claim must never mint host privileges.
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","app_metadata":{"host":true},"user_metadata":{"host":true}}',true);
set local role ost_web_app;
do $$ begin
  if private.is_platform_host() then raise exception 'user metadata granted host status'; end if;
  begin
    perform private.list_host_credentials();
    raise exception 'participant listed host credentials';
  exception when sqlstate 'P0002' then
    null;
  end;
end $$;
reset role;

-- Ordinary authenticated clients cannot query private rows directly, even when
-- they know another participant's UUID or the host audit table name.
set local role authenticated;
do $$ declare table_name text; begin
  foreach table_name in array array['competitions','participants','submissions','ratings','score_snapshots','host_audit_log'] loop
    begin
      execute format('select count(*) from private.%I',table_name);
      raise exception 'authenticated directly read private.%',table_name;
    exception when insufficient_privilege then
      null;
    end;
  end loop;
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
  if (select count(*) from pg_policies where schemaname='storage' and tablename='objects')<>1
     or not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects'
       and policyname='competition_participant_upload' and cmd='INSERT'
       and with_check like '%can_upload_competition_object%') then
    raise exception 'Storage insert must be restricted to a participant pending-upload key';
  end if;
end $$;

rollback;
