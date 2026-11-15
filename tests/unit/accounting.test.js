// تست‌های منطق حسابداری ساختمان ۴۹ — ۲۰ سناریو
// توابع زیر عیناً از index.html کپی شده‌اند. این فایل با node اجرا می‌شود
// و برای هر سناریو: ورودی، مقدار مورد انتظار و نتیجه‌ی واقعی را ثبت می‌کند.
// اجرا: node tests/unit/accounting.test.js   یا   npm run test:accounting

let pass=0, fail=0, na=0;
const results=[];
function check(name,input,actual,expected,status='run'){
  let ok;
  if(status==='na'){ok=true;na++;}
  else{ok=JSON.stringify(actual)===JSON.stringify(expected);ok?pass++:fail++;}
  results.push({name,status:status==='na'?'N/A':(ok?'PASS':'FAIL'),input,expected,actual});
  console.log((status==='na'?'○':ok?'✓':'✗')+' '+name+(status==='na'?' (پشتیبانی نمی‌شود)':'')+' → '+JSON.stringify(actual)+(status==='na'?'':(ok?'':' [منتظر: '+JSON.stringify(expected)+']')));
}

// ---- توابع عین index.html ----
const B49={cache:{}};
B49.unitBalance=(uid,fund=null)=>{
  const f=B49.cache; if(!f||!f.charges)return {due:0,paid:0,prior:0,credit:0,bal:0};
  const cf=c=>c.unit_id===uid&&((fund?((c.type||'monthly')===fund):true));
  const pf=p=>p.unit_id===uid&&((fund?((p.type||'monthly')===fund):true));
  const due=(f.charges.filter(cf)).reduce((s,c)=>s+Number(c.amount_due||0),0);
  const paid=(f.payments.filter(pf)).reduce((s,p)=>s+Number(p.amount||0),0);
  const pd=(f.prior||[]).filter(d=>d.unit_id===uid);
  const prior=pd.reduce((s,d)=>{if(fund==='monthly')return s+Number(d.monthly_initial||0);if(fund==='construction')return s+Number(d.construction_initial||0);return s+Number(d.monthly_initial||0)+Number(d.construction_initial||0);},0);
  const credit=pd.reduce((s,d)=>{if(fund==='monthly')return s+Number(d.credit_monthly||0);if(fund==='construction')return s+Number(d.credit_construction||0);return s+Number(d.credit_monthly||0)+Number(d.credit_construction||0);},0);
  return {due,paid,prior,credit,bal:due+prior-paid-credit};
};
B49.fundIncome=(fund)=>(B49.cache.payments||[]).filter(p=>(p.type||'monthly')===fund).reduce((s,p)=>s+Number(p.amount||0),0);
B49.fundExpense=(fund)=>(B49.cache.expenses||[]).filter(e=>e.fund===fund).reduce((s,e)=>s+Number(e.amount||0),0);
B49.fundOpening=(fund)=>{const s=B49.cache.settings||{};return Number(fund==='monthly'?s.fund_monthly_opening:fund==='construction'?s.fund_construction_opening:0)||0;};
B49.fundBalance=(fund)=>B49.fundOpening(fund)+B49.fundIncome(fund)-B49.fundExpense(fund);
B49.unitLedgerRows=(uid)=>{
  const rows=[];
  (B49.cache.prior||[]).filter(d=>d.unit_id===uid).forEach(d=>{
    if(d.monthly_initial)rows.push({date:d.as_of_date,fundKey:'monthly',debit:Number(d.monthly_initial),credit:0});
    if(d.construction_initial)rows.push({date:d.as_of_date,fundKey:'construction',debit:Number(d.construction_initial),credit:0});
    if(d.credit_monthly)rows.push({date:d.as_of_date,fundKey:'monthly',debit:0,credit:Number(d.credit_monthly)});
    if(d.credit_construction)rows.push({date:d.as_of_date,fundKey:'construction',debit:0,credit:Number(d.credit_construction)});
  });
  (B49.cache.charges||[]).filter(c=>c.unit_id===uid).forEach(c=>rows.push({date:c.created_at||'2024-10-01',fundKey:(c.type||'monthly'),debit:Number(c.amount_due||0),credit:0}));
  (B49.cache.payments||[]).filter(p=>p.unit_id===uid).forEach(p=>rows.push({date:p.payment_date,fundKey:(p.type||'monthly'),debit:0,credit:Number(p.amount||0)}));
  rows.sort((a,b)=>new Date(a.date)-new Date(b.date));
  let runM=0,runC=0;rows.forEach(r=>{if(r.fundKey==='monthly'){runM+=r.debit-r.credit;r.run=runM;}else{runC+=r.debit-r.credit;r.run=runC;}});
  return rows;
};
// توزیع سهم متراژی/مساوی + کنترل گردکردن (عین bulkCharge)
function distributeEqual(amt,n){const base=Math.floor(amt/n),rem=amt-base*n;return Array.from({length:n},(_,i)=>base+(i<rem?1:0));}
function distributeByArea(amt,pending){
  const total=pending.reduce((s,u)=>s+Number(u.area||0),0);
  if(total<=0)return distributeEqual(amt,pending.length);
  let allocated=0;const shares=pending.map(u=>{const s=Math.round(amt*(Number(u.area||0)/total));allocated+=s;return s;});
  let diff=amt-allocated;for(let i=0;i<pending.length&&diff!==0;i++){shares[i]+=diff>0?1:-1;diff+=diff>0?-1:1;}
  return shares;
}
// upsert+ignoreDuplicates: شبیه‌سازی جلوگیری از صدور تکراری (کلید unit_id+jmonth+type)
function issueCharges(existing,rows){
  const ex=new Set(existing.map(c=>c.unit_id+'|'+c.jmonth+'|'+c.type));
  const ins=[];const skip=[];
  rows.forEach(r=>{const k=r.unit_id+'|'+r.jmonth+'|'+r.type;if(ex.has(k)){skip.push(r);}else{ins.push(r);ex.add(k);}});
  return {inserted:ins.length,skipped:skip.length};
}
// گزارش پروژه
function projectReport(projects,charges,payments,expenses){
  return projects.map(p=>{
    const issued=charges.filter(c=>c.project_id===p.id&&c.type==='construction').reduce((s,c)=>s+Number(c.amount_due||0),0);
    const collected=payments.filter(pay=>pay.project_id===p.id).reduce((s,pay)=>s+Number(pay.amount||0),0);
    const exp=expenses.filter(e=>e.project_id===p.id).reduce((s,e)=>s+Number(e.amount||0),0);
    return {name:p.name,budget:p.budget_approved,issued,collected,remaining:issued-collected,exp,cash:collected-exp,progress:issued>0?Math.round(collected/issued*100):0};
  });
}

// ============ سناریوها ============
function reset(extra={}){B49.cache={charges:[],payments:[],units:[{id:1,number:'101',area:100}],owners:[],tenants:[],expenses:[],prior:[],settings:{fund_monthly_opening:0,fund_construction_opening:0},projects:[],...extra};}

// ۱) واحد بدون بدهی و پرداخت
reset();
check('۱. واحد خالی — bal=0',{unit:1},B49.unitBalance(1).bal,0);

// ۲) بدهی اولیه
reset({prior:[{unit_id:1,monthly_initial:500000,construction_initial:0,credit_monthly:0,credit_construction:0,as_of_date:'2024-09-01'}]});
check('۲. بدهی اولیه — bal=500000',{prior:500000},B49.unitBalance(1,'monthly').bal,500000);

// ۳) اعتبار اولیه
reset({prior:[{unit_id:1,monthly_initial:0,construction_initial:0,credit_monthly:300000,credit_construction:0,as_of_date:'2024-09-01'}]});
check('۳. اعتبار اولیه — bal=-300000 (طلب)',{credit:300000},B49.unitBalance(1,'monthly').bal,-300000);

// ۴) بدهی و اعتبار هم‌زمان
reset({prior:[{unit_id:1,monthly_initial:800000,construction_initial:0,credit_monthly:200000,credit_construction:0,as_of_date:'2024-09-01'}]});
check('۴. بدهی+اعتبار — bal=600000',{debt:800000,credit:200000},B49.unitBalance(1,'monthly').bal,600000);

// ۵) پرداخت کامل
reset({charges:[{unit_id:1,jmonth:'1403/08',type:'monthly',amount_due:500000}],payments:[{unit_id:1,type:'monthly',amount:500000,payment_date:'2024-10-05'}]});
check('۵. پرداخت کامل — bal=0',{due:500000,paid:500000},B49.unitBalance(1,'monthly').bal,0);

// ۶) پرداخت ناقص
reset({charges:[{unit_id:1,jmonth:'1403/08',type:'monthly',amount_due:500000}],payments:[{unit_id:1,type:'monthly',amount:300000,payment_date:'2024-10-05'}]});
check('۶. پرداخت ناقص — bal=200000',{due:500000,paid:300000},B49.unitBalance(1,'monthly').bal,200000);

// ۷) پرداخت بیشتر → اعتبار
reset({charges:[{unit_id:1,jmonth:'1403/08',type:'monthly',amount_due:500000}],payments:[{unit_id:1,type:'monthly',amount:700000,payment_date:'2024-10-05'}]});
check('۷. پرداخت بیشتر — bal=-200000 (طلب)',{due:500000,paid:700000},B49.unitBalance(1,'monthly').bal,-200000);

// ۸) تفکیک ماهانه/عمرانی
reset({charges:[{unit_id:1,jmonth:'1403/08',type:'monthly',amount_due:400000},{unit_id:1,jmonth:'1403/08',type:'construction',amount_due:600000}],payments:[{unit_id:1,type:'monthly',amount:100000,payment_date:'2024-10-05'}]});
check('۸. تفکیک — ماهانه bal=300000',{m:'400k-100k'},B49.unitBalance(1,'monthly').bal,300000);
check('۸. تفکیک — عمرانی bal=600000',{c:'600k'},B49.unitBalance(1,'construction').bal,600000);

// ۹) تفکیک موجودی دو صندوق
reset({payments:[{unit_id:1,type:'monthly',amount:1000000,payment_date:'2024-10-05'},{unit_id:1,type:'construction',amount:2000000,payment_date:'2024-10-05'}],expenses:[{fund:'monthly',amount:300000},{fund:'construction',amount:500000}],settings:{fund_monthly_opening:0,fund_construction_opening:0}});
check('۹. صندوق ماهانه = ۱۰۰k درآمد − ۳۰۰k هزینه',{inc:1000000,exp:300000},B49.fundBalance('monthly'),700000);
check('۹. صندوق عمرانی = ۲۰۰k درآمد − ۵۰۰k هزینه',{inc:2000000,exp:500000},B49.fundBalance('construction'),1500000);

// ۱۰) افتتاحیه + درآمد - هزینه
reset({payments:[{unit_id:1,type:'monthly',amount:500000,payment_date:'2024-10-05'}],expenses:[{fund:'monthly',amount:200000}],settings:{fund_monthly_opening:1000000,fund_construction_opening:0}});
check('۱۰. fundBalance = افتتاحیه+درآمد−هزینه',{open:1000000,inc:500000,exp:200000},B49.fundBalance('monthly'),1300000);

// ۱۱) صدور شارژ مساوی
const eq=distributeEqual(1000000,4);
check('۱۱. شارژ مساوی — جمع=مبلغ',{amt:1000000,n:4},eq.reduce((a,b)=>a+b,0),1000000);
check('۱۱. شارژ مساوی — توزیع',{amt:1000000,n:4},eq,[250000,250000,250000,250000]);

// ۱۲) شارژ متراژی + کنترل گردکردن
const ar=distributeByArea(1000000,[{area:100},{area:100},{area:100}]);
check('۱۲. متراژی — جمع=مبلغ',{amt:1000000},ar.reduce((a,b)=>a+b,0),1000000);
check('۱۲. متراژی — توزیع باقی‌مانده',{},ar,[333334,333333,333333]);

// ۱۳) جلوگیری از صدور تکراری (upsert+ignoreDuplicates شبیه‌سازی)
const existing=[{unit_id:1,jmonth:'1403/08',type:'monthly'},{unit_id:2,jmonth:'1403/08',type:'monthly'}];
const r=issueCharges(existing,[{unit_id:1,jmonth:'1403/08',type:'monthly'},{unit_id:3,jmonth:'1403/08',type:'monthly'}]);
check('۱۳. صدور تکراری — ۱ درج، ۱ رد',{dup:1,new:1},r,{inserted:1,skipped:1});

// ۱۴) تخصیص پرداخت به پروژه
const pr=projectReport([{id:9,name:'نما',budget_approved:50000000}],[{unit_id:1,type:'construction',project_id:9,amount_due:3000000}],[{unit_id:1,project_id:9,amount:1000000}],[]);
check('۱۴. وصول‌شده‌ی پروژه = ۱۰۰k',{},pr[0].collected,1000000);

// ۱۵) بدهی باقی‌مانده پروژه
check('۱۵. بدهی باقی پروژه = صادرشده − وصول',{issued:3000000,collected:1000000},pr[0].remaining,2000000);

// ۱۶) پرداخت‌های تخصیص‌نیافته (بدون project_id)
reset({payments:[{unit_id:1,type:'monthly',amount:400000,payment_date:'2024-10-05'},{unit_id:1,type:'construction',amount:600000,project_id:null,payment_date:'2024-10-05'}]});
const unalloc=B49.cache.payments.filter(p=>p.type==='construction'&&!p.project_id).reduce((s,p)=>s+p.amount,0);
check('۱۶. پرداخت عمرانی تخصیص‌نیافته = ۶۰۰k',{},unalloc,600000);

// ۱۷) انتقال بین دو صندوق — پشتیبانی نمی‌شود
check('۱۷. انتقال بین صندوق‌ها','N/A','پشتیبانی نمی‌شود','پشتیبانی نمی‌شود','na');

// ۱۸) گردش حساب واحد — مانده نهایی مستقل هر صندوق
reset({prior:[{unit_id:1,monthly_initial:100000,construction_initial:0,credit_monthly:0,credit_construction:0,as_of_date:'2024-09-01'}],charges:[{unit_id:1,jmonth:'1403/08',type:'monthly',amount_due:500000,created_at:'2024-10-01'},{unit_id:1,jmonth:'1403/08',type:'construction',amount_due:200000,created_at:'2024-10-01'}],payments:[{unit_id:1,type:'monthly',amount:300000,payment_date:'2024-10-05'}]});
const rows=B49.unitLedgerRows(1);
const lastM=[...rows].reverse().find(r=>r.fundKey==='monthly');
const lastC=[...rows].reverse().find(r=>r.fundKey==='construction');
check('۱۸. مانده نهایی ماهانه',{prior:100000,due:500000,paid:300000},lastM.run,300000);
check('۱۸. مانده نهایی عمرانی (مستقل)',{due:200000},lastC.run,200000);

// ۱۹) تطبیق مجموع دفتر کل با گزارش صندوق
// مجموع مانده‌ی ماهانه‌ی همه‌ی واحدها = مجموع صادرشده‌ی ماهانه + مجموع prior ماهانه − درآمد ماهانه − مجموع credit ماهانه
reset({charges:[{unit_id:1,jmonth:'1403/08',type:'monthly',amount_due:500000},{unit_id:2,jmonth:'1403/08',type:'monthly',amount_due:500000}],payments:[{unit_id:1,type:'monthly',amount:300000,payment_date:'2024-10-05'}],prior:[{unit_id:1,monthly_initial:100000,construction_initial:0,credit_monthly:0,credit_construction:0,as_of_date:'2024-09-01'}],units:[{id:1,number:'101'},{id:2,number:'102'}],settings:{}});
const sumUnitBal=[1,2].reduce((s,u)=>s+B49.unitBalance(u,'monthly').bal,0);
const fundInc=B49.fundIncome('monthly');
const totalIssued=B49.cache.charges.filter(c=>(c.type||'monthly')==='monthly').reduce((s,c)=>s+c.amount_due,0);
const totalPrior=B49.cache.prior.reduce((s,d)=>s+(d.monthly_initial||0)-(d.credit_monthly||0),0);
const recon=totalIssued+totalPrior-fundInc;
check('۱۹. تطبیق: Σمانده واحدها = صادرشده+prior−درآمد',{sumBal:sumUnitBal,recon},sumUnitBal,recon);

// ۲۰) مبالغ منفی/صفر/بسیار بزرگ/خالی
reset({charges:[{unit_id:1,jmonth:'1403/08',type:'monthly',amount_due:0}],payments:[{unit_id:1,type:'monthly',amount:null,payment_date:'2024-10-05'}],prior:[{unit_id:1,monthly_initial:null,construction_initial:null,credit_monthly:null,credit_construction:null,as_of_date:'2024-09-01'}],settings:{}});
const b0=B49.unitBalance(1,'monthly');
check('۲۰. داده خالی/صفر — bal=0 بدون NaN',{nullish:true},b0.bal,0);
reset({charges:[{unit_id:1,jmonth:'1403/08',type:'monthly',amount_due:999999999999}],payments:[{unit_id:1,type:'monthly',amount:1,payment_date:'2024-10-05'}]});
check('۲۰. مبلغ بسیار بزرگ — بدون سرریز/NaN',{big:999999999999},Number.isFinite(B49.unitBalance(1,'monthly').bal),true);

// ============ گزارش نهایی ============
console.log('\n═══════════════════════════════════════════════');
console.log(`خلاصه: کل=${pass+fail+na} | موفق=${pass} | ناموفق=${fail} | پشتیبانی‌نشده=${na}`);
console.log('═══════════════════════════════════════════════');
// خروجی JSON برای داشبورد
const fs=require('fs'),path=require('path');
const out={suite:'accounting',total:pass+fail+na,passed:pass,failed:fail,notApplicable:na,timestamp:new Date().toISOString(),results};
// مسیر نسبی به دایرکتوری همین فایل (کارا هم در GitHub Actions و هم محلی)
fs.writeFileSync(path.join(__dirname,'.last-accounting-report.json'),JSON.stringify(out,null,2));
process.exit(fail?1:0);
