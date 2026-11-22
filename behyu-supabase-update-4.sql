-- =====================================================================
-- BEHYU update 4: several photos per product
-- Run once: Supabase > SQL Editor > New query > paste > Run
-- (Already included in behyu-supabase-setup.sql for new projects.)
-- =====================================================================
alter table public.products add column if not exists image_paths text[] not null default '{}';

-- products that already have one photo keep it as their first photo
update public.products set image_paths = array[image_path]
where image_path is not null and image_paths = '{}';
