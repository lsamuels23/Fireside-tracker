-- Fireside Tracker: move tasks from the single app_state 'fs_tasks' blob
-- into one row per task. Run once in the Supabase SQL editor.
--
-- Safe to run before the app is changed: it only reads app_state, never
-- modifies it, and the current app keeps using the blob until it's updated.

begin;

-- 1. One row per task ---------------------------------------------------------

create table if not exists public.tasks (
  id           bigint primary key,              -- same ids the app already uses
  jobs         text[]      not null default '{}',
  type         text        not null default '',
  trade        text        not null default '',
  location     text        not null default '',
  room         text        not null default '',
  task         text        not null default '',
  contact      text        not null default '',
  due          date,
  status       text        not null default 'open'
               check (status in ('open', 'in-progress', 'completed')),
  started_at   timestamptz,
  completed_at timestamptz,
  added_at     timestamptz not null default now(),
  updated_at   timestamptz,                     -- the "Date updated" column; null until edited
  -- Deleting sets this instead of removing the row, so a device holding an
  -- old copy can't bring a deleted task back.
  deleted      boolean     not null default false
);

create index if not exists tasks_live_idx on public.tasks (added_at desc) where not deleted;

-- 2. Access: same as app_state today (anyone with the app's public key can
--    read, add and edit). No delete policy — the app only soft-deletes.

alter table public.tasks enable row level security;

-- Newer Supabase projects don't grant new tables to the API roles by default.
grant select, insert, update on public.tasks to anon, authenticated;

drop policy if exists "tasks read"   on public.tasks;
drop policy if exists "tasks insert" on public.tasks;
drop policy if exists "tasks update" on public.tasks;

create policy "tasks read"   on public.tasks for select to anon, authenticated using (true);
create policy "tasks insert" on public.tasks for insert to anon, authenticated with check (true);
create policy "tasks update" on public.tasks for update to anon, authenticated using (true) with check (true);

-- 3. Live updates, so every open device sees edits within seconds ------------

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'tasks'
  ) then
    alter publication supabase_realtime add table public.tasks;
  end if;
end $$;

-- 4. Copy the existing tasks over ---------------------------------------------
-- Re-running is harmless: tasks already copied are skipped.

insert into public.tasks
  (id, jobs, type, trade, location, room, task, contact, due,
   status, started_at, completed_at, added_at, updated_at)
select
  (t->>'id')::bigint,
  coalesce(array(select jsonb_array_elements_text(t->'jobs')), '{}'),
  coalesce(t->>'type', ''),
  coalesce(t->>'trade', ''),
  coalesce(t->>'location', ''),
  coalesce(t->>'room', ''),
  coalesce(t->>'task', ''),
  coalesce(t->>'contact', ''),
  nullif(t->>'due', '')::date,
  coalesce(t->>'status', 'open'),
  nullif(t->>'startedAt', '')::timestamptz,
  nullif(t->>'completedAt', '')::timestamptz,
  coalesce(nullif(t->>'added', '')::timestamptz, now()),
  nullif(t->>'updatedAt', '')::timestamptz
from public.app_state s,
     jsonb_array_elements(s.value::jsonb) as t
where s.key = 'fs_tasks'
on conflict (id) do nothing;

commit;

-- 5. Check: both numbers should match (226 as of 2026-10-02) -----------------

select
  (select jsonb_array_length(value::jsonb) from public.app_state where key = 'fs_tasks') as tasks_in_old_blob,
  (select count(*) from public.tasks)                                               as tasks_in_new_table;
