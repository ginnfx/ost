begin;

create table private.participant_batch_entries (
  participant_id uuid not null references private.participants(id) on delete cascade,
  batch_id uuid not null references private.batches(id) on delete cascade,
  listening_id uuid not null references private.listening_labels(listening_id) on delete cascade,
  display_order integer not null check(display_order>0),
  primary key(participant_id,batch_id,listening_id),
  unique(participant_id,batch_id,display_order)
);
alter table private.participant_batch_entries enable row level security;
alter table private.participant_batch_entries force row level security;
revoke all on private.participant_batch_entries from public,anon,authenticated,ost_web_app;

create or replace function private.host_lock_submissions(p_competition_id uuid)
returns void language plpgsql security definer set search_path=''
as $$ declare required_count smallint; state private.competition_status; begin
  perform private.require_platform_host();
  select c.status,(c.settings->>'entries_per_participant')::smallint into state,required_count
  from private.competitions c where c.id=p_competition_id for update;
  if state<>'submissions_open' or required_count is null then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  if exists(select 1 from private.participants p where p.competition_id=p_competition_id and p.withdrawn_at is null
    and (select count(*) from private.submissions s where s.competition_id=p_competition_id
      and s.participant_id=p.id and s.status='confirmed')<required_count) then
    raise exception 'Every participant must confirm every entry before locking.' using errcode='23514';
  end if;
  update private.competitions set status='submissions_locked' where id=p_competition_id;
  insert into private.host_audit_log(competition_id,actor_user_id,event_type)
    values(p_competition_id,auth.uid(),'submissions_locked');
end $$;
revoke all on function private.host_lock_submissions(uuid) from public,anon,authenticated;
grant execute on function private.host_lock_submissions(uuid) to ost_web_app;

create or replace function private.host_start_listening(p_competition_id uuid)
returns smallint language plpgsql security definer set search_path=''
as $$ declare state private.competition_status; total_entries integer; batch_total smallint; seed bytea; begin
  perform private.require_platform_host();
  select c.status,(c.settings->>'batch_count')::smallint into state,batch_total
    from private.competitions c where c.id=p_competition_id for update;
  if state<>'submissions_locked' or batch_total is null or batch_total<1 then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  select count(*) into total_entries from private.submissions s where s.competition_id=p_competition_id and s.status='confirmed';
  if total_entries<1 then raise exception 'No confirmed entries.' using errcode='23514'; end if;
  batch_total:=least(batch_total,total_entries)::smallint;
  update private.competitions set status='listening',settings=jsonb_set(settings,'{batch_count}',to_jsonb(batch_total)) where id=p_competition_id;
  seed:=extensions.gen_random_bytes(32);
  insert into private.listening_labels(competition_id,submission_id,label_number,label)
    select p_competition_id,s.id,row_number() over(order by extensions.digest(seed||convert_to(s.id::text,'UTF8'),'sha256'))::integer,
      'Mystery OST #'||row_number() over(order by extensions.digest(seed||convert_to(s.id::text,'UTF8'),'sha256'))::text
    from private.submissions s where s.competition_id=p_competition_id and s.status='confirmed';
  insert into private.batches(competition_id,batch_number,shuffle_seed)
    select p_competition_id,n,extensions.digest(seed||pg_catalog.int2send(n::smallint),'sha256') from generate_series(1,batch_total) n;
  insert into private.batch_entries(batch_id,listening_id,display_order_seed)
    with assigned as (
      select l.listening_id,l.competition_id,
        ((row_number() over(partition by s.participant_id order by extensions.digest(seed||convert_to(s.id::text,'UTF8'),'sha256'))-1)%batch_total)+1 as batch_number
      from private.listening_labels l join private.submissions s on s.id=l.submission_id
      where l.competition_id=p_competition_id
    )
    select b.id,a.listening_id,row_number() over(partition by b.id order by extensions.digest(seed||convert_to(a.listening_id::text,'UTF8'),'sha256'))::integer
    from assigned a join private.batches b on b.competition_id=a.competition_id and b.batch_number=a.batch_number;
  insert into private.participant_batch_entries(participant_id,batch_id,listening_id,display_order)
    select p.id,be.batch_id,be.listening_id,
      row_number() over(partition by p.id,be.batch_id order by extensions.digest(seed||convert_to(p.id::text||be.listening_id::text,'UTF8'),'sha256'))::integer
    from private.participants p join private.batches b on b.competition_id=p.competition_id
    join private.batch_entries be on be.batch_id=b.id
    where p.competition_id=p_competition_id and p.withdrawn_at is null;
  insert into private.ratings(participant_id,submission_id,batch_id,score)
    select s.participant_id,s.id,be.batch_id,10
    from private.submissions s join private.listening_labels l on l.submission_id=s.id
    join private.batch_entries be on be.listening_id=l.listening_id
    where s.competition_id=p_competition_id and s.status='confirmed';
  insert into private.host_audit_log(competition_id,actor_user_id,event_type,details)
    values(p_competition_id,auth.uid(),'listening_started',jsonb_build_object('entries',total_entries,'batches',batch_total));
  return batch_total;
end $$;
revoke all on function private.host_start_listening(uuid) from public,anon,authenticated;
grant execute on function private.host_start_listening(uuid) to ost_web_app;

create or replace function private.host_release_batch(p_competition_id uuid,p_batch_number smallint)
returns void language plpgsql security definer set search_path=''
as $$ declare changed integer; begin
  perform private.require_platform_host();
  update private.batches b set status='released',released_at=now()
  from private.competitions c where b.competition_id=p_competition_id and b.batch_number=p_batch_number
    and b.status='scheduled' and c.id=b.competition_id and c.status='listening';
  get diagnostics changed=row_count;
  if changed<>1 then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  insert into private.host_audit_log(competition_id,actor_user_id,event_type,details)
    values(p_competition_id,auth.uid(),'batch_released',jsonb_build_object('batch',p_batch_number));
end $$;
revoke all on function private.host_release_batch(uuid,smallint) from public,anon,authenticated;
grant execute on function private.host_release_batch(uuid,smallint) to ost_web_app;

create or replace function private.my_listening_batches(p_competition_id uuid)
returns table(batch_number smallint,status private.batch_status,released_at timestamptz,
              entry_count bigint,rated_count bigint,finalized boolean)
language sql stable security definer set search_path=''
as $$ select b.batch_number,b.status,b.released_at,
  (select count(*) from private.participant_batch_entries x where x.participant_id=p.id and x.batch_id=b.id),
  (select count(*) from private.participant_batch_entries x join private.listening_labels l on l.listening_id=x.listening_id
    join private.ratings r on r.submission_id=l.submission_id and r.participant_id=p.id where x.participant_id=p.id and x.batch_id=b.id),
  exists(select 1 from private.batch_finalizations f where f.participant_id=p.id and f.batch_id=b.id and f.reopened_at is null)
from private.participants p join private.batches b on b.competition_id=p.competition_id
join private.competitions c on c.id=b.competition_id
where p.competition_id=p_competition_id and p.user_id=auth.uid() and p.withdrawn_at is null and c.status='listening'
order by b.batch_number $$;
revoke all on function private.my_listening_batches(uuid) from public,anon,authenticated;
grant execute on function private.my_listening_batches(uuid) to ost_web_app;

create or replace function private.my_listening_batch_entries(p_competition_id uuid,p_batch_number smallint)
returns table(listening_id uuid,label text,audio_storage_key text,duration_seconds numeric,is_own boolean,
              own_rating smallint,current_rating smallint,rating_version bigint)
language plpgsql stable security definer set search_path=''
as $$ declare participant uuid; batch uuid; begin
  select p.id,b.id into participant,batch from private.participants p
  join private.competitions c on c.id=p.competition_id and c.status='listening'
  join private.batches b on b.competition_id=c.id and b.batch_number=p_batch_number and b.status in ('released','closed')
  where p.competition_id=p_competition_id and p.user_id=auth.uid() and p.withdrawn_at is null;
  if participant is null or batch is null then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  return query select l.listening_id,l.label,s.audio_storage_key,s.audio_seconds,(s.participant_id=participant),
    case when s.participant_id=participant then 10::smallint else null::smallint end,
    r.score,r.version
  from private.participant_batch_entries x join private.listening_labels l on l.listening_id=x.listening_id
    join private.submissions s on s.id=l.submission_id
    left join private.ratings r on r.participant_id=participant and r.submission_id=s.id
  where x.participant_id=participant and x.batch_id=batch order by x.display_order;
end $$;
revoke all on function private.my_listening_batch_entries(uuid,smallint) from public,anon,authenticated;
grant execute on function private.my_listening_batch_entries(uuid,smallint) to ost_web_app;

create or replace function private.save_listening_rating(p_competition_id uuid,p_batch_number smallint,p_listening_id uuid,p_score smallint,p_expected_version bigint)
returns bigint language plpgsql security definer set search_path=''
as $$ declare participant uuid; batch uuid; submission uuid; owner uuid; old_version bigint; result_version bigint; is_locked boolean; begin
  if p_score not between 1 and 10 then raise exception 'Invalid rating.' using errcode='23514'; end if;
  select p.id,b.id,l.submission_id,s.participant_id into participant,batch,submission,owner
  from private.participants p join private.competitions c on c.id=p.competition_id and c.status='listening'
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
  where p.competition_id=p_competition_id and p.user_id=auth.uid() and p.withdrawn_at is null and c.status='listening';
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

create or replace function private.host_reopen_listening_batch(p_competition_id uuid,p_participant_id uuid,p_batch_number smallint)
returns void language plpgsql security definer set search_path=''
as $$ declare batch uuid; changed integer; begin
  perform private.require_platform_host();
  select b.id into batch from private.batches b where b.competition_id=p_competition_id and b.batch_number=p_batch_number;
  if batch is null then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  update private.batch_finalizations set reopened_at=now() where participant_id=p_participant_id and batch_id=batch and reopened_at is null;
  get diagnostics changed=row_count;
  if changed<>1 then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  insert into private.host_audit_log(competition_id,actor_user_id,event_type,target_id,details)
    values(p_competition_id,auth.uid(),'rating_batch_reopened',p_participant_id,jsonb_build_object('batch',p_batch_number));
end $$;
revoke all on function private.host_reopen_listening_batch(uuid,uuid,smallint) from public,anon,authenticated;
grant execute on function private.host_reopen_listening_batch(uuid,uuid,smallint) to ost_web_app;

create or replace function private.host_close_ratings(p_competition_id uuid)
returns void language plpgsql security definer set search_path=''
as $$ declare changed integer; begin
  perform private.require_platform_host();
  update private.competitions set status='rating_closed' where id=p_competition_id and status='listening';
  get diagnostics changed=row_count;
  if changed<>1 then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  insert into private.host_audit_log(competition_id,actor_user_id,event_type)
    values(p_competition_id,auth.uid(),'ratings_closed');
end $$;
revoke all on function private.host_close_ratings(uuid) from public,anon,authenticated;
grant execute on function private.host_close_ratings(uuid) to ost_web_app;

create or replace function private.host_scoring_input(p_competition_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$ declare result jsonb; begin
  perform private.require_platform_host();
  select jsonb_build_object(
    'seed',encode(extensions.gen_random_bytes(32),'hex'),
    'batchCount',(c.settings->>'batch_count')::integer,
    'revealGroupCount',(c.settings->>'reveal_group_count')::integer,
    'participants',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'withdrawn',p.withdrawn_at is not null,
      'finalizedBatches',coalesce((select jsonb_agg(b.batch_number order by b.batch_number) from private.batch_finalizations f join private.batches b on b.id=f.batch_id
        where f.participant_id=p.id and f.reopened_at is null), '[]'::jsonb))) from private.participants p where p.competition_id=c.id),'[]'::jsonb),
    'entries',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'ownerId',s.participant_id)) from private.submissions s where s.competition_id=c.id and s.status='confirmed'),'[]'::jsonb),
    'ratings',coalesce((select jsonb_agg(jsonb_build_object('raterId',r.participant_id,'entryId',r.submission_id,'score',r.score))
      from private.ratings r join private.submissions s on s.id=r.submission_id where s.competition_id=c.id),'[]'::jsonb)) into result
  from private.competitions c where c.id=p_competition_id and c.status='rating_closed';
  if result is null then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  return result;
end $$;
revoke all on function private.host_scoring_input(uuid) from public,anon,authenticated;
grant execute on function private.host_scoring_input(uuid) to ost_web_app;

create or replace function private.host_record_score_snapshot(p_competition_id uuid,p_seed text,p_payload jsonb)
returns void language plpgsql security definer set search_path=''
as $$ declare group_item jsonb; begin
  perform private.require_platform_host();
  if not exists(select 1 from private.competitions c where c.id=p_competition_id and c.status='rating_closed')
    or p_seed !~ '^[a-f0-9]{64}$' or jsonb_typeof(p_payload->'ranked')<>'array'
    or jsonb_typeof(p_payload->'revealGroups')<>'array' then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  insert into private.score_snapshots(competition_id,algorithm_version,seed,payload)
    values(p_competition_id,1,decode(p_seed,'hex'),p_payload);
  for group_item in select value from jsonb_array_elements(p_payload->'revealGroups') loop
    insert into private.reveal_groups(competition_id,group_number) values(p_competition_id,(group_item->>'number')::smallint);
  end loop;
  update private.competitions set status='scored' where id=p_competition_id;
  insert into private.host_audit_log(competition_id,actor_user_id,event_type,details)
    values(p_competition_id,auth.uid(),'scoring_snapshot_frozen',jsonb_build_object('algorithm_version',1));
end $$;
revoke all on function private.host_record_score_snapshot(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function private.host_record_score_snapshot(uuid,text,jsonb) to ost_web_app;

create or replace function private.host_publish_reveal_group(p_competition_id uuid,p_group_number smallint)
returns void language plpgsql security definer set search_path=''
as $$ declare changed integer; begin
  perform private.require_platform_host();
  update private.reveal_groups g set published_at=now() from private.competitions c
  where g.competition_id=p_competition_id and g.group_number=p_group_number and g.published_at is null
    and c.id=g.competition_id and c.status in ('scored','revealing')
    and not exists(select 1 from private.reveal_groups prev where prev.competition_id=g.competition_id
      and prev.group_number<p_group_number and (prev.published_at is null or exists(
        select 1 from private.score_snapshots snap
        cross join lateral jsonb_array_elements(snap.payload->'revealGroups') earlier(value)
        cross join lateral jsonb_array_elements(earlier.value->'entryIds') ids(value)
        where snap.competition_id=prev.competition_id and (earlier.value->>'number')::smallint=prev.group_number
          and not exists(select 1 from private.reveal_events e join private.listening_labels l on l.listening_id=e.listening_id
            where e.competition_id=prev.competition_id and e.group_number=prev.group_number and l.submission_id=(ids.value#>>'{}')::uuid)
      )));
  get diagnostics changed=row_count;
  if changed<>1 then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  update private.competitions set status='revealing' where id=p_competition_id;
  insert into private.host_audit_log(competition_id,actor_user_id,event_type,details)
    values(p_competition_id,auth.uid(),'reveal_group_published',jsonb_build_object('group',p_group_number));
end $$;
revoke all on function private.host_publish_reveal_group(uuid,smallint) from public,anon,authenticated;
grant execute on function private.host_publish_reveal_group(uuid,smallint) to ost_web_app;

create or replace function private.host_reveal_next_entry(p_competition_id uuid,p_group_number smallint)
returns boolean language plpgsql security definer set search_path=''
as $$ declare entry_id uuid; group_item jsonb; begin
  perform private.require_platform_host();
  if not exists(select 1 from private.reveal_groups g where g.competition_id=p_competition_id and g.group_number=p_group_number and g.published_at is not null) then
    raise exception 'Resource unavailable' using errcode='P0002'; end if;
  select value into group_item from private.score_snapshots s,jsonb_array_elements(s.payload->'revealGroups') value
    where s.competition_id=p_competition_id and (value->>'number')::smallint=p_group_number;
  select (items.value#>>'{}')::uuid into entry_id
    from jsonb_array_elements(group_item->'entryIds') with ordinality as items(value,ordinality)
    where not exists(select 1 from private.reveal_events e join private.listening_labels l on l.listening_id=e.listening_id
      where e.competition_id=p_competition_id and e.group_number=p_group_number and l.submission_id=(items.value#>>'{}')::uuid)
    order by items.ordinality limit 1;
  if entry_id is null then return false; end if;
  insert into private.reveal_events(competition_id,listening_id,group_number)
    select p_competition_id,l.listening_id,p_group_number from private.listening_labels l
      join private.submissions s on s.id=l.submission_id where l.competition_id=p_competition_id and s.id=entry_id;
  insert into private.host_audit_log(competition_id,actor_user_id,event_type,target_id,details)
    values(p_competition_id,auth.uid(),'reveal_entry_advanced',entry_id,jsonb_build_object('group',p_group_number));
  if not exists(select 1 from private.reveal_groups g where g.competition_id=p_competition_id and g.published_at is null)
    and not exists(select 1 from private.score_snapshots s,jsonb_array_elements(s.payload->'ranked') r
      where s.competition_id=p_competition_id and not exists(select 1 from private.reveal_events e join private.listening_labels l on l.listening_id=e.listening_id
        where e.competition_id=p_competition_id and l.submission_id=(r->>'id')::uuid)) then
    update private.competitions set status='complete' where id=p_competition_id;
  end if;
  return true;
end $$;
revoke all on function private.host_reveal_next_entry(uuid,smallint) from public,anon,authenticated;
grant execute on function private.host_reveal_next_entry(uuid,smallint) to ost_web_app;

create or replace function private.list_published_results(p_competition_id uuid)
returns table(listening_id uuid,label text,franchise text,ost_title text,rank integer,mean_score text,rating_count integer,group_number smallint,published_at timestamptz)
language sql stable security definer set search_path=''
as $$ select l.listening_id,l.label,s.franchise,s.ost_title,(r->>'rank')::integer,r->>'mean',
  (r->>'count')::integer,e.group_number,e.published_at
from private.participants p join private.competitions c on c.id=p.competition_id and c.id=p_competition_id
join private.reveal_events e on e.competition_id=c.id
join private.listening_labels l on l.listening_id=e.listening_id
join private.submissions s on s.id=l.submission_id
join private.score_snapshots snap on snap.competition_id=c.id
cross join lateral jsonb_array_elements(snap.payload->'ranked') r
where p.user_id=auth.uid() and p.withdrawn_at is null and s.id=(r->>'id')::uuid
order by e.published_at $$;
revoke all on function private.list_published_results(uuid) from public,anon,authenticated;
grant execute on function private.list_published_results(uuid) to ost_web_app;

create or replace function private.host_round_control_state(p_competition_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$ declare result jsonb; begin
  perform private.require_platform_host();
  select jsonb_build_object('name',c.name,'status',c.status,'isTrial',c.is_trial,
    'batches',coalesce((select jsonb_agg(jsonb_build_object('number',b.batch_number,'status',b.status,
      'entryCount',(select count(*) from private.batch_entries x where x.batch_id=b.id)) order by b.batch_number)
      from private.batches b where b.competition_id=c.id),'[]'::jsonb),
    'participants',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'nickname',p.nickname,'withdrawn',p.withdrawn_at is not null,
      'finalizedBatches',coalesce((select jsonb_agg(b.batch_number order by b.batch_number) from private.batch_finalizations f
        join private.batches b on b.id=f.batch_id where f.participant_id=p.id and f.reopened_at is null),'[]'::jsonb)) order by p.created_at)
      from private.participants p where p.competition_id=c.id),'[]'::jsonb),
    'groups',coalesce((select jsonb_agg(jsonb_build_object('number',g.group_number,'published',g.published_at is not null,
      'entryCount',jsonb_array_length(group_data.value->'entryIds'),
      'revealedCount',(select count(*) from private.reveal_events e where e.competition_id=c.id and e.group_number=g.group_number)) order by g.group_number)
      from private.reveal_groups g join private.score_snapshots snap on snap.competition_id=g.competition_id
      cross join lateral jsonb_array_elements(snap.payload->'revealGroups') group_data(value)
      where g.competition_id=c.id and (group_data.value->>'number')::smallint=g.group_number),'[]'::jsonb)) into result
  from private.competitions c where c.id=p_competition_id;
  if result is null then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  return result;
end $$;
revoke all on function private.host_round_control_state(uuid) from public,anon,authenticated;
grant execute on function private.host_round_control_state(uuid) to ost_web_app;

commit;
