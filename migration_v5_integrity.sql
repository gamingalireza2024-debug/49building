-- =====================================================================
--  ساختمان ۴۹ — Migration v5: اصلاح یکپارچگی حسابداری + RPCها + قفل‌گذاری
--  -------------------------------------------------------------------
--  این فایل یک migration نهایی، idempotent و غیرمخرب است.
--  • با وضعیت فعلی دیتابیس (پس از schema/v2/v3) کاملاً سازگار است.
--  • هیچ داده‌ی مالی بدون snapshot قابل‌بازیابی بازنویسی نمی‌شود.
--  • همه‌ی توابع: SECURITY DEFINER + set search_path = public.
--  • اجرا در Supabase Dashboard → SQL Editor → کل فایل → Run.
--  • امن برای اجرای مکرر (create or replace / add column if not exists /
--    جدول marker برای reconciliation).
-- =====================================================================

-- ---------------------------------------------------------------------
-- ۰) ستون guest_code روی units (نبود آن باعث می‌شد ذخیره‌ی کد مهمان
--    بی‌صدا fail شود). یک ستون متنی ساده؛ مقدار آن توسط ادمین تنظیم می‌شود.
-- ---------------------------------------------------------------------
alter table public.units
  add column if not exists guest_code text;

-- ایندکس روی guest_code برای ورود مهمان (lookup سریع، فقط ردیف‌های دارای کد)
create index if not exists idx_units_guest_code
  on public.units (guest_code) where guest_code is not null;

-- ---------------------------------------------------------------------
-- ایندهای justified برای مسیرهای داغ (unit_finance، اعتبارسنجی پروژه، داشبورد)
-- همه partial/conditional تا کوچک و هدفمند بمانند.
-- ---------------------------------------------------------------------
create index if not exists idx_payments_unit_type   on public.payments (unit_id, type);
create index if not exists idx_charges_unit_type    on public.charges  (unit_id, type);
create index if not exists idx_payments_project     on public.payments (project_id) where project_id is not null;
create index if not exists idx_charges_project_type on public.charges  (project_id, type) where project_id is not null;
create index if not exists idx_expenses_project     on public.expenses (project_id) where project_id is not null;
create index if not exists idx_expenses_fund        on public.expenses (fund);
create index if not exists idx_audit_record         on public.audit_log (table_name, record_id);

-- =====================================================================
-- فاز ۲ — بازیابی یکپارچگی داده‌ی prior_debts (بدون از دست رفتن مبلغ)
-- =====================================================================
-- پس‌زمینه: dedup نسخه‌ی قبلی migration_v3 ردیف‌های تکراری prior_debts را
-- حذف می‌کرد بدون اینکه مبالغ آن‌ها را پیش از حذف تجمیع کند. در نتیجه برای
-- واحدهایی که بیش از یک ردیف داشتند، مبالغِ ردیف‌های قدیمی‌تر از دست رفت.
-- جدول prior_debts_backup_v3 (ایجادشده توسط v3) همه‌ی ردیف‌های اصلی را نگه داشته.
--
-- استراتژی ایمن:
--   ۱) فقط واحدهایی که در backup بیش از یک ردیف دارند (قربانیِ احتمالی) پردازش می‌شوند.
--   ۲) مبالغِ همه‌ی ردیف‌های backup برای آن واحد تجمیع می‌شود (مقادیر واقعیِ پیش از dedup).
--   ۳) مقدار تجمیع‌شده روی ردیفِ بازمانده upsert می‌شود.
--   ۴) snapshot قبل/بعد در prior_debts_reconciled_v5 ذخیره می‌شود (قابل بازیابی).
--   ۵) جدول marker با PK(unit_id) تضمین می‌کند اجرای مکرر双重‌شمارش نمی‌کند.
--   ۶) credit_initial (ستون legacy) هم‌گام با credit_monthly به‌روز می‌شود.
-- ---------------------------------------------------------------------

create table if not exists public.prior_debts_reconciled_v5 (
  unit_id                   bigint primary key,
  before_monthly            bigint,
  before_construction       bigint,
  before_credit_monthly     bigint,
  before_credit_construction bigint,
  after_monthly             bigint,
  after_construction        bigint,
  after_credit_monthly      bigint,
  after_credit_construction bigint,
  reconciled_at             timestamptz not null default now()
);
alter table public.prior_debts_reconciled_v5 enable row level security;
drop policy if exists "rls recon sel" on public.prior_debts_reconciled_v5;
create policy "rls recon sel" on public.prior_debts_reconciled_v5 for select using (public.is_admin());

do $$
declare
  v_has_backup boolean;
  r record;
  v_before record;
  v_after record;
  v_asof date;
  v_cnt int := 0;
begin
  select exists(select 1 from pg_tables where schemaname='public' and tablename='prior_debts_backup_v3')
    into v_has_backup;
  if not v_has_backup then
    raise notice 'prior_debts_backup_v3 وجود ندارد — نیازی به reconciliation نیست.';
    return;
  end if;

  for r in
    select b.unit_id
    from public.prior_debts_backup_v3 b
    where b.unit_id is not null
      and exists (select 1 from public.units u where u.id = b.unit_id)
      and not exists (select 1 from public.prior_debts_reconciled_v5 x where x.unit_id = b.unit_id)
    group by b.unit_id
    having count(*) > 1
  loop
    -- قبل: مقدار فعلی در prior_debts برای این واحد
    select coalesce(sum(monthly_initial),0)       as m,
           coalesce(sum(construction_initial),0)  as c,
           coalesce(sum(credit_monthly),0)        as cm,
           coalesce(sum(credit_construction),0)   as cc
      into v_before
    from public.prior_debts where unit_id = r.unit_id;

    -- بعد: تجمیعِ همه‌ی ردیف‌های backup (مقادیر واقعیِ پیش از dedup)
    select coalesce(sum(monthly_initial),0)       as m,
           coalesce(sum(construction_initial),0)  as c,
           coalesce(sum(credit_monthly),0)        as cm,
           coalesce(sum(credit_construction),0)   as cc
      into v_after
    from public.prior_debts_backup_v3 where unit_id = r.unit_id;

    select min(as_of_date) into v_asof from public.prior_debts_backup_v3 where unit_id = r.unit_id;

    -- upsert مقدار تجمیع‌شده (as_of_date = earliest، note حفظ می‌شود)
    insert into public.prior_debts
      (unit_id, monthly_initial, construction_initial, credit_monthly, credit_construction, credit_initial, as_of_date)
      values (r.unit_id, v_after.m, v_after.c, v_after.cm, v_after.cc, v_after.cm, coalesce(v_asof, current_date))
      on conflict (unit_id) do update
        set monthly_initial       = excluded.monthly_initial,
            construction_initial  = excluded.construction_initial,
            credit_monthly        = excluded.credit_monthly,
            credit_construction   = excluded.credit_construction,
            credit_initial        = excluded.credit_initial,
            as_of_date            = least(prior_debts.as_of_date, excluded.as_of_date);

    -- snapshot برای حسابرسی و بازیابی
    insert into public.prior_debts_reconciled_v5
      (unit_id, before_monthly, before_construction, before_credit_monthly, before_credit_construction,
       after_monthly, after_construction, after_credit_monthly, after_credit_construction)
      values (r.unit_id, v_before.m, v_before.c, v_before.cm, v_before.cc,
              v_after.m, v_after.c, v_after.cm, v_after.cc)
      on conflict (unit_id) do nothing;

    v_cnt := v_cnt + 1;
  end loop;

  raise notice 'reconciliation v5: % واحدِ تکراری تجمیع و اصلاح شد.', v_cnt;
end;
$$;

-- =====================================================================
-- توابع پایه (تضمین search_path)
-- =====================================================================
create or replace function public.is_admin()
returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin');
$$;

create or replace function public.my_unit_ids()
returns bigint[] language sql security definer stable set search_path = public as $$
  select case when public.is_admin()
    then array(select id from public.units)
    else coalesce(array(select unit_id from public.resident_units where user_id = auth.uid()), array[]::bigint[])
  end;
$$;
grant execute on function public.my_unit_ids() to authenticated;

-- =====================================================================
-- حذف نسخه‌های قبلیِ RPCهای داده (اجازه‌ی تغییر return type)
-- ---------------------------------------------------------------------
-- create or replace نمی‌تواند return type را تغییر دهد؛ لذا نسخه‌های قبلی
-- را با همان signature حذف می‌کنیم و سپس از نو می‌سازیم.
-- تأییدشده: هیچ policy/view/تابع دیگری به این توابع ارجاع نمی‌دهد (drop امن).
-- is_admin و my_unit_ids حذف نمی‌شوند چون policyها به آن‌ها وابسته‌اند و
-- return typeشان با نسخۀ موجود یکسان است.
-- drop function if exists اگر نسخه‌ای با این signature نباشد، no-op است.
-- =====================================================================
drop function if exists public.record_audit(text, bigint, text, text, jsonb);
drop function if exists public.record_payment(bigint, bigint, text, text, date, text, bigint, text, text);
drop function if exists public.update_payment(bigint, bigint, bigint, text, text, date, text, bigint, text, text);
drop function if exists public.delete_payment(bigint, text);
drop function if exists public.record_expense(text, bigint, text, bigint, date, text, text, text, bigint, text, text, text);
drop function if exists public.update_expense(bigint, text, bigint, text, bigint, date, text, text, text, bigint, text, text, text);
drop function if exists public.delete_expense(bigint, text);
drop function if exists public.save_prior_debt(bigint, bigint, bigint, bigint, bigint, date, text, text);
drop function if exists public.delete_prior_debt(bigint, text);
drop function if exists public.bulk_charge(text, text, jsonb, text);
drop function if exists public.delete_unit(bigint, text);
drop function if exists public.save_unit_owner_tenant(jsonb, jsonb, jsonb, boolean);
drop function if exists public.unit_finance(bigint);
drop function if exists public.guest_login(text);

-- =====================================================================
-- record_audit — ثبت سابقه‌ی ad-hoc (تنها مسیر عمومی برای audit غیرمالی).
-- actor سمت‌سرور برابر auth.uid() تضمین می‌شود (نه از پارامتر).
-- عملیات مالی audit خود را داخل RPC اتمیک مربوطه ثبت می‌کنند.
-- =====================================================================
create or replace function public.record_audit(
  p_table text, p_record_id bigint, p_action text,
  p_reason text default null, p_change_data jsonb default null
) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'ثبت سابقه فقط برای کاربر واردشده ممکن است';
  end if;
  if p_action not in ('insert','update','delete') then
    raise exception 'نوع عملیات سابقه نامعتبر است (insert/update/delete)';
  end if;
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values (p_table, coalesce(p_record_id,0), p_action, p_reason, v_uid, p_change_data);
  return true;
end;
$$;
revoke execute on function public.record_audit(text, bigint, text, text, jsonb) from public, anon;
grant execute on function public.record_audit(text, bigint, text, text, jsonb) to authenticated;

-- =====================================================================
-- record_payment — ثبت اتمیک پرداخت + قفل‌گذاری پروژه (FOR UPDATE) + audit
-- ---------------------------------------------------------------------
-- قفل‌گذاری: هنگام تخصیص به پروژه، ردیفِ construction_projects با FOR UPDATE
-- قفل می‌شود تا دو پرداخت هم‌زمان نتوانند از سقفِ شارژ صادرشده عبور کنند.
-- SELECT سپس INSERT کافی نیست؛ این الگو serialization در سطح دیتابیس می‌دهد.
-- =====================================================================
create or replace function public.record_payment(
  p_unit_id bigint, p_amount bigint, p_type text, p_jmonth text,
  p_payment_date date, p_method text, p_project_id bigint default null,
  p_note text default null, p_reason text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint; v_uid uuid := auth.uid();
  v_pid bigint; v_collected bigint; v_issued bigint;
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
  if not exists(select 1 from public.units where id = p_unit_id) then
    raise exception 'واحد موردنظر وجود ندارد';
  end if;
  if p_project_id is not null then
    -- تخصیص به پروژه فقط برای پرداخت عمرانی
    if p_type <> 'construction' then
      raise exception 'تخصیص پرداخت به پروژه فقط برای پرداخت عمرانی مجاز است (پرداخت ماهانه هرگز به پروژه‌ی عمرانی تخصیص نمی‌یابد)';
    end if;
    -- قفل ردیف پروژه (serialize) + اعتبارسنجی وجود
    select cp.id into v_pid from public.construction_projects cp where cp.id = p_project_id for update;
    if v_pid is null then
      raise exception 'پروژه‌ی عمرانی موردنظر وجود ندارد';
    end if;
    -- وصول فعلیِ پروژه (قفل گرفته شده، پس امن از رقابت)
    select coalesce(sum(amount),0) into v_collected
      from public.payments where project_id = p_project_id;
    -- شارژ صادرشده‌ی عمرانی برای این پروژه
    select coalesce(sum(amount_due),0) into v_issued
      from public.charges where project_id = p_project_id and type = 'construction';
    if v_collected + p_amount > v_issued then
      raise exception 'تخصیص پرداخت به پروژه بیش از مبلغ شارژ صادرشده برای آن پروژه است (وصول:%، صادرشده:%)',
        v_collected + p_amount, v_issued;
    end if;
  end if;
  insert into public.payments (unit_id, amount, type, jmonth, payment_date, method, project_id, note, created_by)
    values (p_unit_id, p_amount, p_type, p_jmonth, p_payment_date, p_method, p_project_id, p_note, v_uid)
    returning id into v_id;
  -- audit در همان تراکنش: شکست → rollback کل عملیات
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('payments', v_id, 'insert', p_reason, v_uid,
      jsonb_build_object('unit_id',p_unit_id,'amount',p_amount,'type',p_type,'project_id',p_project_id));
  return v_id;
end;
$$;
grant execute on function public.record_payment(bigint, bigint, text, text, date, text, bigint, text, text) to authenticated;

-- =====================================================================
-- update_payment — ویرایش اتمیک + قفل ردیف پرداخت + قفل پروژه‌ی جدید + audit
-- ---------------------------------------------------------------------
-- • ردیف پرداخت با FOR UPDATE قفل می‌شود (serialize ویرایش هم‌زمان).
-- • هنگام تخصیص به پروژه (جدید)، ردیف پروژه قفل می‌شود.
-- • وصولِ فعلی منهای مبلغ قدیمیِ همین رکورد محاسبه می‌شود (چون جایگزینی است).
-- • تغییر پروژه: اعتبارسنجی روی پروژه‌ی جدید با کسر همین رکورد انجام می‌شود.
-- =====================================================================
create or replace function public.update_payment(
  p_id bigint, p_unit_id bigint, p_amount bigint, p_type text, p_jmonth text,
  p_payment_date date, p_method text, p_project_id bigint default null,
  p_note text default null, p_reason text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_pid bigint; v_collected bigint; v_issued bigint;
  v_lock bigint;
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند پرداخت را ویرایش کند';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'مبلغ پرداخت باید مثبت و بزرگتر از صفر باشد';
  end if;
  if p_type not in ('monthly','construction') then
    raise exception 'نوع پرداخت نامعتبر است (monthly یا construction)';
  end if;
  if not exists(select 1 from public.units where id = p_unit_id) then
    raise exception 'واحد موردنظر وجود ندارد';
  end if;
  -- قفل ردیف پرداخت (و اعتبارسنجی وجود)
  select id into v_lock from public.payments where id = p_id for update;
  if v_lock is null then
    raise exception 'پرداختی با این شناسه وجود ندارد';
  end if;
  if p_project_id is not null then
    if p_type <> 'construction' then
      raise exception 'تخصیص پرداخت به پروژه فقط برای پرداخت عمرانی مجاز است';
    end if;
    -- قفل پروژه‌ی جدید + اعتبارسنجی وجود
    select cp.id into v_pid from public.construction_projects cp where cp.id = p_project_id for update;
    if v_pid is null then
      raise exception 'پروژه‌ی عمرانی موردنظر وجود ندارد';
    end if;
    -- وصولِ فعلی منهای همین رکورد (در حال جایگزینی است)
    select coalesce(sum(amount),0) into v_collected
      from public.payments where project_id = p_project_id and id <> p_id;
    select coalesce(sum(amount_due),0) into v_issued
      from public.charges where project_id = p_project_id and type = 'construction';
    if v_collected + p_amount > v_issued then
      raise exception 'تخصیص پرداخت به پروژه بیش از مبلغ شارژ صادرشده برای آن پروژه است (وصول جدید:%، صادرشده:%)',
        v_collected + p_amount, v_issued;
    end if;
  end if;
  update public.payments set
    unit_id = p_unit_id, amount = p_amount, type = p_type, jmonth = p_jmonth,
    payment_date = p_payment_date, method = p_method, project_id = p_project_id, note = p_note
    where id = p_id;
  -- اگر هیچ ردیفی تغییر نکرد (نباید رخ دهد چون قفل گرفته شد)، صریح خطا بده
  if not found then
    raise exception 'ویرایش پرداخت انجام نشد — رکورد یافت نشد';
  end if;
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('payments', p_id, 'update', p_reason, v_uid,
      jsonb_build_object('unit_id',p_unit_id,'amount',p_amount,'type',p_type,'project_id',p_project_id));
  return p_id;
end;
$$;
grant execute on function public.update_payment(bigint, bigint, bigint, text, text, date, text, bigint, text, text) to authenticated;

-- =====================================================================
-- delete_payment — حذف اتمیک + audit (با قفل ردیف)
-- =====================================================================
create or replace function public.delete_payment(p_id bigint, p_reason text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_old jsonb; v_lock bigint;
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند پرداخت را حذف کند';
  end if;
  select id, to_jsonb(p) into v_lock, v_old from public.payments p where id = p_id for update;
  if v_lock is null then
    raise exception 'پرداختی با این شناسه وجود ندارد';
  end if;
  delete from public.payments where id = p_id;
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('payments', p_id, 'delete', p_reason, v_uid, v_old);
  return true;
end;
$$;
grant execute on function public.delete_payment(bigint, text) to authenticated;

-- =====================================================================
-- record_expense — ثبت اتمیک هزینه + اعتبارسنجی سخت‌گیرانه + audit
-- ---------------------------------------------------------------------
-- • مبلغ باید اکیداً بزرگتر از صفر باشد (> 0، نه ≥ 0).
-- • fund باید monthly یا construction باشد.
-- • دسته (category) اگر داده شد باید موجود باشد و type آن با fund سازگار باشد
--   (monthly↔monthly، construction↔construction، general↔هرکدام).
-- • پروژه فقط با fund=construction (هزینه‌ی ماهانه هرگز به پروژه‌ی عمرانی نمی‌رسد).
-- • receipt_url و metadata حفظ می‌شوند.
-- =====================================================================
create or replace function public.record_expense(
  p_title text, p_amount bigint, p_fund text, p_category_id bigint default null,
  p_expense_date date default null, p_jmonth text default null, p_payment_type text default 'bank',
  p_reference_no text default null, p_project_id bigint default null, p_receipt_path text default null,
  p_description text default null, p_reason text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint; v_uid uuid := auth.uid();
  v_cat_type text;
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند هزینه ثبت کند';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'مبلغ هزینه باید اکیداً مثبت و بزرگتر از صفر باشد';
  end if;
  if p_fund not in ('monthly','construction') then
    raise exception 'صندوق هزینه نامعتبر است (monthly یا construction)';
  end if;
  if p_title is null or btrim(p_title) = '' then
    raise exception 'عنوان هزینه الزامی است';
  end if;
  -- اعتبارسنجی دسته + سازگاری type دسته با fund
  if p_category_id is not null then
    select type into v_cat_type from public.expense_categories where id = p_category_id;
    if v_cat_type is null then
      raise exception 'دسته‌ی هزینه‌ی موردنظر وجود ندارد';
    end if;
    if v_cat_type <> 'general' and v_cat_type <> p_fund then
      raise exception 'دسته‌ی انتخابی (%) با صندوق (%) سازگار نیست', v_cat_type, p_fund;
    end if;
  end if;
  -- پروژه فقط با fund=construction (سازگاری fund↔project)
  if p_project_id is not null then
    if p_fund <> 'construction' then
      raise exception 'هزینه‌ی پروژه‌ی عمرانی فقط از صندوق عمرانی ممکن است (هزینه‌ی ماهانه به پروژه تخصیص نمی‌یابد)';
    end if;
    if not exists(select 1 from public.construction_projects where id = p_project_id) then
      raise exception 'پروژه‌ی عمرانی موردنظر وجود ندارد';
    end if;
  end if;
  insert into public.expenses (title, amount, fund, category_id, expense_date, jmonth, payment_type,
    reference_no, project_id, receipt_url, description, created_by)
    values (p_title, p_amount, p_fund, p_category_id, coalesce(p_expense_date, current_date),
      p_jmonth, p_payment_type, p_reference_no, p_project_id, p_receipt_path, p_description, v_uid)
    returning id into v_id;
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('expenses', v_id, 'insert', p_reason, v_uid,
      jsonb_build_object('title',p_title,'amount',p_amount,'fund',p_fund,'category_id',p_category_id,'project_id',p_project_id));
  return v_id;
end;
$$;
grant execute on function public.record_expense(text, bigint, text, bigint, date, text, text, text, bigint, text, text, text) to authenticated;

-- =====================================================================
-- update_expense — ویرایش اتمیک + اعتبارسنجی کامل + audit (بدون drop فیلد)
-- =====================================================================
create or replace function public.update_expense(
  p_id bigint,
  p_title text, p_amount bigint, p_fund text, p_category_id bigint default null,
  p_expense_date date default null, p_jmonth text default null, p_payment_type text default 'bank',
  p_reference_no text default null, p_project_id bigint default null, p_receipt_path text default null,
  p_description text default null, p_reason text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_cat_type text; v_lock bigint;
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند هزینه را ویرایش کند';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'مبلغ هزینه باید اکیداً مثبت و بزرگتر از صفر باشد';
  end if;
  if p_fund not in ('monthly','construction') then
    raise exception 'صندوق هزینه نامعتبر است (monthly یا construction)';
  end if;
  if p_title is null or btrim(p_title) = '' then
    raise exception 'عنوان هزینه الزامی است';
  end if;
  -- قفل ردیف هزینه + اعتبارسنجی وجود
  select id into v_lock from public.expenses where id = p_id for update;
  if v_lock is null then
    raise exception 'هزینه‌ای با این شناسه وجود ندارد';
  end if;
  if p_category_id is not null then
    select type into v_cat_type from public.expense_categories where id = p_category_id;
    if v_cat_type is null then
      raise exception 'دسته‌ی هزینه‌ی موردنظر وجود ندارد';
    end if;
    if v_cat_type <> 'general' and v_cat_type <> p_fund then
      raise exception 'دسته‌ی انتخابی (%) با صندوق (%) سازگار نیست', v_cat_type, p_fund;
    end if;
  end if;
  if p_project_id is not null then
    if p_fund <> 'construction' then
      raise exception 'هزینه‌ی پروژه‌ی عمرانی فقط از صندوق عمرانی ممکن است';
    end if;
    if not exists(select 1 from public.construction_projects where id = p_project_id) then
      raise exception 'پروژه‌ی عمرانی موردنظر وجود ندارد';
    end if;
  end if;
  -- به‌روزرسانی همه‌ی فیلدها (هیچ فیلدی drop نمی‌شود؛ receipt_url از پارامتر)
  update public.expenses set
    title = p_title, amount = p_amount, fund = p_fund, category_id = p_category_id,
    expense_date = coalesce(p_expense_date, expense_date), jmonth = p_jmonth,
    payment_type = p_payment_type, reference_no = p_reference_no, project_id = p_project_id,
    receipt_url = p_receipt_path, description = p_description
    where id = p_id;
  if not found then
    raise exception 'ویرایش هزینه انجام نشد — رکورد یافت نشد';
  end if;
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('expenses', p_id, 'update', p_reason, v_uid,
      jsonb_build_object('title',p_title,'amount',p_amount,'fund',p_fund,'category_id',p_category_id,'project_id',p_project_id));
  return p_id;
end;
$$;
grant execute on function public.update_expense(bigint, text, bigint, text, bigint, date, text, text, text, bigint, text, text, text) to authenticated;

-- =====================================================================
-- delete_expense — حذف اتمیک + audit
-- =====================================================================
create or replace function public.delete_expense(p_id bigint, p_reason text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_old jsonb; v_lock bigint;
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند هزینه را حذف کند';
  end if;
  select id, to_jsonb(e) into v_lock, v_old from public.expenses e where id = p_id for update;
  if v_lock is null then
    raise exception 'هزینه‌ای با این شناسه وجود ندارد';
  end if;
  delete from public.expenses where id = p_id;
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('expenses', p_id, 'delete', p_reason, v_uid, v_old);
  return true;
end;
$$;
grant execute on function public.delete_expense(bigint, text) to authenticated;

-- =====================================================================
-- save_prior_debt — upsert اتمیک مانده‌ی افتتاحیه + Audit (یک ردیف به ازای هر واحد)
-- =====================================================================
create or replace function public.save_prior_debt(
  p_unit_id bigint, p_monthly_initial bigint default 0, p_construction_initial bigint default 0,
  p_credit_monthly bigint default 0, p_credit_construction bigint default 0,
  p_as_of_date date default null, p_note text default null, p_reason text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_id bigint; v_is_new boolean; v_lock bigint;
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند مانده‌ی افتتاحیه را ثبت کند';
  end if;
  if not exists(select 1 from public.units where id = p_unit_id) then
    raise exception 'واحد موردنظر وجود ندارد';
  end if;
  if coalesce(p_monthly_initial,0) < 0 or coalesce(p_construction_initial,0) < 0
     or coalesce(p_credit_monthly,0) < 0 or coalesce(p_credit_construction,0) < 0 then
    raise exception 'مبالغ مانده نمی‌توانند منفی باشند';
  end if;
  -- قفل ردیف موجود (serialize) — هم‌زمان با upsert
  select id into v_lock from public.prior_debts where unit_id = p_unit_id for update;
  v_is_new := v_lock is null;
  if v_is_new then
    insert into public.prior_debts (unit_id, monthly_initial, construction_initial, credit_monthly, credit_construction, credit_initial, as_of_date, note)
      values (p_unit_id, coalesce(p_monthly_initial,0), coalesce(p_construction_initial,0),
        coalesce(p_credit_monthly,0), coalesce(p_credit_construction,0),
        coalesce(p_credit_monthly,0), coalesce(p_as_of_date,current_date), p_note)
      returning id into v_id;
  else
    v_id := v_lock;
    update public.prior_debts set
      monthly_initial      = coalesce(p_monthly_initial,0),
      construction_initial = coalesce(p_construction_initial,0),
      credit_monthly       = coalesce(p_credit_monthly,0),
      credit_construction  = coalesce(p_credit_construction,0),
      credit_initial       = coalesce(p_credit_monthly,0),
      as_of_date           = coalesce(p_as_of_date, as_of_date),
      note                 = p_note
      where id = v_id;
  end if;
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('prior_debts', v_id, case when v_is_new then 'insert' else 'update' end, p_reason, v_uid,
      jsonb_build_object('unit_id',p_unit_id,'monthly_initial',p_monthly_initial,
        'construction_initial',p_construction_initial,'credit_monthly',p_credit_monthly,
        'credit_construction',p_credit_construction));
  return v_id;
end;
$$;
grant execute on function public.save_prior_debt(bigint, bigint, bigint, bigint, bigint, date, text, text) to authenticated;

-- =====================================================================
-- delete_prior_debt — حذف اتمیک + Audit
-- =====================================================================
create or replace function public.delete_prior_debt(p_unit_id bigint, p_reason text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id bigint; v_old jsonb;
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند مانده‌ی افتتاحیه را حذف کند';
  end if;
  select id, to_jsonb(pd) into v_id, v_old from public.prior_debts pd where unit_id = p_unit_id for update;
  if v_id is null then
    raise exception 'مانده‌ی افتتاحیه‌ای برای این واحد وجود ندارد';
  end if;
  delete from public.prior_debts where id = v_id;
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('prior_debts', v_id, 'delete', p_reason, v_uid, v_old);
  return true;
end;
$$;
grant execute on function public.delete_prior_debt(bigint, text) to authenticated;

-- =====================================================================
-- bulk_charge — صدور گروهی اتمیک + جلوگیری از تکرار + اعتبارسنجی هر ردیف + Audit
-- ---------------------------------------------------------------------
-- p_rows: [{"unit_id":1,"amount_due":500000}, ...]
-- ردیف تکراری (unit_id,jmonth,type) skip می‌شود. ردیف با amount_due<=0 رد می‌شود.
-- همه در یک تراکنش؛ شکست Audit → rollback کل عملیات.
-- =====================================================================
create or replace function public.bulk_charge(
  p_jmonth text, p_type text, p_rows jsonb, p_reason text default null
) returns table(unit_id bigint, charge_id bigint, skipped boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); r jsonb; v_id bigint; v_skipped boolean; v_cnt int := 0;
  v_uid_row bigint; v_amt bigint;
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند شارژ صادر کند';
  end if;
  if p_type not in ('monthly','construction') then
    raise exception 'نوع شارژ نامعتبر است (monthly یا construction)';
  end if;
  if p_jmonth is null or btrim(p_jmonth) = '' then
    raise exception 'ماه شارژ الزامی است';
  end if;
  if p_rows is null or jsonb_array_length(p_rows) = 0 then
    raise exception 'هیچ ردیفی برای صدور شارژ ارائه نشده است';
  end if;
  for r in select * from jsonb_array_elements(p_rows)
  loop
    v_skipped := false;
    v_uid_row := nullif(r->>'unit_id','')::bigint;
    v_amt := nullif(r->>'amount_due','')::bigint;
    if v_uid_row is null then
      raise exception 'یک ردیف بدون unit_id معتبر وجود دارد';
    end if;
    if not exists(select 1 from public.units where id = v_uid_row) then
      raise exception 'واحد % وجود ندارد', v_uid_row;
    end if;
    if v_amt is null or v_amt <= 0 then
      -- مبلغ نامعتبر: به‌جای skip بی‌صدا، skip با علامت‌گذاری (و audit در انتها)
      v_skipped := true; v_id := null;
    elsif exists(select 1 from public.charges where unit_id = v_uid_row and jmonth = p_jmonth and type = p_type) then
      v_skipped := true; v_id := null;
    else
      insert into public.charges (unit_id, jmonth, type, amount_due, created_by)
        values (v_uid_row, p_jmonth, p_type, v_amt, v_uid)
        returning id into v_id;
      v_cnt := v_cnt + 1;
    end if;
    return query select v_uid_row, v_id, v_skipped;
  end loop;
  -- Audit یکپارچه در همان تراکنش
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('charges', 0, 'insert', p_reason, v_uid,
      jsonb_build_object('jmonth',p_jmonth,'type',p_type,'rows',p_rows,'inserted_count',v_cnt));
end;
$$;
grant execute on function public.bulk_charge(text, text, jsonb, text) to authenticated;

-- =====================================================================
-- delete_unit — حذف اتمیک واحد با گارد سابقه‌ی مالی + Audit
-- ---------------------------------------------------------------------
-- اگر واحد شارژ/پرداخت/مانده‌ی افتتاحیه داشته باشد، حذف انجام نمی‌شود (raise).
-- این از از بین رفتن داده‌ی مالی جلوگیری می‌کند.
-- =====================================================================
create or replace function public.delete_unit(p_id bigint, p_reason text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_old jsonb; v_n int; v_lock bigint;
begin
  if not public.is_admin() then
    raise exception 'فقط مدیر می‌تواند واحد را حذف کند';
  end if;
  select id, to_jsonb(u) into v_lock, v_old from public.units u where id = p_id for update;
  if v_lock is null then
    raise exception 'واحد موردنظر وجود ندارد';
  end if;
  select count(*) into v_n from public.charges  where unit_id = p_id;
  if v_n > 0 then raise exception 'این واحد % شارژ ثبت‌شده دارد؛ ابتما آن‌ها را حذف کنید', v_n; end if;
  select count(*) into v_n from public.payments where unit_id = p_id;
  if v_n > 0 then raise exception 'این واحد % پرداخت ثبت‌شده دارد؛ ابتدا آن‌ها را حذف کنید', v_n; end if;
  select count(*) into v_n from public.prior_debts where unit_id = p_id;
  if v_n > 0 then raise exception 'این واحد مانده‌ی افتتاحیه دارد؛ ابتدا آن را حذف کنید'; end if;
  -- حذف وابسته‌ها سپس خود واحد (همه در همان تراکنش)
  delete from public.resident_units where unit_id = p_id;
  delete from public.tenants where unit_id = p_id;
  delete from public.owners  where unit_id = p_id;
  delete from public.units where id = p_id;
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('units', p_id, 'delete', p_reason, v_uid, v_old);
  return true;
end;
$$;
grant execute on function public.delete_unit(bigint, text) to authenticated;

-- =====================================================================
-- save_unit_owner_tenant — ذخیره‌ی اتمیک واحد+مالک+مستاجر + Audit
-- ---------------------------------------------------------------------
-- نکته: همه‌ی ارجاعات unit_id با نام جدول مشخص شده‌اند (owners.unit_id، ...)
-- تا با ستون خروجی تابع (returns table(unit_id,...)) تداخل مبهم نشود.
-- =====================================================================
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
    insert into public.units (number, floor, area)
      values (v_num, nullif(p_unit->>'floor','')::int, nullif(p_unit->>'area','')::numeric)
      returning id into v_unit_id;
    v_is_new := true;
  else
    v_unit_id := (p_unit->>'id')::bigint;
    update public.units set number = v_num,
      floor = nullif(p_unit->>'floor','')::int,
      area  = nullif(p_unit->>'area','')::numeric
      where id = v_unit_id;
    v_is_new := false;
  end if;
  -- owner (یکی به ازای هر واحد)
  select o.id into v_owner_id from public.owners o where o.unit_id = v_unit_id limit 1;
  if v_owner_id is null then
    insert into public.owners (unit_id, name, national_code, phone, email)
      values (v_unit_id, p_owner->>'name',
        nullif(p_owner->>'national_code',''),
        nullif(p_owner->>'phone',''),
        nullif(p_owner->>'email',''))
      returning id into v_owner_id;
  else
    update public.owners set name = p_owner->>'name',
      national_code = nullif(p_owner->>'national_code',''),
      phone = nullif(p_owner->>'phone',''),
      email = nullif(p_owner->>'email','')
      where id = v_owner_id;
  end if;
  -- tenant
  if p_tenant_remove then
    delete from public.tenants where tenants.unit_id = v_unit_id;
    insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
      values ('tenants', v_unit_id, 'delete', 'حذف مستاجر (RPC)', v_uid, jsonb_build_object('unit_id',v_unit_id));
  elsif p_tenant is not null and btrim(coalesce(p_tenant->>'name','')) <> '' then
    select t.id into v_tenant_id from public.tenants t where t.unit_id = v_unit_id limit 1;
    if v_tenant_id is null then
      insert into public.tenants (unit_id, name, phone, lease_start, lease_end)
        values (v_unit_id, p_tenant->>'name', nullif(p_tenant->>'phone',''),
          nullif(p_tenant->>'lease_start','')::date, nullif(p_tenant->>'lease_end','')::date)
        returning id into v_tenant_id;
    else
      update public.tenants set name = p_tenant->>'name', phone = nullif(p_tenant->>'phone',''),
        lease_start = nullif(p_tenant->>'lease_start','')::date, lease_end = nullif(p_tenant->>'lease_end','')::date
        where id = v_tenant_id;
    end if;
  end if;
  -- audit در همان تراکنش
  insert into public.audit_log (table_name, record_id, action, reason, actor, change_data)
    values ('units', v_unit_id, case when v_is_new then 'insert' else 'update' end,
      'ذخیره واحد/مالک/مستاجر (RPC)', v_uid, p_unit);
  return query select v_unit_id, v_owner_id, v_tenant_id;
end;
$$;
grant execute on function public.save_unit_owner_tenant(jsonb, jsonb, jsonb, boolean) to authenticated;

-- =====================================================================
-- unit_finance — لایه‌ی авторیتاتیک محاسبات مالی یک واحد (هم‌گام با JS)
-- ---------------------------------------------------------------------
-- صندوق ماهانه و عمرانی مستقل: اعتبار یک صندوق، بدهی صندوق دیگر را خالص نمی‌کند.
-- total_debt = greatest(0, bal_monthly) + greatest(0, bal_construction).
-- این تابع با b49_accounting.js (unitTotalDebt) منطقاً یکسان است.
-- =====================================================================
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
  bm bigint; bc bigint;
begin
  if not (public.is_admin() or p_unit = any(public.my_unit_ids())) then
    return;
  end if;
  dm  := coalesce((select sum(amount_due)        from public.charges  where unit_id = p_unit and (type = 'monthly'   or type is null)),0);
  dc  := coalesce((select sum(amount_due)        from public.charges  where unit_id = p_unit and  type = 'construction'),0);
  pm  := coalesce((select sum(amount)            from public.payments where unit_id = p_unit and (type = 'monthly'   or type is null)),0);
  pc  := coalesce((select sum(amount)            from public.payments where unit_id = p_unit and  type = 'construction'),0);
  prm := coalesce((select sum(monthly_initial)      from public.prior_debts where unit_id = p_unit),0);
  prc := coalesce((select sum(construction_initial) from public.prior_debts where unit_id = p_unit),0);
  cm  := coalesce((select sum(credit_monthly)       from public.prior_debts where unit_id = p_unit),0);
  cc  := coalesce((select sum(credit_construction)  from public.prior_debts where unit_id = p_unit),0);
  bm  := dm + prm - pm - cm;
  bc  := dc + prc - pc - cc;
  return query select
    dm, dc, pm, pc, prm, prc, cm, cc,
    bm, bc,
    greatest(0, bm) + greatest(0, bc);
end;
$$;
grant execute on function public.unit_finance(bigint) to authenticated;

-- =====================================================================
-- guest_login — ورود مهمان با کد دسترسی واحد (بدون Supabase Auth)
-- ---------------------------------------------------------------------
-- کد را با units.guest_code تطبیق می‌دهد و ردیفِ واحد را برمی‌گرداند.
-- callable توسط anon (مهمان وارد‌نشده) و authenticated.
-- =====================================================================
create or replace function public.guest_login(p_code text)
returns public.units
language plpgsql security definer set search_path = public as $$
declare v_row public.units%rowtype;
begin
  if p_code is null or btrim(p_code) = '' then
    raise exception 'کد دسترسی وارد نشده است';
  end if;
  select * into v_row from public.units where guest_code = p_code and guest_code is not null limit 1;
  if v_row.id is null then
    raise exception 'کد دسترسی اشتباه است یا برای واحد شما کدی تعریف نشده است';
  end if;
  return v_row;
end;
$$;
revoke execute on function public.guest_login(text) from public;
grant execute on function public.guest_login(text) to anon, authenticated;

-- =====================================================================
--  پایان migration v5
--  همه‌ی عملیات مالی اتمیک‌اند (عمل + audit در یک تراکنش، rollback در شکست).
--  قفل‌گذاری FOR UPDATE روی پروژه/پرداخت/هزینه/مانده، رقابت هم‌زمان را serialize می‌کند.
--  اعتبارسنجی: مبلغ>0، fund معتبر، category/project موجود و سازگار، واحد موجود.
--  prior_debts reconciliation فقط برای واحدهای تکراری، با snapshot قابل‌بازیابی.
-- =====================================================================
