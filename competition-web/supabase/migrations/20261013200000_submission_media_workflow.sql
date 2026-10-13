begin;

alter table private.auth_rate_limits drop constraint auth_rate_limits_action_check;
alter table private.auth_rate_limits add constraint auth_rate_limits_action_check
  check(action in ('invite','login','recovery','rating','upload','search'));

drop function private.current_memberships();
create function private.current_memberships()
returns table(competition_id uuid,round_name text,round_status private.competition_status,nickname text,is_trial boolean,entries_per_participant smallint)
language sql stable security definer set search_path=''
as $$
  select c.id,c.name,c.status,p.nickname,c.is_trial,(c.settings->>'entries_per_participant')::smallint
  from private.participants p join private.competitions c on c.id=p.competition_id
  where p.user_id=auth.uid() and p.withdrawn_at is null and c.status<>'archived'
  order by c.created_at desc
$$;
revoke all on function private.current_memberships() from public,anon,authenticated;
grant execute on function private.current_memberships() to ost_web_app;

create table private.submission_uploads (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references private.competitions(id) on delete cascade,
  participant_id uuid not null references private.participants(id) on delete cascade,
  slot smallint not null check(slot between 1 and 5),
  franchise text not null check(length(franchise) between 1 and 120),
  anilist_id bigint,
  ost_title text not null check(length(ost_title) between 1 and 160),
  original_storage_key text not null unique,
  original_bytes bigint not null check(original_bytes between 1 and 524288000),
  claimed_seconds numeric(8,3) not null,
  status text not null check(status in ('uploading','processing','failed','complete')) default 'uploading',
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index submission_uploads_one_pending_slot
  on private.submission_uploads(competition_id,participant_id,slot)
  where status in ('uploading','processing');
alter table private.submission_uploads enable row level security;
alter table private.submission_uploads force row level security;
revoke all on private.submission_uploads from public,anon,authenticated,ost_web_app;

create or replace function private.can_upload_competition_object(p_name text)
returns boolean language sql stable security definer set search_path=''
as $$ select exists(
  select 1 from private.submission_uploads u
  join private.participants p on p.id=u.participant_id
  join private.competitions c on c.id=u.competition_id
  where u.original_storage_key=p_name and u.status='uploading'
    and p.user_id=auth.uid() and p.withdrawn_at is null
    and c.status='submissions_open'
    and (c.submission_deadline is null or c.submission_deadline>now())
) $$;
grant usage on schema private to authenticated;
revoke all on function private.can_upload_competition_object(text) from public,anon,authenticated;
grant execute on function private.can_upload_competition_object(text) to authenticated;
create policy competition_participant_upload
on storage.objects for insert to authenticated
with check (bucket_id='competition-media' and private.can_upload_competition_object(name));

create or replace function private.start_submission_upload(
  p_competition_id uuid,p_slot smallint,p_franchise text,p_anilist_id bigint,
  p_ost_title text,p_bytes bigint,p_claimed_seconds numeric,p_storage_key text
) returns table(upload_id uuid,storage_key text,old_storage_key text,max_upload_bytes bigint,
                min_clip_seconds numeric,max_clip_seconds numeric,normalize_loudness boolean)
language plpgsql security definer set search_path=''
as $$
declare participant uuid; config jsonb; old_key text; max_bytes bigint; min_seconds numeric; max_seconds numeric;
begin
  select p.id into participant from private.participants p
  where p.competition_id=p_competition_id and p.user_id=auth.uid() and p.withdrawn_at is null;
  select c.settings into config from private.competitions c
  where c.id=p_competition_id and c.status='submissions_open'
    and (c.submission_deadline is null or c.submission_deadline>now());
  if participant is null or config is null or p_franchise is null or length(trim(p_franchise)) not between 1 and 120
    or p_ost_title is null or length(trim(p_ost_title)) not between 1 and 160
    or p_storage_key !~ '^[a-f0-9]{32}/[a-f0-9]{32}\.(mp4|mov|webm|mkv)$' then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  if p_slot>(config->>'entries_per_participant')::smallint then raise exception 'Invalid submission slot' using errcode='23514'; end if;
  max_bytes:=least((config->>'max_upload_bytes')::bigint,524288000);
  min_seconds:=coalesce((config->>'min_clip_seconds')::numeric,20);
  max_seconds:=coalesce((config->>'max_clip_seconds')::numeric,360);
  if p_bytes<1 or p_bytes>max_bytes or p_claimed_seconds<min_seconds or p_claimed_seconds>max_seconds then
    raise exception 'Submission file is outside configured limits' using errcode='23514';
  end if;
  select u.original_storage_key into old_key from private.submission_uploads u
    where u.competition_id=p_competition_id and u.participant_id=participant and u.slot=p_slot
      and u.status in ('uploading','failed') for update;
  delete from private.submission_uploads u
    where u.competition_id=p_competition_id and u.participant_id=participant and u.slot=p_slot
      and u.status in ('uploading','failed');
  insert into private.submission_uploads(competition_id,participant_id,slot,franchise,anilist_id,ost_title,original_storage_key,original_bytes,claimed_seconds)
  values(p_competition_id,participant,p_slot,trim(p_franchise),p_anilist_id,trim(p_ost_title),p_storage_key,p_bytes,p_claimed_seconds)
  returning id,original_storage_key into upload_id,storage_key;
  return query select upload_id,storage_key,old_key,max_bytes,min_seconds,max_seconds,coalesce((config->>'loudness_normalization')::boolean,false);
end $$;
revoke all on function private.start_submission_upload(uuid,smallint,text,bigint,text,bigint,numeric,text) from public,anon,authenticated;
grant execute on function private.start_submission_upload(uuid,smallint,text,bigint,text,bigint,numeric,text) to ost_web_app;

create or replace function private.begin_submission_processing(p_upload_id uuid)
returns table(upload_id uuid,competition_id uuid,participant_id uuid,storage_key text,upload_bytes bigint,
               claimed_seconds numeric,min_clip_seconds numeric,max_clip_seconds numeric,
               max_upload_bytes bigint,normalize_loudness boolean)
language plpgsql security definer set search_path=''
as $$ declare csettings jsonb; begin
  return query
  update private.submission_uploads u set status='processing',updated_at=now()
  from private.competitions c,private.participants p
  where u.id=p_upload_id and u.competition_id=c.id and u.participant_id=p.id
    and p.user_id=auth.uid() and p.withdrawn_at is null and c.status='submissions_open'
    and u.status='uploading'
  returning u.id,u.competition_id,u.participant_id,u.original_storage_key,u.original_bytes,u.claimed_seconds,
    (c.settings->>'min_clip_seconds')::numeric,(c.settings->>'max_clip_seconds')::numeric,
    least((c.settings->>'max_upload_bytes')::bigint,524288000),coalesce((c.settings->>'loudness_normalization')::boolean,false);
  if not found then raise exception 'Resource unavailable' using errcode='P0002'; end if;
end $$;
revoke all on function private.begin_submission_processing(uuid) from public,anon,authenticated;
grant execute on function private.begin_submission_processing(uuid) to ost_web_app;

create or replace function private.finish_submission_processing(
  p_upload_id uuid,p_audio_storage_key text,p_original_seconds numeric,
  p_audio_seconds numeric,p_duration_mismatch boolean
) returns table(submission_id uuid,status private.submission_status,
                old_original_key text,old_audio_key text)
language plpgsql security definer set search_path=''
as $$ declare item private.submission_uploads%rowtype; prev private.submissions%rowtype; config jsonb; result_id uuid; result_status private.submission_status;
begin
  select u.* into item from private.submission_uploads u
  where u.id=p_upload_id and u.status='processing' for update;
  select c.settings into config from private.competitions c where c.id=item.competition_id;
  if item.id is null or config is null or p_audio_storage_key !~ '^[a-f0-9]{32}/[a-f0-9]{32}\.m4a$'
    or p_original_seconds<coalesce((config->>'min_clip_seconds')::numeric,20)
    or p_original_seconds>coalesce((config->>'max_clip_seconds')::numeric,360)
    or p_audio_seconds<=0
    or p_duration_mismatch is distinct from (abs(p_original_seconds-p_audio_seconds)>0.100) then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  if not exists(select 1 from private.competitions c where c.id=item.competition_id and c.status='submissions_open'
      and (c.submission_deadline is null or c.submission_deadline>now())) then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  select s.* into prev from private.submissions s
  where s.competition_id=item.competition_id and s.participant_id=item.participant_id and s.slot=item.slot
  for update;
  result_status:=case when p_duration_mismatch then 'needs_review'::private.submission_status else 'awaiting_confirmation'::private.submission_status end;
  insert into private.submissions(competition_id,participant_id,slot,franchise,anilist_id,ost_title,status,
    original_storage_key,audio_storage_key,original_bytes,original_seconds,audio_seconds,duration_mismatch)
  values(item.competition_id,item.participant_id,item.slot,item.franchise,item.anilist_id,item.ost_title,result_status,
    item.original_storage_key,p_audio_storage_key,item.original_bytes,p_original_seconds,p_audio_seconds,p_duration_mismatch)
  on conflict(competition_id,participant_id,slot) do update set
    franchise=excluded.franchise,anilist_id=excluded.anilist_id,ost_title=excluded.ost_title,status=excluded.status,
    original_storage_key=excluded.original_storage_key,audio_storage_key=excluded.audio_storage_key,
    original_bytes=excluded.original_bytes,original_seconds=excluded.original_seconds,audio_seconds=excluded.audio_seconds,
    duration_mismatch=excluded.duration_mismatch,confirmed_at=null,rejection_reason=null,version=private.submissions.version+1,updated_at=now()
  returning id into result_id;
  update private.submission_uploads set status='complete',updated_at=now() where id=p_upload_id;
  insert into private.media_jobs(submission_id,state,attempt_count)
  values(result_id,'complete',1)
  on conflict(submission_id) do update set state='complete',attempt_count=private.media_jobs.attempt_count+1,updated_at=now();
  return query select result_id,result_status,prev.original_storage_key,prev.audio_storage_key;
end $$;
revoke all on function private.finish_submission_processing(uuid,text,numeric,numeric,boolean) from public,anon,authenticated;
grant execute on function private.finish_submission_processing(uuid,text,numeric,numeric,boolean) to ost_web_app;

create or replace function private.fail_submission_processing(p_upload_id uuid,p_error_code text)
returns void language plpgsql security definer set search_path=''
as $$ begin
  update private.submission_uploads u set status='failed',error_code=left(p_error_code,48),updated_at=now()
  where u.id=p_upload_id and u.participant_id in (select p.id from private.participants p where p.user_id=auth.uid()) and u.status='processing';
  if not found then raise exception 'Resource unavailable' using errcode='P0002'; end if;
end $$;
revoke all on function private.fail_submission_processing(uuid,text) from public,anon,authenticated;
grant execute on function private.fail_submission_processing(uuid,text) to ost_web_app;

create or replace function private.confirm_submission(p_submission_id uuid)
returns void language plpgsql security definer set search_path=''
as $$ declare changed integer; begin
  update private.submissions s set status='confirmed',confirmed_at=now(),version=version+1,updated_at=now()
  from private.participants p,private.competitions c
  where s.id=p_submission_id and s.participant_id=p.id and p.user_id=auth.uid() and p.withdrawn_at is null
    and s.competition_id=c.id and c.status='submissions_open'
    and (c.submission_deadline is null or c.submission_deadline>now()) and s.status='awaiting_confirmation';
  get diagnostics changed=row_count;
  if changed<>1 then raise exception 'Resource unavailable' using errcode='P0002'; end if;
end $$;
revoke all on function private.confirm_submission(uuid) from public,anon,authenticated;
grant execute on function private.confirm_submission(uuid) to ost_web_app;

create or replace function private.host_clear_submission_review(p_submission_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=''
as $$ declare c_id uuid; begin
  perform private.require_platform_host();
  update private.submissions set status=case when p_approve then 'awaiting_confirmation'::private.submission_status else 'rejected'::private.submission_status end,
    rejection_reason=case when p_approve then null else 'host_rejected' end,version=version+1,updated_at=now()
  where id=p_submission_id and status='needs_review' returning competition_id into c_id;
  if c_id is null then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  insert into private.host_audit_log(competition_id,actor_user_id,event_type,target_id,details)
  values(c_id,auth.uid(),case when p_approve then 'submission_review_approved' else 'submission_review_rejected' end,p_submission_id,'{}');
end $$;
revoke all on function private.host_clear_submission_review(uuid,boolean) from public,anon,authenticated;
grant execute on function private.host_clear_submission_review(uuid,boolean) to ost_web_app;

create or replace function private.list_host_submission_reviews()
returns table(submission_id uuid,competition_id uuid,round_name text,nickname text,slot smallint,
              franchise text,anilist_id bigint,ost_title text,original_seconds numeric,audio_seconds numeric,
              original_key text,audio_key text,status private.submission_status,
              duplicate_count bigint,history_reuse_count bigint)
language plpgsql stable security definer set search_path=''
as $$ begin
  perform private.require_platform_host();
  return query select s.id,s.competition_id,c.name,p.nickname,s.slot,s.franchise,s.anilist_id,s.ost_title,
    s.original_seconds,s.audio_seconds,s.original_storage_key,s.audio_storage_key,s.status,
    (select count(*) from private.submissions d where d.competition_id=s.competition_id
      and lower(d.franchise)=lower(s.franchise) and lower(d.ost_title)=lower(s.ost_title)),
    (select count(*) from private.submissions d join private.participants prior on prior.id=d.participant_id
      where prior.user_id=p.user_id and d.competition_id<>s.competition_id
        and lower(d.franchise)=lower(s.franchise) and lower(d.ost_title)=lower(s.ost_title))
  from private.submissions s join private.competitions c on c.id=s.competition_id
    join private.participants p on p.id=s.participant_id
  where s.status in ('needs_review','awaiting_confirmation','confirmed') order by s.created_at;
end $$;
revoke all on function private.list_host_submission_reviews() from public,anon,authenticated;
grant execute on function private.list_host_submission_reviews() to ost_web_app;

create or replace function private.list_my_submissions(p_competition_id uuid)
returns table(submission_id uuid,slot smallint,franchise text,anilist_id bigint,ost_title text,status private.submission_status,
              duration_mismatch boolean,version bigint)
language sql stable security definer set search_path=''
as $$ select s.id,s.slot,s.franchise,s.anilist_id,s.ost_title,s.status,s.duration_mismatch,s.version
from private.submissions s join private.participants p on p.id=s.participant_id
where s.competition_id=p_competition_id and p.user_id=auth.uid() and p.withdrawn_at is null
order by s.slot $$;
revoke all on function private.list_my_submissions(uuid) from public,anon,authenticated;
grant execute on function private.list_my_submissions(uuid) to ost_web_app;

create or replace function private.my_submission_upload_policy(p_competition_id uuid)
returns table(max_upload_bytes bigint,min_clip_seconds numeric,max_clip_seconds numeric,entries_per_participant smallint)
language sql stable security definer set search_path=''
as $$ select least((c.settings->>'max_upload_bytes')::bigint,524288000),
  coalesce((c.settings->>'min_clip_seconds')::numeric,20),
  coalesce((c.settings->>'max_clip_seconds')::numeric,360),
  (c.settings->>'entries_per_participant')::smallint
from private.competitions c join private.participants p on p.competition_id=c.id
where c.id=p_competition_id and p.user_id=auth.uid() and p.withdrawn_at is null
  and c.status='submissions_open' and (c.submission_deadline is null or c.submission_deadline>now()) $$;
revoke all on function private.my_submission_upload_policy(uuid) from public,anon,authenticated;
grant execute on function private.my_submission_upload_policy(uuid) to ost_web_app;

create or replace function private.my_submission_preview_key(p_submission_id uuid)
returns text language sql stable security definer set search_path=''
as $$ select s.audio_storage_key from private.submissions s join private.participants p on p.id=s.participant_id
where s.id=p_submission_id and p.user_id=auth.uid() and p.withdrawn_at is null
  and s.status in ('awaiting_confirmation','confirmed') $$;
revoke all on function private.my_submission_preview_key(uuid) from public,anon,authenticated;
grant execute on function private.my_submission_preview_key(uuid) to ost_web_app;

commit;
