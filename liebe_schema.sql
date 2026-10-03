-- =====================================================================
-- LIEBE Laundry Engine — PostgreSQL / Supabase schema
-- Run in the Supabase SQL editor (or as a migration) in one go.
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
-- ENUMS
-- ---------------------------------------------------------------------
do $$ begin
  create type user_role as enum ('customer', 'admin', 'staff');
exception when duplicate_object then null; end $$;

do $$ begin
  create type order_status as enum
    ('pending', 'pickup_done', 'in_processing', 'ready_for_delivery', 'delivered', 'cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type order_source as enum ('app', 'walk_in', 'phone');
exception when duplicate_object then null; end $$;

do $$ begin
  create type payment_status as enum ('unpaid', 'partial', 'paid', 'refunded');
exception when duplicate_object then null; end $$;

do $$ begin
  create type payment_method as enum ('cash', 'upi', 'card', 'wallet', 'other');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- HELPERS
-- ---------------------------------------------------------------------
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- USERS (profile row per Supabase auth user; phone/OTP handled by Supabase Auth)
-- ---------------------------------------------------------------------
create table if not exists users (
  id            uuid primary key references auth.users(id) on delete cascade,
  phone         text not null unique check (phone ~ '^\+?[0-9]{10,15}$'),
  full_name     text,
  email         text,
  role          user_role not null default 'customer',
  address_line  text,
  city          text,
  pincode       text,
  fcm_token     text,                       -- push notification device token
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists idx_users_role  on users(role);
create index if not exists idx_users_name  on users using gin (to_tsvector('simple', coalesce(full_name, '')));
create trigger trg_users_updated before update on users
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- CATEGORIES (Dry Cleaning, Wash & Fold, Steam Ironing, Sofa Cleaning, ...)
-- ---------------------------------------------------------------------
create table if not exists categories (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique,
  slug          text not null unique,
  description   text,
  icon_url      text,
  sort_order    int  not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists idx_categories_active_sort on categories(is_active, sort_order);
create trigger trg_categories_updated before update on categories
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- SERVICES (priced items inside a category, e.g. Shirt @ ₹80 under Dry Cleaning)
-- ---------------------------------------------------------------------
create table if not exists services (
  id            uuid primary key default gen_random_uuid(),
  category_id   uuid not null references categories(id) on delete restrict,
  name          text not null,
  unit          text not null default 'piece',      -- piece | kg | seat | sqft
  price         numeric(10,2) not null check (price >= 0),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (category_id, name)
);
create index if not exists idx_services_category on services(category_id) where is_active;
create trigger trg_services_updated before update on services
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- ORDERS
-- ---------------------------------------------------------------------
create sequence if not exists order_number_seq start 1001;

create table if not exists orders (
  id               uuid primary key default gen_random_uuid(),
  order_number     text not null unique
                   default ('LB-' || nextval('order_number_seq')),
  customer_id      uuid references users(id) on delete set null,
  customer_name    text,                              -- snapshot for walk-ins
  customer_phone   text,
  source           order_source not null default 'app',
  status           order_status not null default 'pending',
  payment_status   payment_status not null default 'unpaid',
  payment_method   payment_method,
  pickup_address   text,
  pickup_slot      timestamptz,
  delivery_slot    timestamptz,
  subtotal         numeric(12,2) not null default 0 check (subtotal >= 0),
  discount         numeric(12,2) not null default 0 check (discount >= 0),
  tax              numeric(12,2) not null default 0 check (tax >= 0),
  total_amount     numeric(12,2) not null default 0 check (total_amount >= 0),
  notes            text,
  created_by       uuid references users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (customer_id is not null or customer_phone is not null)
);
create index if not exists idx_orders_customer      on orders(customer_id, created_at desc);
create index if not exists idx_orders_status        on orders(status, created_at desc);
create index if not exists idx_orders_phone         on orders(customer_phone);
create index if not exists idx_orders_created       on orders(created_at desc);
create trigger trg_orders_updated before update on orders
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- ORDER ITEMS (price/name snapshotted so later price edits never alter history)
-- ---------------------------------------------------------------------
create table if not exists order_items (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references orders(id) on delete cascade,
  service_id    uuid references services(id) on delete set null,
  item_name     text not null,
  category_name text not null,
  quantity      int  not null check (quantity > 0),
  unit_price    numeric(10,2) not null check (unit_price >= 0),
  line_total    numeric(12,2) generated always as (quantity * unit_price) stored,
  created_at    timestamptz not null default now()
);
create index if not exists idx_order_items_order   on order_items(order_id);
create index if not exists idx_order_items_service on order_items(service_id);

-- ---------------------------------------------------------------------
-- ORDER STATUS HISTORY (drives the live tracker timeline)
-- ---------------------------------------------------------------------
create table if not exists order_status_history (
  id          bigint generated always as identity primary key,
  order_id    uuid not null references orders(id) on delete cascade,
  status      order_status not null,
  changed_by  uuid references users(id) on delete set null,
  note        text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_status_history_order on order_status_history(order_id, created_at);

-- ---------------------------------------------------------------------
-- INVOICES
-- ---------------------------------------------------------------------
create sequence if not exists invoice_number_seq start 1;

create table if not exists invoices (
  id              uuid primary key default gen_random_uuid(),
  invoice_number  text not null unique,
  order_id        uuid not null unique references orders(id) on delete cascade,
  subtotal        numeric(12,2) not null,
  discount        numeric(12,2) not null default 0,
  tax             numeric(12,2) not null default 0,
  total_amount    numeric(12,2) not null,
  pdf_url         text,
  issued_at       timestamptz not null default now()
);
create index if not exists idx_invoices_issued on invoices(issued_at desc);

-- ---------------------------------------------------------------------
-- PAYMENTS (transaction history for CRM)
-- ---------------------------------------------------------------------
create table if not exists payments (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references orders(id) on delete cascade,
  amount      numeric(12,2) not null check (amount > 0),
  method      payment_method not null,
  reference   text,
  paid_at     timestamptz not null default now(),
  created_by  uuid references users(id) on delete set null
);
create index if not exists idx_payments_order on payments(order_id);

-- ---------------------------------------------------------------------
-- APP CONFIG (single-row-per-key branding, banners, metadata)
-- ---------------------------------------------------------------------
create table if not exists app_config (
  key         text primary key,
  value       jsonb not null,
  updated_by  uuid references users(id) on delete set null,
  updated_at  timestamptz not null default now()
);

create table if not exists banners (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  image_url   text not null,
  link_url    text,
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists idx_banners_active on banners(is_active, sort_order);

insert into app_config (key, value) values
  ('branding', '{"app_name":"LIEBE Laundry","primary_color":"#6D28D9","logo_url":null,"support_phone":null}'::jsonb),
  ('metadata', '{"currency":"INR","currency_symbol":"₹","tax_percent":0,"min_app_version":"1.0.0"}'::jsonb)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- BUSINESS LOGIC
-- ---------------------------------------------------------------------

-- Recalculate order totals whenever items change.
create or replace function recalc_order_totals(p_order_id uuid)
returns void language plpgsql as $$
declare
  v_subtotal numeric(12,2);
  v_discount numeric(12,2);
  v_tax_pct  numeric;
begin
  select coalesce(sum(line_total), 0) into v_subtotal
  from order_items where order_id = p_order_id;

  select discount into v_discount from orders where id = p_order_id;

  select coalesce((value->>'tax_percent')::numeric, 0) into v_tax_pct
  from app_config where key = 'metadata';

  update orders
  set subtotal     = v_subtotal,
      tax          = round(greatest(v_subtotal - v_discount, 0) * coalesce(v_tax_pct, 0) / 100, 2),
      total_amount = greatest(v_subtotal - v_discount, 0)
                     + round(greatest(v_subtotal - v_discount, 0) * coalesce(v_tax_pct, 0) / 100, 2)
  where id = p_order_id;
end $$;

create or replace function trg_order_items_recalc()
returns trigger language plpgsql as $$
begin
  perform recalc_order_totals(coalesce(new.order_id, old.order_id));
  return null;
end $$;

create trigger trg_order_items_totals
  after insert or update or delete on order_items
  for each row execute function trg_order_items_recalc();

-- Log every status change (including the initial one) for the live tracker.
create or replace function trg_order_status_log()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into order_status_history(order_id, status, changed_by)
    values (new.id, new.status, auth.uid());
  end if;
  return new;
end $$;

create trigger trg_orders_status_log
  after insert or update of status on orders
  for each row execute function trg_order_status_log();

-- Enforce forward-only status flow (cancel allowed until delivered).
create or replace function trg_order_status_guard()
returns trigger language plpgsql as $$
declare
  rank_old int; rank_new int;
begin
  if new.status = old.status then return new; end if;
  if old.status in ('delivered', 'cancelled') then
    raise exception 'Order % is already %', old.order_number, old.status;
  end if;
  if new.status = 'cancelled' then return new; end if;

  rank_old := array_position(
    array['pending','pickup_done','in_processing','ready_for_delivery','delivered']::text[], old.status::text);
  rank_new := array_position(
    array['pending','pickup_done','in_processing','ready_for_delivery','delivered']::text[], new.status::text);

  if rank_new <> rank_old + 1 then
    raise exception 'Invalid status transition: % -> %', old.status, new.status;
  end if;
  return new;
end $$;

create trigger trg_orders_status_guard
  before update of status on orders
  for each row execute function trg_order_status_guard();

-- Automated invoice generator: idempotent, returns existing invoice if present.
create or replace function generate_invoice(p_order_id uuid)
returns invoices language plpgsql security definer as $$
declare
  v_order   orders;
  v_invoice invoices;
begin
  select * into v_invoice from invoices where order_id = p_order_id;
  if found then return v_invoice; end if;

  select * into v_order from orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;
  if not exists (select 1 from order_items where order_id = p_order_id) then
    raise exception 'Order % has no items', v_order.order_number;
  end if;

  insert into invoices(invoice_number, order_id, subtotal, discount, tax, total_amount)
  values (
    'INV-' || to_char(now(), 'YYYYMM') || '-' || lpad(nextval('invoice_number_seq')::text, 5, '0'),
    v_order.id, v_order.subtotal, v_order.discount, v_order.tax, v_order.total_amount
  )
  returning * into v_invoice;

  return v_invoice;
end $$;

-- Atomic order creation: header + items in one transaction.
-- p_items: [{"service_id":"<uuid>","quantity":2}, ...]
create or replace function create_order_with_items(
  p_customer_id    uuid,
  p_customer_name  text,
  p_customer_phone text,
  p_source         order_source,
  p_pickup_address text,
  p_pickup_slot    timestamptz,
  p_discount       numeric,
  p_notes          text,
  p_items          jsonb,
  p_created_by     uuid
) returns orders language plpgsql security definer as $$
declare
  v_order orders;
  v_item  jsonb;
  v_svc   record;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one item is required';
  end if;

  insert into orders(customer_id, customer_name, customer_phone, source,
                     pickup_address, pickup_slot, discount, notes, created_by)
  values (p_customer_id, p_customer_name, p_customer_phone, p_source,
          p_pickup_address, p_pickup_slot, coalesce(p_discount, 0), p_notes, p_created_by)
  returning * into v_order;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select s.id, s.name, s.price, c.name as category_name
      into v_svc
      from services s join categories c on c.id = s.category_id
     where s.id = (v_item->>'service_id')::uuid and s.is_active and c.is_active;

    if not found then
      raise exception 'Service % not found or inactive', v_item->>'service_id';
    end if;

    insert into order_items(order_id, service_id, item_name, category_name, quantity, unit_price)
    values (v_order.id, v_svc.id, v_svc.name, v_svc.category_name,
            (v_item->>'quantity')::int, v_svc.price);
  end loop;

  select * into v_order from orders where id = v_order.id;
  return v_order;
end $$;

-- ---------------------------------------------------------------------
-- CRM VIEW: customer lifetime stats
-- ---------------------------------------------------------------------
create or replace view customer_summary as
select
  u.id, u.full_name, u.phone, u.created_at,
  count(o.id)                                         as total_orders,
  coalesce(sum(o.total_amount) filter (where o.status <> 'cancelled'), 0) as lifetime_value,
  max(o.created_at)                                   as last_order_at
from users u
left join orders o on o.customer_id = u.id
where u.role = 'customer'
group by u.id;

-- ---------------------------------------------------------------------
-- ROW LEVEL SECURITY
-- (Express uses the service-role key and bypasses RLS; these policies protect
--  direct Supabase access from the mobile app, e.g. realtime subscriptions.)
-- ---------------------------------------------------------------------
create or replace function is_staff()
returns boolean language sql stable security definer as $$
  select exists (select 1 from users where id = auth.uid() and role in ('admin','staff'));
$$;

alter table users                 enable row level security;
alter table categories            enable row level security;
alter table services              enable row level security;
alter table orders                enable row level security;
alter table order_items           enable row level security;
alter table order_status_history  enable row level security;
alter table invoices              enable row level security;
alter table payments              enable row level security;
alter table app_config            enable row level security;
alter table banners               enable row level security;

create policy users_self_read   on users for select using (id = auth.uid() or is_staff());
create policy users_self_update on users for update using (id = auth.uid() or is_staff());

create policy categories_read   on categories for select using (is_active or is_staff());
create policy categories_write  on categories for all using (is_staff()) with check (is_staff());
create policy services_read     on services   for select using (is_active or is_staff());
create policy services_write    on services   for all using (is_staff()) with check (is_staff());

create policy orders_read   on orders for select using (customer_id = auth.uid() or is_staff());
create policy orders_write  on orders for all    using (is_staff()) with check (is_staff());

create policy items_read on order_items for select using (
  is_staff() or exists (select 1 from orders o where o.id = order_id and o.customer_id = auth.uid()));
create policy items_write on order_items for all using (is_staff()) with check (is_staff());

create policy history_read on order_status_history for select using (
  is_staff() or exists (select 1 from orders o where o.id = order_id and o.customer_id = auth.uid()));

create policy invoices_read on invoices for select using (
  is_staff() or exists (select 1 from orders o where o.id = order_id and o.customer_id = auth.uid()));
create policy invoices_write on invoices for all using (is_staff()) with check (is_staff());

create policy payments_read on payments for select using (
  is_staff() or exists (select 1 from orders o where o.id = order_id and o.customer_id = auth.uid()));
create policy payments_write on payments for all using (is_staff()) with check (is_staff());

create policy config_read   on app_config for select using (true);
create policy config_write  on app_config for all using (is_staff()) with check (is_staff());
create policy banners_read  on banners    for select using (is_active or is_staff());
create policy banners_write on banners    for all using (is_staff()) with check (is_staff());

-- ---------------------------------------------------------------------
-- REALTIME (order tracker + status history)
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table orders;
alter publication supabase_realtime add table order_status_history;

-- ---------------------------------------------------------------------
-- SEED DATA
-- ---------------------------------------------------------------------
insert into categories (name, slug, sort_order) values
  ('Dry Cleaning',  'dry-cleaning',  1),
  ('Wash & Fold',   'wash-and-fold', 2),
  ('Steam Ironing', 'steam-ironing', 3),
  ('Sofa Cleaning', 'sofa-cleaning', 4)
on conflict (name) do nothing;

insert into services (category_id, name, unit, price)
select c.id, v.name, v.unit, v.price
from (values
  ('dry-cleaning',  'Shirt',          'piece', 80),
  ('dry-cleaning',  'Jeans',          'piece', 50),
  ('dry-cleaning',  'Suit (2 pc)',    'piece', 350),
  ('dry-cleaning',  'Saree',          'piece', 250),
  ('wash-and-fold', 'Mixed Laundry',  'kg',    90),
  ('steam-ironing', 'Shirt / T-Shirt','piece', 15),
  ('steam-ironing', 'Trousers',       'piece', 20),
  ('sofa-cleaning', 'Sofa Seat',      'seat',  400)
) as v(slug, name, unit, price)
join categories c on c.slug = v.slug
on conflict (category_id, name) do nothing;
