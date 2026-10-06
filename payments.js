// Parent-facing "pay your team's fee" card. Used by pay.html (link from the registration confirmation, no login
// needed) and by the Parent Dashboard (one card per athlete).
// window.renderFeeCard(container, { sb, regId, email, compact })
(function(){
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const money=v=>'$'+(+v||0).toFixed(2).replace(/\.00$/,'');
const fmtD=d=>d?new Date(String(d).slice(0,10)+'T12:00:00').toLocaleDateString('en-US',{month:'long',day:'numeric',year:'numeric'}):'';
const METHOD={card:'Card',zelle:'Zelle',cashapp:'Cash App',venmo:'Venmo',check:'Check',cash:'Cash',other:'Other',waiver:'Waived'};
const STATUS={reported:'Sent — waiting for the team to confirm',received:'Received',failed:'Did not go through',refunded:'Refunded',void:'Not received'};

window.renderFeeCard=async function(el, o){
  el.innerHTML='<p class="text-sm text-gray-500">Checking your balance…</p>';
  let d;
  try{ const {data,error}=await o.sb.rpc('fee_for_registration',{p_reg:o.regId,p_email:o.email||''}); if(error) throw error; d=data; }
  catch(e){ el.innerHTML=`<p class="text-sm text-red-700">${esc(e.message||e)}</p>`; return; }
  const r=d.registration, s=d.settings, f=d.fee, team=d.team_name||r.team_code;
  const who=`${esc(r.first_name)} ${esc(r.last_name)}`;
  if(!s||!(+s.fee_amount>0)){ el.innerHTML=`<div class="font-bold">${o.compact?'Team fee':who+' — '+esc(team)+' team fee'}</div><p class="text-sm text-gray-600 mt-1"><b>${esc(team)} hasn't posted its team fee here yet</b>, so there's nothing to pay in the app right now. Your team admin can add it on their Payments tab, and this page (and your Parent Dashboard) will then show the amount and the ways to pay.</p>`; return; }
  if(!f){ el.innerHTML=`<p class="text-sm text-gray-600">${esc(team)}'s fee is <b>${money(s.fee_amount)}</b> per athlete${s.fee_note?` (${esc(s.fee_note)})`:''}. Your athlete's fee hasn't been added yet — check back shortly or ask your team.</p>`; return; }
  const bal=+f.balance, paid=+f.paid;
  const pending=(d.payments||[]).filter(p=>p.status==='reported');
  const head=f.status==='paid'?`<span class="pill" style="background:#16a34a;color:#fff">Paid in full ✓</span>`
    :f.status==='waived'?`<span class="pill" style="background:#e5e7eb">Fee waived</span>`
    :f.status==='void'?`<span class="pill" style="background:#e5e7eb">No fee due</span>`
    :f.status==='plan'?`<span class="pill" style="background:${f.plan_failed?'#dc2626':'#2563eb'};color:#fff">${f.plan_failed?'Payment plan — card problem':'Payment plan — '+f.plan_paid+' of '+f.plan_installments+' paid'}</span>`
    :pending.length?`<span class="pill" style="background:#fef3c7;color:#92400e">Payment sent — awaiting team confirmation</span>`
    :`<span class="pill" style="background:#fee2e2;color:#991b1b">${money(bal)} due</span>`;
  const hist=(d.payments||[]).length?`<details class="mt-2 text-xs"><summary class="cursor-pointer text-gray-600">Payment history</summary><table class="w-full mt-1">${d.payments.map(p=>`<tr class="border-t"><td class="py-1">${esc(fmtD(p.received_on||p.reported_at))}</td><td>${esc(METHOD[p.method]||p.method)}${p.kind==='deposit'?' · deposit':p.kind==='installment'?' · monthly payment':p.kind==='refund'?' · refund':''}${p.reference?` · ${esc(p.reference)}`:''}</td><td class="text-right font-mono">${p.kind==='refund'?'−':''}${money(p.amount)}</td><td class="text-right">${esc(STATUS[p.status]||p.status)}</td></tr>`).join('')}</table></details>`:'';
  let body='';
  if(f.status==='paid'||f.status==='waived'||f.status==='void'){ body=''; }
  else if(f.status==='plan'){
    body=`<p class="text-sm mt-1">${f.plan_failed?`<b class="text-red-700">The last monthly payment didn't go through</b> (card declined or expired). Put a new card on file and we'll retry right away.`
      :`Monthly payments of <b>${money(f.plan_amount)}</b> are charged automatically to your card${f.plan_next_on?`; next one ${esc(fmtD(f.plan_next_on))}`:''}. Remaining balance: <b>${money(bal)}</b>.`}</p>
      <div class="flex flex-wrap gap-2 mt-2">${f.plan_failed?`<button class="btn" style="background:#dc2626;color:#fff" data-pay="update_card">Update my card</button>`:''}${bal>0?`<button class="btn bg-gray-200" data-pay="pay">Pay the rest now (${money(bal)})</button>`:''}</div>`;
  } else {
    const cardOk=s.accept_card&&d.card_ready;
    const planOk=cardOk&&s.plan_enabled&&paid===0&&+s.plan_deposit<bal&&!pending.length;
    let planLine=''; if(planOk){ const n=+s.plan_installments||1, instC=Math.floor((Math.round(bal*100)-Math.round(s.plan_deposit*100))/n), depC=Math.round(bal*100)-instC*n;
      planLine=`<button class="btn bg-white border" data-pay="plan">Payment plan: ${money(depC/100)} today + ${n} monthly payment${n>1?'s':''} of ${money(instC/100)}</button>`; }
    const others=[s.accept_zelle&&['zelle','Zelle',s.zelle_info],s.accept_cashapp&&['cashapp','Cash App',s.cashapp_info],s.accept_venmo&&['venmo','Venmo',s.venmo_info],s.accept_other&&['check','Check or cash',s.other_info]].filter(Boolean);
    body=`<p class="text-sm mt-1">${esc(team)} team fee for ${who}: <b>${money(f.amount_due)}</b>${+f.discount>0?` <span class="text-xs text-gray-500">(${esc(f.discount_note||'discount')} −${money(f.discount)} applied)</span>`:''}${s.fee_note?`<span class="block text-xs text-gray-500">${esc(s.fee_note)}</span>`:''}${paid>0?` — paid so far ${money(paid)}, <b>${money(bal)}</b> left.`:''}${f.note?`<span class="block text-xs text-gray-500">${esc(f.note)}</span>`:''}</p>
      ${pending.length?`<p class="text-sm mt-1" style="color:#92400e">You told us you sent ${pending.map(p=>money(p.amount)+' by '+(METHOD[p.method]||p.method)).join(' and ')}. Your team will mark it received when it arrives.</p>`:''}
      ${cardOk?`<div class="flex flex-wrap gap-2 mt-2"><button class="btn" style="background:#2563eb;color:#fff" data-pay="pay">Pay ${money(bal)} by card</button>${planLine}</div><p class="text-xs text-gray-500 mt-1">Card payments go through Stripe's secure checkout, straight to ${esc(team)}. This app never sees your card number.</p>`
        :s.accept_card?`<p class="text-xs text-gray-500 mt-2">Card payments for ${esc(team)} aren't switched on yet.</p>`:''}
      ${others.length?`<div class="mt-2"><div class="text-sm font-semibold">Other ways to pay</div>${others.map(([k,l,info])=>`<details class="text-sm mt-1"><summary class="cursor-pointer">${esc(l)}</summary><div class="pl-3 mt-1">${info?`<p class="mb-1">${esc(info)}</p>`:''}<p class="text-xs text-gray-500 mb-1">Send ${money(bal)}${k==='check'?' to the team':''}, then tell us so the team knows to look for it:</p>
        <div class="flex flex-wrap gap-2 items-end"><label class="text-xs">Amount<br><input type="number" step="0.01" min="1" value="${bal.toFixed(2)}" class="border rounded p-1" style="width:6rem" data-amt="${k}"></label><label class="text-xs flex-1">Confirmation # / check # (optional)<br><input class="border rounded p-1 w-full" data-ref="${k}"></label>${k==='check'?`<label class="text-xs">Paid by<br><select class="border rounded p-1" data-sub="${k}"><option value="check">Check</option><option value="cash">Cash</option></select></label>`:''}<button class="btn bg-gray-800 text-white text-sm" data-report="${k}">I sent it</button></div></div></details>`).join('')}</div>`:''}`;
  }
  el.innerHTML=`<div class="flex flex-wrap items-center gap-2"><div class="font-bold flex-1">${o.compact?'Team fee':who+' — '+esc(team)+' team fee'}</div>${head}</div>${body}${hist}<p class="text-sm mt-2 hidden" data-msg></p>`;
  const msg=el.querySelector('[data-msg]'), say=(t,bad)=>{ msg.textContent=t; msg.className='text-sm mt-2 '+(bad?'text-red-700':'text-green-700'); };
  el.querySelectorAll('button[data-pay]').forEach(b=>b.onclick=async()=>{ b.disabled=true; say('Opening secure checkout…');
    try{ const {data,error}=await o.sb.functions.invoke('fee-checkout',{body:{action:b.dataset.pay,registration_id:o.regId,email:o.email||''}});
      if(error){ let m=error.message; try{ const j=await error.context?.json(); if(j?.error) m=j.error; }catch(e){} throw new Error(m); }
      if(data?.error) throw new Error(data.error); location.href=data.url; }
    catch(e){ say(e.message||String(e),true); b.disabled=false; } });
  el.querySelectorAll('button[data-report]').forEach(b=>b.onclick=async()=>{ const k=b.dataset.report, amt=+el.querySelector(`[data-amt="${k}"]`).value, ref=el.querySelector(`[data-ref="${k}"]`).value.trim();
    const method=k==='check'?el.querySelector(`[data-sub="${k}"]`).value:k; if(!(amt>0)){ say('Enter the amount you sent.',true); return; }
    b.disabled=true; const {error}=await o.sb.rpc('report_offline_payment',{p_reg:o.regId,p_email:o.email||'',p_method:method,p_amount:amt,p_reference:ref||null});
    if(error){ say(error.message,true); b.disabled=false; return; } window.renderFeeCard(el,o); });
};
})();
