-- =====================================================================
--  ساختمان ۴۹ — اسکیمای دیتابیس Supabase
--  این فایل را در Supabase Dashboard → SQL Editor → New query اجرا کنید.
--  پروژه: axfjnhllvzesydwpmndw
-- =====================================================================

-- ----------------------------- profiles -----------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  role        text not null default 'member' check (role in ('admin','member')),
  unit_id     bigint,
  phone       text,
  created_at  timestamptz default now()
);

-- ----------------------------- units ---------------------------------
create table if not exists public.units (
  id          bigint generated always as identity primary key,
  number      text not null unique,        -- مثال: '101' ... '508'
  floor       int,
  area        numeric,                     -- متراژ (متر مربع)
  created_at  timestamptz default now()
);

-- ----------------------------- owners --------------------------------
create table if not exists public.owners (
  id           bigint generated always as identity primary key,
  unit_id      bigint references public.units(id) on delete set null,
  name         text not null,
  national_code text,
  phone        text,
  email        text,
  created_at   timestamptz default now()
);

-- ----------------------------- tenants -------------------------------
create table if not exists public.tenants (
  id          bigint generated always as identity primary key,
  unit_id     bigint references public.units(id) on delete set null,
  name        text not null,
  phone       text,
  email       text,
  lease_start date,
  lease_end   date,
  created_at  timestamptz default now()
);

-- ----------------------- expense_categories -------------------------
create table if not exists public.expense_categories (
  id    bigint generated always as identity primary key,
  name  text not null,
  type  text not null default 'general' check (type in ('monthly','construction','general'))
);

-- ----------------------------- expenses ------------------------------
create table if not exists public.expenses (
  id            bigint generated always as identity primary key,
  category_id   bigint references public.expense_categories(id) on delete set null,
  title         text not null,
  amount        bigint not null default 0,        -- ریال
  expense_date  date not null default current_date,
  jmonth        text,                              -- مثال: '1403/08'
  payment_type  text default 'bank' check (payment_type in ('cash','bank','card')),
  description   text,
  created_by    uuid references auth.users(id),
  created_at    timestamptz default now()
);

-- ------------------------------ charges ------------------------------
-- مبلغ شارژ تعیین‌شده برای هر واحد در هر ماه/نوع
create table if not exists public.charges (
  id          bigint generated always as identity primary key,
  unit_id     bigint references public.units(id) on delete cascade,
  jmonth      text not null,
  type        text not null default 'monthly' check (type in ('monthly','construction')),
  amount_due  bigint not null default 0,           -- ریال
  created_by  uuid references auth.users(id),
  created_at  timestamptz default now(),
  unique (unit_id, jmonth, type)
);

-- ----------------------------- payments ------------------------------
create table if not exists public.payments (
  id            bigint generated always as identity primary key,
  unit_id       bigint references public.units(id) on delete cascade,
  amount        bigint not null default 0,         -- ریال
  type          text not null default 'monthly' check (type in ('monthly','construction')),
  jmonth        text,                              -- ماه شارژ مربوطه
  payment_date  date not null default current_date,
  method        text default 'card' check (method in ('cash','bank','card')),
  receipt_url   text,
  note          text,
  created_by    uuid references auth.users(id),
  created_at    timestamptz default now()
);

-- -------------------------- building_settings -----------------------
create table if not exists public.building_settings (
  id            int primary key default 1,
  building_name text default 'ساختمان ۴۹',
  bank_name     text,
  bank_account  text,
  card_number   text,
  sheba         text,
  whatsapp_link text,
  manager_name  text,
  manager_phone text,
  address       text
);
insert into public.building_settings (id) values (1) on conflict (id) do nothing;

-- ----------------------------- messages ------------------------------
create table if not exists public.messages (
  id          bigint generated always as identity primary key,
  from_user   uuid references auth.users(id) on delete set null,
  from_name   text,
  subject     text,
  body        text,
  is_read     boolean default false,
  created_at  timestamptz default now()
);

-- --------------------------- announcements --------------------------
create table if not exists public.announcements (
  id          bigint generated always as identity primary key,
  title       text not null,
  body        text,
  created_by  uuid references auth.users(id),
  created_at  timestamptz default now()
);

-- ------------------------ maintenance_requests ----------------------
create table if not exists public.maintenance_requests (
  id          bigint generated always as identity primary key,
  unit_id     bigint references public.units(id) on delete set null,
  title       text not null,
  description text,
  priority    text default 'normal' check (priority in ('low','normal','high')),
  status      text default 'open' check (status in ('open','in_progress','done')),
  created_by  uuid references auth.users(id),
  created_at  timestamptz default now()
);

-- ------------------------------- polls -------------------------------
create table if not exists public.polls (
  id          bigint generated always as identity primary key,
  question    text not null,
  options     jsonb not null default '[]',
  created_by  uuid references auth.users(id),
  created_at  timestamptz default now()
);
create table if not exists public.poll_votes (
  id           bigint generated always as identity primary key,
  poll_id      bigint references public.polls(id) on delete cascade,
  option_index int,
  user_id      uuid references auth.users(id) on delete cascade,
  created_at   timestamptz default now(),
  unique (poll_id, user_id)
);

-- ----------------------------- documents -----------------------------
create table if not exists public.documents (
  id          bigint generated always as identity primary key,
  title       text not null,
  category    text,
  file_url    text,
  created_by  uuid references auth.users(id),
  created_at  timestamptz default now()
);

-- =====================================================================
--  Row Level Security
-- =====================================================================
alter table public.profiles              enable row level security;
alter table public.units                 enable row level security;
alter table public.owners                enable row level security;
alter table public.tenants               enable row level security;
alter table public.expense_categories    enable row level security;
alter table public.expenses              enable row level security;
alter table public.charges               enable row level security;
alter table public.payments              enable row level security;
alter table public.building_settings     enable row level security;
alter table public.messages              enable row level security;
alter table public.announcements         enable row level security;
alter table public.maintenance_requests  enable row level security;
alter table public.polls                 enable row level security;
alter table public.poll_votes            enable row level security;
alter table public.documents             enable row level security;

-- کمک‌تابع: آیا کاربر جاری ادمین است؟
create or replace function public.is_admin()
returns boolean language sql security definer stable as $$
  select exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin');
$$;

-- ---- profiles ----
create policy "read own or admin" on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy "update own profile" on public.profiles for update using (id = auth.uid() or public.is_admin());

-- ---- عمومی: کاربران واردشده همه‌ی داده‌ها را می‌بینند ----
create policy "auth read units"        on public.units                 for select using (auth.role() = 'authenticated');
create policy "auth read owners"       on public.owners                for select using (auth.role() = 'authenticated');
create policy "auth read tenants"      on public.tenants               for select using (auth.role() = 'authenticated');
create policy "auth read categories"   on public.expense_categories    for select using (auth.role() = 'authenticated');
create policy "auth read expenses"     on public.expenses              for select using (auth.role() = 'authenticated');
create policy "auth read charges"      on public.charges               for select using (auth.role() = 'authenticated');
create policy "auth read payments"     on public.payments              for select using (auth.role() = 'authenticated');
create policy "auth read settings"     on public.building_settings     for select using (auth.role() = 'authenticated');
create policy "auth read announcements" on public.announcements        for select using (auth.role() = 'authenticated');
create policy "auth read maintenance"  on public.maintenance_requests  for select using (auth.role() = 'authenticated');
create policy "auth read polls"        on public.polls                 for select using (auth.role() = 'authenticated');
create policy "auth read votes"        on public.poll_votes            for select using (auth.role() = 'authenticated');
create policy "auth read documents"    on public.documents             for select using (auth.role() = 'authenticated');
create policy "auth read messages"     on public.messages              for select using (auth.role() = 'authenticated');

-- ---- نوشتن: فقط ادمین (مدیر) ----
create policy "admin write units"        on public.units                 for all using (public.is_admin()) with check (public.is_admin());
create policy "admin write owners"       on public.owners                for all using (public.is_admin()) with check (public.is_admin());
create policy "admin write tenants"      on public.tenants               for all using (public.is_admin()) with check (public.is_admin());
create policy "admin write categories"   on public.expense_categories    for all using (public.is_admin()) with check (public.is_admin());
create policy "admin write expenses"     on public.expenses              for all using (public.is_admin()) with check (public.is_admin());
create policy "admin write charges"      on public.charges               for all using (public.is_admin()) with check (public.is_admin());
create policy "admin write payments"     on public.payments              for all using (public.is_admin()) with check (public.is_admin());
create policy "admin write settings"     on public.building_settings     for all using (public.is_admin()) with check (public.is_admin());
create policy "admin write announcements" on public.announcements        for all using (public.is_admin()) with check (public.is_admin());
create policy "admin write maintenance"  on public.maintenance_requests  for all using (public.is_admin()) with check (public.is_admin());
create policy "admin write polls"        on public.polls                 for all using (public.is_admin()) with check (public.is_admin());
create policy "admin write documents"    on public.documents             for all using (public.is_admin()) with check (public.is_admin());

-- ---- اعضا می‌توانند پیام به مدیر بفرستند ----
create policy "member insert messages" on public.messages for insert with check (auth.role() = 'authenticated');
create policy "admin upd messages"     on public.messages for update using (public.is_admin()) with check (public.is_admin());

-- ---- اعضا می‌توانند درخواست تعمیرات ثبت کنند ----
create policy "member insert maint"    on public.maintenance_requests for insert with check (auth.role() = 'authenticated');
create policy "owner upd maint"        on public.maintenance_requests for update using (public.is_admin() or created_by = auth.uid()) with check (public.is_admin() or created_by = auth.uid());

-- ---- اعضا می‌توانند در نظرسنجی رأی دهند ----
create policy "member vote"            on public.poll_votes for insert with check (auth.role() = 'authenticated');
create policy "member del own vote"    on public.poll_votes for delete using (user_id = auth.uid());

-- =====================================================================
--  ساخت خودکار پروفایل هنگام ثبت‌نام
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email), 'member')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- =====================================================================
--  داده‌های اولیه (seed)
-- =====================================================================
insert into public.expense_categories (name, type) values
  ('شارژ ماهانه','monthly'),
  ('شارژ عمرانی','construction'),
  ('نظافت','general'),
  ('آسانسور','general'),
  ('آب','general'),
  ('برق','general'),
  ('گاز','general'),
  ('شیمیایی و پسماند','general'),
  ('نگهبانی','general'),
  ('تعمیر و نگهداری','general'),
  ('عمرانی','construction'),
  ('متفرقه','general')
on conflict do nothing;

-- ۳۶ واحد: طبقه ۱ تا ۳ و ۵ هشت واحد، طبقه ۴ چهار واحد (۱۱۱... تا ۵۰۸)
-- شماره‌ها: 101-108, 201-208, 301-308, 401-404, 501-508
insert into public.units (number, floor, area)
select v, v/100, 85
from (values
  (101),(102),(103),(104),(105),(106),(107),(108),
  (201),(202),(203),(204),(205),(206),(207),(208),
  (301),(302),(303),(304),(305),(306),(307),(308),
  (401),(402),(403),(404),
  (501),(502),(503),(504),(505),(506),(507),(508)
) as t(v)
on conflict (number) do nothing;
