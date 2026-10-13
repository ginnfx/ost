begin;

alter table private.competitions add column rating_deadline timestamptz;

create or replace function private.host_create_trial()
returns uuid language plpgsql security definer set search_path=''
as $$ declare result uuid; begin
  perform private.require_platform_host();
  if exists(select 1 from private.competitions c where c.is_trial and c.status<>'archived') then
    raise exception 'A trial round already exists.' using errcode='23514';
  end if;
  insert into private.competitions(name,status,is_trial,settings)
  values('Trial round','draft',true,jsonb_build_object(
    'entries_per_participant',2,'batch_count',1,'reveal_group_count',1,
    'min_clip_seconds',20,'max_clip_seconds',360,'max_upload_bytes',524288000,
    'loudness_normalization',false,'original_retention_days',1
  )) returning id into result;
  insert into private.participants(competition_id,user_id,nickname)
  values(result,auth.uid(),'Host');
  insert into private.host_audit_log(actor_user_id,event_type,target_id,details)
  values(auth.uid(),'trial_round_created',result,jsonb_build_object('entries_per_participant',2,'batches',1,'reveal_groups',1));
  return result;
end $$;
revoke all on function private.host_create_trial() from public,anon,authenticated;
grant execute on function private.host_create_trial() to ost_web_app;

create or replace function private.host_open_trial(p_competition_id uuid)
returns void language plpgsql security definer set search_path=''
as $$ declare changed integer; begin
  perform private.require_platform_host();
  update private.competitions set status='submissions_open',submission_deadline=now()+interval '24 hours',
    rating_deadline=now()+interval '72 hours'
  where id=p_competition_id and is_trial and status='draft';
  get diagnostics changed=row_count;
  if changed<>1 then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  insert into private.host_audit_log(competition_id,actor_user_id,event_type,details)
  values(p_competition_id,auth.uid(),'trial_submissions_opened',jsonb_build_object('submission_deadline_hours',24,'rating_deadline_hours',72));
end $$;
revoke all on function private.host_open_trial(uuid) from public,anon,authenticated;
grant execute on function private.host_open_trial(uuid) to ost_web_app;

create or replace function private.host_list_trials()
returns table(competition_id uuid,name text,status private.competition_status,created_at timestamptz,
              submission_deadline timestamptz,rating_deadline timestamptz,participant_count bigint)
language plpgsql stable security definer set search_path=''
as $$ begin
  perform private.require_platform_host();
  return query select c.id,c.name,c.status,c.created_at,c.submission_deadline,c.rating_deadline,
    (select count(*) from private.participants p where p.competition_id=c.id)
  from private.competitions c where c.is_trial order by c.created_at desc;
end $$;
revoke all on function private.host_list_trials() from public,anon,authenticated;
grant execute on function private.host_list_trials() to ost_web_app;

create or replace function private.host_trial_media_keys(p_competition_id uuid)
returns table(storage_key text)
language plpgsql stable security definer set search_path=''
as $$ begin
  perform private.require_platform_host();
  if not exists(select 1 from private.competitions c where c.id=p_competition_id and c.is_trial) then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  return query select u.original_storage_key from private.submission_uploads u where u.competition_id=p_competition_id
  union select s.original_storage_key from private.submissions s where s.competition_id=p_competition_id and s.original_storage_key is not null
  union select s.audio_storage_key from private.submissions s where s.competition_id=p_competition_id and s.audio_storage_key is not null;
end $$;
revoke all on function private.host_trial_media_keys(uuid) from public,anon,authenticated;
grant execute on function private.host_trial_media_keys(uuid) to ost_web_app;

create or replace function private.host_trial_unused_invite_users(p_competition_id uuid)
returns table(user_id uuid)
language plpgsql stable security definer set search_path=''
as $$ begin
  perform private.require_platform_host();
  if not exists(select 1 from private.competitions c where c.id=p_competition_id and c.is_trial) then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  return query select i.auth_user_id from private.invites i
  where i.competition_id=p_competition_id and i.redeemed_at is null and i.auth_user_id is not null;
end $$;
revoke all on function private.host_trial_unused_invite_users(uuid) from public,anon,authenticated;
grant execute on function private.host_trial_unused_invite_users(uuid) to ost_web_app;

create or replace function private.host_delete_trial(p_competition_id uuid)
returns void language plpgsql security definer set search_path=''
as $$ declare changed integer; begin
  perform private.require_platform_host();
  if not exists(select 1 from private.competitions c where c.id=p_competition_id and c.is_trial) then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  insert into private.host_audit_log(actor_user_id,event_type,target_id,details)
  values(auth.uid(),'trial_data_deleted',p_competition_id,'{"media_removed":true}'::jsonb);
  delete from private.competitions where id=p_competition_id and is_trial;
  get diagnostics changed=row_count;
  if changed<>1 then raise exception 'Resource unavailable' using errcode='P0002'; end if;
end $$;
revoke all on function private.host_delete_trial(uuid) from public,anon,authenticated;
grant execute on function private.host_delete_trial(uuid) to ost_web_app;

-- Trial entries are useful for reviewing the current round, but they are not prior-round history.
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
      join private.competitions prior_round on prior_round.id=d.competition_id and not prior_round.is_trial
      where prior.user_id=p.user_id and d.competition_id<>s.competition_id
        and lower(d.franchise)=lower(s.franchise) and lower(d.ost_title)=lower(s.ost_title))
  from private.submissions s join private.competitions c on c.id=s.competition_id
    join private.participants p on p.id=s.participant_id
  where s.status in ('needs_review','awaiting_confirmation','confirmed') order by s.created_at;
end $$;
revoke all on function private.list_host_submission_reviews() from public,anon,authenticated;
grant execute on function private.list_host_submission_reviews() to ost_web_app;

-- Invites only exist while submissions are open and the ten-person group has room.
create or replace function private.create_invite(p_competition_id uuid,p_email text,p_token_digest bytea,p_expires_at timestamptz,p_actor uuid,p_auth_user_id uuid)
returns uuid language plpgsql security definer set search_path=''
as $$ declare result uuid; begin
  perform private.require_platform_host();
  perform 1 from private.competitions c where c.id=p_competition_id and c.status='submissions_open'
    and (c.submission_deadline is null or c.submission_deadline>now()) for update;
  if not found then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  if p_actor is distinct from auth.uid()
    or not exists(select 1 from auth.users u where u.id=p_auth_user_id and lower(u.email)=lower(p_email))
    or (select count(*) from private.participants p where p.competition_id=p_competition_id)
       + (select count(*) from private.invites i where i.competition_id=p_competition_id
          and i.redeemed_at is null and i.revoked_at is null and i.expires_at>now())>=10 then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  insert into private.invites(competition_id,email,token_digest,expires_at,created_by,auth_user_id)
  values(p_competition_id,lower(p_email),p_token_digest,p_expires_at,p_actor,p_auth_user_id) returning id into result;
  insert into private.host_audit_log(competition_id,actor_user_id,event_type,details)
  values(p_competition_id,p_actor,'invite_created',jsonb_build_object('invite_id',result));
  return result;
end $$;
revoke all on function private.create_invite(uuid,text,bytea,timestamptz,uuid,uuid) from public,anon,authenticated;
grant execute on function private.create_invite(uuid,text,bytea,timestamptz,uuid,uuid) to ost_web_app;

create or replace function private.save_listening_rating(p_competition_id uuid,p_batch_number smallint,p_listening_id uuid,p_score smallint,p_expected_version bigint)
returns bigint language plpgsql security definer set search_path=''
as $$ declare participant uuid; batch uuid; submission uuid; owner uuid; old_version bigint; result_version bigint; is_locked boolean; begin
  if p_score not between 1 and 10 then raise exception 'Invalid rating.' using errcode='23514'; end if;
  select p.id,b.id,l.submission_id,s.participant_id into participant,batch,submission,owner
  from private.participants p join private.competitions c on c.id=p.competition_id and c.status='listening'
    and (c.rating_deadline is null or c.rating_deadline>now())
    join private.batches b on b.competition_id=c.id and b.batch_number=p_batch_number and b.status='released'
    join private.participant_batch_entries x on x.participant_id=p.id and x.batch_id=b.id and x.listening_id=p_listening_id
    join private.listening_labels l on l.listening_id=x.listening_id join private.submissions s on s.id=l.submission_id
  where p.competition_id=p_competition_id and p.user_id=auth.uid() and p.withdrawn_at is null;
  if participant is null or owner=participant then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  select exists(select 1 from private.batch_finalizations f where f.participant_id=participant and f.batch_id=batch and f.reopened_at is null) into is_locked;
  if is_locked then raise exception 'Batch is finalized.' using errcode='23514'; end if;
  select r.version into old_version from private.ratings r where r.participant_id=participant and r.submission_id=submission for update;
  if (old_version is null and p_expected_version is not null and p_expected_version<>0)
     or (old_version is not null and p_expected_version is distinct from old_version) then
    raise exception 'Stale rating.' using errcode='40001';
  end if;
  if old_version is null then
    insert into private.ratings(participant_id,submission_id,batch_id,score) values(participant,submission,batch,p_score) returning version into result_version;
  else
    update private.ratings set score=p_score,version=version+1,updated_at=now()
      where participant_id=participant and submission_id=submission returning version into result_version;
  end if;
  return result_version;
end $$;
revoke all on function private.save_listening_rating(uuid,smallint,uuid,smallint,bigint) from public,anon,authenticated;
grant execute on function private.save_listening_rating(uuid,smallint,uuid,smallint,bigint) to ost_web_app;

create or replace function private.finalize_listening_batch(p_competition_id uuid,p_batch_number smallint)
returns void language plpgsql security definer set search_path=''
as $$ declare participant uuid; batch uuid; total bigint; rated bigint; begin
  select p.id,b.id into participant,batch from private.participants p join private.competitions c on c.id=p.competition_id
  join private.batches b on b.competition_id=c.id and b.batch_number=p_batch_number and b.status='released'
  where p.competition_id=p_competition_id and p.user_id=auth.uid() and p.withdrawn_at is null and c.status='listening'
    and (c.rating_deadline is null or c.rating_deadline>now());
  if participant is null then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  select count(*) into total from private.participant_batch_entries x where x.participant_id=participant and x.batch_id=batch;
  select count(*) into rated from private.participant_batch_entries x join private.listening_labels l on l.listening_id=x.listening_id
    join private.ratings r on r.participant_id=participant and r.submission_id=l.submission_id
    where x.participant_id=participant and x.batch_id=batch;
  if total=0 or total<>rated then raise exception 'Rate every clip in the batch before finalizing.' using errcode='23514'; end if;
  insert into private.batch_finalizations(participant_id,batch_id,finalized_at,reopened_at)
  values(participant,batch,now(),null) on conflict(participant_id,batch_id) do update set finalized_at=now(),reopened_at=null;
end $$;
revoke all on function private.finalize_listening_batch(uuid,smallint) from public,anon,authenticated;
grant execute on function private.finalize_listening_batch(uuid,smallint) to ost_web_app;

commit;
