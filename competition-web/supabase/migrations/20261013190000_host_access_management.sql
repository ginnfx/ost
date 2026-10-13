begin;

create table private.host_bootstrap_tokens (
  token_digest bytea primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table private.host_bootstrap_tokens enable row level security;
alter table private.host_bootstrap_tokens force row level security;
revoke all on private.host_bootstrap_tokens from public,anon,authenticated,ost_web_app;

create or replace function private.lookup_host_bootstrap(p_digest bytea)
returns table(user_id uuid,expires_at timestamptz,redeemed_at timestamptz)
language sql stable security definer set search_path=''
as $$
  select t.user_id,t.expires_at,t.redeemed_at
  from private.host_bootstrap_tokens t
  join private.platform_config c on c.singleton and c.host_user_id=t.user_id
  where t.token_digest=p_digest
$$;
revoke all on function private.lookup_host_bootstrap(bytea) from public,anon,authenticated;
grant execute on function private.lookup_host_bootstrap(bytea) to ost_web_app;

create or replace function private.complete_host_bootstrap(
  p_digest bytea,p_credential_id text,p_public_key bytea,p_sign_count bigint,
  p_transports text[],p_device_type text,p_backed_up boolean,p_nickname text
) returns uuid language plpgsql security definer set search_path=''
as $$ declare host_id uuid; begin
  select t.user_id into host_id from private.host_bootstrap_tokens t
  join private.platform_config c on c.singleton and c.host_user_id=t.user_id
  where t.token_digest=p_digest and t.redeemed_at is null and t.expires_at>now()
  for update of t;
  if host_id is null or exists(select 1 from private.passkey_credentials where user_id=host_id) then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
  insert into private.passkey_credentials(credential_id,user_id,public_key,sign_count,transports,device_type,backed_up,nickname)
  values(p_credential_id,host_id,p_public_key,p_sign_count,coalesce(p_transports,'{}'),p_device_type,p_backed_up,left(trim(p_nickname),60));
  update private.host_bootstrap_tokens set redeemed_at=now() where token_digest=p_digest;
  insert into private.host_audit_log(actor_user_id,event_type,details)
  values(host_id,'host_bootstrap_completed',jsonb_build_object('credential_id',p_credential_id));
  return host_id;
end $$;
revoke all on function private.complete_host_bootstrap(bytea,text,bytea,bigint,text[],text,boolean,text) from public,anon,authenticated;
grant execute on function private.complete_host_bootstrap(bytea,text,bytea,bigint,text[],text,boolean,text) to ost_web_app;

create or replace function private.list_host_credentials()
returns table(credential_id text,nickname text,device_type text,backed_up boolean,created_at timestamptz,last_used_at timestamptz)
language plpgsql stable security definer set search_path=''
as $$ begin
  perform private.require_platform_host();
  return query select c.credential_id,c.nickname,c.device_type,c.backed_up,c.created_at,c.last_used_at
    from private.passkey_credentials c where c.user_id=auth.uid() order by c.created_at;
end $$;
revoke all on function private.list_host_credentials() from public,anon,authenticated;
grant execute on function private.list_host_credentials() to ost_web_app;

create or replace function private.register_host_credential(
  p_credential_id text,p_public_key bytea,p_sign_count bigint,p_transports text[],
  p_device_type text,p_backed_up boolean,p_nickname text
) returns void language plpgsql security definer set search_path=''
as $$ begin
  perform private.require_platform_host();
  insert into private.passkey_credentials(credential_id,user_id,public_key,sign_count,transports,device_type,backed_up,nickname)
  values(p_credential_id,auth.uid(),p_public_key,p_sign_count,coalesce(p_transports,'{}'),p_device_type,p_backed_up,left(trim(p_nickname),60));
  insert into private.host_audit_log(actor_user_id,event_type,details)
  values(auth.uid(),'host_credential_added',jsonb_build_object('credential_id',p_credential_id));
end $$;
revoke all on function private.register_host_credential(text,bytea,bigint,text[],text,boolean,text) from public,anon,authenticated;
grant execute on function private.register_host_credential(text,bytea,bigint,text[],text,boolean,text) to ost_web_app;

create or replace function private.remove_host_credential(p_credential_id text)
returns void language plpgsql security definer set search_path=''
as $$ declare remaining integer; begin
  perform private.require_platform_host();
  select count(*) into remaining from private.passkey_credentials where user_id=auth.uid();
  if remaining<2 then raise exception 'A backup passkey is required' using errcode='23514'; end if;
  delete from private.passkey_credentials where user_id=auth.uid() and credential_id=p_credential_id;
  if not found then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  insert into private.host_audit_log(actor_user_id,event_type,details)
  values(auth.uid(),'host_credential_removed',jsonb_build_object('credential_id',p_credential_id));
end $$;
revoke all on function private.remove_host_credential(text) from public,anon,authenticated;
grant execute on function private.remove_host_credential(text) to ost_web_app;

create or replace function private.revoke_host_sessions()
returns void language plpgsql security definer set search_path=''
as $$ begin
  perform private.require_platform_host();
  delete from auth.sessions where user_id=auth.uid();
  insert into private.host_audit_log(actor_user_id,event_type)
  values(auth.uid(),'host_sessions_revoked');
end $$;
revoke all on function private.revoke_host_sessions() from public,anon,authenticated;
grant execute on function private.revoke_host_sessions() to ost_web_app;

create or replace function private.replace_host_recovery_codes(p_digests bytea[])
returns void language plpgsql security definer set search_path=''
as $$ begin
  perform private.require_platform_host();
  if cardinality(p_digests)<>10 then raise exception 'Exactly ten recovery codes are required'; end if;
  delete from private.recovery_codes where user_id=auth.uid() and used_at is null;
  insert into private.recovery_codes(user_id,code_digest)
  select auth.uid(),digest_value from unnest(p_digests) as digest_value;
  insert into private.host_audit_log(actor_user_id,event_type)
  values(auth.uid(),'host_recovery_codes_rotated');
end $$;
revoke all on function private.replace_host_recovery_codes(bytea[]) from public,anon,authenticated;
grant execute on function private.replace_host_recovery_codes(bytea[]) to ost_web_app;

create or replace function private.prepare_host_recovery(p_digest bytea)
returns uuid language plpgsql security definer set search_path=''
as $$ declare host_id uuid; begin
  select c.user_id into host_id from private.recovery_codes c
  join private.platform_config p on p.singleton and p.host_user_id=c.user_id
  where c.code_digest=p_digest and c.used_at is null;
  if host_id is null then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  return host_id;
end $$;
revoke all on function private.prepare_host_recovery(bytea) from public,anon,authenticated;
grant execute on function private.prepare_host_recovery(bytea) to ost_web_app;

create or replace function private.complete_host_recovery(
  p_digest bytea,p_credential_id text,p_public_key bytea,p_sign_count bigint,
  p_transports text[],p_device_type text,p_backed_up boolean,p_nickname text
) returns uuid language plpgsql security definer set search_path=''
as $$ declare host_id uuid; begin
  select c.user_id into host_id from private.recovery_codes c
  join private.platform_config p on p.singleton and p.host_user_id=c.user_id
  where c.code_digest=p_digest and c.used_at is null for update of c;
  if host_id is null then raise exception 'Resource unavailable' using errcode='P0002'; end if;
  update private.recovery_codes set used_at=now() where user_id=host_id and used_at is null;
  delete from private.passkey_credentials where user_id=host_id;
  delete from auth.sessions where user_id=host_id;
  insert into private.passkey_credentials(credential_id,user_id,public_key,sign_count,transports,device_type,backed_up,nickname)
  values(p_credential_id,host_id,p_public_key,p_sign_count,coalesce(p_transports,'{}'),p_device_type,p_backed_up,left(trim(p_nickname),60));
  insert into private.host_audit_log(actor_user_id,event_type)
  values(host_id,'host_recovery_code_used');
  return host_id;
end $$;
revoke all on function private.complete_host_recovery(bytea,text,bytea,bigint,text[],text,boolean,text) from public,anon,authenticated;
grant execute on function private.complete_host_recovery(bytea,text,bytea,bigint,text[],text,boolean,text) to ost_web_app;

commit;
