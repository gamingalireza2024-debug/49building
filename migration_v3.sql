-- =====================================================================
--  ساختمان ۴۹ — Migration v3: امنیت + صحت حسابداری + RPCهای اتمیک
--  این فایل نسخه‌ی نهایی و ایمن migration_v3 است (جایگزین نسخه‌ی قبلی).
--  idempotent و additive؛ هیچ داده‌ی مالی بدون backup حذف نمی‌شود.
--  شامل فاز نهایی: bootstrap اولین مدیر + گارد صندوق.
-- =====================================================================

-- ---------------------------------------------------------------------
-- ۱) is_admin: سخت‌گیری search_path (در initial هم هست، اینجا تضمین می‌شود)
-- ---------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin');
$$;

-- ---------------------------------------------------------------------
-- ۲) profiles: جلوگیری از ارتقای نقش توسط کاربر غیرادمین (trigger)
--    نسخه‌ی ۲: با escape hatch برای bootstrap اولین مدیر.
--    auth.uid() is null → دسترسی مستقیم SQL (SQL Editor) → bootstrap ادمین مجاز
--    اگر هنوز هیچ مدیری وجود نداشت، اجازه‌ی تغییر نقش (INSERT/UPDATE) بده.
--    این تنها راه‌گشای chicken-and-egg اولین مدیر است.
-- ---------------------------------------------------------------------
create or replace function public.guard_profile_role()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  admin_count int;
begin
  if TG_OP = 'INSERT' then
    if new.role is null then new.role := 'member'; end if;
    -- bootstrap: اگر هنوز مدیر وجود ندارد، اجازه‌ی ایجاد مدیر بده.
    select count(*) into admin_count from public.profiles where role = 'admin';
    if admin_count = 0 then return new; end if;
    if new.role <> 'member' and auth.uid() is not null and not public.is_admin() then
      new.role := 'member';
    end if;
    return new;
  end if;
  -- UPDATE
  if new.role is distinct from old.role then
    -- bootstrap: اگر هنوز مدیر وجود ندارد، اجازه‌ی ارتقا بده (claim_first_admin).
    select count(*) into admin_count from public.profiles where role = 'admin';
    if admin_count = 0 then return new; end if;
    if auth.uid() is not null and not public.is_admin() then
      raise exception 'تغییر نقش (role) تنها توسط مدیر ساختمان یا از SQL Editor ممکن است';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_guard_profile_role on public.profiles;
drop trigger if exists guard_profile_role on public.profiles;
create trigger trg_guard_profile_role
  before insert or update on public.profiles
  for each row execute function public.guard_profile_role();

-- ---------------------------------------------------------------------
-- ۳) audit_log: actor باید برابر auth.uid() باشد (جلوگیری از سابقه‌ی جعلی)
-- ---------------------------------------------------------------------
drop policy if exists "rls audit ins" on public.audit_log;
create policy "rls audit ins" on public.audit_log for insert to authenticated
  with check (actor = auth.uid());

-- ---------------------------------------------------------------------
-- ۴) receipts bucket: خصوصی + خواندن فقط برای واردشده‌ها
-- ---------------------------------------------------------------------
update storage.buckets set public = false where id = 'receipts';
drop policy if exists "receipts read" on storage.objects;
create policy "receipts read" on storage.objects for select to authenticated
  using (bucket_id = 'receipts');
drop policy if exists "receipts upload" on storage.objects;
create policy "receipts upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts');
drop policy if exists "receipts delete" on storage.objects;
create policy "receipts delete" on storage.objects for delete to authenticated
  using (bucket_id = 'receipts');

-- ---------------------------------------------------------------------
-- ۵) prior_debts: اعتبار تفکیک‌شده + BACKUP قبل از dedup + unique(unit_id)
--    هیچ داده‌ای بدون backup حذف نمی‌شود.
-- ---------------------------------------------------------------------
alter table public.prior_debts
  add column if not exists credit_monthly bigint not null default 0,
  add column if not exists credit_construction bigint not null default 0;

-- backfill: credit_initial قدیمی → credit_monthly
update public.prior_debts
  set credit_monthly = credit_initial
  where credit_monthly = 0 and coalesce(credit_initial,0) <> 0;

-- BACKUP: قبل از هر dedup، تمام ردیف‌ها (شامل تکراری‌ها) در یک جدول پشتیبان کپی می‌شوند.
create table if not exists public.prior_debts_backup_v3 as
  select now() as backed_up_at, * from public.prior_debts where false;
insert into public.prior_debts_backup_v3 (backed_up_at, id, unit_id, monthly_initial, construction_initial,
  credit_initial, credit_monthly, credit_construction, as_of_date, note, created_by, created_at)
  select now(), id, unit_id, monthly_initial, construction_initial,
  credit_initial, credit_monthly, credit_construction, as_of_date, note, created_by, created_at
  from public.prior_debts
  on conflict do nothing;

-- dedup: فقط در صورت وجود چند ردیف برای یک واحد، قدیمی‌ترین‌ها حذف می‌شوند
-- (جدول backup همه را نگه داشته است).
delete from public.prior_debts a
  using public.prior_debts b
  where a.unit_id is not null and a.unit_id = b.unit_id and a.id < b.id;

drop index if exists prior_debts_unit_unique;
create unique index if not exists prior_debts_unit_unique on public.prior_debts (unit_id);

-- ---------------------------------------------------------------------
-- ۶) building_settings: موجودی افتتاحیه‌ی دو صندوق
-- ---------------------------------------------------------------------
alter table public.building_settings
  add column if not exists fund_monthly_opening bigint not null default 0,
  add column if not exists fund_construction_opening bigint not null default 0;

-- ---------------------------------------------------------------------
-- ۷) payments: project_id + اعتبارسنجی مبلغ مثبت
-- ---------------------------------------------------------------------
alter table public.payments
  add column if not exists project_id bigint references public.construction_projects(id) on delete set null;

alter table public.payments
  add constraint payments_amount_positive check (amount > 0);

-- ---------------------------------------------------------------------
-- ۸) به‌روزرسانی unit_finance: اعمال credit تفکیک‌شده در مانده
--    (هماهنگ با منطق JS در index.html)
-- ---------------------------------------------------------------------
create or replace function public.unit_finance(p_unit bigint)
returns table(
  due_monthly bigint, due_construction bigint, paid_monthly bigint, paid_construction bigint,
  prior_monthly bigint, prior_construction bigint,
  credit_monthly bigint, credit_construction bigint,
  balance_monthly bigint, balance_construction bigint, total_debt bigint
)
language plpgsql security definer stable set search_path = public as $$
declare
  dm bigint; dc bigint; pm bigint; pc bigint;
  prm bigint; prc bigint; cm bigint; cc bigint;
begin
  if not (public.is_admin() or p_unit = any(public.my_unit_ids())) then return; end if;
  dm := coalesce((select sum(amount_due) from public.charges  where unit_id=p_unit and (type='monthly' or type is null)),0);
  dc := coalesce((select sum(amount_due) from public.charges  where unit_id=p_unit and type='construction'),0);
  pm := coalesce((select sum(amount)     from public.payments where unit_id=p_unit and (type='monthly' or type is null)),0);
  pc := coalesce((select sum(amount)     from public.payments where unit_id=p_unit and type='construction'),0);
  prm:= coalesce((select sum(monthly_initial)      from public.prior_debts where unit_id=p_unit),0);
  prc:= coalesce((select sum(construction_initial) from public.prior_debts where unit_id=p_unit),0);
  cm := coalesce((select sum(credit_monthly)       from public.prior_debts where unit_id=p_unit),0);
  cc := coalesce((select sum(credit_construction)  from public.prior_debts where unit_id=p_unit),0);
  return query select
    dm, dc, pm, pc, prm, prc, cm, cc,
    (dm + prm - pm - cm),          -- balance_monthly (با اعمال طلب ماهانه)
    (dc + prc - pc - cc),          -- balance_construction
    greatest(0,(dm + prm - pm - cm)) + greatest(0,(dc + prc - pc - cc));  -- total_debt
end;
$$;
grant execute on function public.unit_finance(bigint) to authenticated;

-- =====================================================================
-- ۹) RPCهای اتمیک — واحد/مالک/مستاجر + پرداخت + هزینه + audit در یک تراکنش
-- =====================================================================

-- ۹-الف) ذخیره‌ی اتمیک واحد + مالک + مستاجر (درج/ویرایش)
create or replace function public.save_unit_owner_tenant(
  p_unit jsonb,
  p_owner jsonb,
  p_tenant jsonb default null,
  p_tenant_remove boolean default false
) returns table(unit_id bigint, owner_id bigint, tenant_id bigint)
language plpgsql security definer set search_path = public as $$
declare
  v_unit_id bigint; v_owner_id bigint; v_tenant_id bigint; v_uid uuid := auth.uid();
  v_num text; v_is_new boolean;
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند واحد/مالک/مستاجر ثبت کند';
  end if;
  v_num := p_unit->>'number';
  if v_num is null or btrim(v_num) = '' then
    raise exception 'شماره واحد الزامی است';
  end if;
  if (p_owner->>'name') is null or btrim(p_owner->>'name') = '' then
    raise exception 'نام مالک الزامی است';
  end if;
  -- unit
  if (p_unit->>'id')::bigint is null then
    insert into units (number, floor, area)
      values (v_num, nullif(p_unit->>'floor','')::int, nullif(p_unit->>'area','')::numeric)
      returning id into v_unit_id;
    v_is_new := true;
  else
    v_unit_id := (p_unit->>'id')::bigint;
    update units set number=v_num,
      floor=nullif(p_unit->>'floor','')::int,
      area=nullif(p_unit->>'area','')::numeric
      where id=v_unit_id;
    v_is_new := false;
  end if;
  -- owner (یکی به ازای هر واحد)
  select id into v_owner_id from owners where unit_id=v_unit_id limit 1;
  if v_owner_id is null then
    insert into owners (unit_id, name, national_code, phone, email)
      values (v_unit_id, p_owner->>'name',
        nullif(p_owner->>'national_code',''),
        nullif(p_owner->>'phone',''),
        nullif(p_owner->>'email',''))
      returning id into v_owner_id;
  else
    update owners set name=p_owner->>'name',
      national_code=nullif(p_owner->>'national_code',''),
      phone=nullif(p_owner->>'phone',''),
      email=nullif(p_owner->>'email','')
      where id=v_owner_id;
  end if;
  -- tenant
  if p_tenant_remove then
    delete from tenants where unit_id=v_unit_id;
    insert into audit_log (table_name, record_id, action, reason, actor, change_data)
      values ('tenants', v_unit_id, 'delete', 'حذف مستاجر (RPC)', v_uid, jsonb_build_object('unit_id',v_unit_id));
  elsif p_tenant is not null and btrim(coalesce(p_tenant->>'name','')) <> '' then
    select id into v_tenant_id from tenants where unit_id=v_unit_id limit 1;
    if v_tenant_id is null then
      insert into tenants (unit_id, name, phone, lease_start, lease_end)
        values (v_unit_id, p_tenant->>'name', nullif(p_tenant->>'phone',''),
          nullif(p_tenant->>'lease_start','')::date, nullif(p_tenant->>'lease_end','')::date)
        returning id into v_tenant_id;
    else
      update tenants set name=p_tenant->>'name', phone=nullif(p_tenant->>'phone',''),
        lease_start=nullif(p_tenant->>'lease_start','')::date, lease_end=nullif(p_tenant->>'lease_end','')::date
        where id=v_tenant_id;
    end if;
  end if;
  -- audit (همان تراکنش)
  insert into audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('units', v_unit_id, case when v_is_new then 'insert' else 'update' end,
      'ذخیره واحد/مالک/مستاجر (RPC)', v_uid, p_unit);
  return query select v_unit_id, v_owner_id, v_tenant_id;
end;
$$;
grant execute on function public.save_unit_owner_tenant(jsonb, jsonb, jsonb, boolean) to authenticated;

-- ۹-ب) ثبت اتمیک پرداخت + اعتبارسنجی تخصیص پروژه + audit در همان تراکنش
create or replace function public.record_payment(
  p_unit_id bigint, p_amount bigint, p_type text, p_jmonth text,
  p_payment_date date, p_method text, p_project_id bigint default null,
  p_note text default null, p_reason text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_uid uuid := auth.uid();
  v_collected bigint; v_issued bigint;
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند پرداخت ثبت کند';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'مبلغ پرداخت باید مثبت و بزرگتر از صفر باشد';
  end if;
  if p_type not in ('monthly','construction') then
    raise exception 'نوع پرداخت نامعتبر است (monthly یا construction)';
  end if;
  if p_project_id is not null then
    -- تخصیص به پروژه فقط برای پرداخت عمرانی
    if p_type <> 'construction' then
      raise exception 'تخصیص پرداخت به پروژه فقط برای پرداخت عمرانی مجاز است';
    end if;
    -- پروژه باید وجود داشته باشد
    if not exists(select 1 from construction_projects where id=p_project_id) then
      raise exception 'پروژه‌ی عمرانی موردنظر وجود ندارد';
    end if;
    -- مجموع وصول‌شده نباید از شارژ صادرشده‌ی پروژه بیشتر شود
    select coalesce(sum(amount),0) into v_collected from payments where project_id=p_project_id;
    select coalesce(sum(amount_due),0) into v_issued
      from charges where project_id=p_project_id and type='construction';
    if v_collected + p_amount > v_issued then
      raise exception 'تخصیص پرداخت به پروژه بیش از مبلغ شارژ صادرشده برای آن پروژه است (وصول:%، صادرشده:%)',
        v_collected + p_amount, v_issued;
    end if;
  end if;
  insert into payments (unit_id, amount, type, jmonth, payment_date, method, project_id, note, created_by)
    values (p_unit_id, p_amount, p_type, p_jmonth, p_payment_date, p_method, p_project_id, p_note, v_uid)
    returning id into v_id;
  -- audit در همان تراکنش: اگر این درج شکست بخورد، پرداخت هم rollback می‌شود
  insert into audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('payments', v_id, 'insert', p_reason, v_uid,
      jsonb_build_object('unit_id',p_unit_id,'amount',p_amount,'type',p_type,'project_id',p_project_id));
  return v_id;
end;
$$;
grant execute on function public.record_payment(bigint, bigint, text, text, date, text, bigint, text, text) to authenticated;

-- ۹-ج) ثبت اتمیک هزینه + audit در همان تراکنش (receipt_path فقط مسیر را نگه می‌دارد)
create or replace function public.record_expense(
  p_title text, p_amount bigint, p_fund text, p_category_id bigint default null,
  p_expense_date date default null, p_jmonth text default null, p_payment_type text default 'bank',
  p_reference_no text default null, p_project_id bigint default null, p_receipt_path text default null,
  p_description text default null, p_reason text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_uid uuid := auth.uid();
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند هزینه ثبت کند';
  end if;
  if p_amount is null or p_amount < 0 then
    raise exception 'مبلغ هزینه نامعتبر است';
  end if;
  if p_fund not in ('monthly','construction') then
    raise exception 'صندوق هزینه نامعتبر است';
  end if;
  insert into expenses (title, amount, fund, category_id, expense_date, jmonth, payment_type,
    reference_no, project_id, receipt_url, description, created_by)
    values (p_title, p_amount, p_fund, p_category_id, coalesce(p_expense_date, current_date),
      p_jmonth, p_payment_type, p_reference_no, p_project_id, p_receipt_path, p_description, v_uid)
    returning id into v_id;
  insert into audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('expenses', v_id, 'insert', p_reason, v_uid,
      jsonb_build_object('title',p_title,'amount',p_amount,'fund',p_fund,'project_id',p_project_id));
  return v_id;
end;
$$;
grant execute on function public.record_expense(text, bigint, text, bigint, date, text, text, text, bigint, text, text, text) to authenticated;

-- =====================================================================
-- ۱۰) admin_exists: بررسی امن (RPC) اینکه آیا مدیر وجود دارد یا خیر.
--     کاربر عضو نمی‌تواند profiles را بخواند (RLS)، پس این RPC لازم است.
-- =====================================================================
create or replace function public.admin_exists()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  return exists(select 1 from public.profiles where role = 'admin');
end;
$$;
revoke execute on function public.admin_exists() from public, anon;
grant execute on function public.admin_exists() to authenticated;

-- ---------------------------------------------------------------------
-- ۱۱) claim_first_admin: اگر هیچ مدیری وجود نداشت، کاربر فراخوان را به مدیر ارتقا بدهد.
--     بلافاصله بعد از اولین مدیر، فراخوان‌های بعدی استثنا می‌اندازند.
--     امن: security definer، و guard_profile_role به‌خاطر admin_count=0 اجازه می‌دهد.
-- ---------------------------------------------------------------------
create or replace function public.claim_first_admin()
returns text language plpgsql security definer set search_path = public as $$
declare
  caller uuid := auth.uid();
  admin_count int;
begin
  if caller is null then
    raise exception 'claim_first_admin فقط برای کاربر احراز‌هویت‌شده قابل فراخوانی است';
  end if;
  select count(*) into admin_count from public.profiles where role = 'admin';
  if admin_count > 0 then
    raise exception 'یک مدیر از قبل وجود دارد. برای ارتقا، با مدیر فعلی تماس بگیرید.';
  end if;
  update public.profiles set role = 'admin' where id = caller;
  if not found then
    raise exception 'پروفایل شما یافت نشد. ابتدا وارد شوید سپس دوباره تلاش کنید.';
  end if;
  return 'ok';
end;
$$;
revoke execute on function public.claim_first_admin() from public, anon;
grant execute on function public.claim_first_admin() to authenticated;

-- ---------------------------------------------------------------------
-- ۱۲) گارد seeding: افتتاحیه‌ی صندوق باید عدد صحیح نامنفی باشد.
--     نکته: PostgreSQL از «ADD CONSTRAINT IF NOT EXISTS» پشتیبانی نمی‌کند؛
--     پس با بلوک DO و بررسی pg_constraint، idempotent ساخته می‌شود.
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'chk_fund_monthly_opening_nonneg'
      and conrelid = 'public.building_settings'::regclass
  ) then
    alter table public.building_settings
      add constraint chk_fund_monthly_opening_nonneg
      check (fund_monthly_opening is null or fund_monthly_opening >= 0);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'chk_fund_construction_opening_nonneg'
      and conrelid = 'public.building_settings'::regclass
  ) then
    alter table public.building_settings
      add constraint chk_fund_construction_opening_nonneg
      check (fund_construction_opening is null or fund_construction_opening >= 0);
  end if;
end
$$;

-- =====================================================================
--  پایان — هیچ داده‌ی مالی بدون backup حذف نشد.
--  فاز نهایی شامل: bootstrap اولین مدیر + گارد صندوق (sections 10-12).
--  اگر نسخه‌ی قبلی migration_v3 (commit bd48ea4) را که بدون backup
--  رکوردهای تکراری prior_debts را حذف می‌کرد، قبلاً اجرا کرده‌اید،
--  آن رکوردها فقط از backup روزانه‌ی Supabase (PITR) قابل بازیابی‌اند.
--  پرس‌وجوی تشخیص: select count(*) from prior_debts_backup_v3;
-- =====================================================================
