begin;

create table private.passkey_credentials (
  credential_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  public_key bytea not null,
  sign_count bigint not null default 0 check(sign_count>=0),
  transports text[] not null default '{}',
  device_type text not null check(device_type in ('singleDevice','multiDevice')),
  backed_up boolean not null default false,
  nickname text not null default 'Passkey' check(length(nickname) between 1 and 60),
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
alter table private.invites add column auth_user_id uuid references auth.users(id) on delete set null;
create index passkey_user_lookup on private.passkey_credentials(user_id);

create table private.recovery_codes (
  user_id uuid not null references auth.users(id) on delete cascade,
  code_digest bytea not null unique,
  created_at timestamptz not null default now(),
  used_at timestamptz,
  primary key(user_id,code_digest)
);

create table private.auth_rate_limits (
  action text not null check(action in ('invite','login','recovery','rating','upload')),
  subject_digest bytea not null,
  window_started_at timestamptz not null,
  hit_count integer not null check(hit_count>=0),
  primary key(action,subject_digest)
);

alter table private.passkey_credentials enable row level security;
alter table private.passkey_credentials force row level security;
alter table private.recovery_codes enable row level security;
alter table private.recovery_codes force row level security;
alter table private.auth_rate_limits enable row level security;
alter table private.auth_rate_limits force row level security;
revoke all on private.passkey_credentials,private.recovery_codes,private.auth_rate_limits from public,anon,authenticated,ost_web_app;

create or replace function private.passkey_lookup(p_credential_id text)
returns table(user_id uuid, public_key bytea, sign_count bigint, transports text[], device_type text, backed_up boolean)
language sql stable security definer set search_path=''
as $$ select c.user_id,c.public_key,c.sign_count,c.transports,c.device_type,c.backed_up from private.passkey_credentials c where c.credential_id=p_credential_id $$;
revoke all on function private.passkey_lookup(text) from public,anon,authenticated;
grant execute on function private.passkey_lookup(text) to ost_web_app;

create or replace function private.passkey_ids_for_user(p_user_id uuid)
returns table(credential_id text, transports text[])
language sql stable security definer set search_path=''
as $$ select c.credential_id,c.transports from private.passkey_credentials c where c.user_id=p_user_id $$;
revoke all on function private.passkey_ids_for_user(uuid) from public,anon,authenticated;
grant execute on function private.passkey_ids_for_user(uuid) to ost_web_app;

create or replace function private.current_memberships()
returns table(round_name text,round_status private.competition_status,nickname text,is_trial boolean)
language sql stable security definer set search_path=''
as $$
  select c.name,c.status,p.nickname,c.is_trial
  from private.participants p join private.competitions c on c.id=p.competition_id
  where p.user_id=auth.uid() and p.withdrawn_at is null and c.status<>'archived'
  order by c.created_at desc
$$;
revoke all on function private.current_memberships() from public,anon,authenticated;
grant execute on function private.current_memberships() to ost_web_app;

create or replace function private.lookup_invite(p_token_digest bytea)
returns table(invite_id uuid, email text, auth_user_id uuid, competition_id uuid, expires_at timestamptz, redeemed_at timestamptz, revoked_at timestamptz)
language sql stable security definer set search_path=''
as $$ select i.id,i.email,i.auth_user_id,i.competition_id,i.expires_at,i.redeemed_at,i.revoked_at from private.invites i where i.token_digest=p_token_digest $$;
revoke all on function private.lookup_invite(bytea) from public,anon,authenticated;
grant execute on function private.lookup_invite(bytea) to ost_web_app;

create or replace function private.create_invite(p_competition_id uuid,p_email text,p_token_digest bytea,p_expires_at timestamptz,p_actor uuid,p_auth_user_id uuid)
returns uuid language plpgsql security definer set search_path=''
as $$ declare result uuid; begin
  perform private.require_platform_host();
  if p_actor is distinct from auth.uid() or not exists(select 1 from auth.users u where u.id=p_auth_user_id and lower(u.email)=lower(p_email)) then
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

create or replace function private.register_invite_passkey(
  p_invite_id uuid,p_user_id uuid,p_participant_nickname text,p_credential_id text,p_public_key bytea,p_sign_count bigint,p_transports text[],p_device_type text,p_backed_up boolean,p_nickname text
) returns void language plpgsql security definer set search_path=''
as $$ declare invite_user uuid; competition uuid; begin
  select i.auth_user_id,i.competition_id into invite_user,competition from private.invites i
  where i.id=p_invite_id and i.redeemed_at is null and i.revoked_at is null and i.expires_at>now()
  for update;
  if invite_user is null or invite_user<>p_user_id or length(trim(p_participant_nickname)) not between 1 and 40 then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  insert into private.participants(competition_id,user_id,nickname) values(competition,p_user_id,trim(p_participant_nickname));
  insert into private.passkey_credentials(credential_id,user_id,public_key,sign_count,transports,device_type,backed_up,nickname)
  values(p_credential_id,p_user_id,p_public_key,p_sign_count,coalesce(p_transports,'{}'),p_device_type,p_backed_up,left(p_nickname,60));
  update private.invites set redeemed_at=now(),redeemed_by=p_user_id where id=p_invite_id;
end $$;
revoke all on function private.register_invite_passkey(uuid,uuid,text,text,bytea,bigint,text[],text,boolean,text) from public,anon,authenticated;
grant execute on function private.register_invite_passkey(uuid,uuid,text,text,bytea,bigint,text[],text,boolean,text) to ost_web_app;

create or replace function private.register_passkey(
  p_credential_id text,p_user_id uuid,p_public_key bytea,p_sign_count bigint,p_transports text[],p_device_type text,p_backed_up boolean,p_nickname text
) returns void language plpgsql security definer set search_path=''
as $$ begin
  if not exists(select 1 from auth.users where id=p_user_id) then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  insert into private.passkey_credentials(credential_id,user_id,public_key,sign_count,transports,device_type,backed_up,nickname)
  values(p_credential_id,p_user_id,p_public_key,p_sign_count,coalesce(p_transports,'{}'),p_device_type,p_backed_up,left(p_nickname,60));
end $$;
revoke all on function private.register_passkey(text,uuid,bytea,bigint,text[],text,boolean,text) from public,anon,authenticated;
grant execute on function private.register_passkey(text,uuid,bytea,bigint,text[],text,boolean,text) to ost_web_app;

create or replace function private.update_passkey_counter(p_credential_id text,p_sign_count bigint)
returns void language plpgsql security definer set search_path=''
as $$ begin
  update private.passkey_credentials set sign_count=p_sign_count,last_used_at=now() where credential_id=p_credential_id;
  if not found then raise exception 'Resource unavailable' using errcode='P0002'; end if;
end $$;
revoke all on function private.update_passkey_counter(text,bigint) from public,anon,authenticated;
grant execute on function private.update_passkey_counter(text,bigint) to ost_web_app;

create or replace function private.rate_limit_hit(p_action text,p_subject_digest bytea,p_limit integer,p_window_seconds integer)
returns boolean language plpgsql security definer set search_path=''
as $$ declare current_count integer; begin
  insert into private.auth_rate_limits(action,subject_digest,window_started_at,hit_count)
  values(p_action,p_subject_digest,now(),1)
  on conflict(action,subject_digest) do update set
    window_started_at=case when private.auth_rate_limits.window_started_at+make_interval(secs=>p_window_seconds)<=now() then now() else private.auth_rate_limits.window_started_at end,
    hit_count=case when private.auth_rate_limits.window_started_at+make_interval(secs=>p_window_seconds)<=now() then 1 else private.auth_rate_limits.hit_count+1 end
  returning hit_count into current_count;
  return current_count<=p_limit;
end $$;
revoke all on function private.rate_limit_hit(text,bytea,integer,integer) from public,anon,authenticated;
grant execute on function private.rate_limit_hit(text,bytea,integer,integer) to ost_web_app;

commit;
