-- =====================================================================
-- BEHYU shop: database setup for Supabase
-- Run ONCE: Supabase dashboard > SQL Editor > New query > paste all > Run
-- =====================================================================

-- ---------- TABLES ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  avatar_url text,
  role text not null default 'customer' check (role in ('customer','admin')),
  created_at timestamptz not null default now()
);

create table public.products (
  id bigint generated always as identity primary key,
  category text not null check (category in ('Women','Men','Bags','Lens','Accessories','Makeup')),
  name text not null check (length(trim(name)) > 0),
  price integer not null check (price >= 0),          -- in Nu.
  stock integer not null default 0 check (stock >= 0),
  sizes text[] not null default '{S,M,L}',
  image_path text,                                     -- file name inside the product-images bucket
  image_paths text[] not null default '{}',            -- all photos, first one is the cover
  active boolean not null default true,                -- false = hidden from the shop
  created_at timestamptz not null default now()
);

create table public.orders (
  id bigint generated always as identity (start with 1001) primary key,
  user_id uuid not null references public.profiles(id),
  customer_name text not null,
  phone text not null,
  address text not null,
  town text not null,
  shipping_method text not null check (shipping_method in ('post','taxi','collect')),
  pickup_point text,
  payment_method text not null check (payment_method in ('mbob','cod')),
  journal_number text,
  screenshot_path text,                                -- file inside the payment-screenshots bucket
  total integer not null check (total >= 0),            -- items + shipping
  shipping_fee integer not null default 0 check (shipping_fee >= 0),
  -- placed = waiting for you | approved = payment OK | rejected | shipped | delivered = customer got it | completed = all items reviewed
  status text not null default 'placed' check (status in ('placed','approved','rejected','shipped','delivered','completed')),
  tracking_info text,                                  -- driver number or post office tracking number
  created_at timestamptz not null default now()
);

create table public.order_items (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id) on delete cascade,
  product_id bigint references public.products(id) on delete set null,
  product_name text not null,                          -- copied at order time
  unit_price integer not null,                         -- copied at order time
  size text,
  qty integer not null check (qty > 0),
  reviewed boolean not null default false
);

create table public.reviews (
  id bigint generated always as identity primary key,
  product_id bigint not null references public.products(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  order_item_id bigint not null unique references public.order_items(id),
  reviewer_name text not null,
  rating integer not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

create table public.wishlist (
  user_id uuid not null references public.profiles(id) on delete cascade,
  product_id bigint not null references public.products(id) on delete cascade,
  primary key (user_id, product_id)
);

-- ---------- HELPERS ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- every new account gets a customer profile (role can never come from the sign-up form)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''));
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- ORDER / REVIEW FUNCTIONS (the only way customers write these) ----------
-- Prices and stock are checked on the server, so a customer cannot change the total.
create or replace function public.place_order(
  p_items jsonb, p_name text, p_phone text, p_address text, p_town text,
  p_shipping text, p_pickup text, p_payment text, p_journal text, p_screenshot text
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_order bigint;
  v_total integer := 0;
  v_fee integer := 0;
  it jsonb;
  p public.products;
  v_qty integer;
begin
  if v_uid is null then raise exception 'Please log in first'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your cart is empty';
  end if;
  if p_shipping = 'collect' and coalesce(p_town,'') !~* 'thimphu' then
    raise exception 'Click and collect is only in Thimphu';
  end if;
  if p_payment = 'mbob' then
    if coalesce(p_journal,'') = '' or coalesce(p_screenshot,'') = '' then
      raise exception 'Payment screenshot and journal number are required';
    end if;
    if p_screenshot not like v_uid::text || '/%' then
      raise exception 'Invalid screenshot file';
    end if;
  end if;

  insert into orders (user_id, customer_name, phone, address, town, shipping_method,
                      pickup_point, payment_method, journal_number, screenshot_path, total)
  values (v_uid, p_name, p_phone, p_address, p_town, p_shipping,
          p_pickup, p_payment, nullif(p_journal,''), nullif(p_screenshot,''), 0)
  returning id into v_order;

  for it in select value from jsonb_array_elements(p_items) loop
    v_qty := (it->>'qty')::integer;
    if v_qty is null or v_qty < 1 then raise exception 'Invalid quantity'; end if;
    select * into p from products where id = (it->>'product_id')::bigint and active for update;
    if not found then raise exception 'An item is no longer available'; end if;
    if p.stock < v_qty then raise exception 'Not enough stock for %', p.name; end if;
    update products set stock = stock - v_qty where id = p.id;
    insert into order_items (order_id, product_id, product_name, unit_price, size, qty)
    values (v_order, p.id, p.name, p.price, it->>'size', v_qty);
    v_total := v_total + p.price * v_qty;
  end loop;

  -- SHIPPING: free for click and collect, free in Thimphu, free if the items come to Nu.5000 or more,
  -- otherwise Nu.100. (If you change these numbers, change SHIPPING in index.html too.)
  v_fee := case when p_shipping = 'collect' then 0
                when lower(trim(p_town)) = 'thimphu' then 0
                when v_total >= 5000 then 0
                else 100 end;
  update orders set total = v_total + v_fee, shipping_fee = v_fee where id = v_order;
  return v_order;
end $$;

-- customer taps "Order received"
create or replace function public.mark_received(p_order bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update orders set status = 'delivered'
  where id = p_order and user_id = auth.uid() and status = 'shipped';
  if not found then raise exception 'This order can''t be marked as received'; end if;
end $$;

-- customer reviews an item after receiving it
create or replace function public.add_review(p_item bigint, p_rating integer, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
declare
  it order_items;
  o orders;
  v_name text;
begin
  select * into it from order_items where id = p_item;
  if not found then raise exception 'Item not found'; end if;
  select * into o from orders
   where id = it.order_id and user_id = auth.uid() and status in ('delivered','completed');
  if not found then raise exception 'You can review items after you receive them'; end if;
  if it.reviewed then raise exception 'You already reviewed this item'; end if;
  if it.product_id is null then raise exception 'This product is no longer in the shop'; end if;
  select full_name into v_name from profiles where id = auth.uid();
  insert into reviews (product_id, user_id, order_item_id, reviewer_name, rating, comment)
  values (it.product_id, auth.uid(), p_item, coalesce(nullif(v_name,''),'Customer'),
          p_rating, nullif(trim(p_comment),''));
  update order_items set reviewed = true where id = p_item;
  if not exists (select 1 from order_items where order_id = o.id and not reviewed) then
    update orders set status = 'completed' where id = o.id;
  end if;
end $$;

-- if you reject an order, its items go back into stock
create or replace function public.restore_stock_on_reject() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.status = 'rejected' and old.status <> 'rejected' then
    for r in select product_id, sum(qty) as q from order_items
             where order_id = new.id and product_id is not null group by product_id loop
      update products set stock = stock + r.q where id = r.product_id;
    end loop;
  end if;
  return new;
end $$;

create trigger orders_restock
  after update of status on public.orders
  for each row execute function public.restore_stock_on_reject();

revoke all on function public.place_order(jsonb,text,text,text,text,text,text,text,text,text) from public;
revoke all on function public.mark_received(bigint) from public;
revoke all on function public.add_review(bigint,integer,text) from public;
grant execute on function public.place_order(jsonb,text,text,text,text,text,text,text,text,text) to authenticated;
grant execute on function public.mark_received(bigint) to authenticated;
grant execute on function public.add_review(bigint,integer,text) to authenticated;

-- ---------- SECURITY RULES (row level security) ----------
alter table public.profiles    enable row level security;
alter table public.products    enable row level security;
alter table public.orders      enable row level security;
alter table public.order_items enable row level security;
alter table public.reviews     enable row level security;
alter table public.wishlist    enable row level security;

-- profiles: you see and edit your own; admins see everyone. Nobody can change a role from the website.
create policy "read own profile" on public.profiles for select
  using (id = auth.uid() or public.is_admin());
create policy "edit own profile" on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from anon, authenticated;
grant update (full_name, phone, avatar_url) on public.profiles to authenticated;

-- products: everyone sees active ones; only admins add, edit, delete
create policy "see active products" on public.products for select
  using (active or public.is_admin());
create policy "admin adds products" on public.products for insert
  with check (public.is_admin());
create policy "admin edits products" on public.products for update
  using (public.is_admin()) with check (public.is_admin());
create policy "admin deletes products" on public.products for delete
  using (public.is_admin());

-- orders: customers see their own, admins see and update all (customers create orders only through place_order)
create policy "see own orders" on public.orders for select
  using (user_id = auth.uid() or public.is_admin());
create policy "admin updates orders" on public.orders for update
  using (public.is_admin()) with check (public.is_admin());

create policy "see own order items" on public.order_items for select
  using (public.is_admin() or exists (
    select 1 from public.orders o where o.id = order_items.order_id and o.user_id = auth.uid()));

-- reviews: public to read, created only through add_review
create policy "anyone reads reviews" on public.reviews for select using (true);
create policy "admin deletes reviews" on public.reviews for delete using (public.is_admin());

-- wishlist: only your own
create policy "own wishlist" on public.wishlist for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

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

-- ---------- FILE STORAGE ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('product-images',      'product-images',      true,  5242880, array['image/png','image/jpeg']),
  ('payment-screenshots', 'payment-screenshots', false, 5242880, array['image/png','image/jpeg']),
  ('avatars',             'avatars',             true,  5242880, array['image/png','image/jpeg'])
on conflict (id) do nothing;

create policy "anyone views product images" on storage.objects for select
  using (bucket_id = 'product-images');
create policy "admin manages product images" on storage.objects for all
  using (bucket_id = 'product-images' and public.is_admin())
  with check (bucket_id = 'product-images' and public.is_admin());

-- screenshots are private: saved in a folder named after the customer's id
create policy "customer uploads own screenshot" on storage.objects for insert to authenticated
  with check (bucket_id = 'payment-screenshots' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "customer or admin views screenshot" on storage.objects for select to authenticated
  using (bucket_id = 'payment-screenshots'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

create policy "anyone views avatars" on storage.objects for select
  using (bucket_id = 'avatars');
create policy "user manages own avatar" on storage.objects for all to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- FIRST OWNER ----------
create or replace function public.claim_first_admin() returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please log in first'; end if;
  perform pg_advisory_xact_lock(424242);           -- two people can't claim at the same moment
  if exists (select 1 from public.profiles where role = 'admin') then
    return false;                                  -- an owner already exists: nothing changes
  end if;
  update public.profiles set role = 'admin' where id = auth.uid();
  return true;
end $$;

revoke all on function public.claim_first_admin() from public;
grant execute on function public.claim_first_admin() to authenticated;

-- =====================================================================
-- DONE. Next: open admin.html and click Register. The FIRST account created
-- there becomes the shop owner (do this before you share your website link).
-- Later admins: have them register on the shop, then run this one line:
--
--   update public.profiles set role = 'admin'
--   where id = (select id from auth.users where email = 'their@email.com');
--
-- =====================================================================
