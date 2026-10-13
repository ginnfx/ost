-- Competition platform only. This project is intentionally separate from OSTTracker sync.
begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
drop extension if exists pg_graphql cascade;
revoke all on schema graphql_public from public, anon, authenticated;

do $$ begin
  if not exists(select 1 from pg_roles where rolname='ost_web_app') then
    create role ost_web_app nologin noinherit nosuperuser nobypassrls;
  end if;
end $$;
grant usage on schema private to ost_web_app;

create type private.competition_status as enum ('draft','submissions_open','submissions_locked','listening','rating_closed','scored','revealing','complete','archived');
create type private.submission_status as enum ('uploading','processing','needs_review','awaiting_confirmation','confirmed','rejected','withdrawn');
create type private.batch_status as enum ('scheduled','released','closed');

create table private.platform_config (
  singleton boolean primary key default true check(singleton),
  host_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table private.competitions (
  id uuid primary key default gen_random_uuid(),
  slug uuid not null unique default gen_random_uuid(),
  name text not null check(length(name) between 1 and 120),
  status private.competition_status not null default 'draft',
  is_trial boolean not null default false,
  settings jsonb not null default '{"entries_per_participant":5,"batch_count":5,"reveal_group_count":5,"min_clip_seconds":20,"max_clip_seconds":360,"max_upload_bytes":524288000,"loudness_normalization":false,"original_retention_days":30}'::jsonb,
  submission_deadline timestamptz,
  listening_schedule jsonb not null default '[]'::jsonb,
  retention_until timestamptz,
  created_at timestamptz not null default now(),
  archived_at timestamptz
);

create table private.participants (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references private.competitions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete restrict,
  nickname text not null check(length(nickname) between 1 and 40),
  withdrawn_at timestamptz,
  created_at timestamptz not null default now(),
  unique(competition_id,user_id),
  unique(competition_id,nickname)
);

create table private.invites (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references private.competitions(id) on delete cascade,
  email text not null,
  token_digest bytea not null unique,
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  redeemed_by uuid references auth.users(id) on delete set null,
  revoked_at timestamptz,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  check(expires_at>created_at)
);

create table private.submissions (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references private.competitions(id) on delete cascade,
  participant_id uuid not null references private.participants(id) on delete restrict,
  slot smallint not null check(slot between 1 and 5),
  franchise text not null check(length(franchise) between 1 and 120),
  anilist_id bigint,
  ost_title text not null check(length(ost_title) between 1 and 160),
  status private.submission_status not null default 'uploading',
  original_storage_key text unique,
  audio_storage_key text unique,
  original_bytes bigint check(original_bytes is null or original_bytes between 1 and 524288000),
  original_seconds numeric(8,3),
  audio_seconds numeric(8,3),
  original_sha256 bytea,
  audio_sha256 bytea,
  confirmed_at timestamptz,
  rejection_reason text,
  duration_mismatch boolean not null default false,
  version bigint not null default 1 check(version>0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(competition_id,participant_id,slot)
);

create table private.listening_labels (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references private.competitions(id) on delete cascade,
  submission_id uuid not null references private.submissions(id) on delete cascade,
  listening_id uuid not null default gen_random_uuid(),
  label_number integer not null,
  label text not null,
  created_at timestamptz not null default now(),
  unique(listening_id),
  unique(competition_id,submission_id),
  unique(competition_id,listening_id),
  unique(competition_id,label_number),
  unique(competition_id,label)
);

create table private.batches (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references private.competitions(id) on delete cascade,
  batch_number smallint not null check(batch_number>0),
  day_number smallint not null default 1 check(day_number>0),
  scheduled_at timestamptz,
  released_at timestamptz,
  status private.batch_status not null default 'scheduled',
  shuffle_seed bytea,
  created_at timestamptz not null default now(),
  unique(competition_id,batch_number)
);

create table private.batch_entries (
  batch_id uuid not null references private.batches(id) on delete cascade,
  listening_id uuid not null references private.listening_labels(listening_id) on delete cascade,
  display_order_seed integer not null,
  primary key(batch_id,listening_id),
  unique(batch_id,display_order_seed)
);

create table private.ratings (
  participant_id uuid not null references private.participants(id) on delete cascade,
  submission_id uuid not null references private.submissions(id) on delete cascade,
  batch_id uuid not null references private.batches(id) on delete cascade,
  score smallint not null check(score between 1 and 10),
  version bigint not null default 1 check(version>0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(participant_id,submission_id)
);

create table private.batch_finalizations (
  participant_id uuid not null references private.participants(id) on delete cascade,
  batch_id uuid not null references private.batches(id) on delete cascade,
  finalized_at timestamptz not null default now(),
  reopened_at timestamptz,
  primary key(participant_id,batch_id)
);

create table private.score_snapshots (
  competition_id uuid primary key references private.competitions(id) on delete cascade,
  algorithm_version integer not null,
  seed bytea not null,
  payload jsonb not null,
  scored_at timestamptz not null default now()
);

create table private.reveal_groups (
  competition_id uuid not null references private.competitions(id) on delete cascade,
  group_number smallint not null check(group_number>0),
  published_at timestamptz,
  primary key(competition_id,group_number)
);

create table private.reveal_events (
  id bigint generated always as identity primary key,
  competition_id uuid not null references private.competitions(id) on delete cascade,
  listening_id uuid not null references private.listening_labels(listening_id) on delete restrict,
  group_number smallint not null,
  published_at timestamptz not null default now(),
  unique(competition_id,listening_id)
);

create table private.media_jobs (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null unique references private.submissions(id) on delete cascade,
  state text not null check(state in ('queued','processing','complete','failed')),
  attempt_count smallint not null default 0,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table private.host_audit_log (
  id bigint generated always as identity primary key,
  competition_id uuid,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  event_type text not null,
  target_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Every private table denies all PostgREST/RLS access by default. Only vetted
-- functions in private expose safe DTOs; no table receives a participant policy.
do $$ declare table_name text; begin
  foreach table_name in array array['platform_config','competitions','participants','invites','submissions','listening_labels','batches','batch_entries','ratings','batch_finalizations','score_snapshots','reveal_groups','reveal_events','media_jobs','host_audit_log'] loop
    execute format('alter table private.%I enable row level security',table_name);
    execute format('alter table private.%I force row level security',table_name);
    execute format('revoke all on private.%I from public, anon, authenticated, ost_web_app',table_name);
  end loop;
end $$;
revoke all on all sequences in schema private from public, anon, authenticated, ost_web_app;

create or replace function private.is_platform_host()
returns boolean language sql stable security definer set search_path=''
as $$ select exists(select 1 from private.platform_config where singleton and host_user_id=auth.uid()) $$;
revoke all on function private.is_platform_host() from public, anon, authenticated;
grant execute on function private.is_platform_host() to ost_web_app;

create or replace function private.require_platform_host()
returns void language plpgsql stable security definer set search_path=''
as $$ begin
  if auth.uid() is null or not private.is_platform_host() then
    raise exception 'Resource unavailable' using errcode='P0002';
  end if;
end $$;
revoke all on function private.require_platform_host() from public, anon, authenticated;
grant execute on function private.require_platform_host() to ost_web_app;

create or replace function private.audit_is_append_only()
returns trigger language plpgsql security definer set search_path=''
as $$ begin raise exception 'Audit records are append-only' using errcode='42501'; end $$;
create trigger host_audit_append_only before update or delete on private.host_audit_log
for each row execute function private.audit_is_append_only();
revoke all on function private.audit_is_append_only() from public, anon, authenticated, ost_web_app;

create or replace function private.frozen_snapshot_is_immutable()
returns trigger language plpgsql security definer set search_path=''
as $$ begin raise exception 'A scored snapshot cannot be modified' using errcode='42501'; end $$;
create trigger scored_snapshot_no_update before update on private.score_snapshots
for each row execute function private.frozen_snapshot_is_immutable();
revoke all on function private.frozen_snapshot_is_immutable() from public, anon, authenticated, ost_web_app;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('competition-media','competition-media',false,524288000,array['video/mp4','video/quicktime','video/webm','video/x-matroska','audio/mp4','audio/aac'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

commit;
