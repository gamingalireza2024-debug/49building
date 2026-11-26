// =====================================================================
//  b49_accounting.js — منطق حسابداری ساختمان ۴۹ (ماژول مشترک واقعی)
//  این فایل توسط index.html (مرورگر) و tests/unit/accounting.test.js (Node)
//  به‌طور مشترک استفاده می‌شود. یعنی تست، همان توابع واقعی برنامه را می‌آزماید،
//  نه کپی جداگانه‌ای از آن‌ها را.
//  توابع خالص‌اند: داده را به‌عنوان پارامتر می‌گیرند (cache/projects/...)،
//  به هیچ global وابسته نیستند.
// =====================================================================
(function (root, factory) {
  // UMD: مرورگر → window.B49Acc ؛ Node → module.exports
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.B49Acc = factory();
  }
}(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // ---- مانده‌ی یک واحد (بدهی + پرداخت + مانده افتتاحیه − اعتبار) ----
  // عین منطق index.html (B49.unitBalance) — فقط cache به‌جای B49.cache.
  // مهم: cache ناقص (بدون charges/payments/prior) نباید باعث صفرشدن
  // اطلاعات افتتاحیه یا پرداخت‌ها شود. هر آرایه به‌صورت جداگانه guard می‌شود
  // و early-return حذف شده: حتی اگر charges خالی باشد، prior/paid محاسبه می‌شوند.
  function unitBalance(cache, uid, fund) {
    cache = cache || {};
    // Bug B (فیکس): اگر fund مشخص نیست، هرگز تهاتر میان صندوق‌ها نکن.
    // مجموع بدهی غیرتهاتری = max(0, مانده_ماهانه) + max(0, مانده_عمرانی).
    // (پیش‌تر bal = due+prior−paid−credit روی هر دو صندوق تهاتر می‌کرد.)
    if (!fund) {
      const m = unitBalance(cache, uid, 'monthly');
      const c = unitBalance(cache, uid, 'construction');
      return { due: m.due + c.due, paid: m.paid + c.paid, prior: m.prior + c.prior, credit: m.credit + c.credit, bal: Math.max(0, m.bal) + Math.max(0, c.bal) };
    }
    const charges = cache.charges || [];
    const payments = cache.payments || [];
    const priorArr = cache.prior || [];
    const cf = c => c.unit_id === uid && (fund ? ((c.type || 'monthly') === fund) : true);
    const pf = p => p.unit_id === uid && (fund ? ((p.type || 'monthly') === fund) : true);
    const due = charges.filter(cf).reduce((s, c) => s + Number(c.amount_due || 0), 0);
    const paid = payments.filter(pf).reduce((s, p) => s + Number(p.amount || 0), 0);
    const pd = priorArr.filter(d => d.unit_id === uid);
    const prior = pd.reduce((s, d) => {
      if (fund === 'monthly') return s + Number(d.monthly_initial || 0);
      if (fund === 'construction') return s + Number(d.construction_initial || 0);
      return s + Number(d.monthly_initial || 0) + Number(d.construction_initial || 0);
    }, 0);
    const credit = pd.reduce((s, d) => {
      if (fund === 'monthly') return s + Number(d.credit_monthly || 0);
      if (fund === 'construction') return s + Number(d.credit_construction || 0);
      return s + Number(d.credit_monthly || 0) + Number(d.credit_construction || 0);
    }, 0);
    return { due, paid, prior, credit, bal: due + prior - paid - credit };
  }

  // ---- مجموع بدهی یک واحد (مستقل‌سازی دو صندوق — بدون تهاتر) ----
  // صندوق ماهانه و عمرانی کاملاً مستقل‌اند: اعتبار (overpayment) یک صندوق
  // هرگز بدهی صندوق دیگر را خالص نمی‌کند. هر صندوق در صفر floor می‌شود
  // (اعتبار منفی نشان داده نمی‌شود، فقط بدهی مثبت محاسبه می‌شود).
  // نتیجه = max(0, مانده_ماهانه) + max(0, مانده_عمرانی).
  // این تابع برای تمام محل‌های «مجموع بدهی» / «بدهکار یا تسویه» / داشبورد
  // و گزارش بدهکاران استفاده می‌شود (به‌جای unitBalance با fund=null که net می‌کرد).
  function unitTotalDebt(cache, uid) {
    const m = unitBalance(cache, uid, 'monthly').bal;
    const c = unitBalance(cache, uid, 'construction').bal;
    return Math.max(0, m) + Math.max(0, c);
  }

  // ---- درآمد/هزینه/افتتاحیه/مانده‌ی یک صندوق ----
  function fundIncome(cache, fund) {
    return (cache.payments || []).filter(p => (p.type || 'monthly') === fund).reduce((s, p) => s + Number(p.amount || 0), 0);
  }
  function fundExpense(cache, fund) {
    // Bug A (فیکس): fallback-chain مثل fundIncome تا هزینه با فیلد type یا fund یا پیش‌فرض monthly درست شمرده شود.
    return (cache.expenses || []).filter(e => (e.fund || e.type || 'monthly') === fund).reduce((s, e) => s + Number(e.amount || 0), 0);
  }
  function fundOpening(cache, fund) {
    const s = cache.settings || {};
    return Number(fund === 'monthly' ? s.fund_monthly_opening : fund === 'construction' ? s.fund_construction_opening : 0) || 0;
  }
  function fundBalance(cache, fund) {
    return fundOpening(cache, fund) + fundIncome(cache, fund) - fundExpense(cache, fund);
  }

  // ---- توزیع شارژ: مساوی (با توزیع باقی‌مانده) ----
  // استفاده‌شده در bulkCharge حالت area وقتی مجموع متراژ صفر است (fallback).
  function distributeEqual(amt, n) {
    amt = Number(amt) || 0; n = Math.max(1, Number(n) || 0);
    const base = Math.floor(amt / n), rem = amt - base * n;
    return Array.from({ length: n }, (_, i) => base + (i < rem ? 1 : 0));
  }

  // ---- توزیع شارژ: بر اساس متراژ (با کنترل گردکردن و توزیع باقی‌مانده) ----
  // عین منطق bulkCharge حالت area در index.html.
  function distributeByArea(amt, pending) {
    amt = Number(amt) || 0;
    pending = (pending || []).slice();
    const total = pending.reduce((s, u) => s + Number(u.area || 0), 0);
    if (total <= 0) return distributeEqual(amt, pending.length);
    let allocated = 0;
    const shares = pending.map(u => {
      const s = Math.round(amt * (Number(u.area || 0) / total));
      allocated += s; return s;
    });
    let diff = amt - allocated; // می‌تواند مثبت یا منفی باشد
    for (let i = 0; i < pending.length && diff !== 0; i++) {
      shares[i] += diff > 0 ? 1 : -1; diff += diff > 0 ? -1 : 1;
    }
    return shares;
  }

  // ---- گزارش مالی پروژه‌ی عمرانی ----
  // عین منطق صفحه‌ی گزارش‌ها در index.html (وصول/باقی/هزینه/مانده نقدی/پیشرفت).
  function projectReport(projects, charges, payments, expenses) {
    return (projects || []).map(p => {
      const issued = (charges || []).filter(c => c.project_id === p.id && c.type === 'construction')
        .reduce((s, c) => s + Number(c.amount_due || 0), 0);
      // Bug C (فیکس): وصول پروژه فقط پرداخت‌های عمرانی را بشمار؛ پرداخت ماهانه با project_id سرگردان تهاتر نمی‌شود.
      // پیش‌فرض پرداختِ دارای project_id = construction (مگر type صریحاً monthly باشد).
      const collected = (payments || []).filter(pay => pay.project_id === p.id && (pay.type || 'construction') === 'construction')
        .reduce((s, pay) => s + Number(pay.amount || 0), 0);
      // Bug D (فیکس): هزینه‌ی پروژه فقط هزینه‌های عمرانی را بشمار (پیش‌فرض construction برای هزینه‌ی دارای project_id).
      const exp = (expenses || []).filter(e => e.project_id === p.id && (e.fund || e.type || 'construction') === 'construction')
        .reduce((s, e) => s + Number(e.amount || 0), 0);
      // Bug E (فیکس): overpayment به‌جای remaining منفی، در فیلد credit جدا دیده شود.
      const overpay = Math.max(0, collected - issued);
      return {
        name: p.name, budget: p.budget_approved, issued, collected,
        remaining: Math.max(0, issued - collected), credit: overpay, exp,
        cash: collected - exp,
        progress: issued > 0 ? Math.round(collected / issued * 100)
          : (Number(p.budget_approved) > 0 ? Math.round(exp / Number(p.budget_approved) * 100) : 0),
        // Bug F (فیکس): دو معیار جدا برای وصول و اجرا.
        collection_progress: issued > 0 ? Math.round(collected / issued * 100) : 0,
        execution_progress: Number(p.budget_approved) > 0 ? Math.round(exp / Number(p.budget_approved) * 100) : 0
      };
    });
  }

  // ---- گردش تجمعی حساب (logic مشترک واقعی) ----
  // ردیف‌ها را بر اساس تاریخ مرتب می‌کند و برای هر صندوق یک عدادار تجمعی
  // (run) محاسبه می‌کند. عین منطق انتهای B49.unitLedgerRows در index.html.
  // ورودی: rows = [{date, fundKey:'monthly'|'construction', debit, credit, ...}]
  // خروجی: همان rows با فیلد run اضافه‌شده، مرتب‌شده بر اساس تاریخ.
  function runningBalance(rows) {
    rows = (rows || []).slice();
    // Bug H (فیکس): تاریخ نامعتبر → Infinity (ته ردیف) به‌جای NaN که ترتیب را نامعین می‌کرد.
    const t = d => { const x = new Date(d).getTime(); return isNaN(x) ? Infinity : x; };
    rows.sort((a, b) => t(a.date) - t(b.date));
    let runM = 0, runC = 0;
    rows.forEach(r => {
      // Bug G (فیکس): فقط fundKey‌های معتبر به عدادار اضافه شوند؛ ردیف نامعتبر آلودگی نمی‌کند.
      if (r.fundKey === 'monthly') { runM += Number(r.debit || 0) - Number(r.credit || 0); r.run = runM; }
      else if (r.fundKey === 'construction') { runC += Number(r.debit || 0) - Number(r.credit || 0); r.run = runC; }
      else { r.run = null; }
    });
    return rows;
  }

  // ---- ساخت ردیف‌های دفتر کل یک واحد (هسته‌ی حسابداری، بدون نمایش) ----
  // عین منطق B49.unitLedgerRows در index.html برای بخش مالی (تاریخ/صندوق/بدهکار/بستانکار).
  // تاریخ شارژ از created_at، پرداخت از payment_date، مانده از as_of_date.
  function buildLedgerRows(cache, uid) {
    cache = cache || {};
    const rows = [];
    (cache.prior || []).filter(d => d.unit_id === uid).forEach(d => {
      if (d.monthly_initial) rows.push({ date: d.as_of_date, fundKey: 'monthly', debit: Number(d.monthly_initial), credit: 0 });
      if (d.construction_initial) rows.push({ date: d.as_of_date, fundKey: 'construction', debit: Number(d.construction_initial), credit: 0 });
      if (d.credit_monthly) rows.push({ date: d.as_of_date, fundKey: 'monthly', debit: 0, credit: Number(d.credit_monthly) });
      if (d.credit_construction) rows.push({ date: d.as_of_date, fundKey: 'construction', debit: 0, credit: Number(d.credit_construction) });
    });
    (cache.charges || []).filter(c => c.unit_id === uid).forEach(c => {
      rows.push({ date: c.created_at || '2024-10-01', fundKey: (c.type || 'monthly'), debit: Number(c.amount_due || 0), credit: 0 });
    });
    (cache.payments || []).filter(p => p.unit_id === uid).forEach(p => {
      // Bug H (فیکس): fallback تاریخ برای payment_date خالی تا عدادار تجمعی به‌هم نریزد.
      rows.push({ date: p.payment_date || p.created_at || '2024-10-01', fundKey: (p.type || 'monthly'), debit: 0, credit: Number(p.amount || 0) });
    });
    return runningBalance(rows);
  }

  // ---- شبیه‌سازی اتمیک بودن: عمل + audit در یک واحد، rollback در صورت شکست ----
  // این تابع قراردادِ RPCهای اتمیک برنامه را در JS شبیه می‌کند تا تست بتواند
  // رفتار rollback (شکست audit → برگرداندن عمل اصلی) را راستی‌آزمایی کند.
  // commit(op, audit): op() را اجرا می‌کند؛ اگر audit() خطا دهد، op.undo() را
  // صدا می‌زند و خطا را بازمی‌گرداند (مثل raise در plpgsql → rollback).
  function commit(op, audit) {
    const ctx = op();
    try {
      audit(ctx);
    } catch (e) {
      // Bug J (فیکس): اگر undo هم خطا دهد، دلیل اصلی audit پوشانده نشود.
      if (typeof op.undo === 'function') { try { op.undo(ctx); } catch (u) { console.error('[B49Acc] undo هم شکست خورد:', u); } }
      throw e;
    }
    return ctx;
  }

  return {
    unitBalance, unitTotalDebt, fundIncome, fundExpense, fundOpening, fundBalance,
    distributeEqual, distributeByArea, projectReport,
    runningBalance, buildLedgerRows, commit
  };
}));
