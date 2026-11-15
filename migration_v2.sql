-- =====================================================================
--  ساختمان ۴۹ — مهاجرت v2: حسابداری کامل + امنیت واحد‌محور
--  اجرا در: Supabase Dashboard → SQL Editor → کل فایل را Paste و Run کنید.
--  ویژگی‌ها: idempotent (هر بار بدون ارور) و additive (هیچ داده‌ای حذف نمی‌شود).
--
--  افزودنی‌ها:
--   • prior_debts        — بدهی اولیه هر واحد (ماهانه/عمرانی/طلب)
--   • construction_projects — پروژه‌های عمرانی با بودجه و وضعیت
--   • resident_units     — اتصال حساب ساکن به یک یا چند واحد (امنیت)
--   • audit_log          — سابقه تغییر/حذف تراکنش‌های مالی + دلیل
--   • expenses.fund / receipt_url / reference_no / project_id
--   • charges.project_id
--   • RLS واحد‌محور: ساکن فقط داده‌ی واحدهای متصل‌به‌خودش را می‌بیند.
-- =====================================================================

-- ---------------------------------------------------------------------
-- ۱) جداول جدید
-- ---------------------------------------------------------------------
create table if not exists public.prior_debts (
  id                  bigint generated always as identity primary key,
  unit_id             bigint references public.units(id) on delete cascade,
  monthly_initial     bigint not null default 0,   -- بدهی اولیه شارژ ماهانه (ریال)
  construction_initial bigint not null default 0,  -- بدهی اولیه عمرانی (ریال)
  credit_initial      bigint not null default 0,   -- طلب اولیه واحد (ریال)
  as_of_date          date not null default current_date,
  note                text,
  created_by          uuid references auth.users(id),
  created_at          timestamptz default now()
);

create table if not exists public.construction_projects (
  id              bigint generated always as identity primary key,
  name            text not null,
  description     text,
  budget_approved bigint not null default 0,        -- بودجه مصوب (ریال)
  status          text not null default 'open' check (status in ('open','in_progress','done','cancelled')),
  start_date      date,
  end_date        date,
  created_by      uuid references auth.users(id),
  created_at      timestamptz default now()
);

create table if not exists public.resident_units (
  user_id uuid references auth.users(id) on delete cascade,
  unit_id bigint references public.units(id) on delete cascade,
  primary key (user_id, unit_id)
);

create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  table_name  text not null,
  record_id   bigint not null,
  action      text not null check (action in ('insert','update','delete')),
  reason      text,
  change_data jsonb,
  actor       uuid references auth.users(id),
  created_at  timestamptz default now()
);

-- ---------------------------------------------------------------------
-- ۲) ستون‌های جدید روی جداول موجود
-- ---------------------------------------------------------------------
alter table public.charges
  add column if not exists project_id bigint references public.construction_projects(id) on delete set null;

alter table public.expenses
  add column if not exists project_id   bigint references public.construction_projects(id) on delete set null,
  add column if not exists fund         text not null default 'monthly' check (fund in ('monthly','construction')),
  add column if not exists receipt_url  text,
  add column if not exists reference_no text;

-- backfill: هزینه‌های با دسته‌ی عمرانی → fund=construction
update public.expenses e set fund = 'construction'
  from public.expense_categories c
  where e.category_id = c.id and c.type = 'construction' and e.fund = 'monthly';

-- backfill: شارژ/پرداخت بدون type → 'monthly' (تا تفکیک ماهانه/عمرانی درست کار کند)
update public.charges  set type = 'monthly' where type is null or type = '';
update public.payments set type = 'monthly' where type is null or type = '';

-- ---------------------------------------------------------------------
-- ۳) RLS برای جداول جدید + کمک‌تابع واحدهای مجاز کاربر
-- ---------------------------------------------------------------------
alter table public.prior_debts            enable row level security;
alter table public.construction_projects  enable row level security;
alter table public.resident_units         enable row level security;
alter table public.audit_log              enable row level security;

-- آرایه‌ی واحدهای قابل‌دسترس کاربر جاری (ادمین=همه، ساکن=واحدهای متصل)
create or replace function public.my_unit_ids()
returns bigint[] language sql security definer stable set search_path = public as $$
  select case when public.is_admin()
    then array(select id from public.units)
    else coalesce(array(select unit_id from public.resident_units where user_id = auth.uid()), array[]::bigint[])
  end;
$$;
grant execute on function public.my_unit_ids() to authenticated;

-- ---------------------------------------------------------------------
-- ۴) سیاست‌های RLS (idempotent: drop + create)
--    اصل: ادمین دسترسی کامل؛ ساکن فقط داده‌ی واحدهای متصل‌به‌خودش.
-- ---------------------------------------------------------------------

-- charges: خواندن برای ادمین یا واحدهای خودش؛ نوشتن فقط ادمین
drop policy if exists "rls charges sel" on public.charges;
create policy "rls charges sel" on public.charges for select
  using (public.is_admin() or charges.unit_id = any(public.my_unit_ids()));
drop policy if exists "auth read charges" on public.charges;
drop policy if exists "admin write charges" on public.charges;
create policy "rls charges write" on public.charges for all
  using (public.is_admin()) with check (public.is_admin());

-- payments
drop policy if exists "rls payments sel" on public.payments;
create policy "rls payments sel" on public.payments for select
  using (public.is_admin() or payments.unit_id = any(public.my_unit_ids()));
drop policy if exists "auth read payments" on public.payments;
drop policy if exists "admin write payments" on public.payments;
create policy "rls payments write" on public.payments for all
  using (public.is_admin()) with check (public.is_admin());

-- prior_debts
drop policy if exists "rls prior sel" on public.prior_debts;
create policy "rls prior sel" on public.prior_debts for select
  using (public.is_admin() or prior_debts.unit_id = any(public.my_unit_ids()));
drop policy if exists "rls prior write" on public.prior_debts;
create policy "rls prior write" on public.prior_debts for all
  using (public.is_admin()) with check (public.is_admin());

-- units / owners / tenants: ساکن فقط واحدهای خودش
drop policy if exists "auth read units"   on public.units;   create policy "rls units sel"   on public.units   for select using (public.is_admin() or units.id   = any(public.my_unit_ids()));
drop policy if exists "admin write units" on public.units;   create policy "rls units write" on public.units   for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "auth read owners"  on public.owners;  create policy "rls owners sel"  on public.owners  for select using (public.is_admin() or owners.unit_id  = any(public.my_unit_ids()));
drop policy if exists "admin write owners" on public.owners; create policy "rls owners write" on public.owners for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "auth read tenants" on public.tenants; create policy "rls tenants sel" on public.tenants for select using (public.is_admin() or tenants.unit_id = any(public.my_unit_ids()));
drop policy if exists "admin write tenants" on public.tenants; create policy "rls tenants write" on public.tenants for all using (public.is_admin()) with check (public.is_admin());

-- resident_units: ادمین همه؛ ساکن فقط رکوردهای خودش
drop policy if exists "rls ru sel"   on public.resident_units; create policy "rls ru sel"   on public.resident_units for select using (public.is_admin() or user_id = auth.uid());
drop policy if exists "rls ru write" on public.resident_units; create policy "rls ru write" on public.resident_units for all using (public.is_admin()) with check (public.is_admin());

-- expenses / construction_projects / audit_log / categories / settings: فقط ادمین
drop policy if exists "auth read expenses"   on public.expenses;   create policy "rls exp sel"   on public.expenses   for select using (public.is_admin());
drop policy if exists "admin write expenses" on public.expenses;   create policy "rls exp write" on public.expenses   for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "auth read categories" on public.expense_categories; create policy "rls cat sel" on public.expense_categories for select using (public.is_admin());
drop policy if exists "admin write categories" on public.expense_categories; create policy "rls cat write" on public.expense_categories for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "rls proj sel"   on public.construction_projects; create policy "rls proj sel"   on public.construction_projects for select using (public.is_admin());
drop policy if exists "rls proj write" on public.construction_projects; create policy "rls proj write" on public.construction_projects for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "rls audit sel" on public.audit_log; create policy "rls audit sel" on public.audit_log for select using (public.is_admin());

-- settings: فقط ادمین (شامل access_code است → نباید برای ساکن خوانده شود)
drop policy if exists "auth read settings" on public.building_settings; create policy "rls set sel" on public.building_settings for select using (public.is_admin());
drop policy if exists "admin write settings" on public.building_settings; create policy "rls set write" on public.building_settings for all using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------
-- ۵) profile: ساکن فقط پروفایل خودش را می‌بیند (ادمین همه)
-- ---------------------------------------------------------------------
drop policy if exists "read own or admin" on public.profiles;
create policy "rls prof sel" on public.profiles for select using (id = auth.uid() or public.is_admin());
drop policy if exists "update own profile" on public.profiles;
create policy "rls prof upd" on public.profiles for update using (id = auth.uid() or public.is_admin());

-- ---------------------------------------------------------------------
-- ۶) خلاصه‌ی مالی یک واحد (برای نمایش پرونده‌ی ساکن) — امن
--    فقط اگر unit_id در my_unit_ids باشد (ساکن) یا ادمین.
-- ---------------------------------------------------------------------
create or replace function public.unit_finance(p_unit bigint)
returns table(
  due_monthly bigint, due_construction bigint, paid_monthly bigint, paid_construction bigint,
  prior_monthly bigint, prior_construction bigint, prior_credit bigint,
  balance_monthly bigint, balance_construction bigint, credit bigint, total_debt bigint
)
language plpgsql security definer stable set search_path = public as $$
declare
  dm bigint; dc bigint; pm bigint; pc bigint;
  prm bigint; prc bigint; prcr bigint;
begin
  if not (public.is_admin() or p_unit = any(public.my_unit_ids())) then
    return;
  end if;
  dm  := coalesce((select sum(amount_due) from public.charges  where unit_id=p_unit and (type='monthly' or type is null)),0);
  dc  := coalesce((select sum(amount_due) from public.charges  where unit_id=p_unit and type='construction'),0);
  pm  := coalesce((select sum(amount)     from public.payments where unit_id=p_unit and (type='monthly' or type is null)),0);
  pc  := coalesce((select sum(amount)     from public.payments where unit_id=p_unit and type='construction'),0);
  prm := coalesce((select sum(monthly_initial)      from public.prior_debts where unit_id=p_unit),0);
  prc := coalesce((select sum(construction_initial) from public.prior_debts where unit_id=p_unit),0);
  prcr:= coalesce((select sum(credit_initial)       from public.prior_debts where unit_id=p_unit),0);
  return query select
    dm, dc, pm, pc, prm, prc, prcr,
    (dm + prm - pm),                      -- balance_monthly
    (dc + prc - pc),                      -- balance_construction
    greatest(0, prcr + greatest(0, pm - dm - prm) + greatest(0, pc - dc - prc)),  -- credit (طلب)
    greatest(0, (dm + prm - pm)) + greatest(0, (dc + prc - pc))                  -- total_debt
  ;
end;
$$;
grant execute on function public.unit_finance(bigint) to authenticated;

-- ---------------------------------------------------------------------
-- ۷) سیاست درج audit_log (ثبت سابقه‌ی تغییرات توسط کاربر واردشده)
-- ---------------------------------------------------------------------
drop policy if exists "rls audit ins" on public.audit_log;
create policy "rls audit ins" on public.audit_log for insert to authenticated
  with check (auth.role() = 'authenticated');

-- ---------------------------------------------------------------------
-- ۸) باکت ذخیره‌سازی رسید/فاکتور (receipts) — خواندن عمومی، درج با احراز
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('receipts', 'receipts', true)
  on conflict (id) do nothing;
drop policy if exists "receipts read" on storage.objects;
create policy "receipts read" on storage.objects for select using (bucket_id = 'receipts');
drop policy if exists "receipts upload" on storage.objects;
create policy "receipts upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts');
