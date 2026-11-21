-- =====================================================================
-- BEHYU update 2: fixes "permission denied for table products" (and the same
-- problem for orders, wishlist, etc.)
-- Run once: Supabase > SQL Editor > New query > paste > Run
-- (Already included in behyu-supabase-setup.sql for new projects.)
-- =====================================================================
-- ---------- TABLE PERMISSIONS ----------
-- Newer Supabase projects don't give the website access to new tables automatically.
-- These lines do it. The security rules (row level security) still decide who can do what.
grant usage on schema public to anon, authenticated;
grant select on public.products, public.reviews to anon, authenticated;
grant select on public.profiles, public.orders, public.order_items, public.wishlist to authenticated;
grant update (full_name, phone, avatar_url) on public.profiles to authenticated;
grant insert, update, delete on public.products to authenticated;
grant update on public.orders to authenticated;
grant delete on public.reviews to authenticated;
grant insert, delete on public.wishlist to authenticated;
grant execute on function public.is_admin() to anon, authenticated;
-- ---------- END TABLE PERMISSIONS ----------
