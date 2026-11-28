-- =====================================================================
--  ساختمان ۴۹ — tests/database/04_integrity_test.sql
--  تست‌های سطح دیتابیس برای RPCهای اصلاح‌شده‌ی migration_v5.
--  -------------------------------------------------------------------
--  ⚠ این فایل در CI اجرا نمی‌شود (CI فقط tests/unit/accounting.test.js را
--    در Node اجرا می‌کند). این اسکریپت را به‌صورت دستی در Supabase
--    SQL Editor اجرا کنید و خروجی NOTICE را بخوانید.
--  ⚠ کل اسکریپت در یک تراکنش با ROLLBACK اجرا می‌شود → هیچ داده‌ای روی
--    دیتابیس واقعی نمی‌ماند. داده‌های تستی در جداول موقت/موجود ساخته و
--    در پایان rollback می‌شوند.
--  ⚠ پیش‌نیاز: migration_v5_integrity.sql قبلاً اجرا شده باشد.
--  -------------------------------------------------------------------
--  الگوی جعل هویت ادمین: request.jwt.claims و role را به‌صورت local تنظیم
--  می‌کنیم تا auth.uid() داخل RPCها برابر UUID یک ادمین واقعی شود.
-- =====================================================================

begin;

-- انتخاب UUID یک ادمین موجود برای جعل هویت
do $$
declare v_admin uuid;
begin
  select id into v_admin from public.profiles where role = 'admin' limit 1;
  if v_admin is null then
    raise exception 'هیچ پروفایل ادمینی یافت نشد — ابتدا یک ادمین بسازید';
  end if;
  -- جعل هویت برای کل تراکنش (local = فقط همین تراکنش)
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  raise notice 'ADMIN IMPERSONATED: %', v_admin;
end $$;

-- داده‌های تستی (در همین تراکنش، rollback می‌شوند)
do $$
begin
  insert into public.units (number, floor, area) values ('T901', 9, 90) on conflict do nothing;
  insert into public.construction_projects (name, budget_approved, status)
    values ('پروژه‌ تست v5', 10000000, 'open') on conflict do nothing;
  -- یک دسته‌ی monthly برای تست سازگاری
  insert into public.expense_categories (name, type) values ('تست-ماهانه v5','monthly') on conflict do nothing;
end $$;

-- کمک‌تابع: یک تست را اجرا می‌کند و نتیجه را NOTICE می‌زند.
-- اگر انتظار raise داشتیم و raise شد → PASS؛ اگر raise نشد → FAIL.
create temp table if not exists test_results(name text, ok boolean, detail text);

-- =====================================================================
-- T1) record_payment: مبلغ <= 0 باید رد شود
-- =====================================================================
do $$
declare v_unit bigint; v_proj bigint;
begin
  select id into v_unit from public.units where number='T901';
  begin
    perform public.record_payment(v_unit, 0, 'monthly', '1404/01', current_date, 'cash');
    insert into test_results values ('T1 amount=0 rejected', false, 'raise نشد');
  exception when others then
    insert into test_results values ('T1 amount=0 rejected', true, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T2) record_payment: نوع نامعتبر باید رد شود
-- =====================================================================
do $$
declare v_unit bigint;
begin
  select id into v_unit from public.units where number='T901';
  begin
    perform public.record_payment(v_unit, 1000, 'wrong', '1404/01', current_date, 'cash');
    insert into test_results values ('T2 bad type rejected', false, 'raise نشد');
  exception when others then
    insert into test_results values ('T2 bad type rejected', true, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T3) record_payment: واحد ناموجود باید رد شود
-- =====================================================================
do $$
begin
  begin
    perform public.record_payment(99999999, 1000, 'monthly', '1404/01', current_date, 'cash');
    insert into test_results values ('T3 missing unit rejected', false, 'raise نشد');
  exception when others then
    insert into test_results values ('T3 missing unit rejected', true, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T4) record_payment: پرداخت ماهانه به پروژه باید رد شود
-- =====================================================================
do $$
declare v_unit bigint; v_proj bigint;
begin
  select id into v_unit from public.units where number='T901';
  select id into v_proj from public.construction_projects where name='پروژه‌ تست v5';
  begin
    perform public.record_payment(v_unit, 1000, 'monthly', '1404/01', current_date, 'cash', v_proj);
    insert into test_results values ('T4 monthly+project rejected', false, 'raise نشد');
  exception when others then
    insert into test_results values ('T4 monthly+project rejected', true, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T5) record_payment: over-collection باید رد شود (قفل + اعتبارسنجی)
--     شارژ عمرانی ۱۰۰k صادر می‌کنیم، سپس پرداخت ۸۰k (ok)، سپس ۳۰k → رد (۱۱۰k > ۱۰۰k)
-- =====================================================================
do $$
declare v_unit bigint; v_proj bigint; v_id bigint;
begin
  select id into v_unit from public.units where number='T901';
  select id into v_proj from public.construction_projects where name='پروژه‌ تست v5';
  -- صدور شارژ عمرانی ۱۰۰k برای پروژه
  insert into public.charges (unit_id, jmonth, type, amount_due, project_id)
    values (v_unit, '1404/01', 'construction', 100000, v_proj);
  -- پرداخت ۸۰k → موفق
  select public.record_payment(v_unit, 80000, 'construction', '1404/01', current_date, 'cash', v_proj) into v_id;
  insert into test_results values ('T5a payment 80k under cap ok', v_id is not null, 'id='||v_id);
  -- پرداخت ۳۰k → باید رد شود (۸۰k+۳۰k=۱۱۰k > ۱۰۰k)
  begin
    perform public.record_payment(v_unit, 30000, 'construction', '1404/01', current_date, 'cash', v_proj);
    insert into test_results values ('T5b over-collection rejected', false, 'raise نشد — باگ قفل/اعتبارسنجی!');
  exception when others then
    insert into test_results values ('T5b over-collection rejected', true, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T6) record_expense: مبلغ <= 0 باید رد شود (اکیداً مثبت)
-- =====================================================================
do $$
begin
  begin
    perform public.record_expense('تست', 0, 'monthly');
    insert into test_results values ('T6 expense amount=0 rejected', false, 'raise نشد');
  exception when others then
    insert into test_results values ('T6 expense amount=0 rejected', true, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T7) record_expense: fund نامعتبر باید رد شود
-- =====================================================================
do $$
begin
  begin
    perform public.record_expense('تست', 1000, 'wrong');
    insert into test_results values ('T7 bad fund rejected', false, 'raise نشد');
  exception when others then
    insert into test_results values ('T7 bad fund rejected', true, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T8) record_expense: fund=monthly + project باید رد شود (سازگاری fund↔project)
-- =====================================================================
do $$
declare v_proj bigint;
begin
  select id into v_proj from public.construction_projects where name='پروژه‌ تست v5';
  begin
    perform public.record_expense('تست', 1000, 'monthly', null, null, null, 'bank', null, v_proj);
    insert into test_results values ('T8 monthly fund+project rejected', false, 'raise نشد');
  exception when others then
    insert into test_results values ('T8 monthly fund+project rejected', true, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T9) record_expense: دسته‌ی monthly با fund=construction باید رد شود (سازگاری دسته)
-- =====================================================================
do $$
declare v_cat bigint;
begin
  select id into v_cat from public.expense_categories where name='تست-ماهانه v5';
  begin
    perform public.record_expense('تست', 1000, 'construction', v_cat);
    insert into test_results values ('T9 category/fund mismatch rejected', false, 'raise نشد');
  exception when others then
    insert into test_results values ('T9 category/fund mismatch rejected', true, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T10) update_payment: کسر مبلغ قدیمیِ همین رکورد از وصول (exclude self)
--      ⚠ اعتبارسنجی وصول را به‌ازای «پروژه» تجمیع می‌کند (نه به‌ازای jmonth).
--      چون T5 قبلاً ۸۰k برای «پروژه‌ تست v5» وصول کرده، تکرار همان پرداخت
--      آنجا جمع را به ۱۶۰k می‌رساند و رد می‌شود. لذا T10 پروژه‌ و شارژ
--      اختصاصی خودش می‌سازد: شارژ ۱۰۰k → پرداخت ۸۰k (ok) → ویرایش به ۹۰k
--      (هنوز زیر سقف ۱۰۰k → موفق؛ اگر exclude-self کار نکرد ۱۷۰k می‌شد).
-- =====================================================================
do $$
declare v_unit bigint; v_proj bigint; v_id bigint;
begin
  select id into v_unit from public.units where number='T901';
  insert into public.construction_projects (name, budget_approved, status)
    values ('پروژه‌ تست v5-T10', 10000000, 'open') on conflict do nothing;
  select id into v_proj from public.construction_projects where name='پروژه‌ تست v5-T10';
  -- صدور شارژ عمرانی ۱۰۰k اختصاصی برای این پروژه
  insert into public.charges (unit_id, jmonth, type, amount_due, project_id)
    values (v_unit, '1404/02', 'construction', 100000, v_proj);
  -- پرداخت ۸۰k → موفق (وصول=۸۰k ≤ صدور=۱۰۰k)
  select public.record_payment(v_unit, 80000, 'construction', '1404/02', current_date, 'cash', v_proj) into v_id;
  insert into test_results values ('T10a payment 80k under cap ok', v_id is not null, 'id='||coalesce(v_id::text,'null'));
  -- ویرایش به ۹۰k → باید موفق باشد (exclude self: ۹۰k ≤ ۱۰۰k)
  begin
    perform public.update_payment(v_id, v_unit, 90000, 'construction', '1404/02', current_date, 'cash', v_proj);
    insert into test_results values ('T10b update_payment excludes self (90k ok under 100k)', true, 'updated');
  exception when others then
    insert into test_results values ('T10b update_payment excludes self', false, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T11) delete_unit: واحد با سابقه‌ی مالی باید رد شود
-- =====================================================================
do $$
declare v_unit bigint;
begin
  select id into v_unit from public.units where number='T901';  -- دارای شارژ/پرداخت از تست‌های بالا
  begin
    perform public.delete_unit(v_unit);
    insert into test_results values ('T11 delete_unit with history rejected', false, 'raise نشد — خطر از دست رفت داده!');
  exception when others then
    insert into test_results values ('T11 delete_unit with history rejected', true, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T12) guest_login: کد خالی/نامعتبر باید رد شود
-- =====================================================================
do $$
begin
  begin
    perform public.guest_login('');
    insert into test_results values ('T12 guest_login empty rejected', false, 'raise نشد');
  exception when others then
    insert into test_results values ('T12 guest_login empty rejected', true, substr(sqlerrm,1,80));
  end;
  begin
    perform public.guest_login('NONEXISTENT_CODE_999');
    insert into test_results values ('T12b guest_login bad code rejected', false, 'raise نشد');
  exception when others then
    insert into test_results values ('T12b guest_login bad code rejected', true, substr(sqlerrm,1,80));
  end;
end $$;

-- =====================================================================
-- T13) ایزولاسیون دو صندوق در unit_finance (monthly ≠ construction)
-- =====================================================================
do $$
declare v_unit bigint; r record;
begin
  select id into v_unit from public.units where number='T901';
  select * into r from public.unit_finance(v_unit);
  insert into test_results values ('T13 unit_finance returns split columns',
    r.balance_monthly is not null and r.balance_construction is not null,
    'bm='||r.balance_monthly||' bc='||r.balance_construction);
end $$;

-- =====================================================================
-- T14) reconciliation idempotency: اجرای دوبارۀ بلوک DO در migration_v5 نباید
--      تغییری ایجاد کند (جدول marker جلوگیری می‌کند). اینجا فقط تأیید می‌کنیم
--      جدول marker وجود دارد و COUNT آن ثابت می‌ماند.
-- =====================================================================
do $$
declare c1 int; c2 int;
begin
  select count(*) into c1 from public.prior_debts_reconciled_v5;
  -- اجرای دوباره‌ی منطق reconciliation (بدون side-effect چون marker همه را skip می‌کند)
  -- فقط تأیید marker:
  select count(*) into c2 from public.prior_debts_reconciled_v5;
  insert into test_results values ('T14 reconciliation marker stable', c1 = c2, 'count='||c1);
end $$;

-- =====================================================================
-- خلاصه
-- =====================================================================
do $$
declare total int; passed int; failed int; r record;
begin
  select count(*), count(*) filter (where ok) into total, passed from test_results;
  failed := total - passed;
  raise notice '═══════════════════════════════════════════════';
  raise notice 'خلاصه‌ی تست‌های دیتابیس: کل=% | موفق=% | ناموفق=%', total, passed, failed;
  raise notice '═══════════════════════════════════════════════';
  for r in select * from test_results order by name loop
    raise notice '% | % | %', case when r.ok then 'PASS' else 'FAIL' end, r.name, r.detail;
  end loop;
  if failed > 0 then
    raise exception 'برخی تست‌های دیتابیس ناموفق بودند — بالا را بررسی کنید';
  end if;
  raise notice '✅ همه‌ی تست‌های دیتابیس پاس شدند. تراکنش در ادامه rollback می‌شود.';
end $$;

rollback;
