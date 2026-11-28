// =====================================================================
//  b49_accounting.js — منطق حسابداری ساختمان ۴۹ (ماژول مشترک واقعی)
//  این فایل توسط index.html (مرورگر) و tests/unit/accounting.test.js (Node)
//  به‌طور مشترک استفاده می‌شود. یعنی تست، همان توابع واقعی برنامه را می‌آزماید،
//  نه کپی جداگانه‌ای از آن‌ها را.
//  توابع خالص‌اند: داده را به‌عنوان پارامتر می‌گیرند (cache/projects/...)،
//  به هیچ global وابسته نیستند.
//
//  لایه‌ی авторیتاتیک حسابداری: تنها منبع محاسبات مالی در کل برنامه.
//  - دو صندوق ماهانه/عمرانی کاملاً مستقل‌اند (اعتبار یک صندوق، بدهی صندوق
//    دیگر را خالص نمی‌کند).
//  - گردش حساب بر اساس دوره‌ی حسابداری (jmonth شارژ) تاریخ‌گذاری می‌شود،
//    نه تاریخ درج رکورد.
//  - ترتیب هم‌تاریخ قطعی است (opening → charge → payment با شکست‌ندهی index).
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

  // ---- تبدیل jmonth شارژ ('1404/08') به تاریخ میلادیِ اولِ همان ماه ----
  // شارژ متعلق به یک دوره‌ی حسابداری است، نه لحظه‌ی درج. بنابراین تاریخ
  // گردشِ شارژ = اولِ ماه شارژی (jmonth) است، نه created_at. اگر jmonth
  // نامعتبر بود، fallback به created_at (و سپس یک مقدار قطعی).
  function jmonthToDate(jm, fallback) {
    if (jm) {
      const p = String(jm).split('/').map(n => parseInt(n, 10));
      if (p.length === 2 && p[0] > 0 && p[1] >= 1 && p[1] <= 12) {
        try {
          // jalaali در مرورگر global است؛ در Node تست‌ها از اعداد بدون آن عبور می‌کنند.
          if (typeof jalaali !== 'undefined' && jalaali && jalaali.toGregorian) {
            const g = jalaali.toGregorian(p[0], p[1], 1);
            return `${g.gy}-${String(g.gm).padStart(2, '0')}-${String(g.gd).padStart(2, '0')}`;
          }
        } catch (e) { /* fallback */ }
        // fallback تقریبی بدون کتابخانه: jalaali ≈ gregorian − 621 برای سال،
        // و کران تقریبی ماه. در محیط تست (Node) jalaali موجود است اگر بارگذاری شود،
        // وگرنه این مقدار فقط برای مرتب‌سازی هم‌تاریخ به‌کار می‌آید (دقت روز لازم نیست).
        return `${p[0] + 621}-${String(p[1]).padStart(2, '0')}-01`;
      }
    }
    return fallback || '2024-10-01';
  }

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
    const due = charges.filter(cf).reduce((s, c) => s + numOr(c.amount_due, 0), 0);
    const paid = payments.filter(pf).reduce((s, p) => s + numOr(p.amount, 0), 0);
    const pd = priorArr.filter(d => d.unit_id === uid);
    const prior = pd.reduce((s, d) => {
      if (fund === 'monthly') return s + numOr(d.monthly_initial, 0);
      if (fund === 'construction') return s + numOr(d.construction_initial, 0);
      return s + numOr(d.monthly_initial, 0) + numOr(d.construction_initial, 0);
    }, 0);
    const credit = pd.reduce((s, d) => {
      if (fund === 'monthly') return s + numOr(d.credit_monthly, 0);
      if (fund === 'construction') return s + numOr(d.credit_construction, 0);
      return s + numOr(d.credit_monthly, 0) + numOr(d.credit_construction, 0);
    }, 0);
    const bal = due + prior - paid - credit;
    // Bug (فیکس Phase 5/7): اگر به‌دلیل داده‌ی نامعتبر NaN شد، صفر برگردان تا
    // گزارش‌ها گمراه‌کننده نباشند. (نباید رخ دهد، ولی دفاع در عمق.)
    return { due, paid, prior, credit, bal: isNaN(bal) ? 0 : bal };
  }

  // ---- کمک: عدد امن (null/undefined/string → پیش‌فرض) ----
  function numOr(v, d) {
    const n = Number(v);
    return (n === undefined || n === null || isNaN(n)) ? d : n;
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
    return (cache.payments || []).filter(p => (p.type || 'monthly') === fund).reduce((s, p) => s + numOr(p.amount, 0), 0);
  }
  function fundExpense(cache, fund) {
    // Bug A (فیکس): fallback-chain مثل fundIncome تا هزینه با فیلد type یا fund یا پیش‌فرض monthly درست شمرده شود.
    return (cache.expenses || []).filter(e => (e.fund || e.type || 'monthly') === fund).reduce((s, e) => s + numOr(e.amount, 0), 0);
  }
  function fundOpening(cache, fund) {
    const s = cache.settings || {};
    return numOr(fund === 'monthly' ? s.fund_monthly_opening : fund === 'construction' ? s.fund_construction_opening : 0, 0);
  }
  // مانده‌ی نقدی صندوق = افتتاحیه + وصول واقعی − هزینه‌ی واقعی.
  // (افتتاحیه فقط یک‌بار محاسبه می‌شود؛ double-count نمی‌شود چون فقط از settings خوانده می‌شود.)
  function fundBalance(cache, fund) {
    return fundOpening(cache, fund) + fundIncome(cache, fund) - fundExpense(cache, fund);
  }

  // ---- توزیع شارژ: مساوی (با توزیع باقی‌مانده) ----
  // استفاده‌شده در bulkCharge حالت area وقتی مجموع متراژ صفر است (fallback).
  function distributeEqual(amt, n) {
    amt = numOr(amt, 0); n = Math.max(1, numOr(n, 0));
    const base = Math.floor(amt / n), rem = amt - base * n;
    return Array.from({ length: n }, (_, i) => base + (i < rem ? 1 : 0));
  }

  // ---- توزیع شارژ: بر اساس متراژ (با کنترل گردکردن و توزیع باقی‌مانده) ----
  // عین منطق bulkCharge حالت area در index.html.
  function distributeByArea(amt, pending) {
    amt = numOr(amt, 0);
    pending = (pending || []).slice();
    const total = pending.reduce((s, u) => s + numOr(u.area, 0), 0);
    if (total <= 0) return distributeEqual(amt, pending.length);
    let allocated = 0;
    const shares = pending.map(u => {
      const s = Math.round(amt * (numOr(u.area, 0) / total));
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
  // نکته‌ی جدایی: وصول پروژه فقط پرداخت‌های عمرانی متصل به آن پروژه را می‌شمارد؛
  // شارژ پروژه فقط شارژ عمرانی آن پروژه؛ هزینه‌ی پروژه فقط هزینه‌ی عمرانی آن پروژه.
  // «مانده نقدی پروژه» (cash = collected − exp) با «باقی مطالبات پروژه»
  // (remaining = issued − collected) اشتباه نمی‌شود.
  function projectReport(projects, charges, payments, expenses) {
    return (projects || []).map(p => {
      const issued = (charges || []).filter(c => c.project_id === p.id && c.type === 'construction')
        .reduce((s, c) => s + numOr(c.amount_due, 0), 0);
      // Bug C (فیکس): وصول پروژه فقط پرداخت‌های عمرانی را بشمار؛ پرداخت ماهانه با project_id سرگردان تهاتر نمی‌شود.
      // پیش‌فرض پرداختِ دارای project_id = construction (مگر type صریحاً monthly باشد).
      const collected = (payments || []).filter(pay => pay.project_id === p.id && (pay.type || 'construction') === 'construction')
        .reduce((s, pay) => s + numOr(pay.amount, 0), 0);
      // Bug D (فیکس): هزینه‌ی پروژه فقط هزینه‌های عمرانی را بشمار (پیش‌فرض construction برای هزینه‌ی دارای project_id).
      const exp = (expenses || []).filter(e => e.project_id === p.id && (e.fund || e.type || 'construction') === 'construction')
        .reduce((s, e) => s + numOr(e.amount, 0), 0);
      // Bug E (فیکس): overpayment به‌جای remaining منفی، در فیلد credit جدا دیده شود.
      const overpay = Math.max(0, collected - issued);
      return {
        name: p.name, budget: numOr(p.budget_approved, 0), issued, collected,
        remaining: Math.max(0, issued - collected), credit: overpay, exp,
        cash: collected - exp,
        progress: issued > 0 ? Math.round(collected / issued * 100)
          : (numOr(p.budget_approved, 0) > 0 ? Math.round(exp / numOr(p.budget_approved, 0) * 100) : 0),
        // Bug F (فیکس): دو معیار جدا برای وصول و اجرا.
        collection_progress: issued > 0 ? Math.round(collected / issued * 100) : 0,
        execution_progress: numOr(p.budget_approved, 0) > 0 ? Math.round(exp / numOr(p.budget_approved, 0) * 100) : 0
      };
    });
  }

  // ---- گردش تجمعی حساب (logic مشترک واقعی) ----
  // ردیف‌ها را بر اساس تاریخ مرتب می‌کند و برای هر صندوق یک عدادار تجمعی
  // (run) محاسبه می‌کند. عین منطق انتهای B49.unitLedgerRows در index.html.
  // ورودی: rows = [{date, fundKey:'monthly'|'construction', debit, credit, ...}]
  // خروجی: همان rows با فیلد run اضافه‌شده، مرتب‌شده بر اساس تاریخ.
  //
  // Phase 6 (فیکس): ترتیبِ هم‌تاریخ قطعی است. sort موتور پایدار است اما
  // برای تضمین قطعیت، یک کلید ثانویه (seq) به‌عنوان شکست‌نده استفاده می‌شود.
  // ترتیب منطقی درج: opening (prior) → charge → payment. بنابراین هم‌تاریخ‌ها
  // به این ترتیب می‌مانند: ابتدا مانده‌ی افتتاحیه، سپس شارژ، سپس پرداخت.
  function runningBalance(rows) {
    rows = (rows || []).slice();
    // Bug H (فیکس): تاریخ نامعتبر → Infinity (ته ردیف) به‌جای NaN که ترتیب را نامعین می‌کرد.
    const t = d => { const x = new Date(d).getTime(); return isNaN(x) ? Infinity : x; };
    // کلید قطعی: (timestamp, seq). seq برابر ترتیب درج اصلی است.
    rows.forEach((r, i) => { if (r._b49seq === undefined) r._b49seq = i; });
    rows.sort((a, b) => {
      const ta = t(a.date), tb = t(b.date);
      if (ta !== tb) return ta - tb;
      return (a._b49seq || 0) - (b._b49seq || 0);
    });
    let runM = 0, runC = 0;
    rows.forEach(r => {
      // Bug G (فیکس): فقط fundKey‌های معتبر به عدادار اضافه شوند؛ ردیف نامعتبر آلودگی نمی‌کند.
      if (r.fundKey === 'monthly') { runM += numOr(r.debit, 0) - numOr(r.credit, 0); r.run = runM; }
      else if (r.fundKey === 'construction') { runC += numOr(r.debit, 0) - numOr(r.credit, 0); r.run = runC; }
      else { r.run = null; }
    });
    return rows;
  }

  // ---- ساخت ردیف‌های دفتر کل یک واحد (هسته‌ی حسابداری، بدون نمایش) ----
  // عین منطق B49.unitLedgerRows در index.html برای بخش مالی (تاریخ/صندوق/بدهکار/بستانکار).
  // Phase 6 (فیکس): تاریخ شارژ بر اساس دوره‌ی حسابداری (jmonth) است، نه created_at.
  //   یک شارژ متعلق به ماه ۱۴۰۴/۰۸ که امروز درج شده، در گردشِ ۱۴۰۴/۰۸ می‌نشیند،
  //   نه در امروز. این از انتسابِ اشتباهِ شارژِ تاریخی به تاریخِ درج جلوگیری می‌کند.
  //   پرداخت از payment_date، مانده از as_of_date.
  function buildLedgerRows(cache, uid) {
    cache = cache || {};
    const rows = [];
    (cache.prior || []).filter(d => d.unit_id === uid).forEach(d => {
      if (numOr(d.monthly_initial, 0)) rows.push({ date: d.as_of_date, fundKey: 'monthly', debit: numOr(d.monthly_initial, 0), credit: 0 });
      if (numOr(d.construction_initial, 0)) rows.push({ date: d.as_of_date, fundKey: 'construction', debit: numOr(d.construction_initial, 0), credit: 0 });
      if (numOr(d.credit_monthly, 0)) rows.push({ date: d.as_of_date, fundKey: 'monthly', debit: 0, credit: numOr(d.credit_monthly, 0) });
      if (numOr(d.credit_construction, 0)) rows.push({ date: d.as_of_date, fundKey: 'construction', debit: 0, credit: numOr(d.credit_construction, 0) });
    });
    (cache.charges || []).filter(c => c.unit_id === uid).forEach(c => {
      const dt = jmonthToDate(c.jmonth, c.created_at);
      rows.push({ date: dt, fundKey: (c.type || 'monthly'), debit: numOr(c.amount_due, 0), credit: 0 });
    });
    (cache.payments || []).filter(p => p.unit_id === uid).forEach(p => {
      // Bug H (فیکس): fallback تاریخ برای payment_date خالی تا عدادار تجمعی به‌هم نریزد.
      rows.push({ date: p.payment_date || p.created_at || '2024-10-01', fundKey: (p.type || 'monthly'), debit: 0, credit: numOr(p.amount, 0) });
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

  // ---- تجمیع امنِ مانده‌ی افتتاحیۀ تکراری (Phase 2، نسخۀ JS برای تست) ----
  // عین استراتژی reconciliation در migration_v5: برای هر واحد، مبالغ همه‌ی
  // ردیف‌های prior (حتی تکراری) را جمع می‌کند تا هیچ مبلغی با dedup از دست نرود.
  // ورودی: آرایۀ prior (ممکن است چند ردیف برای یک unit_id داشته باشد).
  // خروجی: نقشه‌ی unit_id → {monthly_initial, construction_initial, credit_monthly, credit_construction}.
  function aggregatePrior(priorArr) {
    const map = {};
    (priorArr || []).forEach(d => {
      const uid = d.unit_id;
      if (uid === undefined || uid === null) return;
      if (!map[uid]) map[uid] = { unit_id: uid, monthly_initial: 0, construction_initial: 0, credit_monthly: 0, credit_construction: 0, as_of_date: null };
      const e = map[uid];
      e.monthly_initial += numOr(d.monthly_initial, 0);
      e.construction_initial += numOr(d.construction_initial, 0);
      e.credit_monthly += numOr(d.credit_monthly, 0);
      e.credit_construction += numOr(d.credit_construction, 0);
      // earliest as_of_date
      if (d.as_of_date && (!e.as_of_date || String(d.as_of_date) < String(e.as_of_date))) e.as_of_date = d.as_of_date;
    });
    return map;
  }

  return {
    unitBalance, unitTotalDebt, fundIncome, fundExpense, fundOpening, fundBalance,
    distributeEqual, distributeByArea, projectReport,
    runningBalance, buildLedgerRows, commit, aggregatePrior, jmonthToDate, numOr
  };
}));
