-- Store artwork bytes separately from the revisioned JSON state document.
-- Every user gets an isolated folder in the private bucket.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('osttracker-covers', 'osttracker-covers', false, 5242880, array['image/jpeg'])
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Read own OSTTracker covers" on storage.objects;
create policy "Read own OSTTracker covers"
    on storage.objects for select to authenticated
    using (bucket_id = 'osttracker-covers' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "Upload own OSTTracker covers" on storage.objects;
create policy "Upload own OSTTracker covers"
    on storage.objects for insert to authenticated
    with check (bucket_id = 'osttracker-covers' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "Update own OSTTracker covers" on storage.objects;
create policy "Update own OSTTracker covers"
    on storage.objects for update to authenticated
    using (bucket_id = 'osttracker-covers' and (storage.foldername(name))[1] = (select auth.uid())::text)
    with check (bucket_id = 'osttracker-covers' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "Delete own OSTTracker covers" on storage.objects;
create policy "Delete own OSTTracker covers"
    on storage.objects for delete to authenticated
    using (bucket_id = 'osttracker-covers' and (storage.foldername(name))[1] = (select auth.uid())::text);
