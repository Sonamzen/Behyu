-- =====================================================================
-- BEHYU update 5: click and collect points you manage in admin, in any dzongkhag
-- Run once: Supabase > SQL Editor > New query > paste > Run
-- (Already included in behyu-supabase-setup.sql for new projects.)
-- =====================================================================
-- (safe to run even if update 3 was skipped: the order function below also records shipping)
alter table public.orders add column if not exists shipping_fee integer not null default 0 check (shipping_fee >= 0);

create table if not exists public.pickup_points (
  id bigint generated always as identity primary key,
  dzongkhag text not null check (dzongkhag in ('Bumthang','Chhukha','Dagana','Gasa','Haa','Lhuentse','Mongar','Paro','Pemagatshel','Punakha','Samdrup Jongkhar','Samtse','Sarpang','Thimphu','Trashigang','Trashiyangtse','Trongsa','Tsirang','Wangdue Phodrang','Zhemgang')),
  name text not null check (length(trim(name)) > 0),
  address text not null check (length(trim(address)) > 0),
  notes text,                                          -- for example opening hours
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.pickup_points enable row level security;
drop policy if exists "see active pickup points" on public.pickup_points;
create policy "see active pickup points" on public.pickup_points for select using (active or public.is_admin());
drop policy if exists "admin adds pickup points" on public.pickup_points;
create policy "admin adds pickup points" on public.pickup_points for insert with check (public.is_admin());
drop policy if exists "admin edits pickup points" on public.pickup_points;
create policy "admin edits pickup points" on public.pickup_points for update using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin deletes pickup points" on public.pickup_points;
create policy "admin deletes pickup points" on public.pickup_points for delete using (public.is_admin());

grant select on public.pickup_points to anon, authenticated;
grant insert, update, delete on public.pickup_points to authenticated;

-- the order function now checks the pickup point (so it needs a new signature)
drop function if exists public.place_order(jsonb,text,text,text,text,text,text,text,text,text);

create or replace function public.place_order(
  p_items jsonb, p_name text, p_phone text, p_address text, p_town text,
  p_shipping text, p_pickup bigint, p_payment text, p_journal text, p_screenshot text
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_order bigint;
  v_total integer := 0;
  v_fee integer := 0;
  v_pickup text;
  it jsonb;
  p public.products;
  v_qty integer;
begin
  if v_uid is null then raise exception 'Please log in first'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your cart is empty';
  end if;
  if p_shipping = 'collect' then
    select name || ', ' || address into v_pickup
      from pickup_points where id = p_pickup and active and dzongkhag = p_town;
    if v_pickup is null then raise exception 'Please choose a pickup point in your dzongkhag'; end if;
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
          v_pickup, p_payment, nullif(p_journal,''), nullif(p_screenshot,''), 0)
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

revoke all on function public.place_order(jsonb,text,text,text,text,text,bigint,text,text,text) from public;
grant execute on function public.place_order(jsonb,text,text,text,text,text,bigint,text,text,text) to authenticated;
