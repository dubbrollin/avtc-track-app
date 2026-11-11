// Parent-facing "pay your team's fee" card. Used by pay.html (link from the registration confirmation, no login
// needed) and by the Parent Dashboard (one card per athlete).
// window.renderFeeCard(container, { sb, regId, email, compact })  → resolves to { due, paid, balance, status } (or null)
// The team keeps a LIST of fees and discounts; the card shows the total and every line that makes it up.
(function(){
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const money=v=>'$'+(+v||0).toFixed(2).replace(/\.00$/,'');
const fmtD=d=>d?new Date(String(d).slice(0,10)+'T12:00:00').toLocaleDateString('en-US',{month:'long',day:'numeric',year:'numeric'}):'';
const METHOD={card:'Card',zelle:'Zelle',cashapp:'Cash App',venmo:'Venmo',check:'Check',cash:'Cash',other:'Other',waiver:'Waived'};
const STATUS={reported:'Sent — waiting for the team to confirm',received:'Received',failed:'Did not go through',refunded:'Refunded',void:'Not received'};

// Every line that makes up this athlete's total, then the total (and what's paid / left once money has come in).
function breakdown(d){ const f=d.fee, L=d.lines||[]; if(!f||!L.length) return '';
  const paid=+f.paid||0;
  return `<table class="w-full text-sm mt-2" style="border-collapse:collapse">${L.map(l=>`<tr style="border-top:1px solid #eee${l.removed?';color:#9ca3af':''}"><td class="py-1 pr-2"><span ${l.removed?'style="text-decoration:line-through"':''}>${esc(l.name)}</span>${l.family?' <span class="text-xs text-gray-500">· once per family</span>':''}${l.percent!=null&&!l.removed?` <span class="text-xs text-gray-500">· ${+l.percent}% off</span>`:''}${l.removed?' <span class="text-xs">· taken off</span>':''}${l.note?`<span class="block text-xs text-gray-500">${esc(l.note)}</span>`:''}</td>
    <td class="py-1 text-right font-mono whitespace-nowrap" ${l.removed?'style="text-decoration:line-through"':''}>${l.kind==='discount'?'−':''}${money(l.amount)}</td></tr>`).join('')}
    <tr style="border-top:2px solid #111"><td class="py-1 font-bold">Total</td><td class="py-1 text-right font-mono font-bold">${money(f.amount_due)}</td></tr>
    ${paid>0?`<tr><td class="py-1">Paid so far</td><td class="py-1 text-right font-mono">−${money(paid)}</td></tr><tr><td class="py-1 font-bold">Left to pay</td><td class="py-1 text-right font-mono font-bold">${money(f.balance)}</td></tr>`:''}</table>`; }
const WHO={athlete:'each athlete',family:'once per family',sibling:'each additional child',new:'new athletes',returning:'returning athletes',choose:'if it applies to your athlete'};
function teamList(d){ const I=d.items||[]; if(!I.length) return '';
  return `<table class="w-full text-sm mt-2" style="border-collapse:collapse">${I.map(i=>`<tr style="border-top:1px solid #eee"><td class="py-1 pr-2">${esc(i.name)} <span class="text-xs text-gray-500">· ${WHO[i.applies]||''}</span>${i.note?`<span class="block text-xs text-gray-500">${esc(i.note)}</span>`:''}</td><td class="py-1 text-right font-mono whitespace-nowrap">${i.kind==='discount'?'−':''}${i.is_percent?(+i.amount)+'%':money(i.amount)}</td></tr>`).join('')}</table>`; }

window.renderFeeCard=async function(el, o){ const r=await card(el,o); return r||null; };
async function card(el, o){
  el.innerHTML='<p class="text-sm text-gray-500">Checking your balance…</p>';
  let d;
  try{ const {data,error}=await o.sb.rpc('fee_for_registration',{p_reg:o.regId,p_email:o.email||''}); if(error) throw error; d=data; }
  catch(e){ el.innerHTML=`<p class="text-sm text-red-700">${esc(e.message||e)}</p>`; return; }
  const r=d.registration, s=d.settings, f=d.fee, team=d.team_name||r.team_code;
  // Parent Dashboard (compact): once the fee is settled — paid in full, waived, or nothing due — the box disappears for good.
  // The fee belongs to this season's registration, so it comes back only with next season's registration. (pay.html still shows "Paid in full".)
  const sum=f?{due:+f.amount_due,paid:+f.paid,balance:+f.balance,status:f.status}:null;
  if(o.compact&&f&&(f.status==='paid'||f.status==='waived'||f.status==='void')){ el.remove(); return sum; }
  const who=`${esc(r.first_name)} ${esc(r.last_name)}`;
  if(!f&&!(d.items||[]).length&&(!s||!(+s.fee_amount>0))){ el.innerHTML=`<div class="font-bold">${o.compact?'Team fee':who+' — '+esc(team)+' team fee'}</div><p class="text-sm text-gray-600 mt-1"><b>${esc(team)} hasn't posted its team fee here yet</b>, so there's nothing to pay in the app right now. Your team admin can add it on their Payments tab, and this page (and your Parent Dashboard) will then show the amount and the ways to pay.</p>`; return; }
  if(!f){ el.innerHTML=`<div class="font-bold">${o.compact?'Team fees':who+' — '+esc(team)+' team fees'}</div><p class="text-sm text-gray-600 mt-1">Here is what ${esc(team)} charges this season${s&&s.fee_note?` (${esc(s.fee_note)})`:''}. Your athlete's own total hasn't been added yet — check back shortly or ask your team.</p>${teamList(d)}`; return; }
  // Paying online and having the app track payments is a paid team extra. Without it the parent simply sees what the team charges.
  let extras=false; try{ const {data:x}=await o.sb.from('team_messaging').select('enabled').eq('team_code',r.team_code).maybeSingle(); extras=!!(x&&x.enabled); }catch(e){}
  if(!extras){ const none=f.status==='waived'||f.status==='void';
    el.innerHTML=`<div class="flex flex-wrap items-center gap-2"><div class="font-bold flex-1">${o.compact?'Team fee':who+' — '+esc(team)+' team fee'}</div><span class="pill" style="background:#e5e7eb">${none?(f.status==='waived'?'Fee waived':'No fee due'):money(f.amount_due)}</span></div>
      ${none?'':`<p class="text-sm mt-1">${esc(team)} team fees for ${who}: <b>${money(f.amount_due)}</b>${s&&s.fee_note?`<span class="block text-xs text-gray-500">${esc(s.fee_note)}</span>`:''}${f.note?`<span class="block text-xs text-gray-500">${esc(f.note)}</span>`:''}</p>${breakdown(d)}
      <p class="text-xs text-gray-500 mt-1">Your team will let you know how and when to pay.</p>`}`; return sum; }
  const bal=+f.balance, paid=+f.paid;
  const pending=(d.payments||[]).filter(p=>p.status==='reported');
  const head=f.status==='paid'?`<span class="pill" style="background:#16a34a;color:#fff">Paid in full ✓</span>`
    :f.status==='waived'?`<span class="pill" style="background:#e5e7eb">Fee waived</span>`
    :f.status==='void'?`<span class="pill" style="background:#e5e7eb">No fee due</span>`
    :f.status==='plan'?`<span class="pill" style="background:${f.plan_failed?'#dc2626':'#2563eb'};color:#fff">${f.plan_failed?'Payment plan — card problem':'Payment plan — '+f.plan_paid+' of '+f.plan_installments+' paid'}</span>`
    :pending.length?`<span class="pill" style="background:#fef3c7;color:#92400e">Payment sent — awaiting team confirmation</span>`
    :`<span class="pill" style="background:#fee2e2;color:#991b1b">${money(bal)} due</span>`;
  const hist=(d.payments||[]).length?`<details class="mt-2 text-xs"><summary class="cursor-pointer text-gray-600">Payment history</summary><table class="w-full mt-1">${d.payments.map(p=>`<tr class="border-t"><td class="py-1">${esc(fmtD(p.received_on||p.reported_at))}</td><td>${esc(METHOD[p.method]||p.method)}${p.kind==='deposit'?' · deposit':p.kind==='installment'?' · plan payment':p.kind==='refund'?' · refund':''}${p.reference?` · ${esc(p.reference)}`:''}</td><td class="text-right font-mono">${p.kind==='refund'?'−':''}${money(p.amount)}</td><td class="text-right">${esc(STATUS[p.status]||p.status)}</td></tr>`).join('')}</table></details>`:'';
  let body='';
  if(f.status==='paid'||f.status==='waived'||f.status==='void'){ body=f.status==='paid'&&!o.compact?`<details class="mt-1 text-sm"><summary class="cursor-pointer text-gray-600">What this covered</summary>${breakdown(d)}</details>`:''; }
  else if(f.status==='plan'){
    body=`<p class="text-sm mt-1">${f.plan_failed?`<b class="text-red-700">The last monthly payment didn't go through</b> (card declined or expired). Put a new card on file and we'll retry right away.`
      :`Payments of <b>${money(f.plan_amount)}</b> are charged automatically to your card${f.plan_next_on?`; next one ${esc(fmtD(f.plan_next_on))}`:''} (${f.plan_paid} of ${f.plan_installments} done). Remaining balance: <b>${money(bal)}</b>.`}</p><details class="mt-1 text-sm"><summary class="cursor-pointer text-gray-600">See what the ${money(f.amount_due)} is made of</summary>${breakdown(d)}</details>
      <div class="flex flex-wrap gap-2 mt-2">${f.plan_failed?`<button class="btn" style="background:#dc2626;color:#fff" data-pay="update_card">Update my card</button>`:''}${bal>0?`<button class="btn bg-gray-200" data-pay="pay">Pay the rest now (${money(bal)})</button>`:''}</div>`;
  } else {
    const cardOk=s.accept_card&&d.card_ready;
    const planOk=cardOk&&s.plan_enabled&&paid===0&&+s.plan_deposit<bal&&!pending.length;
    let planLine=''; if(planOk){ const n=+s.plan_installments||1, instC=Math.floor((Math.round(bal*100)-Math.round(s.plan_deposit*100))/n), depC=Math.round(bal*100)-instC*n;
      const every={week:'weekly',"2weeks":'every-two-weeks',month:'monthly'}[s.plan_interval||'month']||'monthly';
      planLine=`<button class="btn bg-white border" data-pay="plan">Payment plan: ${money(depC/100)} today + ${n} ${every} payment${n>1?'s':''} of ${money(instC/100)}${s.plan_first_date?' starting '+esc(fmtD(s.plan_first_date)):''}</button>`; }
    const others=[s.accept_zelle&&['zelle','Zelle',s.zelle_info],s.accept_cashapp&&['cashapp','Cash App',s.cashapp_info],s.accept_venmo&&['venmo','Venmo',s.venmo_info],s.accept_other&&['check','Check or cash',s.other_info]].filter(Boolean);
    body=`<p class="text-sm mt-1">${esc(team)} team fees for ${who}: <b>${money(f.amount_due)}</b>${paid>0?` — paid so far ${money(paid)}, <b>${money(bal)}</b> left.`:''}${s.fee_note?`<span class="block text-xs text-gray-500">${esc(s.fee_note)}</span>`:''}${f.note?`<span class="block text-xs text-gray-500">${esc(f.note)}</span>`:''}</p>${breakdown(d)}
      ${pending.length?`<p class="text-sm mt-1" style="color:#92400e">You told us you sent ${pending.map(p=>money(p.amount)+' by '+(METHOD[p.method]||p.method)).join(' and ')}. Your team will mark it received when it arrives.</p>`:''}
      ${cardOk?`<div class="flex flex-wrap gap-2 mt-2"><button class="btn" style="background:#2563eb;color:#fff" data-pay="pay">Pay ${money(bal)} by card</button>${planLine}</div><p class="text-xs text-gray-500 mt-1">Card payments go through Stripe's secure checkout, straight to ${esc(team)}. This app never sees your card number.</p>`
        :''}
      ${others.length?`<div class="mt-2"><div class="text-sm font-semibold">Other ways to pay</div>${others.map(([k,l,info])=>`<details class="text-sm mt-1"><summary class="cursor-pointer">${esc(l)}</summary><div class="pl-3 mt-1">${info?`<p class="mb-1">${esc(info)}</p>`:''}<p class="text-xs text-gray-500 mb-1">Send ${money(bal)}${k==='check'?' to the team':''}, then tell us so the team knows to look for it:</p>
        <div class="flex flex-wrap gap-2 items-end"><label class="text-xs">Amount<br><input type="number" step="0.01" min="1" value="${bal.toFixed(2)}" class="border rounded p-1" style="width:6rem" data-amt="${k}"></label><label class="text-xs flex-1">Confirmation # / check # (optional)<br><input class="border rounded p-1 w-full" data-ref="${k}"></label>${k==='check'?`<label class="text-xs">Paid by<br><select class="border rounded p-1" data-sub="${k}"><option value="check">Check</option><option value="cash">Cash</option></select></label>`:''}<button class="btn bg-gray-800 text-white text-sm" data-report="${k}">I sent it</button></div></div></details>`).join('')}</div>`:''}`;
  }
  el.innerHTML=`<div class="flex flex-wrap items-center gap-2"><div class="font-bold flex-1">${o.compact?'Team fee':who+' — '+esc(team)+' team fee'}</div>${head}</div>${body}${hist}<p class="text-sm mt-2 hidden" data-msg></p>`;
  const msg=el.querySelector('[data-msg]'), say=(t,bad)=>{ msg.textContent=t; msg.className='text-sm mt-2 '+(bad?'text-red-700':'text-green-700'); };
  el.querySelectorAll('button[data-pay]').forEach(b=>b.onclick=async()=>{ b.disabled=true; say('Opening secure checkout…');
    try{ const {data,error}=await o.sb.functions.invoke('fee-checkout',{body:{action:b.dataset.pay,registration_id:o.regId,email:o.email||'',regs:(o.siblings||[]).join(',')}});
      if(error){ let m=error.message; try{ const j=await error.context?.json(); if(j?.error) m=j.error; }catch(e){} throw new Error(m); }
      if(data?.error) throw new Error(data.error); location.href=data.url; }
    catch(e){ say(e.message||String(e),true); b.disabled=false; } });
  el.querySelectorAll('button[data-report]').forEach(b=>b.onclick=async()=>{ const k=b.dataset.report, amt=+el.querySelector(`[data-amt="${k}"]`).value, ref=el.querySelector(`[data-ref="${k}"]`).value.trim();
    const method=k==='check'?el.querySelector(`[data-sub="${k}"]`).value:k; if(!(amt>0)){ say('Enter the amount you sent.',true); return; }
    b.disabled=true; const {error}=await o.sb.rpc('report_offline_payment',{p_reg:o.regId,p_email:o.email||'',p_method:method,p_amount:amt,p_reference:ref||null});
    if(error){ say(error.message,true); b.disabled=false; return; } await window.renderFeeCard(el,o); if(o.onChange) o.onChange(); });
  return sum;
}
})();
