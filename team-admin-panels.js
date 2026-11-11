// Team-admin panels shared by the Coach Dashboard's "Team admin" section and the Site Admin page:
//   window.mountTeamPayments(el, ctx)   — the team's payment portal (Stripe setup, fee, ways to pay, athletes' balances)
//   window.mountParentSignup(el, ctx)   — the "parents enter meet events themselves: ON / OFF" switch
//   window.mountTeamMessaging(el, ctx)  — Team Messenger (paid team extra): on/off per team (site admins switch it)
// ctx = { sb, team, season, teams:[{code,name,active}], canPickTeam:bool, onTeamChange(code) }
(function(){
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const money=v=>'$'+(+v||0).toFixed(2).replace(/\.00$/,'');
const opts=(list,v)=>list.map(x=>{ const [val,lab]=Array.isArray(x)?x:[x,x]; return `<option value="${esc(val)}" ${String(val)===String(v??'')?'selected':''}>${esc(lab)}</option>`; }).join('');
const teamName=(ctx,c)=>{ const t=(ctx.teams||[]).find(x=>x.code===c); return t?t.name:(c||'—'); };
async function pageAll(mk){ const all=[]; for(let f=0;;f+=1000){ const {data,error}=await mk().range(f,f+999); if(error) throw error; all.push(...(data||[])); if(!data||data.length<1000) break; } return all; }
function toast(m,bad){ let t=document.getElementById('tapToast'); if(!t){ t=document.createElement('div'); t.id='tapToast'; t.style.cssText='position:fixed;bottom:16px;left:50%;transform:translateX(-50%);color:#fff;padding:.6rem 1rem;border-radius:.5rem;font-size:.9rem;z-index:9999;display:none;max-width:90vw'; document.body.appendChild(t); }
  t.textContent=m; t.style.background=bad?'#991b1b':'#111827'; t.style.display='block'; clearTimeout(toast.h); toast.h=setTimeout(()=>t.style.display='none',bad?6000:2500); }
function openModal(html){ let m=document.getElementById('tapModal'); if(!m){ m=document.createElement('div'); m.id='tapModal'; m.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.45);display:none;align-items:center;justify-content:center;z-index:9998;padding:1rem'; m.innerHTML='<div id="tapModalBox" style="background:#fff;border-radius:12px;padding:16px;max-width:36rem;width:100%;max-height:90vh;overflow:auto"></div>'; document.body.appendChild(m); m.addEventListener('mousedown',e=>{ if(e.target===m) closeModal(); }); }
  document.getElementById('tapModalBox').innerHTML=html; m.style.display='flex'; }
function closeModal(){ const m=document.getElementById('tapModal'); if(m) m.style.display='none'; }
window.closeTapModal=closeModal;
const btn=(cls,extra)=>`class="tapbtn ${cls}" ${extra||''}`;
const STYLE=`<style>.tapbtn{padding:.45rem .8rem;border-radius:.5rem;font-weight:600;font-size:.85rem;border:0;cursor:pointer}.tapbtn.pri{background:var(--brand,#1d4ed8);color:#fff}.tapbtn.grn{background:#16a34a;color:#fff}.tapbtn.lite{background:#f3f4f6}.tapbtn:disabled{opacity:.5}
.tappill{font-size:11px;font-weight:700;padding:3px 8px;border-radius:999px;background:#e5e7eb}.tappill.ok{background:#dcfce7;color:#166534}.tappill.warn{background:#fef3c7;color:#92400e}.tappill.bad{background:#fee2e2;color:#991b1b}
.tapcard{background:#fff;border-radius:12px;padding:14px;margin-bottom:12px;box-shadow:0 1px 3px rgba(0,0,0,.08)}.tapt{width:100%;border-collapse:collapse;font-size:.85rem}.tapt th,.tapt td{padding:.4rem .5rem;border-bottom:1px solid #eee;text-align:left;vertical-align:top}.tapt th{background:#f9fafb;font-size:.75rem;text-transform:uppercase;letter-spacing:.03em;color:#555}
.tapscroll{overflow:auto;max-height:70vh}.tap input[type=text],.tap input[type=number],.tap input[type=date],.tap input:not([type]),.tap select{border:1px solid #d1d5db;border-radius:.4rem;padding:.35rem .5rem;font-size:.9rem}.hide{display:none!important}</style>`;

/* ============================ PAYMENTS ============================ */
const PAY_METHODS=[['card','Card (Stripe)'],['zelle','Zelle'],['cashapp','Cash App'],['venmo','Venmo'],['check','Check'],['cash','Cash'],['other','Other']];
const PAY_STATUS={unpaid:['warn','Unpaid'],pending:['warn','Sent — confirm'],plan:['ok','Payment plan'],paid:['ok','Paid'],waived:['','Waived'],void:['','No fee']};
window.mountTeamPayments=async function(el, ctx){
  const sb=ctx.sb, team=ctx.team, SEASON=ctx.season; let rows=[], pending=[], items=[];
  el.classList.add('tap'); el.innerHTML=STYLE+'<p class="text-sm text-gray-500">Loading…</p>';
  let st=null, set=null, extras=false;   // extras = this team has the paid team extras (card payments + payment plans live there)
  try{
    const [{data:a},{data:s},r,{data:pend}]=await Promise.all([
      sb.from('team_stripe_accounts').select('*').eq('team_code',team).maybeSingle(),
      sb.from('team_payment_settings').select('*').eq('team_code',team).eq('season_year',SEASON).maybeSingle(),
      pageAll(()=>sb.from('team_fee_overview').select('*').eq('team_code',team).eq('season_year',SEASON).order('last_name').order('first_name')),
      sb.from('fee_payments').select('*').eq('team_code',team).eq('status','reported').order('reported_at')]);
    st=a; set=s; rows=r; pending=pend||[];
    const {data:it,error:ie}=await sb.from('team_fee_items').select('*').eq('team_code',team).eq('season_year',SEASON).order('sort').order('created_at'); if(ie) throw ie; items=it||[];
    try{ const {data:x}=await sb.from('team_messaging').select('enabled').eq('team_code',team).maybeSingle(); extras=!!(x&&x.enabled); }catch(e){}
  }catch(e){ el.innerHTML=STYLE+'<p class="text-red-700 text-sm">'+esc(e.message)+'</p>'; return; }
  const s=set||{fee_amount:0,sibling_discount:0,plan_enabled:false,plan_deposit:0,plan_installments:2,plan_interval:'month',accept_card:true};
  const chk=(id,v,label)=>`<label class="flex items-center gap-2 text-sm"><input type="checkbox" data-id="${id}" ${v?'checked':''}> ${label}</label>`;
  const q=id=>el.querySelector(`[data-id="${id}"]`);
  const tn=teamName(ctx,team);
  const stripeBox=st?.status==='active'?`<span class="tappill ok">Card payments ON ✓</span> <span class="text-xs text-gray-500">${esc(st.status_detail||'')} Checked ${esc(String(st.checked_at||'').slice(0,10))}</span>`
    :st?`<span class="tappill ${st.status==='restricted'?'bad':'warn'}">${st.status==='restricted'?'Action needed':'Setup not finished'}</span> <span class="text-xs text-gray-500">${esc(st.status_detail||'')}</span>`
    :'<span class="tappill">Not set up</span>';
  const tot=f=>rows.filter(r=>r.status!=='void'&&r.status!=='waived').reduce((a,r)=>a+(+r[f]||0),0);
  el.innerHTML=STYLE+`${ctx.canPickTeam?`<div class="flex items-center gap-2 mb-2 text-sm"><b>Team</b><select data-id="teamSel">${opts((ctx.teams||[]).filter(t=>t.active!==false).map(t=>[t.code,t.name+' ('+t.code+')']),team)}</select></div>`:''}
${extras?`<div class="tapcard"><h3 class="font-bold mb-1">Card payments — ${esc(tn)}'s own Stripe account</h3>
<p class="text-xs text-gray-500 mb-2">Parents pay by card through Stripe and the money is deposited straight into ${esc(tn)}'s bank account. The Stripe account belongs to ${esc(tn)}: the team signs Stripe's agreement itself and handles its own refunds and disputes with Stripe. The conference has no part in it. The team pays Stripe's standard card fee (about 2.9% + 30¢ per payment). Setup takes about 10 minutes: the team's bank account, the responsible person's details, and the team's tax ID (EIN) or that person's SSN for a club without one. Stripe sends you back here when you're done.</p>
<div class="flex flex-wrap items-center gap-2">${stripeBox}
  <button ${btn(st?.status==='active'?'lite':'pri','data-id="stripeConnect"')}>${!st?'Set up Stripe for this team':st.status==='active'?'Open Stripe setup again':'Continue Stripe setup'}</button>
  ${st?`<button ${btn('lite','data-id="stripeStatus"')}>Re-check status</button> <a class="tapbtn lite" href="https://dashboard.stripe.com/" target="_blank" rel="noopener">Stripe dashboard ↗</a>`:''}</div>
${st?`<p class="text-xs text-gray-400 mt-1">Account ${esc(st.stripe_account_id)} · set up by ${esc(st.created_by||'')}. Refunds for card payments are done in the Stripe dashboard; the app records them automatically.</p>`:''}</div>`:`<div class="tapcard" style="border:1px solid #f59e0b;background:#fffbeb"><span class="tappill warn">Paid team extra</span> <b>Taking payments online and tracking them</b> — parents paying by card, payment plans, Zelle / Cash App / Venmo / check with "I sent it", and the app keeping track of who has paid — is part of the paid team extras, which aren't switched on for ${esc(tn)}. ${ctx.canPickTeam?'Switch them on in the Paid Extras tab.':'See the Paid extras tab; the league site admin switches them on.'} What's free: post your team fee below so every parent sees what they owe.</div>`}

<div class="tapcard"><h3 class="font-bold mb-1">${SEASON} team fees &amp; ways to pay</h3>
<p class="text-xs text-gray-500 mb-2">Every team sets its own fees. Every athlete who registers with ${esc(tn)} gets them automatically, and the parent ${extras?'is taken to the payment portal right after submitting the registration':'sees what they owe on their dashboard'}.</p>
<p class="text-sm mb-1"><b>Your fees and discounts</b> <span class="text-xs text-gray-500">— add as many as you need, name them how you like, and choose who each one is for. Parents see the total and every line.</span></p>
<div class="tapscroll" style="max-height:none"><table class="tapt"><thead><tr><th>Name parents see</th><th>Fee or discount</th><th>Amount</th><th>Who gets it</th><th>Note for parents (optional)</th><th></th></tr></thead><tbody data-id="flBody"></tbody></table></div>
<div class="flex flex-wrap gap-2 mt-2"><button ${btn('lite','data-id="flAddFee"')}>+ Add a fee</button><button ${btn('lite','data-id="flAddDisc"')}>+ Add a discount</button></div>
<div data-id="flTotals" class="mt-2 rounded-lg p-2 text-sm" style="background:#f9fafb;border:1px solid #e5e7eb"></div>
<label class="text-sm block mt-2"><b>Message to parents about the fees</b> <span class="text-xs text-gray-500">(optional, shown with the total)</span><br><input data-id="psNote" value="${esc(s.fee_note||'')}" class="w-full" placeholder="e.g. due by March 1 — ask us about scholarships"></label>
<div class="mt-3 ${extras?'':'hide'}">${chk('psCard',s.accept_card!==false,'<b>Card</b> (needs the Stripe setup above)')}
<div class="ml-6 mt-1">${chk('psPlan',s.plan_enabled,'<b>Offer a payment plan</b> — deposit now, then equal monthly card payments charged automatically')}
 <div data-id="psPlanBox" class="flex flex-wrap gap-2 items-end mt-1 ${s.plan_enabled?'':'hide'}">
  <label class="text-sm">Deposit today $<br><input data-id="psDep" type="number" min="0" step="0.01" value="${+s.plan_deposit||''}" style="width:7rem"></label>
  <label class="text-sm">Number of payments<br><select data-id="psN">${opts([1,2,3,4,5,6,7,8,9,10,11,12].map(n=>[n,n]),s.plan_installments||2)}</select></label>
  <label class="text-sm">How often<br><select data-id="psEvery">${opts([['week','Weekly'],['2weeks','Every two weeks'],['month','Monthly']],s.plan_interval||'month')}</select></label>
  <label class="text-sm">First one on<br><input data-id="psFirst" type="date" value="${esc(s.plan_first_date||'')}"></label>
  <span class="text-xs text-gray-500">Example: $250 fee, $100 deposit, 3 payments monthly → $100 today then $50 a month. Pick weekly or every two weeks to collect faster. A missed payment is flagged here and the parent is asked for a new card.</span></div></div></div>
<div class="mt-2 grid gap-2 ${extras?'':'hide'}" style="grid-template-columns:repeat(auto-fit,minmax(18rem,1fr))">
 <div>${chk('psZelle',s.accept_zelle,'<b>Zelle</b>')}<input data-id="psZelleInfo" value="${esc(s.zelle_info||'')}" class="w-full mt-1" placeholder="Zelle to: email or phone, and the name that shows"></div>
 <div>${chk('psCashapp',s.accept_cashapp,'<b>Cash App</b>')}<input data-id="psCashappInfo" value="${esc(s.cashapp_info||'')}" class="w-full mt-1" placeholder="$Cashtag"></div>
 <div>${chk('psVenmo',s.accept_venmo,'<b>Venmo</b>')}<input data-id="psVenmoInfo" value="${esc(s.venmo_info||'')}" class="w-full mt-1" placeholder="@Venmo-handle"></div>
 <div>${chk('psOther',s.accept_other,'<b>Check or cash</b>')}<input data-id="psOtherInfo" value="${esc(s.other_info||'')}" class="w-full mt-1" placeholder="Who to make the check out to, where to bring it"></div>
</div>
<p class="text-xs text-gray-500 mt-2">${extras?'For Zelle, Cash App, Venmo, check and cash the parent taps "I sent it" and you confirm below once it arrives. ':''}Athletes who register after you save get the new list automatically. Athletes already registered keep what they have until you tap "Update athletes who haven't paid"; anyone who has paid something or is on a payment plan is never changed (use "Fees" on their row below).</p>
<div class="flex flex-wrap gap-2 mt-2"><button ${btn('pri','data-id="psSave"')}>Save</button><button ${btn('lite','data-id="psEnsure" title="Puts the saved list on athletes who have no fee yet and on athletes who have not paid anything"')}>Update athletes who haven't paid</button></div></div>

${extras&&pending.length?`<div class="tapcard" style="border:1px solid #f59e0b;background:#fffbeb"><h3 class="font-bold mb-1">Parents say they've sent ${pending.length} payment${pending.length>1?'s':''} — confirm when it arrives</h3>
<table class="tapt"><thead><tr><th>Athlete</th><th>How</th><th>Amount</th><th>Reference</th><th>Sent</th><th></th></tr></thead><tbody>${pending.map(p=>{ const f=rows.find(r=>r.id===p.fee_id)||{};
 return `<tr data-pay="${p.id}"><td>${esc(f.first_name||'')} ${esc(f.last_name||'')}<div class="text-xs text-gray-500">${esc(f.email||'')}</div></td><td>${esc((PAY_METHODS.find(x=>x[0]===p.method)||[0,p.method])[1])}</td><td class="font-mono">${money(p.amount)}</td><td>${esc(p.reference||'')}${p.note?`<div class="text-xs text-gray-500">${esc(p.note)}</div>`:''}</td><td>${esc(String(p.reported_at).slice(0,10))}</td>
 <td class="whitespace-nowrap"><button ${btn('grn','data-act="confirm"')}>Received ✓</button> <button ${btn('lite','data-act="notreceived"')}>Not received</button></td></tr>`; }).join('')}</tbody></table></div>`:''}

<div class="tapcard"><div class="flex flex-wrap items-center gap-2 mb-2"><h3 class="font-bold flex-1">Athletes — ${rows.length} with a fee${extras?` · ${money(tot('paid'))} collected · ${money(tot('balance'))} outstanding`:''}</h3>
 <select data-id="payFilter" class="${extras?'':'hide'}"><option value="">Everyone</option><option value="owing">Still owing</option><option value="plan">On a payment plan</option><option value="paid">Paid</option></select></div>
<div class="tapscroll"><table class="tapt"><thead><tr><th>Athlete</th><th>Parent</th><th>Fee</th>${extras?'<th>Paid</th><th>Balance</th><th>Status</th>':''}<th></th></tr></thead><tbody data-id="payBody"></tbody></table></div>
<p class="text-xs text-gray-500 mt-1">${extras?`"Record payment" is for money you received outside the app (Zelle, check, cash…). Card payments record themselves. "Fees" opens one athlete's lines: change an amount, take a fee off (for example the volunteer fee once the hours are worked), or add a discount or scholarship. "Pay link" copies the parent's personal pay page for this athlete — handy to text or email.`:`"Fees" opens one athlete's lines: change an amount, take a fee off, or add a discount or scholarship; "Waive" removes everything. Tracking who has paid is part of the paid team extras.`}</p></div>`;
  const draw=()=>{ const flt=q('payFilter').value, L=rows.filter(r=>flt==='owing'?(+r.balance>0&&!['waived','void'].includes(r.status)):flt==='plan'?r.status==='plan':flt==='paid'?r.status==='paid':true);
    q('payBody').innerHTML=L.map(r=>{ const [cls,lab]=PAY_STATUS[r.status]||['',r.status];
     return `<tr data-fee="${r.id}"><td>${esc(r.first_name)} ${esc(r.last_name)}<div class="text-xs text-gray-500">${esc(r.division||'')}${r.reg_status==='rejected'?' · rejected':''}</div></td><td class="text-xs">${esc(r.email)}</td>
     <td><span class="font-mono font-bold">${money(r.amount_due)}</span>${(r.lines||[]).map(l=>`<div class="text-xs text-gray-500" ${l.removed?'style="text-decoration:line-through"':''}>${esc(l.name)}${l.family?' (family)':''} ${l.kind==='discount'?'−':''}${money(l.amount)}</div>`).join('')}${r.note?`<div class="text-xs text-gray-500">${esc(r.note)}</div>`:''}</td><td class="font-mono">${money(r.paid)}</td><td class="font-mono ${+r.balance>0&&!['waived','void'].includes(r.status)?'text-red-700 font-bold':''}">${['waived','void'].includes(r.status)?'—':money(r.balance)}</td>
     <td><span class="tappill ${cls}">${lab}</span>${r.status==='plan'?`<div class="text-xs text-gray-500">${r.plan_paid} of ${r.plan_installments} × ${money(r.plan_amount)}${r.plan_next_on?' · next '+esc(r.plan_next_on):''}${r.plan_failed?' · <b class="text-red-700">card failed</b>':''}</div>`:''}${+r.reported_count>0?`<div class="text-xs" style="color:#92400e">${r.reported_count} payment(s) to confirm above</div>`:''}</td>
     <td class="whitespace-nowrap"><button ${btn('lite','data-act="link" title="Copy this athlete\'s pay page link"')}>Pay link</button> ${!['paid','waived','void'].includes(r.status)?`<button ${btn('grn','data-act="record"')}>Record payment</button> `:''}${r.status!=='plan'&&r.status!=='void'?`<button ${btn('lite','data-act="adjust" title="See, change, add or take off this athlete\'s fees and discounts"')}>Fees</button> `:''}${!['paid','waived','void','plan'].includes(r.status)?`<button ${btn('lite','data-act="waive"')}>Waive</button>`:''}</td></tr>`; }).join('')
     ||'<tr><td colspan="7" class="p-3 text-gray-500">No athletes here yet.</td></tr>';
    // Without the paid extras the app doesn't track payments: fee only, plus Adjust / Waive.
    if(!extras) q('payBody').querySelectorAll('tr[data-fee]').forEach(tr=>{ [5,4,3].forEach(i=>tr.children[i]&&tr.children[i].remove()); tr.querySelectorAll('[data-act="link"],[data-act="record"]').forEach(x=>x.remove()); }); };
  draw();
  const refresh=()=>window.mountTeamPayments(el,ctx);
  /* ---- the fee list ---- */
  const WHO=[['athlete','Every athlete'],['family','Once per family'],['sibling','Each additional child (2nd, 3rd…)'],['new','New athletes only'],['returning','Returning athletes only'],['choose','Only athletes I pick']];
  let list=items.map(i=>({id:i.id,name:i.name,kind:i.kind,amount:+i.amount,is_percent:!!i.is_percent,applies:i.applies,note:i.note||''})), dirty=false;
  const readList=()=>{ q('flBody').querySelectorAll('tr[data-i]').forEach(tr=>{ const x=list[+tr.dataset.i]; if(!x) return; const g=k=>tr.querySelector(`[data-f="${k}"]`);
    x.name=g('name').value; x.amount=+g('amount').value||0; x.applies=g('applies').value; x.note=g('note').value; x.is_percent=x.kind==='discount'&&g('unit').value==='pct'; }); };
  // what a family of 1, 2, 3 would pay (new vs returning shown apart only when the list treats them differently)
  const famTotal=(n,ret)=>{ let t=0; for(let k=0;k<n;k++){ let fees=0, disc=0, pct=0;
      list.forEach(x=>{ const on=x.applies==='athlete'||(x.applies==='family'&&k===0)||(x.applies==='sibling'&&k>0)||(x.applies==='new'&&!ret)||(x.applies==='returning'&&ret); if(!on) return;
        if(x.kind==='fee') fees+=x.amount; else if(x.is_percent) pct+=x.amount; else disc+=x.amount; });
      t+=Math.max(fees-disc-Math.round(fees*pct)/100,0); } return t; };
  const drawTotals=()=>{ const split=list.some(x=>x.applies==='new'||x.applies==='returning'), opt=list.filter(x=>x.applies==='choose');
    const row=(lab,ret)=>`<tr><td class="pr-3">${lab}</td>${[1,2,3].map(n=>`<td class="pr-4 font-mono"><b>${money(famTotal(n,ret))}</b></td>`).join('')}</tr>`;
    q('flTotals').innerHTML=!list.length?'<b>No fees yet.</b> Tap "+ Add a fee" to start — for example Registration, Uniform, Fundraiser, Parent volunteer fee.'
      :`<b>What a family pays in total</b>${dirty?' <span class="tappill warn">not saved yet</span>':''}<table class="mt-1 text-sm"><tr class="text-xs text-gray-500"><td></td><td class="pr-4">1 athlete</td><td class="pr-4">2 athletes</td><td class="pr-4">3 athletes</td></tr>${split?row('New athletes',false)+row('Returning athletes',true):row('Family total',false)}</table>
      <div class="text-xs text-gray-500 mt-1">"Once per family" lines are charged one time, on the family's first athlete. A family is the athletes registered with the same parent email.${opt.length?` Not counted above: ${opt.map(x=>esc(x.name)).join(', ')} (added only to athletes you pick, with "Fees" on their row).`:''}</div>`; };
  const drawList=()=>{ q('flBody').innerHTML=list.map((x,i)=>`<tr data-i="${i}"><td><input data-f="name" value="${esc(x.name)}" placeholder="${x.kind==='fee'?'e.g. Uniform':'e.g. Sibling discount'}" style="width:100%;min-width:9rem"></td>
      <td><span class="tappill ${x.kind==='fee'?'':'ok'}">${x.kind==='fee'?'Fee':'Discount'}</span></td>
      <td class="whitespace-nowrap">${x.kind==='discount'?`<select data-f="unit"><option value="usd" ${x.is_percent?'':'selected'}>$ off</option><option value="pct" ${x.is_percent?'selected':''}>% off</option></select>`:'$ <input type="hidden" data-f="unit" value="usd">'} <input data-f="amount" type="number" min="0" step="0.01" value="${x.amount||''}" style="width:6rem"></td>
      <td><select data-f="applies">${opts(WHO,x.applies)}</select></td><td><input data-f="note" value="${esc(x.note)}" style="width:100%;min-width:8rem"></td>
      <td class="whitespace-nowrap"><button ${btn('lite','data-fl="up" title="Move up"')}>↑</button> <button ${btn('lite','data-fl="del" title="Remove from the list"')}>✕</button></td></tr>`).join('')
      ||'<tr><td colspan="6" class="p-3 text-gray-500">Nothing on the list yet.</td></tr>'; drawTotals(); };
  drawList();
  q('flBody').oninput=()=>{ readList(); dirty=true; drawTotals(); };
  q('flBody').onchange=()=>{ readList(); dirty=true; drawTotals(); };
  q('flBody').onclick=e=>{ const b=e.target.closest('button[data-fl]'); if(!b) return; e.stopPropagation(); readList(); const i=+b.closest('tr').dataset.i;
    if(b.dataset.fl==='del') list.splice(i,1); else if(i>0) [list[i-1],list[i]]=[list[i],list[i-1]]; dirty=true; drawList(); };
  const addRow=kind=>{ readList(); list.push({name:'',kind,amount:0,is_percent:false,applies:kind==='discount'?'sibling':'athlete',note:''}); dirty=true; drawList(); const ins=q('flBody').querySelectorAll('[data-f="name"]'); ins[ins.length-1].focus(); };
  q('flAddFee').onclick=()=>addRow('fee'); q('flAddDisc').onclick=()=>addRow('discount');
  const applyList=async()=>{ const {data,error}=await sb.rpc('apply_fee_list',{p_team:team,p_season:SEASON}); if(error){ toast(error.message,true); return false; } toast(data?`Updated ${data} athlete(s)`:'Everyone is already up to date'); return true; };
  q('payFilter').onchange=draw;
  if(q('teamSel')) q('teamSel').onchange=()=>{ ctx.team=q('teamSel').value; if(ctx.onTeamChange) ctx.onTeamChange(ctx.team); refresh(); };
  q('psPlan').onchange=()=>q('psPlanBox').classList.toggle('hide',!q('psPlan').checked);
  q('psSave').onclick=async()=>{ readList();
    if(list.some(x=>!x.name.trim())){ toast('Give every fee and discount a name (or remove the empty row).',true); return; }
    const p={team_code:team,season_year:SEASON,fee_note:q('psNote').value,
    accept_card:extras&&q('psCard').checked,plan_enabled:extras&&q('psPlan').checked,plan_deposit:+q('psDep').value||0,plan_installments:+q('psN').value||1,plan_interval:q('psEvery').value||'month',plan_first_date:q('psFirst').value||null,
    accept_zelle:q('psZelle').checked,zelle_info:q('psZelleInfo').value,accept_cashapp:q('psCashapp').checked,cashapp_info:q('psCashappInfo').value,accept_venmo:q('psVenmo').checked,venmo_info:q('psVenmoInfo').value,accept_other:q('psOther').checked,other_info:q('psOtherInfo').value};
    for(const [on,info,label] of [['accept_zelle','zelle_info','Zelle'],['accept_cashapp','cashapp_info','Cash App'],['accept_venmo','venmo_info','Venmo']]){ if(p[on]&&!p[info].trim()){ toast(`Add the ${label} details parents should send to.`,true); return; } }
    const changed=dirty;
    const {error:le}=await sb.rpc('save_fee_list',{p_team:team,p_season:SEASON,p_items:list.map(x=>({id:x.id||null,name:x.name,kind:x.kind,amount:x.amount,is_percent:x.is_percent,applies:x.applies,note:x.note}))}); if(le){ toast(le.message,true); return; }
    const {error}=await sb.rpc('save_team_payment_settings',{p}); if(error){ toast(error.message,true); refresh(); return; } toast('Saved');
    if(changed&&list.length&&confirm('Saved.\n\nPut the new list on athletes who are already registered and haven\'t paid anything yet?\n\nAthletes who have paid something or are on a payment plan are not changed.')) await applyList();
    refresh(); };
  q('psEnsure').onclick=async()=>{ if(dirty){ toast('Save your changes to the list first.',true); return; } if(await applyList()) refresh(); };
  const stripeCall=async action=>{ toast(action==='connect'?'Opening Stripe…':'Checking with Stripe…');
    const {data,error}=await sb.functions.invoke('team-stripe',{body:{action,team_code:team}});
    if(error){ let m=error.message; try{ const j=await error.context?.json(); if(j?.error) m=j.error; }catch(e){} toast(m,true); return; }
    if(data?.error){ toast(data.error,true); return; }
    if(action==='connect'&&data.url){ location.href=data.url; return; }
    toast(data.status==='active'?'Card payments are on ✓':data.detail||data.status); refresh(); };
  if(q('stripeConnect')) q('stripeConnect').onclick=()=>stripeCall('connect');
  if(q('stripeStatus')) q('stripeStatus').onclick=()=>stripeCall('status');
  if(ctx.stripeReturn&&extras){ ctx.stripeReturn=false; stripeCall('status'); }
  el.onclick=async e=>{
    const pb=e.target.closest('tr[data-pay] button[data-act]');
    if(pb){ const id=pb.closest('tr').dataset.pay, p=pending.find(x=>x.id===id), f=rows.find(x=>x.id===p.fee_id)||{};
      if(pb.dataset.act==='confirm'){ const amt=prompt(`Confirm ${money(p.amount)} by ${(PAY_METHODS.find(x=>x[0]===p.method)||[0,p.method])[1]} from ${f.first_name||''} ${f.last_name||''}'s family was received.\n\nAmount actually received:`,(+p.amount).toFixed(2)); if(amt===null) return;
        const {error}=await sb.rpc('record_fee_payment',{p_fee:p.fee_id,p_method:p.method,p_amount:+amt,p_confirm:p.id}); if(error){ toast(error.message,true); return; } toast('Recorded'); refresh(); }
      else { const note=prompt('Mark as NOT received? The parent will see this. Note (optional):'); if(note===null) return;
        const {error}=await sb.rpc('set_fee_payment_status',{p_payment:p.id,p_status:'void',p_note:note||null}); if(error){ toast(error.message,true); return; } toast('Marked not received'); refresh(); }
      return; }
    const b=e.target.closest('tr[data-fee] button[data-act]'); if(!b) return;
    const id=b.closest('tr').dataset.fee, r=rows.find(x=>x.id===id), act=b.dataset.act, who=`${r.first_name} ${r.last_name}`;
    if(act==='link'){ const url=new URL('pay.html',location.href); url.search='?reg='+encodeURIComponent(r.registration_id)+'&email='+encodeURIComponent(String(r.email).toLowerCase());
      try{ await navigator.clipboard.writeText(url.href); toast('Pay link copied — paste it into a text or email'); }catch(e){ prompt('Copy this link:',url.href); } return; }
    if(act==='record'){ openModal(`<div class="tap">${STYLE}<h3 class="font-bold mb-2">Record a payment — ${esc(who)}</h3><p class="text-xs text-gray-500 mb-2">Balance ${money(r.balance)}. For money received outside the app.</p>
      <div class="grid gap-2" style="grid-template-columns:1fr 1fr"><label class="text-sm">How<br><select id="rpMethod" class="w-full">${opts(PAY_METHODS.filter(m=>m[0]!=='card'),'zelle')}</select></label><label class="text-sm">Amount $<br><input id="rpAmt" type="number" min="0.01" step="0.01" value="${(+r.balance).toFixed(2)}" class="w-full"></label>
      <label class="text-sm">Received on<br><input id="rpDate" type="date" value="${new Date().toLocaleDateString('en-CA',{timeZone:'America/Los_Angeles'})}" class="w-full"></label><label class="text-sm">Check # / confirmation<br><input id="rpRef" class="w-full"></label>
      <label class="text-sm" style="grid-column:1/-1">Note<br><input id="rpNote" class="w-full"></label></div><div class="flex gap-2 mt-3"><button ${btn('grn','id="rpGo"')}>Record</button><button ${btn('lite','onclick="window.closeTapModal()"')}>Cancel</button></div></div>`);
      document.getElementById('rpGo').onclick=async()=>{ const g=i=>document.getElementById(i); const {error}=await sb.rpc('record_fee_payment',{p_fee:id,p_method:g('rpMethod').value,p_amount:+g('rpAmt').value,p_received_on:g('rpDate').value||null,p_reference:g('rpRef').value||null,p_note:g('rpNote').value||null});
        if(error){ toast(error.message,true); return; } closeModal(); toast('Recorded'); refresh(); }; return; }
    if(act==='adjust'){ let touched=false;
      const show=async()=>{ const {data:f,error}=await sb.from('team_fee_overview').select('*').eq('id',id).maybeSingle(); if(error||!f){ toast(error?error.message:'Fee not found',true); return; }
        const L=f.lines||[], have=new Set(L.filter(l=>!l.removed).map(l=>l.item_id)), can=items.filter(i=>!have.has(i.id));
        openModal(`<div class="tap">${STYLE}<h3 class="font-bold mb-1">Fees — ${esc(who)}</h3><p class="text-xs text-gray-500 mb-2">The family sees every line and any reason you give. ${+f.paid>0?`Paid so far ${money(f.paid)}.`:''}</p>
        <table class="tapt"><thead><tr><th>Line</th><th>Amount</th><th>Reason / note</th><th></th></tr></thead><tbody>${L.map(l=>`<tr data-line="${l.id}" ${l.removed?'style="opacity:.55"':''}><td ${l.removed?'style="text-decoration:line-through"':''}>${esc(l.name)}${l.family?' <span class="tappill">once per family</span>':''}${l.kind==='discount'?' <span class="tappill ok">discount</span>':''}</td>
          <td class="whitespace-nowrap">${l.kind==='discount'?'−':''}${l.percent!=null?'':'$'}<input data-lf="amt" type="number" min="0" step="0.01" value="${l.percent!=null?+l.percent:(+l.amount).toFixed(2)}" style="width:5.5rem" ${l.removed?'disabled':''}>${l.percent!=null?`% <span class="text-xs text-gray-500">= ${money(l.amount)}</span>`:''}</td>
          <td><input data-lf="note" value="${esc(l.note||'')}" style="width:100%;min-width:7rem"></td>
          <td class="whitespace-nowrap">${l.removed?`<button ${btn('lite','data-la="back"')}>Put back</button>`:`<button ${btn('lite','data-la="save"')}>Save</button> <button ${btn('lite','data-la="off" title="This athlete doesn\'t owe this line"')}>Take off</button>`}</td></tr>`).join('')||'<tr><td colspan="4" class="text-gray-500 p-2">No lines yet.</td></tr>'}
          <tr><td class="font-bold">Total</td><td class="font-mono font-bold">${money(f.amount_due)}</td><td colspan="2" class="text-xs text-gray-500">${+f.paid>0?`Balance ${money(f.balance)}`:''}</td></tr></tbody></table>
        <div class="mt-3 text-sm font-semibold">Add a line</div>
        <div class="flex flex-wrap gap-2 items-end mt-1"><label class="text-xs">What<br><select id="alWhat">${can.map(i=>`<option value="${i.id}">${esc(i.name)} (${i.kind==='discount'?'−':''}${i.is_percent?(+i.amount)+'%':money(i.amount)})</option>`).join('')}<option value="fee">Something else — a fee…</option><option value="discount" ${can.length?'':'selected'}>Something else — a discount / scholarship…</option></select></label>
          <label class="text-xs" id="alNameBox">Name<br><input id="alName" style="width:10rem" placeholder="e.g. Scholarship"></label><label class="text-xs" id="alAmtBox">Amount $<br><input id="alAmt" type="number" min="0" step="0.01" style="width:6rem"></label>
          <label class="text-xs flex-1">Reason / note<br><input id="alNote" style="width:100%"></label><button ${btn('pri','id="alGo"')}>Add</button></div>
        <div class="flex gap-2 mt-3"><button ${btn('lite','id="alDone"')}>Done</button></div></div>`);
        const g=i=>document.getElementById(i), box=document.getElementById('tapModalBox');
        const sync=()=>{ const own=g('alWhat').value==='fee'||g('alWhat').value==='discount'; g('alNameBox').classList.toggle('hide',!own); g('alAmtBox').classList.toggle('hide',!own); }; sync(); g('alWhat').onchange=sync;
        const run=async(fn,args)=>{ const {error}=await sb.rpc(fn,args); if(error){ toast(error.message,true); return; } touched=true; show(); };
        g('alGo').onclick=()=>{ const w=g('alWhat').value, own=w==='fee'||w==='discount';
          if(own&&(!g('alName').value.trim()||!(+g('alAmt').value>=0)||g('alAmt').value==='')){ toast('Enter a name and an amount.',true); return; }
          run('fee_line_add',own?{p_fee:id,p_name:g('alName').value,p_kind:w,p_amount:+g('alAmt').value,p_note:g('alNote').value||null}:{p_fee:id,p_item:w,p_note:g('alNote').value||null}); };
        g('alDone').onclick=()=>{ closeModal(); if(touched) refresh(); };
        box.querySelectorAll('button[data-la]').forEach(b=>b.onclick=()=>{ const tr=b.closest('tr'), a=b.dataset.la, note=tr.querySelector('[data-lf="note"]').value;
          run('fee_line_set',a==='save'?{p_line:tr.dataset.line,p_amount:+tr.querySelector('[data-lf="amt"]').value||0,p_note:note}:{p_line:tr.dataset.line,p_removed:a==='off',p_note:note}); }); };
      show(); return; }
    if(act==='waive'){ const note=prompt(`Waive ${who}'s fee entirely? Reason:`); if(note===null) return;
      const {error}=await sb.rpc('set_athlete_fee',{p_fee:id,p_amount:0,p_note:note||null,p_waive:true}); if(error){ toast(error.message,true); return; } toast('Fee waived'); refresh(); }
  };
};

/* ============================ PARENT MEET SIGN-UP: can parents pick events? ============================ */
window.mountParentSignup=async function(el, ctx){
  const sb=ctx.sb; el.classList.add('tap');
  const {data:tsRows}=await sb.from('team_settings').select('*'); const ts={}; (tsRows||[]).forEach(t=>ts[t.team_code]=t);
  const list=ctx.canPickTeam?(ctx.teams||[]).filter(t=>t.active!==false):(ctx.teams||[]).filter(t=>t.code===ctx.team);
  el.innerHTML=STYLE+`<div class="tapcard"><h3 class="font-bold mb-1">Parent meet sign-up</h3>
<p class="text-xs text-gray-500 mb-2">Before every meet, parents are asked on their dashboard: <b>"Is your athlete coming?"</b> (yes / no, by the Thursday before at 8 PM). The coaches do all the entering. Your choice here: <b>can parents also pick the events</b> they'd like their athlete in? If yes, say how many they may choose — up to three. ${ctx.canPickTeam?'Each team chooses for itself.':'Your choice applies to '+esc(teamName(ctx,ctx.team))+' only.'}</p>
<table class="tapt"><thead><tr><th>Team</th><th>Can parents pick events?</th><th>How many events may they choose?</th><th></th></tr></thead><tbody>${list.map(t=>{ const row=ts[t.code]||{}, on=!!row.parent_entry_enabled&&row.team_code, n=Math.min(3,Math.max(1,+row.parent_event_picks||2));
  return `<tr data-team="${esc(t.code)}"><td>${esc(t.name)}</td><td><span class="tappill ${on?'ok':'warn'}">${on?'YES — they say if coming + pick events':'NO — they only say if coming'}</span>${row.team_code?`<div class="text-xs text-gray-400">${esc(row.updated_by||'')} ${esc(String(row.updated_at||'').slice(0,10))}</div>`:''}</td>
  <td>${on?`<select data-picks>${[1,2,3].map(k=>`<option value="${k}" ${k===n?'selected':''}>${k} event${k>1?'s':''}</option>`).join('')}</select>`:'<span class="text-xs text-gray-400">—</span>'}</td>
  <td><button ${btn('lite',`data-pe="${on?'off':'on'}"`)}>${on?'Switch to: only ask if coming':'Switch to: let parents pick events'}</button></td></tr>`; }).join('')||'<tr><td colspan="5" class="text-gray-500">No team.</td></tr>'}</tbody></table></div>`;
  el.onclick=async e=>{ const pe=e.target.closest('button[data-pe]'); if(!pe) return; const team=pe.closest('tr').dataset.team, on=pe.dataset.pe==='on', tn=teamName(ctx,team);
    if(!confirm(on?`${tn}: parents will say whether their athlete is coming AND pick the events they'd like (you choose how many). The coaches still do the entering.`:`${tn}: parents will ONLY say whether their athlete is coming. The coaches choose the events.`)) return;
    const {error}=await sb.rpc('set_parent_entry',{p_team:team,p_on:on,p_picks:on?2:null}); if(error){ toast(error.message,true); return; } toast('Saved'); window.mountParentSignup(el,ctx); };
  el.onchange=async e=>{ const sel=e.target.closest('select[data-picks]'); if(!sel) return; const team=sel.closest('tr').dataset.team;
    const {error}=await sb.rpc('set_parent_entry',{p_team:team,p_on:true,p_picks:+sel.value}); if(error){ toast(error.message,true); return; } toast(`Parents may pick up to ${sel.value} event${+sel.value>1?'s':''}`); window.mountParentSignup(el,ctx); };
};
/* Once a team's paid extras are on, its team admin needs an obvious way to set up Stripe (card payments + payment plans).
   Returns a notice with a "Set up Stripe" link, or '' when extras are off or Stripe is already active. */
window.stripeSetupNotice=async function(sb, team){
  try{
    const [{data:x},{data:a}]=await Promise.all([sb.from('team_messaging').select('enabled').eq('team_code',team).maybeSingle(),
      sb.from('team_stripe_accounts').select('status').eq('team_code',team).maybeSingle()]);
    if(!(x&&x.enabled)||(a&&a.status==='active')) return '';
    return `<div class="rounded-lg p-2 mt-2 text-sm" style="border:1px solid #f59e0b;background:#fffbeb"><b>Next step: set up Stripe.</b> Your paid extras are on. Connect your team's own Stripe account so parents can pay the team fee by card and use payment plans${a?' (setup was started but isn\'t finished)':''}. <a class="underline font-semibold" style="color:#1764c8" href="coach.html?view=roster&tab=payments">${a?'Finish Stripe setup':'Set up Stripe'} →</a></div>`;
  }catch(e){ return ''; }
};
/* ============================ PAID TEAM EXTRAS: one on/off switch per team (Team Messenger + taking payments online) ============================ */
window.mountTeamMessaging=async function(el, ctx){
  const sb=ctx.sb; el.classList.add('tap'); el.innerHTML=STYLE+'<p class="text-sm text-gray-500">Loading…</p>';
  let stripeOn={}; try{ const {data:sa}=await sb.from('team_stripe_accounts').select('team_code,status'); (sa||[]).forEach(r=>stripeOn[r.team_code]=r.status); }catch(e){}
  const stripeNote=ctx.canPickTeam?'':await window.stripeSetupNotice(sb, ctx.team);
  const [{data:sw,error},{data:ch}]=await Promise.all([sb.from('team_messaging').select('*'), sb.from('msg_channels').select('team_code,audience,archived').eq('season_year',ctx.season)]);
  if(error){ el.innerHTML=STYLE+'<div class="tapcard"><b>Team Messenger isn\'t set up yet.</b><p class="text-xs text-gray-500 mt-1">'+esc(error.message)+'</p></div>'; return; }
  const on={}; (sw||[]).forEach(r=>on[r.team_code]=r);
  const cnt={}; (ch||[]).filter(c=>!c.archived).forEach(c=>{ const k=cnt[c.team_code]??={g:0,d:0}; c.audience==='direct'?k.d++:k.g++; });
  const list=ctx.canPickTeam?(ctx.teams||[]).filter(t=>t.active!==false):(ctx.teams||[]).filter(t=>t.code===ctx.team);
  const nOn=list.filter(t=>on[t.code]&&on[t.code].enabled).length;
  el.innerHTML=STYLE+`<div class="tapcard"><div class="flex flex-wrap items-center gap-2 mb-1"><h3 class="font-bold flex-1">Paid team extras${ctx.canPickTeam?` <span class="text-sm font-normal text-gray-500">on for ${nOn} of ${list.length} teams</span>`:''}</h3></div>${stripeNote}
<p class="text-sm text-gray-700 mb-2">Everything a team needs to run its season is <b>free</b>: registration, proof-of-birth review, certification, rosters, coach approval, meet entries, "is your athlete coming?" (and letting parents pick events), and posting the team fee so parents see what they owe.</p>
<p class="text-sm text-gray-700 mb-1">The <b>paid team extras</b> — $99 per team per season — are the things that aren't required to manage the team:</p>
<ul class="text-sm text-gray-700 mb-2" style="list-style:disc;padding-left:1.25rem">
<li><b>Team Messenger</b> — coaches and parents message each other on their dashboards: team, division and coaches-only groups, one-to-one direct messages, photos and files, message history, and email/text alerts.</li>
<li><b>Taking payments online and tracking them</b> — parents pay by card straight into the team's bank account (with optional automatic payment plans) or by Zelle / Cash App / Venmo / check with "I sent it", and the app keeps track of who has paid, what's outstanding, and each family's payment history.</li>
<li><b>Live results</b> — post results live during the team's home meets: the timing laptop connects to Meet Manager and every event shows up on the Results page as it's scored, so parents follow along on their phones. Without it, results are posted after the meet.</li>
<li><b>Livestream</b> — coaches stream a meet to YouTube Live (free) and paste the link; the team's coaches and parents watch it on their dashboards, and it stays as a replay.</li>
<li><b>Photo gallery</b> — albums of team photos on the team page for the team's parents and coaches (parents can be allowed to add photos too).</li>
<li><b>Team store</b> — the team sells its shirts, hoodies and gear on its team page; parents order and pay the team, the team confirms and hands the order over.</li></ul>
<p class="text-xs text-gray-500 mb-2">Always free, on every team's page: the page itself (about, practice info, coaches, news, schedule) and meet-day volunteer duties.</p>
<p class="text-xs text-gray-500 mb-2">${ctx.canPickTeam?`Switch a team on once they've paid. Switching off hides the chats (every message is kept) and stops online payments and payment tracking (the records are kept). Coaches and parents never see any of this until their team is on.`:(nOn?`They are ON for your team: the chats are on the <a class="underline" href="coach.html#messages">Coach Dashboard</a> and each parent's dashboard, and online payments are set up on the Payments tab.`:`They are not switched on for your team, so your coaches and parents don't see any of it. To add them, contact the league site admin.`)}</p>
<table class="tapt"><thead><tr><th>Team</th><th>Paid extras</th><th>Messages in use</th><th>Card payments (Stripe)</th>${ctx.canPickTeam?'<th></th>':''}</tr></thead><tbody>${list.map(t=>{ const r=on[t.code], y=!!(r&&r.enabled), k=cnt[t.code];
  return `<tr data-team="${esc(t.code)}"><td>${esc(t.name)}</td><td><span class="tappill ${y?'ok':''}">${y?'ON':'Off'}</span>${r?`<div class="text-xs text-gray-400">${esc(r.updated_by||'')} ${esc(String(r.updated_at||'').slice(0,10))}</div>`:''}</td>
  <td class="text-xs text-gray-600">${k?`${k.g} group${k.g===1?'':'s'}${k.d?` · ${k.d} direct message${k.d===1?'':'s'}`:''}`:'—'}</td>
  <td>${!y?'<span class="text-xs text-gray-400">—</span>':stripeOn[t.code]==='active'?'<span class="tappill ok">Set up ✓</span>':`<span class="tappill warn">${stripeOn[t.code]?'Setup not finished':'Not set up'}</span>${ctx.canPickTeam?'':' <a class="underline text-xs" style="color:#1764c8" href="coach.html?view=roster&tab=payments">Set up Stripe →</a>'}`}</td>
  ${ctx.canPickTeam?`<td class="whitespace-nowrap"><button ${btn(y?'lite':'grn',`data-msg="${y?'off':'on'}"`)}>${y?'Switch off':'Switch on'}</button>${y?` <button ${btn('lite','data-open')}>See chats</button>`:''}</td>`:''}</tr>`; }).join('')||'<tr><td colspan="4" class="text-gray-500">No team.</td></tr>'}</tbody></table></div>
<div data-id="msgViewCard" class="tapcard hide"><h3 class="font-bold mb-2" data-id="msgViewTitle"></h3><div data-id="msgView"></div></div>`;
  el.onclick=async e=>{ const o=e.target.closest('button[data-open]');
    if(o){ const team=o.closest('tr').dataset.team, card=el.querySelector('[data-id="msgViewCard"]'); card.classList.remove('hide'); el.querySelector('[data-id="msgViewTitle"]').textContent=teamName(ctx,team)+' — chats';
      await window.mountMessenger(el.querySelector('[data-id="msgView"]'),{sb,team,lockTeam:true}); card.scrollIntoView({behavior:'smooth',block:'start'}); return; }
    const b=e.target.closest('button[data-msg]'); if(!b) return; const team=b.closest('tr').dataset.team, go=b.dataset.msg==='on', tn=teamName(ctx,team);
    if(!confirm(go?`Switch the paid team extras ON for ${tn}? Team Messenger appears on their dashboards right away, and they can take and track payments.`:`Switch the paid team extras OFF for ${tn}? Their chats are hidden (every message is kept) and parents can no longer pay through the app.`)) return;
    const {error}=await sb.rpc('msg_set_enabled',{p_team:team,p_on:go}); if(error){ toast(error.message,true); return; } toast(go?'Switched on — their team admin now sees a "Set up Stripe" link on the Coach Dashboard and Paid extras tab':'Switched off'); window.mountTeamMessaging(el,ctx); };
};
})();
