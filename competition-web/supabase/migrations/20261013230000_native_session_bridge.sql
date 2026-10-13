begin;

create table private.native_authorization_codes (
  code_digest bytea primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  check (octet_length(code_digest)=32),
  check (expires_at<=created_at+interval '2 minutes')
);
alter table private.native_authorization_codes enable row level security;
alter table private.native_authorization_codes force row level security;
revoke all on private.native_authorization_codes from public,anon,authenticated,ost_web_app;

create or replace function private.create_native_authorization_code(p_digest bytea,p_expires_at timestamptz)
returns void language plpgsql security definer set search_path=''
as $$ begin
  delete from private.native_authorization_codes
  where expires_at<now() or consumed_at<now()-interval '1 hour';
  if auth.uid() is null or octet_length(p_digest)<>32 or p_expires_at<=now()
    or p_expires_at>now()+interval '2 minutes'
    or not exists(select 1 from private.participants p join private.competitions c on c.id=p.competition_id
      where p.user_id=auth.uid() and p.withdrawn_at is null and c.status<>'archived') then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  insert into private.native_authorization_codes(code_digest,user_id,expires_at)
  values(p_digest,auth.uid(),p_expires_at);
end $$;
revoke all on function private.create_native_authorization_code(bytea,timestamptz) from public,anon,authenticated;
grant execute on function private.create_native_authorization_code(bytea,timestamptz) to ost_web_app;

create or replace function private.consume_native_authorization_code(p_digest bytea)
returns uuid language plpgsql security definer set search_path=''
as $$ declare result uuid; begin
  update private.native_authorization_codes set consumed_at=now()
  where code_digest=p_digest and consumed_at is null and expires_at>now()
  returning user_id into result;
  if result is null then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  return result;
end $$;
revoke all on function private.consume_native_authorization_code(bytea) from public,anon,authenticated;
grant execute on function private.consume_native_authorization_code(bytea) to ost_web_app;

create index native_authorization_expiry on private.native_authorization_codes(expires_at);

create or replace function private.my_competition_memberships()
returns table(competition_id uuid,round_name text,round_status private.competition_status,nickname text,
              is_trial boolean,entries_per_participant smallint)
language sql stable security definer set search_path=''
as $$ select c.id,c.name,c.status,p.nickname,c.is_trial,(c.settings->>'entries_per_participant')::smallint
from private.participants p join private.competitions c on c.id=p.competition_id
where p.user_id=auth.uid() and p.withdrawn_at is null and c.status<>'archived'
order by c.created_at desc $$;
revoke all on function private.my_competition_memberships() from public,anon,authenticated;
grant execute on function private.my_competition_memberships() to ost_web_app;

create table private.legacy_competition_imports (
  source_id uuid primary key,
  imported_by uuid not null references auth.users(id) on delete restrict,
  round_name text not null check(length(round_name) between 1 and 120),
  payload jsonb not null check(octet_length(payload::text)<=5000000),
  imported_at timestamptz not null default now()
);
alter table private.legacy_competition_imports enable row level security;
alter table private.legacy_competition_imports force row level security;
revoke all on private.legacy_competition_imports from public,anon,authenticated,ost_web_app;

create or replace function private.host_import_legacy_round(p_source_id uuid,p_name text,p_payload jsonb)
returns boolean language plpgsql security definer set search_path=''
as $$ declare inserted boolean; begin
  perform private.require_platform_host();
  if p_source_id is null or length(trim(p_name)) not between 1 and 120
    or jsonb_typeof(p_payload->'osts')<>'array' or jsonb_typeof(p_payload->'ratings')<>'array'
    or octet_length(p_payload::text)>5000000 then
    raise exception 'Invalid imported archive' using errcode='23514';
  end if;
  if exists(select 1 from jsonb_array_elements(p_payload->'ratings') r
    where coalesce((r->>'score')::numeric,0)<0 or coalesce((r->>'score')::numeric,0)>10) then
    raise exception 'Invalid imported rating' using errcode='23514';
  end if;
  insert into private.legacy_competition_imports(source_id,imported_by,round_name,payload)
  values(p_source_id,auth.uid(),trim(p_name),p_payload) on conflict(source_id) do nothing;
  inserted:=found;
  if inserted then
    insert into private.host_audit_log(actor_user_id,event_type,target_id,details)
    values(auth.uid(),'legacy_round_imported',p_source_id,jsonb_build_object('round_name',trim(p_name),'ost_count',jsonb_array_length(p_payload->'osts')));
  end if;
  return inserted;
end $$;
revoke all on function private.host_import_legacy_round(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function private.host_import_legacy_round(uuid,text,jsonb) to ost_web_app;

create or replace function private.my_completed_competition_archive(p_competition_id uuid)
returns table(listening_id uuid,label text,franchise text,ost_title text,rank integer,mean_score text,
              rating_count integer,audio_storage_key text,group_number smallint)
language plpgsql stable security definer set search_path=''
as $$ begin
  if not exists(select 1 from private.participants p join private.competitions c on c.id=p.competition_id
    where p.competition_id=p_competition_id and p.user_id=auth.uid() and p.withdrawn_at is null and c.status='complete') then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  return query select l.listening_id,l.label,s.franchise,s.ost_title,(r->>'rank')::integer,r->>'mean',
    (r->>'count')::integer,s.audio_storage_key,e.group_number
  from private.reveal_events e join private.listening_labels l on l.listening_id=e.listening_id
    join private.submissions s on s.id=l.submission_id
    join private.score_snapshots snap on snap.competition_id=s.competition_id
    cross join lateral jsonb_array_elements(snap.payload->'ranked') r
  where e.competition_id=p_competition_id and s.id=(r->>'id')::uuid
  order by (r->>'rank')::integer;
end $$;
revoke all on function private.my_completed_competition_archive(uuid) from public,anon,authenticated;
grant execute on function private.my_completed_competition_archive(uuid) to ost_web_app;

create or replace function private.host_archived_original_keys(p_competition_id uuid)
returns table(storage_key text)
language plpgsql stable security definer set search_path=''
as $$ begin
  perform private.require_platform_host();
  if not exists(select 1 from private.competitions c where c.id=p_competition_id and c.status='complete') then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  return query select s.original_storage_key from private.submissions s
    where s.competition_id=p_competition_id and s.original_storage_key is not null;
end $$;
revoke all on function private.host_archived_original_keys(uuid) from public,anon,authenticated;
grant execute on function private.host_archived_original_keys(uuid) to ost_web_app;

create or replace function private.host_mark_originals_archived(p_competition_id uuid,p_archive_digest bytea)
returns void language plpgsql security definer set search_path=''
as $$ declare changed integer; begin
  perform private.require_platform_host();
  if octet_length(p_archive_digest)<>32 then raise exception 'Invalid archive digest' using errcode='23514'; end if;
  update private.submissions s set original_storage_key=null
    from private.competitions c where s.competition_id=p_competition_id and c.id=s.competition_id and c.status='complete'
      and s.original_storage_key is not null;
  get diagnostics changed=row_count;
  if changed=0 then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  insert into private.host_audit_log(competition_id,actor_user_id,event_type,details)
  values(p_competition_id,auth.uid(),'original_media_archived_locally',jsonb_build_object('digest',encode(p_archive_digest,'hex'),'object_count',changed));
end $$;
revoke all on function private.host_mark_originals_archived(uuid,bytea) from public,anon,authenticated;
grant execute on function private.host_mark_originals_archived(uuid,bytea) to ost_web_app;

commit;
