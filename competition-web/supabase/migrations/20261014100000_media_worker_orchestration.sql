begin;

create table private.media_worker_jobs (
  upload_id uuid primary key references private.submission_uploads(id) on delete cascade,
  state text not null check(state in ('queued','complete','failed')) default 'queued',
  attempt_count integer not null default 0 check(attempt_count>=0),
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table private.media_worker_jobs enable row level security;
alter table private.media_worker_jobs force row level security;
revoke all on private.media_worker_jobs from public,anon,authenticated,ost_web_app;

create or replace function private.begin_submission_processing(p_upload_id uuid)
returns table(upload_id uuid,competition_id uuid,participant_id uuid,storage_key text,upload_bytes bigint,
               claimed_seconds numeric,min_clip_seconds numeric,max_clip_seconds numeric,
               max_upload_bytes bigint,normalize_loudness boolean)
language plpgsql security definer set search_path=''
as $$ begin
  return query
  update private.submission_uploads u set status='processing',error_code=null,updated_at=now()
  from private.competitions c,private.participants p
  where u.id=p_upload_id and u.competition_id=c.id and u.participant_id=p.id
    and p.user_id=auth.uid() and p.withdrawn_at is null and c.status='submissions_open'
    and u.status in ('uploading','failed','processing')
  returning u.id,u.competition_id,u.participant_id,u.original_storage_key,u.original_bytes,u.claimed_seconds,
    (c.settings->>'min_clip_seconds')::numeric,(c.settings->>'max_clip_seconds')::numeric,
    least((c.settings->>'max_upload_bytes')::bigint,524288000),coalesce((c.settings->>'loudness_normalization')::boolean,false);
  if not found then raise exception 'Resource unavailable' using errcode='P0002'; end if;
end $$;
revoke all on function private.begin_submission_processing(uuid) from public,anon,authenticated;
grant execute on function private.begin_submission_processing(uuid) to ost_web_app;

create or replace function private.media_worker_queued(p_upload_id uuid)
returns integer language plpgsql security definer set search_path=''
as $$ declare attempt_no integer; begin
  if not exists(select 1 from private.submission_uploads u where u.id=p_upload_id and u.status='processing') then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  insert into private.media_worker_jobs(upload_id,state,attempt_count,error_code)
  values(p_upload_id,'queued',1,null)
  on conflict(upload_id) do update set state='queued',attempt_count=private.media_worker_jobs.attempt_count+1,error_code=null,updated_at=now()
  returning attempt_count into attempt_no;
  return attempt_no;
end $$;
revoke all on function private.media_worker_queued(uuid) from public,anon,authenticated;
grant execute on function private.media_worker_queued(uuid) to ost_web_app;

-- The OUT parameter is named submission_id; use the unique constraint name in
-- ON CONFLICT so PL/pgSQL cannot confuse it with the returned variable.
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
  on conflict on constraint media_jobs_submission_id_key do update set state='complete',attempt_count=private.media_jobs.attempt_count+1,updated_at=now();
  return query select result_id,result_status,prev.original_storage_key,prev.audio_storage_key;
end $$;
revoke all on function private.finish_submission_processing(uuid,text,numeric,numeric,boolean) from public,anon,authenticated;
grant execute on function private.finish_submission_processing(uuid,text,numeric,numeric,boolean) to ost_web_app;

create or replace function private.media_worker_complete(
  p_upload_id uuid,p_audio_storage_key text,p_original_seconds numeric,
  p_audio_seconds numeric,p_duration_mismatch boolean,p_task_attempt integer
) returns table(submission_id uuid,status private.submission_status)
language plpgsql security definer set search_path=''
as $$ declare finished_id uuid; finished_status private.submission_status; begin
  if exists(select 1 from private.media_worker_jobs j where j.upload_id=p_upload_id and j.state='complete') then
    return query select s.id,s.status from private.submissions s
      join private.submission_uploads u on u.competition_id=s.competition_id and u.participant_id=s.participant_id and u.slot=s.slot
      where u.id=p_upload_id;
    return;
  end if;
  select f.submission_id,f.status into finished_id,finished_status
  from private.finish_submission_processing(
    p_upload_id,p_audio_storage_key,p_original_seconds,p_audio_seconds,p_duration_mismatch
  ) as f;
  update private.media_worker_jobs set state='complete',attempt_count=greatest(attempt_count,p_task_attempt+1),error_code=null,updated_at=now()
  where upload_id=p_upload_id;
  return query select finished_id,finished_status;
end $$;
revoke all on function private.media_worker_complete(uuid,text,numeric,numeric,boolean,integer) from public,anon,authenticated;
grant execute on function private.media_worker_complete(uuid,text,numeric,numeric,boolean,integer) to ost_web_app;

create or replace function private.media_worker_fail(p_upload_id uuid,p_error_code text,p_task_attempt integer)
returns void language plpgsql security definer set search_path=''
as $$ begin
  if exists(select 1 from private.media_worker_jobs j where j.upload_id=p_upload_id and j.state in ('complete','failed')) then
    return;
  end if;
  update private.submission_uploads set status='failed',error_code=left(p_error_code,48),updated_at=now()
  where id=p_upload_id and status='processing';
  if not found and not exists(select 1 from private.submission_uploads where id=p_upload_id and status='failed') then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  insert into private.media_worker_jobs(upload_id,state,attempt_count,error_code)
  values(p_upload_id,'failed',greatest(p_task_attempt+1,1),left(p_error_code,48))
  on conflict(upload_id) do update set state='failed',attempt_count=greatest(private.media_worker_jobs.attempt_count,p_task_attempt+1),error_code=left(p_error_code,48),updated_at=now();
end $$;
revoke all on function private.media_worker_fail(uuid,text,integer) from public,anon,authenticated;
grant execute on function private.media_worker_fail(uuid,text,integer) to ost_web_app;

create or replace function private.my_submission_upload_status(p_upload_id uuid)
returns table(status text,error_code text)
language sql stable security definer set search_path=''
as $$ select coalesce(s.status::text,u.status),u.error_code from private.submission_uploads u
join private.participants p on p.id=u.participant_id
left join private.submissions s on s.competition_id=u.competition_id and s.participant_id=u.participant_id and s.slot=u.slot
where u.id=p_upload_id and p.user_id=auth.uid() and p.withdrawn_at is null $$;
revoke all on function private.my_submission_upload_status(uuid) from public,anon,authenticated;
grant execute on function private.my_submission_upload_status(uuid) to ost_web_app;

create or replace function private.host_list_media_failures()
returns table(upload_id uuid,competition_id uuid,round_name text,nickname text,slot smallint,ost_title text,error_code text,attempt_count integer,updated_at timestamptz)
language plpgsql stable security definer set search_path=''
as $$ begin
  perform private.require_platform_host();
  return query select u.id,u.competition_id,c.name,p.nickname,u.slot,u.ost_title,u.error_code,
    coalesce(j.attempt_count,0),u.updated_at
  from private.submission_uploads u join private.competitions c on c.id=u.competition_id
  join private.participants p on p.id=u.participant_id left join private.media_worker_jobs j on j.upload_id=u.id
  where u.status='failed' order by u.updated_at desc;
end $$;
revoke all on function private.host_list_media_failures() from public,anon,authenticated;
grant execute on function private.host_list_media_failures() to ost_web_app;

commit;
