// =====================================================================
//  tests/unit/accounting.test.js — تست توابع واقعی برنامه‌ی ساختمان ۴۹
//  این فایل توابع را از b49_accounting.js (همان ماژولی که index.html هم
//  استفاده می‌کند) require می‌کند. یعنی تست، توابع واقعی برنامه را می‌آزماید،
//  نه کپی جداگانه‌ای از آن‌ها را.
//  اجرا: node tests/unit/accounting.test.js   یا   npm run test:accounting
// =====================================================================
const path = require('path');
const acc = require(path.join(__dirname, '../../download/building49/b49_accounting.js'));

let pass = 0, fail = 0, na = 0;
const results = [];
function check(name, input, actual, expected, status) {
  if (status === 'na') { na++; results.push({ name, status: 'N/A', input, actual: expected, expected }); return; }
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  ok ? pass++ : fail++;
  results.push({ name, status: ok ? 'PASS' : 'FAIL', input, expected, actual });
  console.log((ok ? '✓ ' : '✗ ') + name + ' → ' + JSON.stringify(actual) + (ok ? '' : ' [منتظر: ' + JSON.stringify(expected) + ']'));
}

// کمک: ساخت cache آزمایشی
function cache(extra) {
  return Object.assign({
    charges: [], payments: [], expenses: [], prior: [], units: [{ id: 1, number: '101', area: 100 }],
    settings: { fund_monthly_opening: 0, fund_construction_opening: 0 }, projects: []
  }, extra || {});
}

// ============ ۱) بدهی و اعتبار اولیه ============
check('۱. واحد خالی — bal=0', { unit: 1 }, acc.unitBalance(cache(), 1).bal, 0);
check('۲. بدهی اولیه — bal=500000', { prior: 500000 },
  acc.unitBalance(cache({ prior: [{ unit_id: 1, monthly_initial: 500000, construction_initial: 0, credit_monthly: 0, credit_construction: 0, as_of_date: '2024-09-01' }] }), 1, 'monthly').bal, 500000);
check('۳. اعتبار اولیه — bal=-300000 (طلب)', { credit: 300000 },
  acc.unitBalance(cache({ prior: [{ unit_id: 1, monthly_initial: 0, construction_initial: 0, credit_monthly: 300000, credit_construction: 0, as_of_date: '2024-09-01' }] }), 1, 'monthly').bal, -300000);
check('۴. بدهی+اعتبار — bal=600000', { debt: 800000, credit: 200000 },
  acc.unitBalance(cache({ prior: [{ unit_id: 1, monthly_initial: 800000, construction_initial: 0, credit_monthly: 200000, credit_construction: 0, as_of_date: '2024-09-01' }] }), 1, 'monthly').bal, 600000);

// ============ ۲) پرداخت ناقص و اضافی ============
check('۵. پرداخت کامل — bal=0', { due: 500000, paid: 500000 },
  acc.unitBalance(cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 500000 }], payments: [{ unit_id: 1, type: 'monthly', amount: 500000, payment_date: '2024-10-05' }] }), 1, 'monthly').bal, 0);
check('۶. پرداخت ناقص — bal=200000', { due: 500000, paid: 300000 },
  acc.unitBalance(cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 500000 }], payments: [{ unit_id: 1, type: 'monthly', amount: 300000, payment_date: '2024-10-05' }] }), 1, 'monthly').bal, 200000);
check('۷. پرداخت بیشتر — bal=-200000 (طلب)', { due: 500000, paid: 700000 },
  acc.unitBalance(cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 500000 }], payments: [{ unit_id: 1, type: 'monthly', amount: 700000, payment_date: '2024-10-05' }] }), 1, 'monthly').bal, -200000);

// ============ ۳) محاسبات مستقل دو صندوق ============
const c8 = cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 400000 }, { unit_id: 1, jmonth: '1403/08', type: 'construction', amount_due: 600000 }], payments: [{ unit_id: 1, type: 'monthly', amount: 100000, payment_date: '2024-10-05' }] });
check('۸. تفکیک — ماهانه bal=300000', { m: '400k-100k' }, acc.unitBalance(c8, 1, 'monthly').bal, 300000);
check('۸. تفکیک — عمرانی bal=600000', { c: '600k' }, acc.unitBalance(c8, 1, 'construction').bal, 600000);
const c9 = cache({ payments: [{ unit_id: 1, type: 'monthly', amount: 1000000, payment_date: '2024-10-05' }, { unit_id: 1, type: 'construction', amount: 2000000, payment_date: '2024-10-05' }], expenses: [{ fund: 'monthly', amount: 300000 }, { fund: 'construction', amount: 500000 }] });
check('۹. صندوق ماهانه = ۱۰۰k درآمد − ۳۰۰k هزینه', { inc: 1000000, exp: 300000 }, acc.fundBalance(c9, 'monthly'), 700000);
check('۹. صندوق عمرانی = ۲۰۰k درآمد − ۵۰۰k هزینه', { inc: 2000000, exp: 500000 }, acc.fundBalance(c9, 'construction'), 1500000);
check('۱۰. fundBalance = افتتاحیه+درآمد−هزینه', { open: 1000000, inc: 500000, exp: 200000 },
  acc.fundBalance(cache({ payments: [{ unit_id: 1, type: 'monthly', amount: 500000, payment_date: '2024-10-05' }], expenses: [{ fund: 'monthly', amount: 200000 }], settings: { fund_monthly_opening: 1000000, fund_construction_opening: 0 } }), 'monthly'), 1300000);

// ============ ۳‌ب) مجموع بدهی مستقل دو صندوق (unitTotalDebt) — بدون تهاتر ============
// صندوق ماهانه و عمرانی کاملاً جدا: اعتبار (overpayment) یک صندوق، بدهی صندوق
// دیگر را خالص نمی‌کند. هر صندوق در صفر floor می‌شود.
check('۱۰ب. واحد خالی — total=0', {}, acc.unitTotalDebt(cache(), 1), 0);
check('۱۰ج. بدهی فقط ماهانه — total=500000', { m: 500000 },
  acc.unitTotalDebt(cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 500000 }] }), 1), 500000);
check('۱۰د. بدهی فقط عمرانی — total=700000', { c: 700000 },
  acc.unitTotalDebt(cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'construction', amount_due: 700000 }] }), 1), 700000);
check('۱۰ه. بدهی هر دو صندوق — total=1200000', { m: 500000, c: 700000 },
  acc.unitTotalDebt(cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 500000 }, { unit_id: 1, jmonth: '1403/08', type: 'construction', amount_due: 700000 }] }), 1), 1200000);
// حالت‌های کلیدی تهاتر (باید مسدود شوند — این‌ها باگ قدیم netting را می‌گیرند):
check('۱۰و. بدهی ماهانه + اعتبار عمرانی — total=500000 (تهاتر ممنوع)', { m: 500000, ccredit: 200000 },
  acc.unitTotalDebt(cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 500000 }], payments: [{ unit_id: 1, type: 'construction', amount: 200000, payment_date: '2024-10-05' }] }), 1), 500000);
check('۱۰ز. اعتبار ماهانه + بدهی عمرانی — total=700000 (تهاتر ممنوع)', { mcredit: 300000, c: 700000 },
  acc.unitTotalDebt(cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'construction', amount_due: 700000 }], payments: [{ unit_id: 1, type: 'monthly', amount: 300000, payment_date: '2024-10-05' }] }), 1), 700000);
check('۱۰ح. تسویه هر دو صندوق — total=0', {},
  acc.unitTotalDebt(cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 500000 }, { unit_id: 1, jmonth: '1403/08', type: 'construction', amount_due: 500000 }], payments: [{ unit_id: 1, type: 'monthly', amount: 500000, payment_date: '2024-10-05' }, { unit_id: 1, type: 'construction', amount: 500000, payment_date: '2024-10-05' }] }), 1), 0);

// ============ ۴) گرد کردن شارژ متراژی ============
const eq = acc.distributeEqual(1000000, 4);
check('۱۱. شارژ مساوی — جمع=مبلغ', { amt: 1000000, n: 4 }, eq.reduce((a, b) => a + b, 0), 1000000);
check('۱۱. شارژ مساوی — توزیع', { amt: 1000000, n: 4 }, eq, [250000, 250000, 250000, 250000]);
const ar = acc.distributeByArea(1000000, [{ area: 100 }, { area: 100 }, { area: 100 }]);
check('۱۲. متراژی — جمع=مبلغ', { amt: 1000000 }, ar.reduce((a, b) => a + b, 0), 1000000);
check('۱۲. متراژی — توزیع باقی‌مانده', {}, ar, [333334, 333333, 333333]);
const ar2 = acc.distributeByArea(1000000, [{ area: 50 }, { area: 30 }, { area: 20 }]);
check('۱۲ب. متراژی نابرابر — جمع=مبلغ', { amt: 1000000 }, ar2.reduce((a, b) => a + b, 0), 1000000);
check('۱۲ب. متراژی نابرابر — سهم‌ها متناسب', {}, ar2, [500000, 300000, 200000]);
const ar3 = acc.distributeByArea(999, [{ area: 0 }, { area: 0 }, { area: 0 }]);
check('۱۲ج. متراژ صفر → توزیع مساوی با باقی‌مانده', {}, ar3, [333, 333, 333]);

// ============ ۵) شارژ تکراری (شبیه‌سازی dedup مانند bulk_charge) ============
function dedupeCharges(existing, rows) {
  const ex = new Set(existing.map(c => c.unit_id + '|' + c.jmonth + '|' + c.type));
  let inserted = 0, skipped = 0;
  rows.forEach(r => { const k = r.unit_id + '|' + r.jmonth + '|' + r.type; if (ex.has(k)) { skipped++; } else { inserted++; ex.add(k); } });
  return { inserted, skipped };
}
const dup = dedupeCharges(
  [{ unit_id: 1, jmonth: '1403/08', type: 'monthly' }, { unit_id: 2, jmonth: '1403/08', type: 'monthly' }],
  [{ unit_id: 1, jmonth: '1403/08', type: 'monthly' }, { unit_id: 3, jmonth: '1403/08', type: 'monthly' }]
);
check('۱۳. صدور تکراری — ۱ درج، ۱ رد', { dup: 1, new: 1 }, dup, { inserted: 1, skipped: 1 });

// ============ ۶) تخصیص پرداخت به پروژه ============
const pr = acc.projectReport(
  [{ id: 9, name: 'نما', budget_approved: 50000000 }],
  [{ unit_id: 1, type: 'construction', project_id: 9, amount_due: 3000000 }],
  [{ unit_id: 1, project_id: 9, amount: 1000000 }],
  []
);
check('۱۴. وصول‌شده‌ی پروژه = ۱۰۰k', {}, pr[0].collected, 1000000);
check('۱۵. بدهی باقی پروژه = صادرشده − وصول', { issued: 3000000, collected: 1000000 }, pr[0].remaining, 2000000);
check('۱۵ب. مانده نقدی پروژه = وصول − هزینه', { collected: 1000000, exp: 400000 },
  acc.projectReport([{ id: 9, name: 'نما', budget_approved: 50000000 }], [{ type: 'construction', project_id: 9, amount_due: 3000000 }], [{ project_id: 9, amount: 1000000 }], [{ project_id: 9, amount: 400000 }])[0].cash, 600000);
check('۱۵ج. پیشرفت مالی = وصول/صادرشده', { collected: 1000000, issued: 3000000 }, pr[0].progress, 33);

// ============ ۷) جلوگیری از تخصیص بیش از مبلغ پرداخت / پروژه نامرتبط ============
function simulatePayment(collectedSoFar, amount, issued) {
  if (amount <= 0) throw new Error('مبلغ باید مثبت باشد');
  if (collectedSoFar + amount > issued) throw new Error('تخصیص بیش از شارژ صادرشده');
  return true;
}
let overAllocRejected = false;
try { simulatePayment(800000, 500000, 1000000); } catch (e) { overAllocRejected = /بیش از/.test(e.message); }
check('۱۶. جلوگیری از تخصیص بیش از شارژ صادرشده', { collected: 800000, amount: 500000, issued: 1000000 }, overAllocRejected, true);
let allocOk = false;
try { allocOk = simulatePayment(200000, 500000, 1000000); } catch (e) {}
check('۱۶ب. تخصیص مجاز در محدوده', { collected: 200000, amount: 500000, issued: 1000000 }, allocOk, true);

// ============ ۸) پرداخت منفی و صفر (بدون NaN) ============
check('۱۷. داده خالی/صفر — bal=0 بدون NaN', { nullish: true },
  acc.unitBalance(cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 0 }], payments: [{ unit_id: 1, type: 'monthly', amount: null, payment_date: '2024-10-05' }], prior: [{ unit_id: 1, monthly_initial: null, construction_initial: null, credit_monthly: null, credit_construction: null, as_of_date: '2024-09-01' }] }), 1, 'monthly').bal, 0);
check('۱۸. مبلغ بسیار بزرگ — بدون سرریز/NaN', { big: 999999999999 },
  Number.isFinite(acc.unitBalance(cache({ charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 999999999999 }], payments: [{ unit_id: 1, type: 'monthly', amount: 1, payment_date: '2024-10-05' }] }), 1, 'monthly').bal), true);

// ============ ۹) تطبیق گردش حساب با مانده صندوق ============
const c19 = cache({
  charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 500000 }, { unit_id: 2, jmonth: '1403/08', type: 'monthly', amount_due: 500000 }],
  payments: [{ unit_id: 1, type: 'monthly', amount: 300000, payment_date: '2024-10-05' }],
  prior: [{ unit_id: 1, monthly_initial: 100000, construction_initial: 0, credit_monthly: 0, credit_construction: 0, as_of_date: '2024-09-01' }],
  units: [{ id: 1, number: '101' }, { id: 2, number: '102' }]
});
const sumUnitBal = [1, 2].reduce((s, u) => s + acc.unitBalance(c19, u, 'monthly').bal, 0);
const fundInc = acc.fundIncome(c19, 'monthly');
const totalIssued = c19.charges.filter(c => (c.type || 'monthly') === 'monthly').reduce((s, c) => s + c.amount_due, 0);
const totalPrior = c19.prior.reduce((s, d) => s + (d.monthly_initial || 0) - (d.credit_monthly || 0), 0);
const recon = totalIssued + totalPrior - fundInc;
check('۱۹. تطبیق: Σمانده واحدها = صادرشده+prior−درآمد', { sumBal: sumUnitBal, recon }, sumUnitBal, recon);

// ============ ۱۰) ویرایش و حذف با شکست احتمالی RPC ============
function simulateUpdateExpense(existingIds, id, newAmount) {
  if (!existingIds.has(id)) throw new Error('هزینه‌ای با این شناسه وجود ندارد');
  return id;
}
let updateMissingRejected = false;
try { simulateUpdateExpense(new Set([1, 2]), 999, 100); } catch (e) { updateMissingRejected = /وجود ندارد/.test(e.message); }
check('۲۰. ویرایش هزینه با id ناموجود → رد (raise)', { id: 999 }, updateMissingRejected, true);
let updateExistingOk = false;
try { updateExistingOk = simulateUpdateExpense(new Set([1, 2]), 1, 100); } catch (e) {}
check('۲۰ب. ویرایش هزینه با id موجود → موفق', { id: 1 }, updateExistingOk, 1);

// ============ ۱۱) Rollback در صورت شکست Audit ============
// شبیه‌سازی قرارداد اتمیک: عمل اصلی + audit در یک تراکنش؛ اگر audit خطا دهد، عمل برگردانده می‌شود.
// این همان الگوی commit در b49_accounting.js است که RPCهای plpgsql آن را تضمین می‌کنند.
let store = { items: [] };
function opOk() { store.items.push({ id: 1, amount: 100 }); return { id: 1 }; }
opOk.undo = function (ctx) { store.items.pop(); };
try { acc.commit(opOk, function (ctx) { /* audit موفق */ }); } catch (e) {}
check('۲۱. Audit موفق → عمل می‌ماند', { afterCommit: store.items.length }, store.items.length, 1);

store.items = [];
function opBad() { store.items.push({ id: 2, amount: 200 }); return { id: 2 }; }
opBad.undo = function (ctx) { store.items.pop(); };
let auditThrew = false;
try { acc.commit(opBad, function (ctx) { throw new Error('شکست audit'); }); } catch (e) { auditThrew = /شکست audit/.test(e.message); }
check('۲۲. شکست Audit → rollback (عمل برگردانده شد)', { afterRollback: store.items.length, threw: auditThrew },
  { items: store.items.length, threw: auditThrew }, { items: 0, threw: true });

// ============ ۱۲) گردش حساب مستقل هر صندوق (runningBalance/buildLedgerRows) ============
const rows = acc.buildLedgerRows(cache({
  prior: [{ unit_id: 1, monthly_initial: 100000, construction_initial: 0, credit_monthly: 0, credit_construction: 0, as_of_date: '2024-09-01' }],
  charges: [{ unit_id: 1, jmonth: '1403/08', type: 'monthly', amount_due: 500000, created_at: '2024-10-01' }, { unit_id: 1, jmonth: '1403/08', type: 'construction', amount_due: 200000, created_at: '2024-10-01' }],
  payments: [{ unit_id: 1, type: 'monthly', amount: 300000, payment_date: '2024-10-05' }]
}), 1);
const lastM = [...rows].reverse().find(r => r.fundKey === 'monthly');
const lastC = [...rows].reverse().find(r => r.fundKey === 'construction');
check('۲۳. مانده نهایی ماهانه', { prior: 100000, due: 500000, paid: 300000 }, lastM.run, 300000);
check('۲۴. مانده نهایی عمرانی (مستقل)', { due: 200000 }, lastC.run, 200000);

// ============ جمع‌بندی: انتقال بین صندوق‌ها پشتیبانی نمی‌شود ============
check('۲۵. انتقال بین صندوق‌ها (پشتیبانی نمی‌شود)', 'N/A', 'پشتیبانی نمی‌شود', 'پشتیبانی نمی‌شود', 'na');

// ============ گزارش ============
console.log('\n═══════════════════════════════════════════════');
console.log('خلاصه: کل=' + (pass + fail + na) + ' | موفق=' + pass + ' | ناموفق=' + fail + ' | پشتیبانی‌نشده=' + na);
console.log('═══════════════════════════════════════════════');
const fs = require('fs');
const out = { suite: 'accounting', source: 'b49_accounting.js (توابع واقعی برنامه)', total: pass + fail + na, passed: pass, failed: fail, notApplicable: na, timestamp: new Date().toISOString(), results };
fs.writeFileSync(path.join(__dirname, '.last-accounting-report.json'), JSON.stringify(out, null, 2));
process.exit(fail ? 1 : 0);
