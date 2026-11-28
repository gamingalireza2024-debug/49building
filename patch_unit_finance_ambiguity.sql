-- =====================================================================
--  پچ رفع ابهام OUT-param در unit_finance و bulk_charge
--  -------------------------------------------------------------------
--  علت: در توابعِ returns table(...)، نام ستون‌های خروجی به‌عنوان متغیر
--  PL/pgSQL درمی‌آیند و با ستون‌های هم‌نام جدول مبهم (42702) می‌شوند.
--  راه‌حل: همه‌ی ارجاعات ستونی با alias جدول صریح شده‌اند.
--  این پچ فقط همین دو تابع را drop+recreate می‌کند (بقیه‌ی v5 دست‌نخورده).
--  پیش‌نیاز: migration_v5_integrity.sql قبلاً اجرا شده باشد.
-- =====================================================================
begin;

drop function if exists public.unit_finance(bigint);
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
  -- ⚠ نام ستون‌های خروجی (credit_monthly/credit_construction و …) در PL/pgSQL
  --    به‌عنوان متغیر OUT درمی‌آیند و با ستون‌های هم‌نام جدول مبهم می‌شوند؛
  --    لذا همه‌ی ارجاعات ستونی را با alias جدول (c/p/pd) صریح می‌کنیم.
  dm  := coalesce((select sum(c.amount_due)            from public.charges  c where c.unit_id = p_unit and (c.type = 'monthly'   or c.type is null)),0);
  dc  := coalesce((select sum(c.amount_due)            from public.charges  c where c.unit_id = p_unit and  c.type = 'construction'),0);
  pm  := coalesce((select sum(p.amount)                from public.payments p where p.unit_id = p_unit and (p.type = 'monthly'   or p.type is null)),0);
  pc  := coalesce((select sum(p.amount)                from public.payments p where p.unit_id = p_unit and  p.type = 'construction'),0);
  prm := coalesce((select sum(pd.monthly_initial)      from public.prior_debts pd where pd.unit_id = p_unit),0);
  prc := coalesce((select sum(pd.construction_initial) from public.prior_debts pd where pd.unit_id = p_unit),0);
  cm  := coalesce((select sum(pd.credit_monthly)       from public.prior_debts pd where pd.unit_id = p_unit),0);
  cc  := coalesce((select sum(pd.credit_construction)  from public.prior_debts pd where pd.unit_id = p_unit),0);
  bm  := dm + prm - pm - cm;
  bc  := dc + prc - pc - cc;
  return query select
    dm, dc, pm, pc, prm, prc, cm, cc,
    bm, bc,
    greatest(0, bm) + greatest(0, bc);
end;
$$;
grant execute on function public.unit_finance(bigint) to authenticated;

drop function if exists public.bulk_charge(text, text, jsonb, text);
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
    elsif exists(select 1 from public.charges c where c.unit_id = v_uid_row and c.jmonth = p_jmonth and c.type = p_type) then
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

commit;
