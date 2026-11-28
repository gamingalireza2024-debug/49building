-- =====================================================================
--  ساختمان ۴۹ — verify_integrity.sql
--  اسکریپت واحد اعتبارسنجی یکپارچگی حسابداری پس از migration_v5.
--  اجرا در Supabase SQL Editor (read-only؛ هیچ تغییری نمی‌دهد).
--  خروجی: چند SELECT گزارش‌محور که باید با هم تطبیق داشته باشند.
-- =====================================================================

-- ---------------------------------------------------------------------
-- ۱) موجودی صندوق‌ها (ماندۀ نقدی = افتتاحیه + وصول واقعی − هزینه‌ی واقعی)
--    opening فقط یک‌بار از settings خوانده می‌شود (بدون double-count).
-- ---------------------------------------------------------------------
select 'صندوق ماهانه'   as fund,
       coalesce((select fund_monthly_opening     from public.building_settings limit 1),0)      as opening,
       coalesce(sum(amount) filter (where type='monthly'),0)                                     as income,
       coalesce(sum(amount) filter (where fund='monthly'),0)                                     as expense,
       coalesce((select fund_monthly_opening     from public.building_settings limit 1),0)
         + coalesce(sum(amount) filter (where type='monthly'),0)
         - coalesce(sum(amount) filter (where fund='monthly'),0)                                  as cash_balance
from public.payments, public.expenses
union all
select 'صندوق عمرانی',
       coalesce((select fund_construction_opening from public.building_settings limit 1),0),
       coalesce(sum(amount) filter (where type='construction'),0),
       coalesce(sum(amount) filter (where fund='construction'),0),
       coalesce((select fund_construction_opening from public.building_settings limit 1),0)
         + coalesce(sum(amount) filter (where type='construction'),0)
         - coalesce(sum(amount) filter (where fund='construction'),0)
from public.payments, public.expenses;

-- ---------------------------------------------------------------------
-- ۲) مطالبات از واحدها (Σ بدهی مستقل دو صندوق — بدون تهاتر)
--    هر صندوق در صفر floor می‌شود: greatest(0, bal).
-- ---------------------------------------------------------------------
select
  coalesce(sum(greatest(0, due_m  + prior_monthly     - paid_m  - credit_monthly)),0)     as receivable_monthly,
  coalesce(sum(greatest(0, due_c  + prior_construction - paid_c  - credit_construction)),0) as receivable_construction,
  coalesce(sum(greatest(0, due_m  + prior_monthly     - paid_m  - credit_monthly)
                + greatest(0, due_c + prior_construction - paid_c  - credit_construction)),0) as receivable_total
from (
  select
    coalesce((select sum(amount_due) from public.charges  c where c.unit_id=u.id and c.type='monthly'),0)     as due_m,
    coalesce((select sum(amount_due) from public.charges  c where c.unit_id=u.id and c.type='construction'),0) as due_c,
    coalesce((select sum(amount)     from public.payments p where p.unit_id=u.id and p.type='monthly'),0)      as paid_m,
    coalesce((select sum(amount)     from public.payments p where p.unit_id=u.id and p.type='construction'),0) as paid_c,
    coalesce((select sum(monthly_initial)      from public.prior_debts pd where pd.unit_id=u.id),0) as prior_monthly,
    coalesce((select sum(construction_initial) from public.prior_debts pd where pd.unit_id=u.id),0) as prior_construction,
    coalesce((select sum(credit_monthly)       from public.prior_debts pd where pd.unit_id=u.id),0) as credit_monthly,
    coalesce((select sum(credit_construction)  from public.prior_debts pd where pd.unit_id=u.id),0) as credit_construction
  from public.units u
) x;

-- ---------------------------------------------------------------------
-- ۳) prior_debts — یک ردیف به ازای هر واحد (پس از reconciliation)
-- ---------------------------------------------------------------------
select
  (select count(*) from public.prior_debts)                              as prior_rows,
  (select count(distinct unit_id) from public.prior_debts where unit_id is not null) as distinct_units,
  (select count(*) from public.prior_debts_reconciled_v5)                as reconciled_units,
  coalesce(sum(monthly_initial),0)       as total_prior_monthly,
  coalesce(sum(construction_initial),0)  as total_prior_construction,
  coalesce(sum(credit_monthly),0)        as total_credit_monthly,
  coalesce(sum(credit_construction),0)   as total_credit_construction
from public.prior_debts;

-- ---------------------------------------------------------------------
-- ۴) snapshot reconciliation (قبل/بعد برای واحدهای اصلاح‌شده)
-- ---------------------------------------------------------------------
select unit_id,
       before_monthly, after_monthly,
       before_construction, after_construction,
       before_credit_monthly, after_credit_monthly,
       before_credit_construction, after_credit_construction,
       reconciled_at
from public.prior_debts_reconciled_v5
order by unit_id;

-- ---------------------------------------------------------------------
-- ۵) پروژه‌های عمرانی — وصول/صادرشده/باقی/هزینه/ماندۀ نقدی (جدایی cash از receivable)
--    وصول فقط پرداخت‌های عمرانی متصل به پروژه را می‌شمارد.
-- ---------------------------------------------------------------------
select
  p.id, p.name, p.budget_approved,
  coalesce((select sum(amount_due) from public.charges  c  where c.project_id=p.id  and c.type='construction'),0)  as issued,
  coalesce((select sum(amount)     from public.payments py where py.project_id=p.id and py.type='construction'),0) as collected,
  coalesce((select sum(amount)     from public.expenses e  where e.project_id=p.id  and e.fund='construction'),0)  as expense,
  greatest(0, coalesce((select sum(amount_due) from public.charges c where c.project_id=p.id and c.type='construction'),0)
            - coalesce((select sum(amount) from public.payments py where py.project_id=p.id and py.type='construction'),0)) as remaining_receivable,
  coalesce((select sum(amount) from public.payments py where py.project_id=p.id and py.type='construction'),0)
    - coalesce((select sum(amount) from public.expenses e where e.project_id=p.id and e.fund='construction'),0)        as cash_position
from public.construction_projects p
order by p.id;

-- ---------------------------------------------------------------------
-- ۶) بررسی صحت: آیا پرداخت ماهانه‌ای به پروژه وصل شده؟ (نباید هیچ‌کدام باشد)
--    هر ردیف = نقض ایزولاسیون (Phase 3). انتظار: خروجی خالی.
-- ---------------------------------------------------------------------
select id, unit_id, type, project_id, amount
from public.payments
where type = 'monthly' and project_id is not null;

-- ---------------------------------------------------------------------
-- ۷) بررسی صحت: آیا هزینه‌ی ماهانه‌ای به پروژه وصل شده؟ (نباید هیچ‌کدام باشد)
--    انتظار: خروجی خالی.
-- ---------------------------------------------------------------------
select id, title, fund, project_id, amount
from public.expenses
where fund = 'monthly' and project_id is not null;

-- ---------------------------------------------------------------------
-- ۸) توزیع وصول پروژه‌ها نباید از شارژ صادرشده بیشتر شود (مگر credit مازاد)
--    انتظار: خروجی خالی (یعنی هیچ پروژه‌ای over-collected بدون reason نیست).
-- ---------------------------------------------------------------------
with proj as (
  select p.id,
    coalesce((select sum(amount_due) from public.charges  c  where c.project_id=p.id  and c.type='construction'),0)  as issued,
    coalesce((select sum(amount)     from public.payments py where py.project_id=p.id and py.type='construction'),0) as collected
  from public.construction_projects p
)
select id, issued, collected
from proj
where collected > issued;

-- ---------------------------------------------------------------------
-- ۹) ستون guest_code روی units + واحدهایی که کد دارند
-- ---------------------------------------------------------------------
select
  (select count(*) from public.units)                              as total_units,
  (select count(*) from public.units where guest_code is not null) as units_with_guest_code;

-- ---------------------------------------------------------------------
-- ۱۰) تابع‌های کلیدی موجودند؟ (قرارداد Phase 1)
-- ---------------------------------------------------------------------
select proname as rpc
from pg_proc
where proname in ('record_payment','update_payment','delete_payment','record_expense','update_expense',
                  'delete_expense','bulk_charge','save_prior_debt','delete_prior_debt','delete_unit',
                  'save_unit_owner_tenant','guest_login','record_audit','unit_finance')
order by proname;
