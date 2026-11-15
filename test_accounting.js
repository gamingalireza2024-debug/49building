// تست منطق حسابداری ساختمان ۴۹ — توابع زیر عیناً از index.html کپی شده‌اند.
// این تست فرمول‌های حسابداری را با داده‌ی نمونه و خروجی‌های منتظر تأیید می‌کند.
// اجرا: node /home/z/my-project/scripts/test_accounting.js

// ---- stub کمکی (مستقل از DOM/jalaali) ----
const B49={cache:{}};
B49.faDigits=s=>String(s==null?'':s).replace(/[0-9]/g,d=>'۰۱۲۳۴۵۶۷۸۹'[d]);
B49.toEn=s=>String(s==null?'':s);
B49.rial=n=>String(n);
B49.escape=s=>String(s==null?'':s);
B49.jMonthLabel=s=>s||'';
B49.gToJstr=ds=>ds||'';
B49.jToG=(jy,jm,jd)=>`${jy}-${String(jm).padStart(2,'0')}-${String(jd).padStart(2,'0')}`;
B49.unitOpt=id=>{const u=B49.cache.units?.find(x=>x.id===id);return u?u.number:'—';};

// ============ عین کد index.html: unitBalance ============
B49.unitBalance=(uid,fund=null)=>{
  const f=B49.cache; if(!f||!f.charges)return {due:0,paid:0,prior:0,credit:0,bal:0};
  const cf=c=>c.unit_id===uid&&((fund?((c.type||'monthly')===fund):true));
  const pf=p=>p.unit_id===uid&&((fund?((p.type||'monthly')===fund):true));
  const due=(f.charges.filter(cf)).reduce((s,c)=>s+Number(c.amount_due||0),0);
  const paid=(f.payments.filter(pf)).reduce((s,p)=>s+Number(p.amount||0),0);
  const pd=(f.prior||[]).filter(d=>d.unit_id===uid);
  const prior=pd.reduce((s,d)=>{
    if(fund==='monthly')return s+Number(d.monthly_initial||0);
    if(fund==='construction')return s+Number(d.construction_initial||0);
    return s+Number(d.monthly_initial||0)+Number(d.construction_initial||0);
  },0);
  const credit=pd.reduce((s,d)=>{
    if(fund==='monthly')return s+Number(d.credit_monthly||0);
    if(fund==='construction')return s+Number(d.credit_construction||0);
    return s+Number(d.credit_monthly||0)+Number(d.credit_construction||0);
  },0);
  return {due,paid,prior,credit,bal:due+prior-paid-credit};
};
B49.fundIncome=(fund)=>(B49.cache.payments||[]).filter(p=>(p.type||'monthly')===fund).reduce((s,p)=>s+Number(p.amount||0),0);
B49.fundExpense=(fund)=>(B49.cache.expenses||[]).filter(e=>e.fund===fund).reduce((s,e)=>s+Number(e.amount||0),0);
B49.fundOpening=(fund)=>{const s=B49.cache.settings||{};return Number(fund==='monthly'?s.fund_monthly_opening:fund==='construction'?s.fund_construction_opening:0)||0;};
B49.fundBalance=(fund)=>B49.fundOpening(fund)+B49.fundIncome(fund)-B49.fundExpense(fund);

// ============ عین کد index.html: unitLedgerRows ============
B49.unitLedgerRows=(uid)=>{
  const rows=[];
  (B49.cache.prior||[]).filter(d=>d.unit_id===uid).forEach(d=>{
    if(d.monthly_initial)rows.push({date:d.as_of_date,type:'مانده اولیه',fundKey:'monthly',fund:'ماهانه',desc:'بدهی اولیه شارژ ماهانه',debit:Number(d.monthly_initial),credit:0});
    if(d.construction_initial)rows.push({date:d.as_of_date,type:'مانده اولیه',fundKey:'construction',fund:'عمرانی',desc:'بدهی اولیه شارژ عمرانی',debit:Number(d.construction_initial),credit:0});
    if(d.credit_monthly)rows.push({date:d.as_of_date,type:'مانده اولیه',fundKey:'monthly',fund:'ماهانه',desc:'طلب اولیه ماهانه',debit:0,credit:Number(d.credit_monthly)});
    if(d.credit_construction)rows.push({date:d.as_of_date,type:'مانده اولیه',fundKey:'construction',fund:'عمرانی',desc:'طلب اولیه عمرانی',debit:0,credit:Number(d.credit_construction)});
  });
  (B49.cache.charges||[]).filter(c=>c.unit_id===uid).forEach(c=>{const fk=(c.type||'monthly');const jm=c.jmonth;let dt=c.created_at;if(jm){const p=jm.split('/').map(Number);if(p.length===2){try{dt=B49.jToG(p[0],p[1],1)}catch(e){}}}rows.push({date:dt,type:'شارژ',fundKey:fk,fund:fk==='monthly'?'ماهانه':'عمرانی',desc:'شارژ '+(fk==='monthly'?'ماهانه':'عمرانی')+' — '+B49.jMonthLabel(jm),debit:Number(c.amount_due||0),credit:0});});
  (B49.cache.payments||[]).filter(p=>p.unit_id===uid).forEach(p=>{const fk=(p.type||'monthly');rows.push({date:p.payment_date,type:'پرداخت',fundKey:fk,fund:fk==='monthly'?'ماهانه':'عمرانی',desc:'پرداخت',debit:0,credit:Number(p.amount||0)});});
  rows.sort((a,b)=>new Date(a.date)-new Date(b.date));
  let runM=0,runC=0;
  rows.forEach(r=>{if(r.fundKey==='monthly'){runM+=r.debit-r.credit;r.run=runM;}else{runC+=r.debit-r.credit;r.run=runC;}});
  return rows;
};

// ============ عین کد index.html: توزیع سهم متراژی bulkCharge (هسته) ============
function areaShares(amt,pending){
  const total=pending.reduce((s,u)=>s+Number(u.area||0),0);
  let shares;
  if(total<=0){const base=Math.floor(amt/pending.length),rem=amt-base*pending.length;shares=pending.map((u,i)=>base+(i<rem?1:0));}
  else{let allocated=0;shares=pending.map(u=>{const s=Math.round(amt*(Number(u.area||0)/total));allocated+=s;return s;});let diff=amt-allocated;for(let i=0;i<pending.length&&diff!==0;i++){shares[i]+=diff>0?1:-1;diff+=diff>0?-1:1;}}
  return shares;
}

// ============ داده‌ی نمونه ============
B49.cache={
  units:[{id:1,number:'101',area:100},{id:2,number:'102',area:0}],
  charges:[
    {unit_id:1,jmonth:'1403/08',type:'monthly',amount_due:500000,created_at:'2024-10-01'},
    {unit_id:1,jmonth:'1403/08',type:'construction',amount_due:200000,created_at:'2024-10-01'},
    {unit_id:2,jmonth:'1403/08',type:'monthly',amount_due:500000,created_at:'2024-10-01'}
  ],
  payments:[
    {unit_id:1,type:'monthly',amount:300000,payment_date:'2024-10-05'},
    {unit_id:1,type:'monthly',amount:300000,payment_date:'2024-10-06'}
  ],
  prior:[{unit_id:1,monthly_initial:100000,construction_initial:0,credit_monthly:50000,credit_construction:0,as_of_date:'2024-09-01'}],
  expenses:[{fund:'monthly',amount:100000},{fund:'construction',amount:50000}],
  settings:{fund_monthly_opening:1000000,fund_construction_opening:2000000}
};

// ============ assertions ============
let pass=0,fail=0;
function assert(name,actual,expected){
  const ok=JSON.stringify(actual)===JSON.stringify(expected);
  console.log((ok?'✓':'✗')+' '+name+' → '+JSON.stringify(actual)+(ok?'':' (منتظر: '+JSON.stringify(expected)+')'));
  ok?pass++:fail++;
}

// ۱) باگ بحرانی: unitBalance(uid) کل باید prior را شامل شود (قدیم صفر می‌شد)
const b1t=B49.unitBalance(1);
assert('unitBalance(1) کل — prior اضافه + credit کسر', b1t.bal, 700000+100000-600000-50000); // 150000

// ۲) تفکیک ماهانه: prior=monthly_initial، credit=credit_monthly
const b1m=B49.unitBalance(1,'monthly');
assert('unitBalance(1,"monthly").prior', b1m.prior, 100000);
assert('unitBalance(1,"monthly").credit', b1m.credit, 50000);
assert('unitBalance(1,"monthly").bal', b1m.bal, 500000+100000-600000-50000); // -50000 (طلب)

// ۳) تفکیک عمرانی
const b1c=B49.unitBalance(1,'construction');
assert('unitBalance(1,"construction").bal', b1c.bal, 200000+0-0-0); // 200000

// ۴) واحد بدون prior
const b2=B49.unitBalance(2,'monthly');
assert('unitBalance(2,"monthly").bal', b2.bal, 500000);

// ۵) fundBalance با افتتاحیه
assert('fundBalance("monthly") = افتتاحیه+درآمد−هزینه', B49.fundBalance('monthly'), 1000000+600000-100000); // 1500000
assert('fundBalance("construction") = افتتاحیه+درآمد−هزینه', B49.fundBalance('construction'), 2000000+0-50000); // 1950000

// ۶) گردش مستقل دو صندوق: مانده‌ی آخرین ردیف ماهانه ≠ ترکیب با عمرانی
const rows=B49.unitLedgerRows(1);
const lastM=[...rows].reverse().find(r=>r.fundKey==='monthly');
const lastC=[...rows].reverse().find(r=>r.fundKey==='construction');
assert('گردش ماهانه — مانده‌ی نهایی مستقل', lastM.run, 100000-50000+500000-300000-300000); // -50000
assert('گردش عمرانی — مانده‌ی نهایی مستقل', lastC.run, 200000); // 200000 (تحت‌تأثیر تراکنش‌های ماهانه قرار نگرفت)

// ۷) توزیع سهم متراژی: جمع سهم‌ها دقیقاً برابر مبلغ کل (رفع باگ گردکردن)
const sh1=areaShares(1000000,[{area:100},{area:100},{area:100}]);
assert('سهم متراژی — جمع = مبلغ کل', sh1.reduce((a,b)=>a+b,0), 1000000);
assert('سهم متراژی — توزیع باقی‌مانده', sh1, [333334,333333,333333]);

// ۸) متراژ صفر → تقسیم مساوی + توزیع باقی‌مانده
const sh2=areaShares(1000000,[{area:0},{area:0},{area:0}]);
assert('متراژ صفر — جمع = مبلغ کل', sh2.reduce((a,b)=>a+b,0), 1000000);
assert('متراژ صفر — تقسیم مساوی', sh2, [333334,333333,333333]);

console.log('\n════════════════════════════════════════');
console.log(`نتیجه: ${pass} پاس / ${fail} رد`);
process.exit(fail?1:0);
