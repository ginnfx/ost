-- Private, versioned sync document for one user's OSTTracker data.
-- Clients must authenticate as the same Supabase user on each device.
create table if not exists public.osttracker_state (
    owner_id uuid primary key references auth.users (id) on delete cascade,
    revision bigint not null default 1 check (revision > 0),
    payload jsonb not null,
    updated_at timestamptz not null default now()
);

alter table public.osttracker_state enable row level security;
revoke all on public.osttracker_state from anon, authenticated;
grant select on public.osttracker_state to authenticated;

drop policy if exists "Read own OSTTracker state" on public.osttracker_state;
create policy "Read own OSTTracker state"
    on public.osttracker_state for select to authenticated
    using (owner_id = (select auth.uid()));

-- Compare-and-swap writes prevent a stale device from replacing a newer copy.
create or replace function public.save_osttracker_state(
    p_payload jsonb,
    p_expected_revision bigint default null
)
returns table (revision bigint, updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_owner uuid := auth.uid();
begin
    if v_owner is null then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
        raise exception 'Payload must be a JSON object' using errcode = '22023';
    end if;

    if p_expected_revision is null then
        insert into public.osttracker_state as current_state
            (owner_id, revision, payload, updated_at)
        values (v_owner, 1, p_payload, now())
        on conflict (owner_id) do nothing;
        if not found then
            raise exception 'Sync conflict: cloud state already exists' using errcode = '40001';
        end if;
    else
        update public.osttracker_state as current_state
           set revision = current_state.revision + 1,
               payload = p_payload,
               updated_at = now()
         where current_state.owner_id = v_owner
           and current_state.revision = p_expected_revision;
        if not found then
            raise exception 'Sync conflict: cloud state changed or does not exist' using errcode = '40001';
        end if;
    end if;

    return query
    select current_state.revision, current_state.updated_at
      from public.osttracker_state as current_state
     where current_state.owner_id = v_owner;
end;
$$;

revoke all on function public.save_osttracker_state(jsonb, bigint) from public, anon;
grant execute on function public.save_osttracker_state(jsonb, bigint) to authenticated;
