-- Fireside Tracker: add Subcontractor and Notes fields to each task.
-- Run once in the Supabase SQL editor. Safe to re-run.
--
-- The app leaves each field out of saves until its column exists, so saving
-- keeps working either way, but Subcontractor and Notes typed on tasks are only
-- stored once this has been run.

alter table public.tasks
  add column if not exists subcontractor text not null default '',
  add column if not exists notes         text not null default '';

-- make the API pick up the new columns right away
notify pgrst, 'reload schema';
