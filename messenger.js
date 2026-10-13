// Team Messenger — the chat panel that sits INSIDE the dashboards (there is no separate Messages page):
//   Coach Dashboard  → coaches and team admins message their parents (groups, direct messages, photos/files)
//   Parent Dashboard → each parent sees their team's messages and can reply
//   Site Admin → Messages tab → a site admin can open any team's chats
// A paid team extra: nothing shows for a team until a site admin has switched it on (Site Admin → Messages).
//
//   const state = await window.mountMessenger(el, { sb, team, lockTeam, onUnread(n) })
//     team      start on this team (otherwise the first of my teams that has it switched on)
//     lockTeam  show only that team (the Site Admin view)
//     onUnread  called with my unread count whenever it changes (for a badge on the dashboard card)
//   state: 'on' (chats are showing) · 'off' (my team hasn't got it — a notice shows for team admins) · 'none' (nothing to show)
(function(){
const CSS=`<style id="tmStyle">
.tm{font-size:.95rem}.tm .tm-hide{display:none!important}
.tm .tm-btn{padding:.6rem 1rem;border-radius:.5rem;font-weight:600;border:0;cursor:pointer}.tm .tm-sbtn{padding:.35rem .7rem;border-radius:.5rem;font-weight:600;font-size:.85rem;border:0;cursor:pointer}
.tm .tm-pri{background:var(--act,#1764c8);color:#fff}.tm .tm-lite{background:#eef1f5;color:inherit}
.tm .tm-note{border-radius:10px;padding:10px 12px;margin-bottom:10px;font-size:.9rem;border:1px solid var(--line,#e1e7ef);background:#fff}
.tm .tm-pill{font-size:11px;font-weight:700;padding:3px 8px;border-radius:999px;background:#e5e7eb;white-space:nowrap}.tm .tm-pill.ok{background:#dcfce7;color:#166534}.tm .tm-pill.warn{background:#fef3c7;color:#92400e}
.tm .tm-bar{display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin-bottom:8px}
.tm .tm-shell{display:grid;grid-template-columns:18rem 1fr;gap:10px;align-items:stretch}
.tm .tm-list,.tm .tm-thread{background:#fff;border:1px solid var(--line,#e1e7ef);border-radius:10px;height:min(72vh,36rem);min-height:22rem;display:flex;flex-direction:column;overflow:hidden}
.tm .tm-chans{overflow:auto;flex:1}
.tm .tm-sect{font-size:11px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:#5b6878;padding:.5rem .8rem .25rem;background:var(--soft,#f7f9fc);border-bottom:1px solid var(--line,#e1e7ef)}
.tm .tm-chan{display:block;width:100%;text-align:left;padding:.6rem .8rem;border:0;border-bottom:1px solid var(--line,#e1e7ef);cursor:pointer;background:#fff}
.tm .tm-chan:hover{background:var(--soft,#f7f9fc)}.tm .tm-chan.sel{background:var(--act-soft,#e6f0fc)}
.tm .tm-chan .nm{font-weight:700;display:flex;align-items:center;gap:.4rem}.tm .tm-chan .nm span:first-child{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tm .tm-chan .pv{font-size:12px;color:#5b6878;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tm .tm-unread{background:#d2451e;color:#fff;border-radius:999px;font-size:11px;font-weight:700;padding:1px 7px;margin-left:auto}
.tm .tm-head{display:flex;flex-wrap:wrap;align-items:center;gap:6px;padding:8px;border-bottom:1px solid var(--line,#e1e7ef)}
.tm .tm-msgs{flex:1;overflow:auto;padding:12px;background:var(--soft,#f7f9fc)}
.tm .tm-day{text-align:center;font-size:11px;color:#5b6878;margin:10px 0 6px;font-weight:600}
.tm .tm-m{max-width:min(34rem,85%);margin-bottom:8px}.tm .tm-m.mine{margin-left:auto}
.tm .tm-m .who{font-size:11px;color:#5b6878;margin:0 4px 2px}.tm .tm-m.mine .who{text-align:right}
.tm .tm-m .b{background:#fff;border:1px solid var(--line,#e1e7ef);border-radius:14px;padding:.5rem .75rem;white-space:pre-wrap;overflow-wrap:anywhere;font-size:.93rem}
.tm .tm-m.coach .b{border-left:3px solid var(--act,#1764c8)}
.tm .tm-m.mine .b{background:var(--act,#1764c8);color:#fff;border-color:var(--act,#1764c8)}.tm .tm-m.mine .b a{color:#fff}
.tm .tm-m .b a{text-decoration:underline}.tm .tm-m.gone .b{background:transparent;border-style:dashed;color:#8794a6;font-style:italic}
.tm .tm-m .del{font-size:11px;color:#8794a6;margin:0 4px;cursor:pointer;background:none;border:0}.tm .tm-m .del:hover{color:#b42318}
.tm .tm-atts{display:flex;flex-wrap:wrap;gap:6px;margin-top:4px}.tm .tm-m.mine .tm-atts{justify-content:flex-end}
.tm .tm-atts img,.tm .tm-gal img{width:9.5rem;height:9.5rem;object-fit:cover;border-radius:10px;border:1px solid var(--line,#e1e7ef);background:#fff;cursor:zoom-in}
.tm .tm-file{display:inline-flex;align-items:center;gap:.4rem;background:#fff;border:1px solid var(--line,#e1e7ef);border-radius:10px;padding:.4rem .6rem;font-size:.85rem;text-decoration:none;color:inherit;max-width:16rem}
.tm .tm-file span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tm .tm-file button{color:#b42318;font-weight:700;background:none;border:0;cursor:pointer}
.tm .tm-pending{display:flex;flex-wrap:wrap;gap:6px;padding:6px 8px 0;background:#fff}.tm .tm-pending:empty{display:none}
.tm .tm-composer{border-top:1px solid var(--line,#e1e7ef);padding:8px;display:flex;gap:8px;align-items:flex-end;background:#fff}
.tm .tm-composer textarea{flex:1;resize:none;max-height:9rem;padding:.5rem .65rem;font-size:16px;border:1.5px solid var(--field,#c7d1de);border-radius:8px}
.tm .tm-attach{font-size:1.25rem;line-height:1;padding:.5rem .6rem;border-radius:.5rem;background:#eef1f5;cursor:pointer;border:0}
.tm .tm-ro{font-size:12px;color:#5b6878;padding:.75rem;border-top:1px solid var(--line,#e1e7ef);background:#fff}
.tm .tm-back{display:none}.tm .tm-gal{display:flex;flex-wrap:wrap;gap:8px}
.tm.tm-narrow .tm-shell{grid-template-columns:1fr}.tm.tm-narrow .tm-list,.tm.tm-narrow .tm-thread{height:min(78vh,38rem)}
.tm.tm-narrow .tm-shell.open .tm-list{display:none}.tm.tm-narrow .tm-shell:not(.open) .tm-thread{display:none}
.tm.tm-narrow .tm-back{display:inline-block}.tm.tm-narrow .tm-atts img,.tm.tm-narrow .tm-gal img{width:7rem;height:7rem}
.tm .tm-modal{position:fixed;inset:0;background:rgba(0,0,0,.45);display:none;align-items:center;justify-content:center;z-index:9998;padding:1rem}
.tm .tm-modal>div{background:#fff;border-radius:12px;padding:16px;max-width:34rem;width:100%;max-height:90vh;overflow:auto}
.tm .tm-opt{display:flex;gap:.5rem;align-items:flex-start;border:1px solid var(--line,#e1e7ef);border-radius:8px;padding:.5rem .6rem;margin-bottom:6px;cursor:pointer;font-size:.9rem}
.tm .tm-opt:has(input:checked){border-color:var(--act,#1764c8);background:var(--act-soft,#e6f0fc)}
.tm .tm-row{display:flex;width:100%;text-align:left;gap:.5rem;align-items:center;padding:.5rem .6rem;border:0;border-bottom:1px solid var(--line,#e1e7ef);background:#fff;cursor:pointer;font-size:.9rem}
.tm .tm-row:hover{background:var(--act-soft,#e6f0fc)}
</style>`;
const HTML=`
<div data-tm="notice"></div>
<div data-tm="main" class="tm-hide">
  <div class="tm-bar">
    <select data-tm="teamSel" class="border rounded p-2 text-sm tm-hide"></select>
    <button data-tm="newBtn" class="tm-sbtn tm-pri tm-hide">+ Group</button>
    <button data-tm="dmBtn" class="tm-sbtn tm-pri tm-hide">+ Direct message</button>
    <button data-tm="permBtn" class="tm-sbtn tm-lite tm-hide">Coach permissions</button>
    <button data-tm="allDivBtn" class="tm-sbtn tm-lite tm-hide">+ A group for every division</button>
    <span style="flex:1"></span>
    <button data-tm="alertsBtn" class="tm-sbtn tm-lite">🔔 My alerts</button>
  </div>
  <div data-tm="shell" class="tm-shell">
    <div class="tm-list"><div data-tm="chanList" class="tm-chans"></div></div>
    <div class="tm-thread">
      <div class="tm-head">
        <button data-tm="backBtn" class="tm-sbtn tm-lite tm-back">← All chats</button>
        <div style="flex:1;min-width:0"><div class="font-bold truncate" data-tm="chName">Pick a chat</div><div class="text-xs text-gray-500" data-tm="chSub"></div></div>
        <button data-tm="galBtn" class="tm-sbtn tm-lite tm-hide">Photos</button>
        <button data-tm="editBtn" class="tm-sbtn tm-lite tm-hide">Edit</button>
      </div>
      <div data-tm="msgs" class="tm-msgs"><p class="text-sm text-gray-500">Pick a chat on the left to read its messages.</p></div>
      <div data-tm="pending" class="tm-pending"></div>
      <div data-tm="composer" class="tm-composer tm-hide">
        <button data-tm="attach" type="button" class="tm-attach" title="Add photos or files" aria-label="Add photos or files">📎</button>
        <input data-tm="fileIn" type="file" multiple class="tm-hide" accept="image/*,.pdf,.doc,.docx,.xls,.xlsx,.csv,.txt">
        <textarea data-tm="body" rows="1" maxlength="2000" placeholder="Write a message…"></textarea><button data-tm="send" class="tm-btn tm-pri">Send</button></div>
      <div data-tm="readOnly" class="tm-ro tm-hide"></div>
    </div>
  </div>
</div>
<div data-tm="modal" class="tm-modal"><div data-tm="modalBox"></div></div>`;

const BUCKET='team-messages';
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const linkify=s=>esc(s).replace(/(https?:\/\/[^\s<]+[^\s<.,;:!?)\]])/g,'<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>');
const TEAM=c=>((window.VYC_TEAMS||[]).find(t=>t.code===c)||{}).name||c;
const isImg=a=>/^image\/(jpeg|png|gif|webp)$/.test(a.type||'');
const clean=e=>String((e&&e.message)||e).replace(/^.*?: /,'');
function toast(m,bad){ let t=document.getElementById('tmToast'); if(!t){ t=document.createElement('div'); t.id='tmToast'; t.style.cssText='position:fixed;bottom:16px;left:50%;transform:translateX(-50%);color:#fff;padding:.6rem 1rem;border-radius:.5rem;font-size:.9rem;z-index:9999;display:none;max-width:90vw'; document.body.appendChild(t); }
  t.textContent=m; t.style.background=bad?'#991b1b':'#111827'; t.style.display='block'; clearTimeout(toast.h); toast.h=setTimeout(()=>t.style.display='none',bad?6000:2500); }

window.mountMessenger=async function(root, opts){
  opts=opts||{}; const sb=opts.sb;
  if(root.__tm){ clearInterval(root.__tm.timer); try{ if(root.__tm.live) sb.removeChannel(root.__tm.live); }catch(e){} }
  const S=root.__tm={timer:null,live:null};
  if(!document.getElementById('tmStyle')) document.head.insertAdjacentHTML('beforeend',CSS);
  root.classList.add('tm'); root.innerHTML=HTML;
  const $=k=>root.querySelector(`[data-tm="${k}"]`), hide=(k,h)=>$(k).classList.toggle('tm-hide',!!h);
  const alive=()=>root.__tm===S&&document.body.contains(root);
  let uid=null, email=null, myTeams=[], team=null, mgr=false, chans=[], cur=null, msgs=[], files=[], urls={}, lim=200, hist=[], histLim=100, histQ='';
  // One column (list, then the chat) whenever the panel itself is narrow — a phone, or a slim dashboard column.
  const narrow=()=>(root.clientWidth||window.innerWidth)<700, fit=()=>{ root.classList.toggle('tm-narrow',narrow()); if(!narrow()&&!cur&&chans.length&&!$('main').classList.contains('tm-hide')) openChannel(latest().id); };
  try{ new ResizeObserver(()=>{ if(alive()) fit(); }).observe(root); }catch(e){ window.addEventListener('resize',fit); }
  try{ const {data}=await sb.auth.getSession(); uid=data.session.user.id; email=data.session.user.email; }catch(e){ return 'none'; }
  if(window.leagueReady) await window.leagueReady;

  const {data:mt,error:e0}=await sb.rpc('msg_my_teams'); if(e0) return 'none';   // the database part isn't installed
  myTeams=mt||[];
  const pickable=opts.lockTeam?[opts.team]:myTeams.map(t=>t.team_code);
  if(!pickable.length||!pickable[0]) return 'none';
  team=pickable.includes(opts.team)?opts.team:(myTeams.find(t=>t.enabled)||myTeams[0]).team_code;
  if(pickable.length>1){ $('teamSel').innerHTML=pickable.map(c=>`<option value="${esc(c)}" ${c===team?'selected':''}>${esc(TEAM(c))}</option>`).join(''); hide('teamSel',false);
    $('teamSel').onchange=()=>{ team=$('teamSel').value; cur=null; loadTeam(); }; }

  const latest=()=>chans.find(c=>c.unread>0&&!c.archived)||chans.find(c=>c.last_at&&!c.archived)||chans[0];
  const ALL='__all';   // the "All messages" history view
  const myRow=()=>myTeams.find(t=>t.team_code===team)||null;
  const canStart=()=>mgr||!!(myRow()&&myRow().can_post);
  const note=(html,style)=>`<div class="tm-note" style="${style||''}">${html}</div>`;

  async function loadTeam(){
    const r=myRow(), tn=esc(TEAM(team));
    const [{data:sw},{data:m}]=await Promise.all([sb.from('team_messaging').select('enabled').eq('team_code',team).maybeSingle(), sb.rpc('msg_can_manage',{t:team})]);
    const on=!!(sw&&sw.enabled); mgr=!!m;
    hide('main',true); $('notice').innerHTML=''; report();
    if(!on){
      if(!mgr) return 'none';   // parents and regular coaches see nothing until their team has it
      $('notice').innerHTML=note(`<span class="tm-pill warn">Paid team extra</span> <b>Team Messenger is not switched on for ${tn}.</b><br>Message your parents right here on the dashboard — the whole team, one division (age group), boys or girls only, a coaches-only group, or one parent directly — with photos and files, and each parent sees it on their own dashboard. It is part of the paid team extras; the league site admin switches it on (Site Admin → Messages).`,'border-color:#f59e0b;background:#fffbeb');
      return 'off'; }
    if(r&&!r.is_coach&&r.waiting&&!mgr){ $('notice').innerHTML=note(`You'll see ${tn}'s team messages here as soon as the team has reviewed your athlete's registration.`); return 'on'; }
    if(r&&r.is_coach&&!r.can_post&&!mgr) $('notice').innerHTML=note(`You can read your division's chats and use <b>Coaches only</b>. To message parents, ask your team admin to give you permission.`,'border-color:#f59e0b;background:#fffbeb');
    hide('main',false);
    await loadChannels();
    // Open straight onto the current conversation: the chat with something new, otherwise the one with the latest message.
    if(!cur&&chans.length) openChannel(latest().id);
    subscribe();
    return 'on';
  }

  async function loadChannels(){
    const {data,error}=await sb.rpc('msg_my_channels',{p_team:team});
    if(error){ toast(clean(error),true); return; }
    chans=data||[];
    hide('newBtn',!mgr); hide('permBtn',!mgr); hide('allDivBtn',!mgr); hide('dmBtn',!canStart());
    const row=c=>`<button type="button" class="tm-chan ${cur===c.id?'sel':''}" data-ch="${c.id}">
        <div class="nm"><span>${esc(c.name)}</span>${c.archived?'<span class="tm-pill">closed</span>':''}${c.unread&&cur!==c.id?`<span class="tm-unread">${c.unread}</span>`:''}</div>
        <div class="pv">${c.last_at?`<b>${esc((c.last_sender||'').split(' ')[0])}:</b> ${esc(c.last_body)}`:esc(who(c))}</div></button>`;
    const groups=chans.filter(c=>c.audience!=='direct'), dms=chans.filter(c=>c.audience==='direct');
    const total=chans.reduce((a,c)=>a+(c.unread||0),0);
    const all=chans.length?`<button type="button" class="tm-chan ${cur===ALL?'sel':''}" data-ch="${ALL}"><div class="nm"><span>🕘 All messages</span>${total&&cur!==ALL?`<span class="tm-unread">${total}</span>`:''}</div><div class="pv">History of everything sent, newest first</div></button>`:'';
    $('chanList').innerHTML=all+(groups.map(row).join('')+(dms.length?`<div class="tm-sect">Direct messages</div>`+dms.map(row).join(''):''))
      || `<p class="text-sm text-gray-500 p-3">${mgr?'No groups yet. Tap “+ Group” to make the first one.':'No messages for you yet.'}</p>`;
    report();
  }
  function report(){ const other=chans.reduce((a,c)=>a+(cur===c.id?0:(c.unread||0)),0); $('backBtn').innerHTML='← All chats'+(other?` <span class="tm-unread" style="margin-left:4px">${other}</span>`:'');
    if(opts.onUnread) try{ opts.onUnread(chans.reduce((a,c)=>a+(cur===c.id?0:(c.unread||0)),0)); }catch(e){} }
  function who(c){ const g=c.genders&&c.genders.length===1?(c.genders[0]==='Boy'?' · boys':' · girls'):'';
    return c.audience==='direct'?'Direct message':c.audience==='coaches'?'Coaches only':c.audience==='team'?'Whole team'+g:(c.divisions||[]).join(', ')+g; }

  $('chanList').onclick=e=>{ const b=e.target.closest('[data-ch]'); if(b) openChannel(b.dataset.ch); };
  $('backBtn').onclick=()=>{ $('shell').classList.remove('open'); cur=null; loadChannels(); };

  async function openChannel(id,quiet){
    if(id===ALL) return openHistory();
    cur=id; lim=200; const c=chans.find(x=>x.id===id); if(!c) return;
    files=[]; drawPending();
    $('shell').classList.add('open');
    root.querySelectorAll('.tm-chan').forEach(b=>b.classList.toggle('sel',b.dataset.ch===id));
    $('chName').textContent=c.name;
    $('chSub').innerHTML=c.audience==='direct'
      ? `Direct message · ${c.my_role==='admin'?'you are in this chat as a team admin':'your team admins can also see this conversation'}`
      : `${esc(who(c))}${c.audience!=='coaches'?` · ${c.families} famil${c.families===1?'y':'ies'}`:''} · ${c.mode==='announce'?'announcements — only coaches post':'two-way chat'} · team admins are in every chat`;
    hide('editBtn',!c.can_manage); $('editBtn').textContent=c.audience==='direct'?(c.archived?'Re-open':'Close chat'):'Edit';
    hide('galBtn',false); hide('composer',!c.can_post); hide('readOnly',c.can_post);
    $('readOnly').textContent=c.archived?'This chat is closed — you can still read everything that was sent.':c.my_role==='coach_read'?(c.audience==='team'?"Only a Head Coach or team admin with permission can post to the whole team.":"Your team admin hasn't given you permission to message parents yet."):'Only the coaches can post in this group.';
    $('msgs').innerHTML='<p class="text-sm text-gray-500">Loading…</p>';
    await loadMessages(true);
  }

  // Photos and files are private: each one gets a short-lived link when it's shown.
  async function signAll(list){
    const need=[...new Set(list.flatMap(m=>(m.attachments||[]).map(a=>a.path)))].filter(p=>!urls[p]||urls[p].exp<Date.now());
    if(!need.length) return;
    try{ const {data}=await sb.storage.from(BUCKET).createSignedUrls(need,3600); (data||[]).forEach(x=>{ if(x.signedUrl) urls[x.path]={url:x.signedUrl,exp:Date.now()+50*60000}; }); }catch(e){}
  }
  const U=p=>(urls[p]||{}).url||'';
  const attHtml=a=>{ const u=U(a.path); if(!u) return `<span class="tm-file">📎 <span>${esc(a.name)}</span></span>`;
    return isImg(a)?`<a href="${esc(u)}" target="_blank" rel="noopener"><img src="${esc(u)}" alt="${esc(a.name)}" loading="lazy"></a>`
      :`<a class="tm-file" href="${esc(u)}" target="_blank" rel="noopener" download="${esc(a.name)}">📎 <span>${esc(a.name)}</span></a>`; };

  async function loadMessages(jump){
    const id=cur; if(!id||id===ALL) return;
    const {data,error}=await sb.from('msg_messages').select('*').eq('channel_id',id).order('created_at',{ascending:false}).limit(lim);
    if(id!==cur) return;
    if(error){ $('msgs').innerHTML=`<p class="text-sm text-red-700">${esc(clean(error))}</p>`; return; }
    const more=(data||[]).length>=lim, next=(data||[]).reverse(), box=$('msgs');
    const sig=l=>l.map(m=>m.id+(m.deleted_at?'x':'')).join(','); const changed=sig(next)!==sig(msgs)||jump; msgs=next;
    if(!changed) return;
    await signAll(msgs); if(id!==cur) return;
    const nearEnd=box.scrollHeight-box.scrollTop-box.clientHeight<120, c=chans.find(x=>x.id===id)||{};
    let day='';
    box.innerHTML=(more?`<p class="text-center mb-2"><button class="tm-sbtn tm-lite" data-older>Show earlier messages</button></p>`:msgs.length?`<p class="tm-day">Start of this chat</p>`:'')+msgs.map(m=>{ const d=new Date(m.created_at), dk=d.toDateString(), mine=m.sender_id===uid, att=m.attachments||[];
      const head=dk!==day?`<div class="tm-day">${d.toLocaleDateString('en-US',{weekday:'long',month:'long',day:'numeric'})}</div>`:''; day=dk;
      const t=d.toLocaleTimeString('en-US',{hour:'numeric',minute:'2-digit'});
      return head+`<div class="tm-m ${mine?'mine':''} ${m.sender_role==='coach'?'coach':''} ${m.deleted_at?'gone':''}">
        <div class="who">${mine?'You':`<b>${esc(m.sender_name)}</b>${m.sender_label?' · '+esc(m.sender_label):''}`} · ${t}${!m.deleted_at&&(mine||c.can_manage)?` <button class="del" data-del="${m.id}">remove</button>`:''}</div>
        ${m.deleted_at?'<div class="b">Message removed</div>':(m.body?`<div class="b">${linkify(m.body)}</div>`:'')+(att.length?`<div class="tm-atts">${att.map(attHtml).join('')}</div>`:'')}</div>`; }).join('')
      || `<p class="text-sm text-gray-500">No messages yet.${c.can_post?' Say hello 👋':''}</p>`;
    if(jump||nearEnd){ box.scrollTop=box.scrollHeight; box.querySelectorAll('img').forEach(i=>i.addEventListener('load',()=>{ box.scrollTop=box.scrollHeight; },{once:true})); }
    sb.rpc('msg_mark_read',{p_channel:id}).then(()=>{ const x=chans.find(y=>y.id===id); if(x) x.unread=0; report(); });
  }
  $('msgs').onclick=async e=>{
    if(e.target.closest('[data-older]')){ if(cur===ALL){ histLim+=100; return drawHistory(); } const box=$('msgs'), h=box.scrollHeight; lim+=200; await loadMessages(true); box.scrollTop=box.scrollHeight-h; return; }
    const go=!e.target.closest('a')&&e.target.closest('[data-go]'); if(go) return openChannel(go.dataset.go);
    const b=e.target.closest('[data-del]'); if(!b) return; if(!confirm('Remove this message for everyone?')) return;
    const m=msgs.find(x=>x.id===b.dataset.del), paths=((m&&m.attachments)||[]).map(a=>a.path);
    if(paths.length){ try{ await sb.storage.from(BUCKET).remove(paths); }catch(e){} }
    const {error}=await sb.rpc('msg_delete',{p_message:b.dataset.del}); if(error){ toast(clean(error),true); return; } loadMessages(); };

  /* ---------- All messages: one history of everything sent in my chats, newest first ---------- */
  async function openHistory(){
    cur=ALL; histLim=100; histQ=''; files=[]; drawPending();
    $('shell').classList.add('open');
    root.querySelectorAll('.tm-chan').forEach(b=>b.classList.toggle('sel',b.dataset.ch===ALL));
    $('chName').textContent='All messages';
    $('chSub').textContent=`Everything ever sent in your ${TEAM(team)} chats, newest first — tap a message to open that chat`;
    hide('editBtn',true); hide('galBtn',true); hide('composer',true); hide('readOnly',true);
    $('msgs').innerHTML='<p class="text-sm text-gray-500">Loading…</p>';
    await drawHistory();
  }
  async function drawHistory(quiet){
    const ids=chans.map(c=>c.id); if(!ids.length){ $('msgs').innerHTML='<p class="text-sm text-gray-500">No messages yet.</p>'; return; }
    let rq=sb.from('msg_messages').select('*').in('channel_id',ids).is('deleted_at',null).order('created_at',{ascending:false}).limit(histLim);
    if(histQ) rq=rq.ilike('body','%'+histQ.replace(/[%_]/g,'')+'%');
    const {data,error}=await rq; if(cur!==ALL) return;
    if(error){ $('msgs').innerHTML=`<p class="text-sm text-red-700">${esc(clean(error))}</p>`; return; }
    const sig=(data||[]).map(m=>m.id).join(','); if(quiet&&sig===drawHistory.sig) return; drawHistory.sig=sig; hist=data||[];
    await signAll(hist); if(cur!==ALL) return;
    const box=$('msgs'), keep=box.scrollTop, had=box.querySelector('[data-hq]'), focus=had&&document.activeElement===had;
    let day='';
    box.innerHTML=`<input data-hq class="border rounded p-2 w-full mb-2 text-sm" placeholder="Search the messages…" value="${esc(histQ)}">`+(hist.map(m=>{ const d=new Date(m.created_at), dk=d.toDateString(), c=chans.find(x=>x.id===m.channel_id)||{}, att=m.attachments||[];
        const head=dk!==day?`<div class="tm-day">${d.toLocaleDateString('en-US',{weekday:'long',month:'long',day:'numeric',year:'numeric'})}</div>`:''; day=dk;
        return head+`<div class="tm-m ${m.sender_role==='coach'?'coach':''}" style="max-width:100%;cursor:pointer" data-go="${m.channel_id}" title="Open this chat">
          <div class="who"><span class="tm-pill">${esc(c.name||'Chat')}</span> ${m.sender_id===uid?'You':`<b>${esc(m.sender_name)}</b>${m.sender_label?' · '+esc(m.sender_label):''}`} · ${d.toLocaleTimeString('en-US',{hour:'numeric',minute:'2-digit'})}</div>
          ${m.body?`<div class="b">${linkify(m.body)}</div>`:''}${att.length?`<div class="tm-atts">${att.map(attHtml).join('')}</div>`:''}</div>`; }).join('')
      ||`<p class="text-sm text-gray-500">${histQ?'No message matches that search.':'No messages yet.'}</p>`)
      +(hist.length>=histLim?`<p class="text-center mt-2"><button class="tm-sbtn tm-lite" data-older>Show older messages</button></p>`:hist.length?`<p class="tm-day">That's everything</p>`:'');
    box.scrollTop=quiet?keep:(histLim>100?keep:0);
    const inp=box.querySelector('[data-hq]'); if(focus){ inp.focus(); inp.setSelectionRange(inp.value.length,inp.value.length); }
    inp.oninput=()=>{ clearTimeout(drawHistory.t); drawHistory.t=setTimeout(()=>{ histQ=inp.value.trim(); histLim=100; drawHistory.sig=null; const f=()=>{ const i=$('msgs').querySelector('[data-hq]'); if(i){ i.focus(); i.setSelectionRange(i.value.length,i.value.length); } }; drawHistory().then(f); },350); };
  }

  /* ---------- photos & files ---------- */
  $('attach').onclick=()=>$('fileIn').click();
  $('fileIn').onchange=async e=>{ for(const f of [...e.target.files]){ if(files.length>=6){ toast('Six photos or files at most per message.',true); break; }
      const g=await shrink(f); if(g.size>10*1024*1024){ toast(`${f.name} is over 10 MB.`,true); continue; } files.push(g); }
    e.target.value=''; drawPending(); };
  function drawPending(){ $('pending').innerHTML=files.map((f,i)=>`<span class="tm-file">${/^image\//.test(f.type)?'🖼️':'📎'} <span>${esc(f.name)}</span> <button type="button" data-rm="${i}" aria-label="Remove">✕</button></span>`).join(''); }
  $('pending').onclick=e=>{ const b=e.target.closest('[data-rm]'); if(!b) return; files.splice(+b.dataset.rm,1); drawPending(); };
  // Phone photos are huge — shrink big JPEG/PNG photos to 2000px before uploading.
  async function shrink(f){ if(!/^image\/(jpeg|png)$/.test(f.type)||f.size<1.5*1024*1024) return f;
    try{ const bmp=await createImageBitmap(f), k=Math.min(1,2000/Math.max(bmp.width,bmp.height)), cv=document.createElement('canvas'); cv.width=Math.round(bmp.width*k); cv.height=Math.round(bmp.height*k);
      cv.getContext('2d').drawImage(bmp,0,0,cv.width,cv.height); const blob=await new Promise(r=>cv.toBlob(r,'image/jpeg',.85));
      return blob&&blob.size<f.size?new File([blob],f.name.replace(/\.\w+$/,'')+'.jpg',{type:'image/jpeg'}):f; }catch(e){ return f; } }
  $('galBtn').onclick=()=>{ const live=msgs.filter(m=>!m.deleted_at), pics=live.flatMap(m=>(m.attachments||[]).filter(isImg).map(a=>({a,m}))).reverse(), docs=live.flatMap(m=>(m.attachments||[]).filter(a=>!isImg(a))).reverse();
    openModal(`<h2 class="font-bold text-lg mb-2">Photos &amp; files — ${esc($('chName').textContent)}</h2>
      ${pics.length?`<div class="tm-gal">${pics.map(({a,m})=>`<a href="${esc(U(a.path))}" target="_blank" rel="noopener" title="${esc(m.sender_name)} · ${new Date(m.created_at).toLocaleDateString()}"><img src="${esc(U(a.path))}" alt="${esc(a.name)}" loading="lazy"></a>`).join('')}</div>`:'<p class="text-sm text-gray-500">No photos in this chat yet.</p>'}
      ${docs.length?`<h3 class="font-bold mt-3 mb-1">Files</h3><div class="flex flex-wrap gap-2">${docs.map(attHtml).join('')}</div>`:''}
      <div class="mt-3"><button class="tm-btn tm-lite" data-close>Close</button></div>`); };

  async function send(){
    const ta=$('body'), text=ta.value.trim(), ch=cur; if((!text&&!files.length)||!ch) return;
    $('send').disabled=true; $('send').textContent=files.length?'Uploading…':'Sending…';
    try{
      const att=[];
      for(const f of files){ const path=`${ch}/${crypto.randomUUID()}-${f.name.replace(/[^\w.\-]+/g,'_').slice(-80)}`;
        const {error}=await sb.storage.from(BUCKET).upload(path,f,{contentType:f.type||'application/octet-stream'}); if(error) throw new Error(`${f.name}: ${clean(error)}`);
        att.push({path,name:f.name,type:f.type,size:f.size}); }
      const {data:id,error}=await sb.rpc('msg_post',{p_channel:ch,p_body:text,p_attachments:att}); if(error) throw error;
      ta.value=''; ta.style.height='auto'; files=[]; drawPending();
      try{ sb.functions.invoke('msg-notify',{body:{message_id:id}}).catch(()=>{}); }catch(e){}   // email / text alerts go out in the background
      await loadMessages(true); loadChannels();
    }catch(e){ toast(clean(e),true); }
    $('send').disabled=false; $('send').textContent='Send';
  }
  $('send').onclick=send;
  $('body').addEventListener('keydown',e=>{ if(e.key==='Enter'&&!e.shiftKey&&!narrow()){ e.preventDefault(); send(); } });
  $('body').addEventListener('input',e=>{ e.target.style.height='auto'; e.target.style.height=Math.min(e.target.scrollHeight,144)+'px'; });

  async function refresh(){ if(!alive()){ clearInterval(S.timer); return; } if($('main').classList.contains('tm-hide')||document.hidden) return; await loadChannels(); if(cur===ALL) await drawHistory(true); else if(cur) await loadMessages(); }
  // New messages arrive live; a 25-second check is the safety net.
  function subscribe(){ try{ if(S.live) sb.removeChannel(S.live); S.live=sb.channel('team-messenger-'+Math.random().toString(36).slice(2)).on('postgres_changes',{event:'*',schema:'public',table:'msg_messages'},()=>refresh()).subscribe(); }catch(e){} }
  S.timer=setInterval(refresh,25000);
  document.addEventListener('visibilitychange',()=>{ if(!document.hidden) refresh(); });

  /* ---------- pop-up boxes ---------- */
  function openModal(html){ $('modalBox').innerHTML=html; $('modal').style.display='flex'; }
  function closeModal(){ $('modal').style.display='none'; }
  $('modal').addEventListener('mousedown',e=>{ if(e.target===$('modal')) closeModal(); });
  $('modal').addEventListener('click',e=>{ if(e.target.closest('[data-close]')) closeModal(); });
  const q=sel=>$('modalBox').querySelector(sel);

  /* ---------- create / edit a group (team admins) ---------- */
  $('newBtn').onclick=()=>groupForm(null);
  $('editBtn').onclick=async()=>{ const c=chans.find(x=>x.id===cur); if(!c) return; if(c.audience!=='direct') return groupForm(c);
    if(!confirm(c.archived?'Re-open this direct message?':'Close this direct message? Nobody can post in it any more; you and the parent can still read what was sent.')) return;
    const {error}=await sb.rpc('msg_save_channel',{p_id:c.id,p_team:team,p_name:c.name,p_audience:'team',p_divisions:null,p_genders:null,p_mode:'chat',p_archived:!c.archived});
    if(error){ toast(clean(error),true); return; } await loadChannels(); openChannel(c.id); };
  function groupForm(c){
    const a=c?c.audience:'team', g=c&&c.genders&&c.genders.length===1?c.genders[0]:'', md=c?c.mode:'chat', divs=(c&&c.divisions)||[];
    const rad=(n,v,on,html)=>`<label class="tm-opt"><input type="radio" name="${n}" value="${v}" ${on?'checked':''} class="mt-1"><span>${html}</span></label>`;
    openModal(`<h2 class="font-bold text-lg mb-2">${c?'Edit group':'New message group'} — ${esc(TEAM(team))}</h2>
      <label class="text-sm font-semibold">Group name</label>
      <input data-g="name" maxlength="60" class="border rounded p-2 w-full mb-3" placeholder="e.g. Bantam parents, Meet-day updates" value="${esc(c?c.name:'')}">
      <div class="text-sm font-semibold mb-1">Who is in it?</div>
      ${rad('tmAud','team',a==='team','<b>The whole team</b> — every parent and every coach')}
      ${rad('tmAud','divisions',a==='divisions','<b>Certain divisions (age groups)</b> — those parents, plus the coaches signed up for those divisions')}
      <div data-g="divBox" class="flex flex-wrap gap-x-4 gap-y-1 ml-6 mb-2 text-sm ${a==='divisions'?'':'tm-hide'}">${window.DIVISIONS.map(d=>`<label class="flex items-center gap-1"><input type="checkbox" data-div value="${esc(d.name)}" ${divs.includes(d.name)?'checked':''}> ${esc(d.name)} <span class="text-xs text-gray-400">${d.min}–${d.max}</span></label>`).join('')}</div>
      ${rad('tmAud','coaches',a==='coaches','<b>Coaches only</b> — parents never see it')}
      <div data-g="parentBox" class="${a==='coaches'?'tm-hide':''}">
        <label class="text-sm font-semibold mt-2 block">Boys, girls, or both?</label>
        <select data-g="gen" class="border rounded p-2 w-full mb-3"><option value="">Both</option><option value="Boy" ${g==='Boy'?'selected':''}>Boys' parents only</option><option value="Girl" ${g==='Girl'?'selected':''}>Girls' parents only</option></select>
        <div class="text-sm font-semibold mb-1">Can parents write back?</div>
        ${rad('tmMode','chat',md==='chat','<b>Two-way chat</b> — parents can reply')}
        ${rad('tmMode','announce',md==='announce','<b>Announcements</b> — only coaches post; parents read')}
      </div>
      ${c?`<label class="flex items-center gap-2 text-sm mt-2"><input type="checkbox" data-g="arch" ${c.archived?'checked':''}> Close this group (nobody can post any more; everyone can still read what was sent)</label>`:''}
      <p class="text-xs text-gray-500 mt-2">Team admins are in every group automatically. Parents are added once the team has reviewed their athlete's registration, and each parent sees the messages on their own dashboard. Coaches can read their own divisions' groups; they can post once you give them permission (“Coach permissions”).</p>
      <div class="flex gap-2 mt-3"><button data-g="save" class="tm-btn tm-pri">${c?'Save':'Create group'}</button><button class="tm-btn tm-lite" data-close>Cancel</button><span data-g="msg" class="text-sm text-red-600 self-center"></span></div>`);
    const G=k=>q(`[data-g="${k}"]`), aud=()=>q('input[name=tmAud]:checked').value;
    $('modalBox').querySelectorAll('input[name=tmAud]').forEach(r=>r.onchange=()=>{ G('divBox').classList.toggle('tm-hide',aud()!=='divisions'); G('parentBox').classList.toggle('tm-hide',aud()==='coaches'); });
    G('save').onclick=async()=>{ const A=aud(), gen=G('gen').value;
      const {data,error}=await sb.rpc('msg_save_channel',{p_id:c?c.id:null,p_team:team,p_name:G('name').value,p_audience:A,
        p_divisions:A==='divisions'?[...$('modalBox').querySelectorAll('[data-div]:checked')].map(x=>x.value):null,p_genders:gen?[gen]:null,
        p_mode:q('input[name=tmMode]:checked').value,p_archived:c?G('arch').checked:false});
      if(error){ G('msg').textContent=clean(error); return; }
      closeModal(); toast(c?'Saved':'Group created'); await loadChannels(); openChannel(data||cur); };
  }
  $('allDivBtn').onclick=async()=>{
    const have=new Set(chans.filter(c=>c.audience==='divisions'&&(c.divisions||[]).length===1&&!c.genders).map(c=>c.divisions[0]));
    const todo=window.DIVISIONS.map(d=>d.name).filter(n=>!have.has(n));
    if(!todo.length){ toast('Every division already has a group.'); return; }
    if(!confirm(`Create ${todo.length} two-way chat group${todo.length>1?'s':''} — one for each division: ${todo.join(', ')}?`)) return;
    for(const n of todo){ const {error}=await sb.rpc('msg_save_channel',{p_id:null,p_team:team,p_name:n+' parents',p_audience:'divisions',p_divisions:[n],p_genders:null,p_mode:'chat',p_archived:false}); if(error){ toast(clean(error),true); break; } }
    loadChannels();
  };

  /* ---------- direct message: pick an athlete, talk to that athlete's parent ---------- */
  $('dmBtn').onclick=async()=>{
    openModal(`<h2 class="font-bold text-lg mb-1">Direct message a parent</h2>
      <p class="text-xs text-gray-500 mb-2">Pick the athlete — the message goes to that athlete's parent only, and shows on their dashboard. ${mgr?'':'You can message parents of athletes in your own division. '}Your team admins can always see direct messages.</p>
      <input data-g="q" class="border rounded p-2 w-full mb-2" placeholder="Search by athlete name…"><div data-g="list" class="border rounded" style="max-height:50vh;overflow:auto"><p class="text-sm text-gray-500 p-2">Loading…</p></div>
      <div class="mt-3"><button class="tm-btn tm-lite" data-close>Cancel</button></div>`);
    const G=k=>q(`[data-g="${k}"]`);
    const {data,error}=await sb.rpc('team_roster'); if(error){ G('list').innerHTML=`<p class="text-sm text-red-700 p-2">${esc(clean(error))}</p>`; return; }
    const list=(data||[]).filter(r=>r.team_code===team&&['reviewed','verified'].includes(r.status)).sort((a,b)=>(a.last_name||'').localeCompare(b.last_name||'')||(a.first_name||'').localeCompare(b.first_name||''));
    const draw=()=>{ const s=G('q').value.trim().toLowerCase(), L=list.filter(r=>!s||`${r.first_name} ${r.last_name}`.toLowerCase().includes(s));
      G('list').innerHTML=L.map(r=>`<button type="button" class="tm-row" data-reg="${r.id}"><b>${esc(r.last_name)}, ${esc(r.first_name)}</b><span class="text-xs text-gray-500">${esc(r.division||'')} · ${esc(r.gender||'')}</span><span class="ml-auto text-xs text-blue-700">Message parent →</span></button>`).join('')
        ||`<p class="text-sm text-gray-500 p-2">${list.length?'No athlete matches.':'No reviewed athletes yet — a parent can be messaged once the team has reviewed the registration.'}</p>`; };
    draw(); G('q').oninput=draw; G('q').focus();
    G('list').onclick=async e=>{ const b=e.target.closest('[data-reg]'); if(!b) return;
      const {data:id,error}=await sb.rpc('msg_start_dm',{p_registration:b.dataset.reg}); if(error){ toast(clean(error),true); return; }
      closeModal(); await loadChannels(); openChannel(id); };
  };

  /* ---------- team admin: which coaches may message parents ---------- */
  $('permBtn').onclick=async()=>{
    openModal(`<h2 class="font-bold text-lg mb-1">Coach permissions — ${esc(TEAM(team))}</h2>
      <p class="text-xs text-gray-500 mb-2">Tick a coach to let them message parents. A coach can only post to (and direct-message) parents in the divisions they signed up to coach; a Head Coach covers the whole team. Unticked coaches can still read their divisions' groups and use “Coaches only”. Team admins are in every chat.</p>
      <div data-g="list"><p class="text-sm text-gray-500">Loading…</p></div><div class="mt-3"><button class="tm-btn tm-lite" data-close>Done</button></div>`);
    const L0=q('[data-g="list"]');
    const [{data:cs,error},{data:acc}]=await Promise.all([sb.from('coaches').select('*').eq('team_code',team).eq('approved',true), sb.from('msg_coach_access').select('*').eq('team_code',team)]);
    if(error){ L0.innerHTML=`<p class="text-sm text-red-700">${esc(clean(error))}</p>`; return; }
    const on={}; (acc||[]).forEach(a=>on[a.email.toLowerCase()]=a.can_post);
    const nm=c=>c.name||`${c.first_name||''} ${c.last_name||''}`.trim()||c.email;
    const scope=c=>c.role_type==='division_coach'&&!/^all/i.test(c.division_or_age_group||'')?`${c.division_or_age_group||'—'}${c.coach_gender?' · '+c.coach_gender:''}`:'Whole team';
    const L=(cs||[]).filter(c=>c.role_type!=='timer').sort((a,b)=>nm(a).localeCompare(nm(b)));
    L0.innerHTML=L.map(c=>`<label class="flex items-center gap-2 border-b py-2 text-sm">
        ${(c.team_admin||c.is_admin)?'<span class="tm-pill ok">Admin</span>':`<input type="checkbox" data-coach="${esc(c.email)}" ${on[c.email.toLowerCase()]?'checked':''}>`}
        <span class="flex-1"><b>${esc(nm(c))}</b> <span class="text-xs text-gray-500">${(c.team_admin||c.is_admin)?'in every chat':esc(c.role_type==='head_coach'?'Head Coach':c.role_type==='division_coach'?'Division Coach':'Coach')+' · '+esc(scope(c))}</span></span></label>`).join('')
      ||'<p class="text-sm text-gray-500">No approved coaches on this team yet.</p>';
    L0.onchange=async e=>{ const cb=e.target.closest('[data-coach]'); if(!cb) return;
      const {error}=await sb.rpc('msg_set_coach_access',{p_team:team,p_email:cb.dataset.coach,p_on:cb.checked}); if(error){ toast(clean(error),true); cb.checked=!cb.checked; return; }
      toast(cb.checked?'They can now message parents':'Permission removed'); };
  };

  /* ---------- my alerts: email and/or text when there's a new message ---------- */
  $('alertsBtn').onclick=async()=>{
    const {data:p}=await sb.from('msg_prefs').select('*').maybeSingle(); const d=p||{email_on:true,sms_on:false,sms_phone:''};
    openModal(`<h2 class="font-bold text-lg mb-1">My message alerts</h2>
      <p class="text-xs text-gray-500 mb-3">Get a heads-up when your team posts something new. You get one alert per chat, then no more for that chat until you've opened it — so a busy chat won't flood you.</p>
      <label class="tm-opt"><input type="checkbox" data-g="email" ${d.email_on?'checked':''} class="mt-1"><span><b>Email me</b> at ${esc(email)}</span></label>
      <label class="tm-opt"><input type="checkbox" data-g="sms" ${d.sms_on?'checked':''} class="mt-1"><span><b>Text me</b><br><input data-g="phone" type="tel" class="border rounded p-2 mt-1" placeholder="Mobile number" value="${esc((d.sms_phone||'').replace(/^\+1/,''))}"></span></label>
      <p class="text-xs text-gray-500">By turning on texts you agree to receive team message alerts from VYC Track &amp; Field at this number. Message and data rates may apply. Reply STOP to any text to stop them.</p>
      <div class="flex gap-2 mt-3"><button data-g="save" class="tm-btn tm-pri">Save</button><button class="tm-btn tm-lite" data-close>Cancel</button><span data-g="msg" class="text-sm text-red-600 self-center"></span></div>`);
    const G=k=>q(`[data-g="${k}"]`);
    G('save').onclick=async()=>{ const {error}=await sb.rpc('msg_save_prefs',{p_email_on:G('email').checked,p_sms_on:G('sms').checked,p_phone:G('phone').value});
      if(error){ G('msg').textContent=clean(error); return; } closeModal(); toast('Saved'); };
  };

  return await loadTeam();
};
})();
