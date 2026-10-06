// Team-admin panels shared by the Coach Dashboard's "Team admin" section and the Site Admin page:
//   window.mountTeamPayments(el, ctx)   — the team's payment portal (Stripe setup, fee, ways to pay, athletes' balances)
//   window.mountParentSignup(el, ctx)   — the "parents enter meet events themselves: ON / OFF" switch
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
  const sb=ctx.sb, team=ctx.team, SEASON=ctx.season; let rows=[], pending=[];
  el.classList.add('tap'); el.innerHTML=STYLE+'<p class="text-sm text-gray-500">Loading…</p>';
  let st=null, set=null;
  try{
    const [{data:a},{data:s},r,{data:pend}]=await Promise.all([
      sb.from('team_stripe_accounts').select('*').eq('team_code',team).maybeSingle(),
      sb.from('team_payment_settings').select('*').eq('team_code',team).eq('season_year',SEASON).maybeSingle(),
      pageAll(()=>sb.from('team_fee_overview').select('*').eq('team_code',team).eq('season_year',SEASON).order('last_name').order('first_name')),
      sb.from('fee_payments').select('*').eq('team_code',team).eq('status','reported').order('reported_at')]);
    st=a; set=s; rows=r; pending=pend||[];
  }catch(e){ el.innerHTML=STYLE+'<p class="text-red-700 text-sm">'+esc(e.message)+'</p>'; return; }
  const s=set||{fee_amount:0,sibling_discount:0,plan_enabled:false,plan_deposit:0,plan_installments:2,accept_card:true};
  const chk=(id,v,label)=>`<label class="flex items-center gap-2 text-sm"><input type="checkbox" data-id="${id}" ${v?'checked':''}> ${label}</label>`;
  const q=id=>el.querySelector(`[data-id="${id}"]`);
  const tn=teamName(ctx,team);
  const stripeBox=st?.status==='active'?`<span class="tappill ok">Card payments ON ✓</span> <span class="text-xs text-gray-500">${esc(st.status_detail||'')} Checked ${esc(String(st.checked_at||'').slice(0,10))}</span>`
    :st?`<span class="tappill ${st.status==='restricted'?'bad':'warn'}">${st.status==='restricted'?'Action needed':'Setup not finished'}</span> <span class="text-xs text-gray-500">${esc(st.status_detail||'')}</span>`
    :'<span class="tappill">Not set up</span>';
  const tot=f=>rows.filter(r=>r.status!=='void'&&r.status!=='waived').reduce((a,r)=>a+(+r[f]||0),0);
  el.innerHTML=STYLE+`${ctx.canPickTeam?`<div class="flex items-center gap-2 mb-2 text-sm"><b>Team</b><select data-id="teamSel">${opts((ctx.teams||[]).filter(t=>t.active!==false).map(t=>[t.code,t.name+' ('+t.code+')']),team)}</select></div>`:''}
<div class="tapcard"><h3 class="font-bold mb-1">Card payments — ${esc(tn)}'s own Stripe account</h3>
<p class="text-xs text-gray-500 mb-2">Parents pay by card through Stripe and the money is deposited straight into ${esc(tn)}'s bank account (not VYC's). The team pays Stripe's standard card fee (about 2.9% + 30¢ per payment). Setup takes about 10 minutes: the team's bank account, the responsible person's details, and the team's tax ID (EIN) or that person's SSN for a club without one. Stripe sends you back here when you're done.</p>
<div class="flex flex-wrap items-center gap-2">${stripeBox}
  <button ${btn(st?.status==='active'?'lite':'pri','data-id="stripeConnect"')}>${!st?'Set up Stripe for this team':st.status==='active'?'Open Stripe setup again':'Continue Stripe setup'}</button>
  ${st?`<button ${btn('lite','data-id="stripeStatus"')}>Re-check status</button> <a class="tapbtn lite" href="https://dashboard.stripe.com/" target="_blank" rel="noopener">Stripe dashboard ↗</a>`:''}</div>
${st?`<p class="text-xs text-gray-400 mt-1">Account ${esc(st.stripe_account_id)} · set up by ${esc(st.created_by||'')}. Refunds for card payments are done in the Stripe dashboard; the app records them automatically.</p>`:''}</div>

<div class="tapcard"><h3 class="font-bold mb-1">${SEASON} team fee &amp; ways to pay</h3>
<p class="text-xs text-gray-500 mb-2">Every team sets its own fee. Every athlete who registers with ${esc(tn)} gets it automatically, and the parent is taken to the payment portal right after submitting the registration.</p>
<div class="grid gap-2" style="grid-template-columns:repeat(auto-fit,minmax(14rem,1fr))">
 <label class="text-sm"><b>Fee per athlete $</b><br><input data-id="psFee" type="number" min="0" step="0.01" value="${+s.fee_amount||''}" class="w-full"></label>
 <label class="text-sm"><b>Sibling discount $</b> <span class="text-xs text-gray-500">off each 2nd+ child (same email)</span><br><input data-id="psSib" type="number" min="0" step="0.01" value="${+s.sibling_discount||''}" class="w-full"></label>
 <label class="text-sm" style="grid-column:1/-1"><b>What the fee covers</b> <span class="text-xs text-gray-500">(shown to parents)</span><br><input data-id="psNote" value="${esc(s.fee_note||'')}" class="w-full" placeholder="e.g. uniform, meet entry fees, league certification"></label>
</div>
<div class="mt-3">${chk('psCard',s.accept_card!==false,'<b>Card</b> (needs the Stripe setup above)')}
<div class="ml-6 mt-1">${chk('psPlan',s.plan_enabled,'<b>Offer a payment plan</b> — deposit now, then equal monthly card payments charged automatically')}
 <div data-id="psPlanBox" class="flex flex-wrap gap-2 items-end mt-1 ${s.plan_enabled?'':'hide'}">
  <label class="text-sm">Deposit today $<br><input data-id="psDep" type="number" min="0" step="0.01" value="${+s.plan_deposit||''}" style="width:7rem"></label>
  <label class="text-sm">Monthly payments<br><select data-id="psN">${opts([1,2,3,4,5,6,7,8,9,10,11,12].map(n=>[n,n]),s.plan_installments||2)}</select></label>
  <label class="text-sm">First one on<br><input data-id="psFirst" type="date" value="${esc(s.plan_first_date||'')}"></label>
  <span class="text-xs text-gray-500">Example: $250 fee, $100 deposit, 3 payments → $100 today then $50 a month. A missed payment is flagged here and the parent is asked for a new card.</span></div></div></div>
<div class="mt-2 grid gap-2" style="grid-template-columns:repeat(auto-fit,minmax(18rem,1fr))">
 <div>${chk('psZelle',s.accept_zelle,'<b>Zelle</b>')}<input data-id="psZelleInfo" value="${esc(s.zelle_info||'')}" class="w-full mt-1" placeholder="Zelle to: email or phone, and the name that shows"></div>
 <div>${chk('psCashapp',s.accept_cashapp,'<b>Cash App</b>')}<input data-id="psCashappInfo" value="${esc(s.cashapp_info||'')}" class="w-full mt-1" placeholder="$Cashtag"></div>
 <div>${chk('psVenmo',s.accept_venmo,'<b>Venmo</b>')}<input data-id="psVenmoInfo" value="${esc(s.venmo_info||'')}" class="w-full mt-1" placeholder="@Venmo-handle"></div>
 <div>${chk('psOther',s.accept_other,'<b>Check or cash</b>')}<input data-id="psOtherInfo" value="${esc(s.other_info||'')}" class="w-full mt-1" placeholder="Who to make the check out to, where to bring it"></div>
</div>
<p class="text-xs text-gray-500 mt-2">For Zelle, Cash App, Venmo, check and cash the parent taps "I sent it" and you confirm below once it arrives. Changing the fee later doesn't change athletes who already have a fee (adjust those one by one below).</p>
<div class="flex flex-wrap gap-2 mt-2"><button ${btn('pri','data-id="psSave"')}>Save</button><button ${btn('lite','data-id="psEnsure" title="Athletes who registered before the fee was set don\'t have one yet"')}>Add the fee to athletes who don't have one</button></div></div>

${pending.length?`<div class="tapcard" style="border:1px solid #f59e0b;background:#fffbeb"><h3 class="font-bold mb-1">Parents say they've sent ${pending.length} payment${pending.length>1?'s':''} — confirm when it arrives</h3>
<table class="tapt"><thead><tr><th>Athlete</th><th>How</th><th>Amount</th><th>Reference</th><th>Sent</th><th></th></tr></thead><tbody>${pending.map(p=>{ const f=rows.find(r=>r.id===p.fee_id)||{};
 return `<tr data-pay="${p.id}"><td>${esc(f.first_name||'')} ${esc(f.last_name||'')}<div class="text-xs text-gray-500">${esc(f.email||'')}</div></td><td>${esc((PAY_METHODS.find(x=>x[0]===p.method)||[0,p.method])[1])}</td><td class="font-mono">${money(p.amount)}</td><td>${esc(p.reference||'')}${p.note?`<div class="text-xs text-gray-500">${esc(p.note)}</div>`:''}</td><td>${esc(String(p.reported_at).slice(0,10))}</td>
 <td class="whitespace-nowrap"><button ${btn('grn','data-act="confirm"')}>Received ✓</button> <button ${btn('lite','data-act="notreceived"')}>Not received</button></td></tr>`; }).join('')}</tbody></table></div>`:''}

<div class="tapcard"><div class="flex flex-wrap items-center gap-2 mb-2"><h3 class="font-bold flex-1">Athletes — ${rows.length} with a fee · ${money(tot('paid'))} collected · ${money(tot('balance'))} outstanding</h3>
 <select data-id="payFilter"><option value="">Everyone</option><option value="owing">Still owing</option><option value="plan">On a payment plan</option><option value="paid">Paid</option></select></div>
<div class="tapscroll"><table class="tapt"><thead><tr><th>Athlete</th><th>Parent</th><th>Fee</th><th>Paid</th><th>Balance</th><th>Status</th><th></th></tr></thead><tbody data-id="payBody"></tbody></table></div>
<p class="text-xs text-gray-500 mt-1">"Record payment" is for money you received outside the app (Zelle, check, cash…). Card payments record themselves. "Pay link" copies the parent's personal pay page for this athlete — handy to text or email.</p></div>`;
  const draw=()=>{ const flt=q('payFilter').value, L=rows.filter(r=>flt==='owing'?(+r.balance>0&&!['waived','void'].includes(r.status)):flt==='plan'?r.status==='plan':flt==='paid'?r.status==='paid':true);
    q('payBody').innerHTML=L.map(r=>{ const [cls,lab]=PAY_STATUS[r.status]||['',r.status];
     return `<tr data-fee="${r.id}"><td>${esc(r.first_name)} ${esc(r.last_name)}<div class="text-xs text-gray-500">${esc(r.division||'')}${r.reg_status==='rejected'?' · rejected':''}</div></td><td class="text-xs">${esc(r.email)}</td>
     <td class="font-mono">${money(r.amount_due)}${+r.discount>0?`<div class="text-xs text-gray-500">${esc(r.discount_note||'discount')} −${money(r.discount)}</div>`:''}${r.note?`<div class="text-xs text-gray-500">${esc(r.note)}</div>`:''}</td><td class="font-mono">${money(r.paid)}</td><td class="font-mono ${+r.balance>0&&!['waived','void'].includes(r.status)?'text-red-700 font-bold':''}">${['waived','void'].includes(r.status)?'—':money(r.balance)}</td>
     <td><span class="tappill ${cls}">${lab}</span>${r.status==='plan'?`<div class="text-xs text-gray-500">${r.plan_paid} of ${r.plan_installments} × ${money(r.plan_amount)}${r.plan_next_on?' · next '+esc(r.plan_next_on):''}${r.plan_failed?' · <b class="text-red-700">card failed</b>':''}</div>`:''}${+r.reported_count>0?`<div class="text-xs" style="color:#92400e">${r.reported_count} payment(s) to confirm above</div>`:''}</td>
     <td class="whitespace-nowrap"><button ${btn('lite','data-act="link" title="Copy this athlete\'s pay page link"')}>Pay link</button> ${!['paid','waived','void'].includes(r.status)?`<button ${btn('grn','data-act="record"')}>Record payment</button> `:''}${r.status!=='plan'&&r.status!=='void'?`<button ${btn('lite','data-act="adjust"')}>Adjust</button> `:''}${!['paid','waived','void','plan'].includes(r.status)?`<button ${btn('lite','data-act="waive"')}>Waive</button>`:''}</td></tr>`; }).join('')
     ||'<tr><td colspan="7" class="p-3 text-gray-500">No athletes here yet.</td></tr>'; };
  draw();
  const refresh=()=>window.mountTeamPayments(el,ctx);
  q('payFilter').onchange=draw;
  if(q('teamSel')) q('teamSel').onchange=()=>{ ctx.team=q('teamSel').value; if(ctx.onTeamChange) ctx.onTeamChange(ctx.team); refresh(); };
  q('psPlan').onchange=()=>q('psPlanBox').classList.toggle('hide',!q('psPlan').checked);
  q('psSave').onclick=async()=>{ const p={team_code:team,season_year:SEASON,fee_amount:+q('psFee').value||0,sibling_discount:+q('psSib').value||0,fee_note:q('psNote').value,
    accept_card:q('psCard').checked,plan_enabled:q('psPlan').checked,plan_deposit:+q('psDep').value||0,plan_installments:+q('psN').value||1,plan_first_date:q('psFirst').value||null,
    accept_zelle:q('psZelle').checked,zelle_info:q('psZelleInfo').value,accept_cashapp:q('psCashapp').checked,cashapp_info:q('psCashappInfo').value,accept_venmo:q('psVenmo').checked,venmo_info:q('psVenmoInfo').value,accept_other:q('psOther').checked,other_info:q('psOtherInfo').value};
    for(const [on,info,label] of [['accept_zelle','zelle_info','Zelle'],['accept_cashapp','cashapp_info','Cash App'],['accept_venmo','venmo_info','Venmo']]){ if(p[on]&&!p[info].trim()){ toast(`Add the ${label} details parents should send to.`,true); return; } }
    const {error}=await sb.rpc('save_team_payment_settings',{p}); if(error){ toast(error.message,true); return; } toast('Saved'); refresh(); };
  q('psEnsure').onclick=async()=>{ const {data,error}=await sb.rpc('ensure_athlete_fees',{p_team:team,p_season:SEASON}); if(error){ toast(error.message,true); return; } toast(data?`Added the fee to ${data} athlete(s)`:'Everyone already has a fee'); refresh(); };
  const stripeCall=async action=>{ toast(action==='connect'?'Opening Stripe…':'Checking with Stripe…');
    const {data,error}=await sb.functions.invoke('team-stripe',{body:{action,team_code:team}});
    if(error){ let m=error.message; try{ const j=await error.context?.json(); if(j?.error) m=j.error; }catch(e){} toast(m,true); return; }
    if(data?.error){ toast(data.error,true); return; }
    if(action==='connect'&&data.url){ location.href=data.url; return; }
    toast(data.status==='active'?'Card payments are on ✓':data.detail||data.status); refresh(); };
  q('stripeConnect').onclick=()=>stripeCall('connect');
  if(q('stripeStatus')) q('stripeStatus').onclick=()=>stripeCall('status');
  if(ctx.stripeReturn){ ctx.stripeReturn=false; stripeCall('status'); }
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
    if(act==='adjust'){ const amt=prompt(`New fee amount for ${who} (currently ${money(r.amount_due)}). For a scholarship or special rate:`,(+r.amount_due).toFixed(2)); if(amt===null) return;
      const note=prompt('Reason (the family sees this):',r.note||''); if(note===null) return;
      const {error}=await sb.rpc('set_athlete_fee',{p_fee:id,p_amount:+amt,p_note:note||null}); if(error){ toast(error.message,true); return; } toast('Saved'); refresh(); return; }
    if(act==='waive'){ const note=prompt(`Waive ${who}'s fee entirely? Reason:`); if(note===null) return;
      const {error}=await sb.rpc('set_athlete_fee',{p_fee:id,p_amount:0,p_note:note||null,p_waive:true}); if(error){ toast(error.message,true); return; } toast('Fee waived'); refresh(); }
  };
};

/* ============================ PARENT MEET SIGN-UP SWITCH ============================ */
window.mountParentSignup=async function(el, ctx){
  const sb=ctx.sb; el.classList.add('tap');
  const {data:tsRows}=await sb.from('team_settings').select('*'); const ts={}; (tsRows||[]).forEach(t=>ts[t.team_code]=t);
  const list=ctx.canPickTeam?(ctx.teams||[]).filter(t=>t.active!==false):(ctx.teams||[]).filter(t=>t.code===ctx.team);
  el.innerHTML=STYLE+`<div class="tapcard"><h3 class="font-bold mb-1">Parent meet sign-up</h3>
<p class="text-xs text-gray-500 mb-2"><b>ON</b> = parents enter their athletes into meet events themselves on the Parent Dashboard. <b>OFF</b> = parents only answer "Is your athlete coming?" (yes/no, plus up to two events they'd like) and the coaches of that division enter the athletes on Meet Registration. ${ctx.canPickTeam?'Each team chooses for itself.':'Your choice applies to '+esc(teamName(ctx,ctx.team))+' only.'}</p>
<table class="tapt"><thead><tr><th>Team</th><th>Parents enter events</th><th></th></tr></thead><tbody>${list.map(t=>{ const on=!ts[t.code]||ts[t.code].parent_entry_enabled!==false;
  return `<tr data-team="${esc(t.code)}"><td>${esc(t.name)}</td><td><span class="tappill ${on?'ok':'warn'}">${on?'ON — parents enter':'OFF — parents say yes/no, coaches enter'}</span>${ts[t.code]?`<div class="text-xs text-gray-400">${esc(ts[t.code].updated_by||'')} ${esc(String(ts[t.code].updated_at||'').slice(0,10))}</div>`:''}</td><td><button ${btn('lite',`data-pe="${on?'off':'on'}"`)}>${on?'Turn OFF':'Turn ON'}</button></td></tr>`; }).join('')||'<tr><td colspan="3" class="text-gray-500">No team.</td></tr>'}</tbody></table></div>`;
  el.onclick=async e=>{ const pe=e.target.closest('button[data-pe]'); if(!pe) return; const team=pe.closest('tr').dataset.team, on=pe.dataset.pe==='on', tn=teamName(ctx,team);
    if(!confirm(on?`Turn parent meet entries ON for ${tn}? Parents will enter their athletes into events themselves.`:`Turn parent meet entries OFF for ${tn}? Parents will only say whether their athlete is coming (and which two events they'd like); the coaches enter the athletes.`)) return;
    const {error}=await sb.rpc('set_parent_entry',{p_team:team,p_on:on}); if(error){ toast(error.message,true); return; } toast('Saved'); window.mountParentSignup(el,ctx); };
};
})();
