// Team hub — the pieces of each team's own page (team.html) that are also used on the dashboards:
//   window.TeamHub.mountGallery(el, ctx)      photo albums for the team's parents and coaches   (paid team extra)
//   window.TeamHub.mountStore(el, ctx)        the team store: items, cart, orders, and the team's order desk (paid team extra)
//   window.TeamHub.mountVolunteers(el, ctx)   meet-day duties: host sets them up, visiting teams take them, each team lays out its sign-up list (whole duty / by division / time shifts / own rows), parents sign up for a spot — parents see every meet stacked (free)
//   window.TeamHub.mountPosts(el, ctx)        news on the team page
//   window.TeamHub.editPage(ctx)              the team admin's "Edit team page" form
//   window.TeamHub.mountVolunteerSummary(el, ctx)   the small "volunteering" box on the Coach and Parent dashboards
//   window.TeamHub.mountVolunteerNudge(el, ctx)     parent reminder: athlete is coming to the next meet but nobody has volunteered
// ctx = { sb, team, role ('admin'|'coach'|'parent'|null), email, page (team_pages row), extras (bool) }
(function(){
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money=v=>'$'+(+v||0).toFixed(2).replace(/\.00$/,'');
const TEAM=c=>((window.VYC_TEAMS||[]).find(t=>t.code===c)||{}).name||c||'';
const fmtD=d=>d?new Date(String(d).slice(0,10)+'T12:00:00').toLocaleDateString('en-US',{weekday:'short',month:'short',day:'numeric'}):'';
const today=()=>new Date().toLocaleDateString('en-CA',{timeZone:'America/Los_Angeles'});
const clean=e=>String((e&&e.message)||e).replace(/^.*?: /,'');
const CSS=`<style id="thStyle">
.th{font-size:.95rem}.th .hide{display:none!important}
.th .btn,.th .sbtn{border-radius:8px;font-weight:600;border:1px solid transparent;cursor:pointer;font-size:.9rem;padding:.55rem .9rem;background:#fff;border-color:var(--field,#c7d1de);color:var(--ink,#0f1b2d)}
.th .sbtn{font-size:.82rem;padding:.35rem .7rem}.th .pri{background:var(--act,#1764c8);color:#fff;border-color:var(--act,#1764c8)}.th .grn{background:var(--ok,#1e7f52);color:#fff;border-color:var(--ok,#1e7f52)}
.th .red{color:var(--bad,#b42318);border-color:#e7b4ae}.th button:disabled{opacity:.5;cursor:default}
.th .pill{font-size:11px;font-weight:700;padding:3px 8px;border-radius:999px;background:#eef1f5;color:#4a5768;white-space:nowrap}.th .pill.ok{background:var(--ok-bg,#e4f4ec);color:var(--ok,#1e7f52)}.th .pill.warn{background:var(--warn-bg,#fff3d6);color:var(--warn,#8a5a00)}.th .pill.bad{background:var(--bad-bg,#fde7e4);color:var(--bad,#b42318)}.th .pill.act{background:var(--act,#1764c8);color:#fff}
.th .note{border-radius:10px;padding:10px 12px;margin-bottom:10px;font-size:.9rem;border:1px solid var(--line,#e1e7ef);background:#fff}.th .note.warn{border-color:#f59e0b;background:#fffbeb}.th .note.soft{background:var(--soft,#f7f9fc)}
.th .bar{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:10px}
.th input:not([type=checkbox]):not([type=radio]):not([type=file]),.th select,.th textarea{border:1.5px solid var(--field,#c7d1de);border-radius:8px;padding:.45rem .6rem;font-size:16px;background:#fff;max-width:100%}
.th label.f{display:block;font-size:.85rem;font-weight:600;margin-top:8px}.th label.f input,.th label.f select,.th label.f textarea{display:block;width:100%;margin-top:3px;font-weight:400}
.th .grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(11rem,1fr))}
.th .album{display:block;border:1px solid var(--line,#e1e7ef);border-radius:10px;overflow:hidden;background:#fff;cursor:pointer;text-align:left;padding:0}
.th .album .cv{aspect-ratio:4/3;background:var(--soft,#f7f9fc) center/cover no-repeat;display:grid;place-items:center;color:#8794a6;font-size:2rem}.th .album .nm{padding:8px 10px;font-weight:700;font-size:.9rem}.th .album .ct{padding:0 10px 8px;font-size:12px;color:#5b6878}
.th .photos{display:grid;gap:6px;grid-template-columns:repeat(auto-fill,minmax(9rem,1fr))}.th .ph{position:relative;aspect-ratio:1;border-radius:8px;overflow:hidden;background:var(--soft,#f7f9fc);cursor:zoom-in;border:0;padding:0}.th .ph img{width:100%;height:100%;object-fit:cover;display:block}
.th .ph .del{position:absolute;top:4px;right:4px;background:rgba(0,0,0,.55);color:#fff;border:0;border-radius:999px;width:24px;height:24px;cursor:pointer;font-size:14px;line-height:1}
.th .lb{position:fixed;inset:0;background:rgba(0,0,0,.92);z-index:9999;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:1rem}.th .lb img{max-width:100%;max-height:82vh;object-fit:contain;border-radius:6px}.th .lb .cap{color:#fff;margin-top:8px;font-size:.9rem;text-align:center}.th .lb .x{position:absolute;top:10px;right:14px;color:#fff;font-size:2rem;background:none;border:0;cursor:pointer}.th .lb .nav{position:absolute;top:50%;transform:translateY(-50%);color:#fff;font-size:2.4rem;background:none;border:0;cursor:pointer;padding:0 .6rem}.th .lb .nav.l{left:0}.th .lb .nav.r{right:0}
.th .item{border:1px solid var(--line,#e1e7ef);border-radius:10px;overflow:hidden;background:#fff;display:flex;flex-direction:column}.th .item .im{aspect-ratio:1;background:var(--soft,#f7f9fc) center/cover no-repeat;display:grid;place-items:center;color:#8794a6;font-size:2.4rem}.th .item .bd{padding:10px;display:flex;flex-direction:column;gap:6px;flex:1}.th .item .pr{font-weight:800;font-size:1.05rem}
.th table.t{width:100%;border-collapse:collapse;font-size:.88rem}.th table.t th,.th table.t td{padding:.45rem .5rem;border-bottom:1px solid #eef1f5;text-align:left;vertical-align:top}.th table.t th{background:var(--soft,#f7f9fc);font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:#5b6878}
.th .wrapx{overflow:auto}
.th .duty{border:1px solid var(--line,#e1e7ef);border-radius:10px;padding:10px 12px;margin-bottom:8px;background:#fff}.th .duty.mine{border-color:var(--act,#1764c8);box-shadow:0 0 0 3px var(--act-soft,#e6f0fc)}.th .duty.open{border-style:dashed}
.th .duty .hd{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px}.th .duty .nm{font-weight:700;font-size:1rem}.th .duty .sub{font-size:12px;color:#5b6878}.th .duty .people{font-size:.88rem;margin-top:4px}.th .duty .people span{display:inline-block;background:var(--soft,#f7f9fc);border:1px solid var(--line,#e1e7ef);border-radius:999px;padding:1px 9px;margin:2px 4px 2px 0}
.th .meter{height:6px;border-radius:3px;background:#eef1f5;overflow:hidden;width:7rem;flex:none}.th .meter i{display:block;height:100%;background:var(--ok,#1e7f52)}
.th .slot{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;padding:6px 0;border-top:1px dashed var(--line,#e1e7ef);font-size:.9rem}.th .slot .sl{font-weight:600;min-width:8rem}.th .slot .people{margin-top:0;flex-basis:100%}
.th details.meetbox{border:1px solid var(--line,#e1e7ef);border-radius:12px;background:#fff;padding:10px 12px;margin-bottom:10px}.th details.meetbox[open]{border-color:var(--act,#1764c8)}.th details.meetbox>summary{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;cursor:pointer;list-style:none}.th details.meetbox>summary::-webkit-details-marker{display:none}.th details.meetbox>summary .mt{font-weight:700;font-size:1rem}.th details.meetbox>summary::before{content:'▸';color:#5b6878}.th details.meetbox[open]>summary::before{content:'▾'}
.th .cat{font-size:11px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:#5b6878;margin:14px 0 6px}
.th .cartbar{position:sticky;bottom:0;background:#fff;border:1px solid var(--act,#1764c8);border-radius:10px;padding:10px 12px;margin-top:12px;box-shadow:0 -2px 10px rgba(0,0,0,.08)}
.th-modal{position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;z-index:9998;padding:1rem}.th-modal>div{background:#fff;border-radius:12px;padding:16px;max-width:36rem;width:100%;max-height:92vh;overflow:auto}
</style>`;
function css(){ if(!document.getElementById('thStyle')) document.head.insertAdjacentHTML('beforeend',CSS); }
function toast(m,bad){ let t=document.getElementById('thToast'); if(!t){ t=document.createElement('div'); t.id='thToast'; t.style.cssText='position:fixed;bottom:16px;left:50%;transform:translateX(-50%);color:#fff;padding:.6rem 1rem;border-radius:.5rem;font-size:.9rem;z-index:10000;display:none;max-width:90vw'; document.body.appendChild(t); }
  t.textContent=m; t.style.background=bad?'#991b1b':'#111827'; t.style.display='block'; clearTimeout(toast.h); toast.h=setTimeout(()=>t.style.display='none',bad?6000:2500); }
function modal(html){ closeModal(); const m=document.createElement('div'); m.className='th-modal th'; m.id='thModal'; m.innerHTML='<div>'+html+'</div>'; document.body.appendChild(m); m.addEventListener('mousedown',e=>{ if(e.target===m) closeModal(); }); return m.firstElementChild; }
function closeModal(){ const m=document.getElementById('thModal'); if(m) m.remove(); }
const publicUrl=(sb,path)=>path?sb.storage.from('team-public').getPublicUrl(path).data.publicUrl:'';
// Phone photos are huge — shrink big photos before uploading (longest side `max` px, JPEG).
async function shrink(file,max){ if(!/^image\/(jpeg|png|webp)$/.test(file.type)||file.size<400*1024) return file;
  try{ const bmp=await createImageBitmap(file); const sc=Math.min(1,max/Math.max(bmp.width,bmp.height)); if(sc>=1&&file.size<2.5e6) return file;
    const c=document.createElement('canvas'); c.width=Math.round(bmp.width*sc); c.height=Math.round(bmp.height*sc); c.getContext('2d').drawImage(bmp,0,0,c.width,c.height);
    const blob=await new Promise(r=>c.toBlob(r,'image/jpeg',.86)); return new File([blob],file.name.replace(/\.\w+$/,'')+'.jpg',{type:'image/jpeg'}); }catch(e){ return file; } }
const rnd=()=>Math.random().toString(36).slice(2,10);
const safeName=n=>String(n||'file').replace(/[^\w.\-]+/g,'_').slice(0,60);
const canManage=ctx=>ctx.role==='admin';

/* ============================ team page editor ============================ */
window.TeamHub={esc,money,toast,modal,closeModal,publicUrl,TEAM};
TeamHub.editPage=function(ctx){
  const sb=ctx.sb, p=ctx.page||{}, team=ctx.team;
  const f=(k,l,ph,type)=>`<label class="f">${l}<${type==='textarea'?'textarea rows="4"':'input'} data-k="${k}" placeholder="${esc(ph||'')}">${type==='textarea'?esc(p[k]||''):''}</${type==='textarea'?'textarea':'input'}></label>`;
  const box=modal(`<h3 class="font-bold text-lg mb-1">Edit ${esc(TEAM(team))}'s page</h3>
<p class="text-xs text-gray-500">Everything here is public on the team page (except the two switches at the bottom). Leave anything blank to hide it.</p>
<div class="flex flex-wrap gap-3 items-center mt-2">
  <div><img data-k="logoPrev" src="${esc(publicUrl(sb,p.logo_path))}" alt="" style="width:72px;height:72px;border-radius:50%;object-fit:cover;background:#f1f4f8;border:1px solid #e1e7ef;${p.logo_path?'':'display:none'}"></div>
  <label class="f" style="margin:0"><span>Team logo</span><input type="file" accept="image/*" data-k="logoFile" style="font-size:.85rem"></label>
</div>
${f('tagline','Tagline','e.g. Youth track & field in the Antelope Valley since 1998')}
${f('about','About the team','Who you are, who can join, what a season looks like…','textarea')}
${f('practice_info','Practice days, times & place','e.g. Mon/Wed/Fri 5:30–7:00 PM at Lancaster High School track','textarea')}
<div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(12rem,1fr))">${f('contact_name','Contact name','')}${f('contact_email','Contact email','')}${f('contact_phone','Contact phone','')}</div>
<div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(12rem,1fr))">${f('website','Website','https://')}${f('instagram','Instagram','@handle')}${f('facebook','Facebook','page link')}</div>
<label class="f" style="margin-top:12px"><span>Banner photo <span class="text-xs text-gray-500 font-normal">(wide, optional)</span></span><input type="file" accept="image/*" data-k="bannerFile" style="font-size:.85rem"></label>
${ctx.extras?`<div class="note soft" style="margin-top:12px"><b>Paid extras switches</b>
<label class="flex items-center gap-2 text-sm mt-1"><input type="checkbox" data-k="gallery_parents_upload" ${p.gallery_parents_upload?'checked':''}> Parents may add photos to the gallery (coaches and team admins always can)</label>
<label class="flex items-center gap-2 text-sm mt-1"><input type="checkbox" data-k="store_open" ${p.store_open?'checked':''}> Team store is open (parents can order)</label>
${f('store_note','Store notice','e.g. Orders close March 1. Pickup at practice the week after.')}${f('store_pickup','How orders are handed over','e.g. At practice from Coach T, or at the next home meet')}</div>`:''}
<div class="flex gap-2 mt-3"><button class="btn pri" data-k="save">Save</button><button class="btn" data-k="cancel">Cancel</button><span class="text-sm" data-k="msg"></span></div>`);
  const g=k=>box.querySelector(`[data-k="${k}"]`);
  ['tagline','contact_name','contact_email','contact_phone','website','instagram','facebook','store_note','store_pickup'].forEach(k=>{ if(g(k)) g(k).value=p[k]||''; });
  g('logoFile').onchange=()=>{ const f=g('logoFile').files[0]; if(f){ g('logoPrev').src=URL.createObjectURL(f); g('logoPrev').style.display=''; } };
  g('cancel').onclick=closeModal;
  g('save').onclick=async()=>{ const b=g('save'); b.disabled=true; g('msg').textContent='Saving…';
    try{ const row={team_code:team};
      ['tagline','about','practice_info','contact_name','contact_email','contact_phone','website','instagram','facebook','store_note','store_pickup'].forEach(k=>{ if(g(k)) row[k]=g(k).value.trim()||null; });
      ['gallery_parents_upload','store_open'].forEach(k=>{ if(g(k)) row[k]=g(k).checked; });
      for(const [k,col,max] of [['logoFile','logo_path',600],['bannerFile','banner_path',1800]]){ const f=g(k).files[0]; if(!f) continue; const file=await shrink(f,max); const path=`${team}/${col.replace('_path','')}-${rnd()}.${file.type==='image/png'?'png':'jpg'}`;
        const {error}=await sb.storage.from('team-public').upload(path,file,{contentType:file.type,upsert:true}); if(error) throw new Error(clean(error)); row[col]=path; }
      const {error}=await sb.from('team_pages').upsert(row,{onConflict:'team_code'}); if(error) throw new Error(clean(error));
      closeModal(); toast('Team page saved'); if(ctx.onSaved) ctx.onSaved(); }
    catch(e){ g('msg').textContent=clean(e); g('msg').className='text-sm text-red-700'; b.disabled=false; } };
};

/* ============================ news posts ============================ */
TeamHub.mountPosts=async function(el, ctx){
  css(); el.classList.add('th'); const sb=ctx.sb, team=ctx.team, mgr=canManage(ctx);
  const {data,error}=await sb.from('team_posts').select('*').eq('team_code',team).order('pinned',{ascending:false}).order('created_at',{ascending:false}).limit(30);
  if(error){ el.innerHTML=`<p class="text-sm text-red-700">${esc(clean(error))}</p>`; return; }
  const posts=data||[];
  const linkify=s=>esc(s).replace(/(https?:\/\/[^\s<]+[^\s<.,;:!?)\]])/g,'<a href="$1" target="_blank" rel="noopener" class="underline" style="color:var(--act)">$1</a>').replace(/\n/g,'<br>');
  el.innerHTML=`${mgr?`<div class="bar"><button class="sbtn pri" data-new>+ Post news</button></div>`:''}
  ${posts.length?posts.map(p=>`<div class="note" data-id="${p.id}">${p.pinned?'<span class="pill act">Pinned</span> ':''}${p.audience==='team'?'<span class="pill">Team only</span> ':''}<b>${esc(p.title)}</b> <span class="text-xs text-gray-500">· ${fmtD(p.created_at)}</span>
    <div class="text-sm mt-1">${linkify(p.body||'')}</div>${mgr?`<div class="mt-2 flex gap-2"><button class="sbtn" data-edit>Edit</button><button class="sbtn red" data-del>Delete</button></div>`:''}</div>`).join('')
    :`<p class="text-sm text-gray-500">${mgr?'No news yet. Post practice changes, meet reminders, fundraisers, team dinners…':'No team news posted yet.'}</p>`}`;
  const form=p=>{ const box=modal(`<h3 class="font-bold text-lg mb-2">${p?'Edit post':'Post news'}</h3>
    <label class="f">Title<input data-k="title" value="${esc(p?p.title:'')}" maxlength="120"></label>
    <label class="f">What's the news?<textarea data-k="body" rows="6">${esc(p?p.body:'')}</textarea></label>
    <label class="f">Who can see it<select data-k="audience"><option value="public" ${!p||p.audience==='public'?'selected':''}>Everyone (public team page)</option><option value="team" ${p&&p.audience==='team'?'selected':''}>Only our parents and coaches (signed in)</option></select></label>
    <label class="flex items-center gap-2 text-sm mt-2"><input type="checkbox" data-k="pinned" ${p&&p.pinned?'checked':''}> Keep at the top</label>
    <div class="flex gap-2 mt-3"><button class="btn pri" data-k="save">${p?'Save':'Post'}</button><button class="btn" data-k="cancel">Cancel</button><span class="text-sm text-red-700" data-k="msg"></span></div>`);
    const g=k=>box.querySelector(`[data-k="${k}"]`); g('cancel').onclick=closeModal;
    g('save').onclick=async()=>{ const row={team_code:team,title:g('title').value.trim(),body:g('body').value.trim(),audience:g('audience').value,pinned:g('pinned').checked};
      if(!row.title){ g('msg').textContent='Give it a title.'; return; }
      const r=p?await sb.from('team_posts').update(row).eq('id',p.id):await sb.from('team_posts').insert(row); if(r.error){ g('msg').textContent=clean(r.error); return; }
      closeModal(); toast(p?'Saved':'Posted'); TeamHub.mountPosts(el,ctx); }; };
  el.onclick=async e=>{ if(e.target.closest('[data-new]')) return form(null);
    const card=e.target.closest('[data-id]'); if(!card) return; const p=posts.find(x=>x.id===card.dataset.id);
    if(e.target.closest('[data-edit]')) return form(p);
    if(e.target.closest('[data-del]')){ if(!confirm('Delete this post?')) return; const {error}=await sb.from('team_posts').delete().eq('id',p.id); if(error) return toast(clean(error),true); TeamHub.mountPosts(el,ctx); } };
};

/* ============================ gallery ============================ */
TeamHub.mountGallery=async function(el, ctx){
  css(); el.classList.add('th'); const sb=ctx.sb, team=ctx.team, role=ctx.role;
  if(!ctx.extras){ el.innerHTML=canManage(ctx)?`<div class="note warn"><span class="pill warn">Paid team extra</span> The photo gallery is part of the paid team extras, which aren't switched on for ${esc(TEAM(team))}. The league site admin switches them on (Site Admin → Paid Extras).</div>`:''; return 'none'; }
  if(!role){ el.innerHTML='<p class="text-sm text-gray-600">Sign in with the email you registered with to see the team\'s photos.</p>'; return 'none'; }
  const canAdd=role!=='parent'||!!(ctx.page&&ctx.page.gallery_parents_upload), canAlbum=role!=='parent';
  let albums=[], cur=null, photos=[], urls={};
  const signed=async paths=>{ const need=paths.filter(p=>p&&!urls[p]); if(need.length){ for(let i=0;i<need.length;i+=100){ const {data}=await sb.storage.from('team-gallery').createSignedUrls(need.slice(i,i+100),3600); (data||[]).forEach(x=>{ if(x.signedUrl) urls[x.path]=x.signedUrl; }); } } };
  const load=async()=>{ const {data,error}=await sb.from('team_albums').select('*, team_photos(count)').eq('team_code',team).order('created_at',{ascending:false}); if(error) throw error; albums=data||[]; await signed(albums.map(a=>a.cover_path)); };
  const drawAlbums=()=>{ el.innerHTML=`<div class="bar">${canAlbum?'<button class="sbtn pri" data-new-album>+ New album</button>':''}${ctx.role==='parent'&&!canAdd?'<span class="text-xs text-gray-500">Coaches add the photos; ask your team admin if you\'d like to add some too.</span>':''}</div>
    ${albums.length?`<div class="grid">${albums.map(a=>`<button class="album" data-album="${a.id}"><div class="cv" style="${a.cover_path&&urls[a.cover_path]?`background-image:url('${esc(urls[a.cover_path])}')`:''}">${a.cover_path&&urls[a.cover_path]?'':'📷'}</div><div class="nm">${esc(a.name)}</div><div class="ct">${(a.team_photos&&a.team_photos[0]&&a.team_photos[0].count)||0} photos · ${a.season_year}</div></button>`).join('')}</div>`
      :`<p class="text-sm text-gray-500">No albums yet.${canAlbum?' Make one for each meet, or for the whole season.':''}</p>`}`; };
  const openAlbum=async a=>{ cur=a; el.innerHTML='<p class="text-sm text-gray-500">Loading photos…</p>';
    const {data,error}=await sb.from('team_photos').select('*').eq('album_id',a.id).order('created_at',{ascending:false}); if(error){ el.innerHTML=`<p class="text-sm text-red-700">${esc(clean(error))}</p>`; return; }
    photos=data||[]; await signed(photos.map(p=>p.path)); drawAlbum(); };
  const drawAlbum=()=>{ const a=cur, mine=p=>p.uploaded_by===ctx.uid;
    el.innerHTML=`<div class="bar"><button class="sbtn" data-back>← All albums</button><b class="text-lg">${esc(a.name)}</b><span class="text-xs text-gray-500">${photos.length} photo${photos.length===1?'':'s'}${a.description?' · '+esc(a.description):''}</span><span style="flex:1"></span>
      ${canAdd?'<button class="sbtn pri" data-add>+ Add photos</button><input type="file" accept="image/*" multiple data-file class="hide">':''}${canAlbum?'<button class="sbtn" data-edit-album>Rename</button><button class="sbtn red" data-del-album>Delete album</button>':''}</div>
      <div data-prog class="text-sm text-gray-600"></div>
      ${photos.length?`<div class="photos">${photos.map((p,i)=>`<div class="ph" data-i="${i}"><img src="${esc(urls[p.path]||'')}" alt="${esc(p.caption||'')}" loading="lazy">${(mine(p)||role!=='parent')?`<button class="del" data-del="${p.id}" title="Remove photo">×</button>`:''}</div>`).join('')}</div>`
      :`<p class="text-sm text-gray-500">No photos in this album yet.${canAdd?' Tap "Add photos" — you can pick several at once.':''}</p>`}`; };
  const lightbox=i=>{ const lb=document.createElement('div'); lb.className='th'; const draw=()=>{ const p=photos[i]; lb.innerHTML=`<div class="lb"><button class="x" aria-label="Close">×</button>${photos.length>1?'<button class="nav l">‹</button><button class="nav r">›</button>':''}<img src="${esc(urls[p.path]||'')}" alt=""><div class="cap">${esc(p.caption||'')}${p.uploader_name?` <span style="opacity:.7">· ${esc(p.uploader_name)}</span>`:''}</div></div>`;
      lb.querySelector('.x').onclick=()=>lb.remove(); lb.querySelector('.lb').onclick=e=>{ if(e.target.classList.contains('lb')) lb.remove(); };
      const l=lb.querySelector('.nav.l'), r=lb.querySelector('.nav.r'); if(l) l.onclick=()=>{ i=(i-1+photos.length)%photos.length; draw(); }; if(r) r.onclick=()=>{ i=(i+1)%photos.length; draw(); }; };
    draw(); document.body.appendChild(lb); const key=e=>{ if(!document.body.contains(lb)) return document.removeEventListener('keydown',key); if(e.key==='Escape') lb.remove(); if(e.key==='ArrowLeft'){ i=(i-1+photos.length)%photos.length; draw(); } if(e.key==='ArrowRight'){ i=(i+1)%photos.length; draw(); } }; document.addEventListener('keydown',key); };
  const albumForm=a=>{ const box=modal(`<h3 class="font-bold text-lg mb-2">${a?'Rename album':'New album'}</h3><label class="f">Album name<input data-k="name" value="${esc(a?a.name:'')}" maxlength="80" placeholder="e.g. Week 3 @ Burbank"></label><label class="f">Description (optional)<input data-k="desc" value="${esc(a?a.description||'':'')}" maxlength="200"></label>
    <div class="flex gap-2 mt-3"><button class="btn pri" data-k="save">${a?'Save':'Create'}</button><button class="btn" data-k="cancel">Cancel</button><span class="text-sm text-red-700" data-k="msg"></span></div>`);
    const g=k=>box.querySelector(`[data-k="${k}"]`); g('cancel').onclick=closeModal; g('name').focus();
    g('save').onclick=async()=>{ const name=g('name').value.trim(); if(!name){ g('msg').textContent='Name the album.'; return; }
      const row={team_code:team,name,description:g('desc').value.trim()||null}; const r=a?await sb.from('team_albums').update(row).eq('id',a.id):await sb.from('team_albums').insert(row).select().single();
      if(r.error){ g('msg').textContent=clean(r.error); return; } closeModal(); await load(); if(a){ cur.name=name; cur.description=row.description; drawAlbum(); } else openAlbum(r.data); }; };
  const upload=async files=>{ const prog=el.querySelector('[data-prog]'); let done=0, bad=[]; const list=[...files].filter(f=>/^image\//.test(f.type)).slice(0,40);
    for(const f of list){ prog.textContent=`Uploading ${done+1} of ${list.length}…`;
      try{ const file=await shrink(f,1800); const path=`${team}/${cur.id}/${rnd()}-${safeName(file.name)}`;
        const {error}=await sb.storage.from('team-gallery').upload(path,file,{contentType:file.type}); if(error) throw error;
        const {error:e2}=await sb.from('team_photos').insert({album_id:cur.id,team_code:team,path,uploader_name:ctx.name||null}); if(e2){ await sb.storage.from('team-gallery').remove([path]); throw e2; }
        done++; }catch(e){ bad.push(f.name+': '+clean(e)); } }
    if(done&&!cur.cover_path){ const {data}=await sb.from('team_photos').select('path').eq('album_id',cur.id).order('created_at').limit(1); if(data&&data[0]){ await sb.from('team_albums').update({cover_path:data[0].path}).eq('id',cur.id); cur.cover_path=data[0].path; } }
    if(bad.length) toast(bad.slice(0,2).join(' · '),true); else if(done) toast(`${done} photo${done===1?'':'s'} added`);
    await load(); openAlbum(albums.find(a=>a.id===cur.id)||cur); };
  el.onclick=async e=>{ const t=e.target;
    if(t.closest('[data-new-album]')) return albumForm(null);
    if(t.closest('[data-edit-album]')) return albumForm(cur);
    if(t.closest('[data-back]')){ cur=null; await load(); return drawAlbums(); }
    if(t.closest('[data-add]')) return el.querySelector('[data-file]').click();
    if(t.closest('[data-del-album]')){ if(!confirm(`Delete the album "${cur.name}" and all ${photos.length} photos in it?`)) return; const paths=photos.map(p=>p.path); const {error}=await sb.from('team_albums').delete().eq('id',cur.id); if(error) return toast(clean(error),true); if(paths.length) try{ await sb.storage.from('team-gallery').remove(paths); }catch(x){} cur=null; await load(); return drawAlbums(); }
    const d=t.closest('[data-del]'); if(d){ e.stopPropagation(); const p=photos.find(x=>x.id===d.dataset.del); if(!confirm('Remove this photo?')) return; const {error}=await sb.from('team_photos').delete().eq('id',p.id); if(error) return toast(clean(error),true); try{ await sb.storage.from('team-gallery').remove([p.path]); }catch(x){} photos=photos.filter(x=>x.id!==p.id); return drawAlbum(); }
    const ph=t.closest('.ph'); if(ph) lightbox(+ph.dataset.i);
    const al=t.closest('[data-album]'); if(al) openAlbum(albums.find(a=>a.id===al.dataset.album)); };
  el.addEventListener('change',e=>{ if(e.target.matches('[data-file]')&&e.target.files.length){ upload(e.target.files); e.target.value=''; } });
  try{ await load(); }catch(e){ el.innerHTML=`<p class="text-sm text-red-700">Couldn't load the gallery: ${esc(clean(e))}</p>`; return 'none'; }
  if(ctx.album){ const a=albums.find(x=>x.id===ctx.album); if(a) return openAlbum(a); }
  drawAlbums(); return 'on';
};

/* ============================ store ============================ */
const METHODS={card:'Card',zelle:'Zelle',cashapp:'Cash App',venmo:'Venmo',check:'Check',cash:'Cash',other:'Other'};
const OSTATUS={new:['warn','Ordered — not paid'],sent:['warn','Payment sent — team to confirm'],paid:['ok','Paid'],ready:['act','Ready for pickup'],done:['ok','Picked up'],cancelled:['','Cancelled']};
const lineText=l=>`${l.qty} × ${l.name}${Object.keys(l.choices||{}).length?' ('+Object.entries(l.choices).map(([k,v])=>`${k}: ${v}`).join(', ')+')':''}`;
TeamHub.mountStore=async function(el, ctx){
  css(); el.classList.add('th'); const sb=ctx.sb, team=ctx.team, mgr=canManage(ctx), p=ctx.page||{};
  if(!ctx.extras){ el.innerHTML=mgr?`<div class="note warn"><span class="pill warn">Paid team extra</span> The team store is part of the paid team extras, which aren't switched on for ${esc(TEAM(team))}. The league site admin switches them on (Site Admin → Paid Extras).</div>`:''; return 'none'; }
  let items=[], orders=[], cart=JSON.parse(sessionStorage.getItem('th_cart_'+team)||'[]'), view=ctx.view||'shop', pay=null;
  const saveCart=()=>sessionStorage.setItem('th_cart_'+team,JSON.stringify(cart));
  const load=async()=>{ const [{data:it,error},{data:ps}]=await Promise.all([sb.from('store_items').select('*').eq('team_code',team).order('sort_order').order('name'), sb.from('team_payment_settings').select('*').eq('team_code',team).order('season_year',{ascending:false}).limit(1)]);
    if(error) throw error; items=it||[]; pay=(ps&&ps[0])||null;
    if(ctx.email){ const {data:o}=await sb.from('store_orders').select('*').eq('team_code',team).order('created_at',{ascending:false}); orders=o||[]; } };
  const cartTotal=()=>cart.reduce((a,l)=>{ const it=items.find(i=>i.id===l.item_id); return a+(it?+it.price*l.qty:0); },0);
  const draw=()=>{ const open=!!p.store_open;
    const tabs=mgr?`<div class="bar"><button class="sbtn ${view==='shop'?'pri':''}" data-view="shop">Store</button><button class="sbtn ${view==='items'?'pri':''}" data-view="items">Items</button><button class="sbtn ${view==='orders'?'pri':''}" data-view="orders">Orders ${orders.filter(o=>['new','sent'].includes(o.status)).length?`<span class="pill bad">${orders.filter(o=>['new','sent'].includes(o.status)).length}</span>`:''}</button>
      <span style="flex:1"></span><span class="pill ${open?'ok':'warn'}">${open?'Store is OPEN':'Store is closed'}</span> <button class="sbtn" data-toggle-open>${open?'Close the store':'Open the store'}</button></div>`:'';
    if(view==='items') return drawItems(tabs); if(view==='orders') return drawOrders(tabs);
    const mine=orders.filter(o=>ctx.email&&o.email.toLowerCase()===ctx.email.toLowerCase());
    el.innerHTML=tabs+(p.store_note?`<div class="note soft">${esc(p.store_note)}</div>`:'')+
      (!open?`<p class="text-sm text-gray-600">${esc(TEAM(team))}'s store isn't open right now.${mgr?' Open it with the button above once your items are in.':''}</p>`
      :!items.filter(i=>i.active).length?`<p class="text-sm text-gray-600">Nothing in the store yet.${mgr?' Add items on the Items tab.':''}</p>`
      :`<div class="grid" style="grid-template-columns:repeat(auto-fill,minmax(13rem,1fr))">${items.filter(i=>i.active).map(i=>`<div class="item" data-item="${i.id}"><div class="im" style="${i.image_path?`background-image:url('${esc(publicUrl(sb,i.image_path))}')`:''}">${i.image_path?'':'👕'}</div><div class="bd"><div class="font-bold">${esc(i.name)}</div>${i.description?`<div class="text-xs text-gray-600">${esc(i.description)}</div>`:''}<div class="pr">${money(i.price)}</div>
        ${(i.options||[]).map(o=>`<select data-opt="${esc(o.name)}"><option value="">${esc(o.name)}…</option>${(o.choices||[]).map(c=>`<option>${esc(c)}</option>`).join('')}</select>`).join('')}
        <div class="flex items-center gap-2 mt-auto"><input type="number" min="1" max="50" value="1" data-qty style="width:4.5rem"><button class="sbtn pri" data-add>Add to cart</button></div></div></div>`).join('')}</div>`)+
      (cart.length?`<div class="cartbar"><b>Your cart</b>${cart.map((l,i)=>{ const it=items.find(x=>x.id===l.item_id); return it?`<div class="flex items-center gap-2 text-sm mt-1"><span class="flex-1">${esc(lineText({...l,name:it.name}))}</span><span class="font-mono">${money(+it.price*l.qty)}</span><button class="sbtn red" data-rm="${i}" title="Remove">×</button></div>`:''; }).join('')}
        <div class="flex flex-wrap items-center gap-2 mt-2"><b class="flex-1">Total ${money(cartTotal())}</b>${ctx.email?'<button class="btn pri" data-checkout>Place order</button>':'<span class="text-sm text-gray-600">Sign in (below) to place the order.</span>'}</div></div>`:'')+
      (mine.length?`<h3 class="font-bold mt-4 mb-1">Your orders</h3>${mine.map(o=>orderCard(o)).join('')}`:'');
  };
  const payHow=o=>{ const s=pay||{}; const ways=[s.accept_zelle&&['zelle','Zelle',s.zelle_info],s.accept_cashapp&&['cashapp','Cash App',s.cashapp_info],s.accept_venmo&&['venmo','Venmo',s.venmo_info],s.accept_other&&['check','Check or cash',s.other_info]].filter(Boolean);
    return `<div class="note soft mt-2"><b>How to pay ${money(o.total)}</b>${s.accept_card?`<div class="text-xs text-gray-500 mt-1">Card payments for store orders aren't switched on yet — use one of the ways below.</div>`:''}
      ${ways.length?ways.map(([k,l,info])=>`<details class="text-sm mt-1"><summary class="cursor-pointer font-semibold">${esc(l)}</summary><div class="pl-3 mt-1">${info?`<p class="mb-1">${esc(info)}</p>`:''}<p class="text-xs text-gray-500 mb-1">Send ${money(o.total)} with "order #${o.order_no}" in the note, then tell the team:</p>
        <div class="flex flex-wrap gap-2 items-end"><label class="text-xs flex-1">Confirmation # / check # (optional)<br><input data-ref="${k}" class="w-full"></label>${k==='check'?`<label class="text-xs">Paid by<br><select data-sub="${k}"><option value="check">Check</option><option value="cash">Cash</option></select></label>`:''}<button class="sbtn grn" data-sent="${k}" data-order="${o.id}">I sent it</button></div></div></details>`).join('')
        :`<p class="text-sm text-gray-600 mt-1">The team hasn't listed its ways to pay yet — your team will tell you how to pay (Payments tab on the Team Admin page).</p>`}</div>`; };
  const orderCard=o=>{ const [cls,lab]=OSTATUS[o.status]||['',o.status]; return `<div class="note" data-order="${o.id}"><div class="flex flex-wrap items-center gap-2"><b>Order #${o.order_no}</b><span class="text-xs text-gray-500">${fmtD(o.created_at)}</span><span class="pill ${cls}">${lab}</span><span style="flex:1"></span><b>${money(o.total)}</b></div>
    <div class="text-sm mt-1">${(o.lines||[]).map(l=>esc(lineText(l))).join('<br>')}</div>${o.athlete_name?`<div class="text-xs text-gray-500">For ${esc(o.athlete_name)}</div>`:''}${o.admin_note?`<div class="text-xs mt-1" style="color:#92400e">From the team: ${esc(o.admin_note)}</div>`:''}
    ${o.status==='sent'?`<div class="text-xs text-gray-500 mt-1">You told us you paid by ${esc(METHODS[o.method]||o.method)}${o.reference?` (${esc(o.reference)})`:''}. The team will confirm when it arrives.</div>`:''}
    ${o.status==='ready'?`<div class="text-sm mt-1"><b>Ready!</b> ${esc(p.store_pickup||'Your team will tell you where to pick it up.')}</div>`:''}
    ${o.status==='new'?payHow(o):''}${['new','sent'].includes(o.status)?`<div class="mt-2"><button class="sbtn red" data-cancel="${o.id}">Cancel order</button></div>`:''}</div>`; };
  const checkout=()=>{ const regs=ctx.athletes||[]; const box=modal(`<h3 class="font-bold text-lg mb-1">Place your order — ${money(cartTotal())}</h3><p class="text-xs text-gray-500">${esc(TEAM(team))} gets this order right away. You'll see how to pay as soon as it's placed.</p>
    <label class="f">Your name<input data-k="name" value="${esc(ctx.name||'')}"></label><label class="f">Phone (optional)<input data-k="phone" type="tel" value="${esc(ctx.phone||'')}"></label>
    <label class="f">Which athlete / family is this for?${regs.length?`<select data-k="ath"><option value="">—</option>${regs.map(a=>`<option>${esc(a)}</option>`).join('')}<option value="__other">Someone else…</option></select><input data-k="athOther" class="hide mt-1" placeholder="Name">`:`<input data-k="ath" placeholder="Athlete's name (optional)">`}</label>
    <label class="f">Note to the team (optional)<input data-k="note" maxlength="300"></label>
    <div class="flex gap-2 mt-3"><button class="btn pri" data-k="go">Place order</button><button class="btn" data-k="cancel">Back</button><span class="text-sm text-red-700" data-k="msg"></span></div>`);
    const g=k=>box.querySelector(`[data-k="${k}"]`); g('cancel').onclick=closeModal; if(g('ath')&&g('ath').tagName==='SELECT') g('ath').onchange=()=>g('athOther').classList.toggle('hide',g('ath').value!=='__other');
    g('go').onclick=async()=>{ g('go').disabled=true; let ath=g('ath').value; if(ath==='__other') ath=g('athOther').value.trim();
      const {data,error}=await sb.rpc('store_place_order',{p_team:team,p_lines:cart.map(l=>({item_id:l.item_id,qty:l.qty,choices:l.choices||{}})),p_buyer_name:g('name').value.trim(),p_phone:g('phone').value.trim()||null,p_athlete_name:ath||null,p_note:g('note').value.trim()||null});
      if(error){ g('msg').textContent=clean(error); g('go').disabled=false; return; } cart=[]; saveCart(); closeModal(); toast('Order placed — now pay the team'); await load(); draw(); const c=el.querySelector(`[data-order="${data}"]`); if(c) c.scrollIntoView({behavior:'smooth',block:'start'}); }; };
  /* --- team side: items --- */
  const drawItems=tabs=>{ el.innerHTML=tabs+`<div class="bar"><button class="sbtn pri" data-new-item>+ Add item</button><span class="text-xs text-gray-500">Sizes and colors are "options" — the parent must pick one of each.</span></div>
    ${items.length?`<div class="wrapx"><table class="t"><thead><tr><th></th><th>Item</th><th>Price</th><th>Options</th><th>Shown</th><th></th></tr></thead><tbody>${items.map(i=>`<tr data-item="${i.id}"><td>${i.image_path?`<img src="${esc(publicUrl(sb,i.image_path))}" alt="" style="width:40px;height:40px;object-fit:cover;border-radius:6px">`:''}</td><td><b>${esc(i.name)}</b>${i.description?`<div class="text-xs text-gray-500">${esc(i.description)}</div>`:''}</td><td class="font-mono">${money(i.price)}</td><td class="text-xs">${(i.options||[]).map(o=>`${esc(o.name)}: ${esc((o.choices||[]).join(', '))}`).join('<br>')}</td><td><span class="pill ${i.active?'ok':''}">${i.active?'Yes':'Hidden'}</span></td><td class="whitespace-nowrap"><button class="sbtn" data-edit-item>Edit</button> <button class="sbtn" data-hide-item>${i.active?'Hide':'Show'}</button> <button class="sbtn red" data-del-item>Delete</button></td></tr>`).join('')}</tbody></table></div>`:'<p class="text-sm text-gray-500">No items yet. Add your team shirt, hoodie, hat, warm-ups…</p>'}`; };
  const itemForm=i=>{ const optText=(i&&i.options||[]).map(o=>`${o.name}: ${(o.choices||[]).join(', ')}`).join('\n');
    const box=modal(`<h3 class="font-bold text-lg mb-2">${i?'Edit item':'Add item'}</h3><label class="f">Name<input data-k="name" value="${esc(i?i.name:'')}" maxlength="80" placeholder="e.g. Team t-shirt"></label><label class="f">Description (optional)<input data-k="desc" value="${esc(i?i.description||'':'')}" maxlength="200" placeholder="e.g. Navy, 100% cotton, team logo front and back"></label>
    <label class="f">Price $<input data-k="price" type="number" min="0" step="0.01" value="${i?+i.price:''}"></label>
    <label class="f">Options — one per line, as "Name: choice, choice, choice"<textarea data-k="opts" rows="3" placeholder="Size: YS, YM, YL, S, M, L, XL, 2XL&#10;Color: Navy, Gray">${esc(optText)}</textarea></label>
    <div class="flex gap-3 items-center mt-2">${i&&i.image_path?`<img src="${esc(publicUrl(sb,i.image_path))}" alt="" style="width:56px;height:56px;object-fit:cover;border-radius:8px">`:''}<label class="f" style="margin:0;flex:1">Photo<input type="file" accept="image/*" data-k="file" style="font-size:.85rem"></label></div>
    <label class="f">Order on the page (lower first)<input data-k="sort" type="number" value="${i?i.sort_order:(items.length+1)*10}"></label>
    <div class="flex gap-2 mt-3"><button class="btn pri" data-k="save">Save</button><button class="btn" data-k="cancel">Cancel</button><span class="text-sm text-red-700" data-k="msg"></span></div>`);
    const g=k=>box.querySelector(`[data-k="${k}"]`); g('cancel').onclick=closeModal;
    g('save').onclick=async()=>{ g('save').disabled=true; try{ const name=g('name').value.trim(); if(!name) throw new Error('Name the item.'); const price=+g('price').value; if(!(price>=0)) throw new Error('Enter a price (0 is fine for free items).');
        const options=g('opts').value.split('\n').map(l=>l.trim()).filter(Boolean).map(l=>{ const [n,...rest]=l.split(':'); const choices=rest.join(':').split(',').map(s=>s.trim()).filter(Boolean); if(!n.trim()||!choices.length) throw new Error(`Each option line needs a name, a colon, then the choices — like "Size: S, M, L". Check: ${l}`); return {name:n.trim(),choices}; });
        const row={team_code:team,name,description:g('desc').value.trim()||null,price,options,sort_order:+g('sort').value||0};
        const f=g('file').files[0]; if(f){ const file=await shrink(f,1000); const path=`${team}/store/${rnd()}-${safeName(file.name)}`; const {error}=await sb.storage.from('team-public').upload(path,file,{contentType:file.type}); if(error) throw error; row.image_path=path; }
        const r=i?await sb.from('store_items').update(row).eq('id',i.id):await sb.from('store_items').insert(row); if(r.error) throw r.error;
        closeModal(); toast('Saved'); await load(); draw(); }catch(e){ g('msg').textContent=clean(e); g('save').disabled=false; } }; };
  /* --- team side: orders --- */
  let ofilt='open';
  const drawOrders=tabs=>{ const L=orders.filter(o=>ofilt==='open'?['new','sent','paid','ready'].includes(o.status):ofilt==='all'?true:o.status===ofilt);
    const sum=L.filter(o=>o.status!=='cancelled').reduce((a,o)=>a+ +o.total,0), paid=L.filter(o=>['paid','ready','done'].includes(o.status)).reduce((a,o)=>a+ +(o.paid_amount||o.total),0);
    // what to make/pack: every line across open orders, grouped
    const tally={}; orders.filter(o=>['new','sent','paid','ready'].includes(o.status)).forEach(o=>(o.lines||[]).forEach(l=>{ const k=lineText({...l,qty:1}).replace(/^1 × /,''); tally[k]=(tally[k]||0)+l.qty; }));
    el.innerHTML=tabs+`<div class="bar"><select data-ofilt><option value="open" ${ofilt==='open'?'selected':''}>Open orders</option><option value="sent" ${ofilt==='sent'?'selected':''}>Payment sent — confirm</option><option value="paid" ${ofilt==='paid'?'selected':''}>Paid — to prepare</option><option value="ready" ${ofilt==='ready'?'selected':''}>Ready for pickup</option><option value="done" ${ofilt==='done'?'selected':''}>Picked up</option><option value="cancelled" ${ofilt==='cancelled'?'selected':''}>Cancelled</option><option value="all" ${ofilt==='all'?'selected':''}>Everything</option></select>
      <span class="text-sm text-gray-600">${L.length} order${L.length===1?'':'s'} · ${money(sum)} ordered · ${money(paid)} collected</span><span style="flex:1"></span><button class="sbtn" data-csv>Download CSV</button><button class="sbtn" data-tally>What to order from the printer</button></div>
      <div data-tallybox class="note soft hide"><b>Open orders add up to:</b><div class="text-sm mt-1">${Object.entries(tally).sort().map(([k,n])=>`${n} × ${esc(k)}`).join('<br>')||'nothing yet'}</div></div>
      ${L.length?`<div class="wrapx"><table class="t"><thead><tr><th>#</th><th>Who</th><th>Items</th><th>Total</th><th>Status</th><th></th></tr></thead><tbody>${L.map(o=>{ const [cls,lab]=OSTATUS[o.status]||['',o.status]; return `<tr data-order="${o.id}"><td>${o.order_no}<div class="text-xs text-gray-500">${fmtD(o.created_at)}</div></td><td><b>${esc(o.buyer_name)}</b><div class="text-xs text-gray-500">${esc(o.email)}${o.phone?' · '+esc(o.phone):''}</div>${o.athlete_name?`<div class="text-xs">for ${esc(o.athlete_name)}</div>`:''}${o.note?`<div class="text-xs" style="color:#92400e">"${esc(o.note)}"</div>`:''}</td><td class="text-xs">${(o.lines||[]).map(l=>esc(lineText(l))).join('<br>')}</td><td class="font-mono">${money(o.total)}${o.paid_amount!=null&&+o.paid_amount!==+o.total?`<div class="text-xs">paid ${money(o.paid_amount)}</div>`:''}</td>
        <td><span class="pill ${cls}">${lab}</span>${o.method?`<div class="text-xs text-gray-500">${esc(METHODS[o.method]||o.method)}${o.reference?' · '+esc(o.reference):''}</div>`:''}${o.admin_note?`<div class="text-xs text-gray-500">${esc(o.admin_note)}</div>`:''}</td>
        <td class="whitespace-nowrap">${['new','sent'].includes(o.status)?`<button class="sbtn grn" data-st="paid">Paid ✓</button> `:''}${o.status==='paid'?`<button class="sbtn pri" data-st="ready">Ready for pickup</button> `:''}${o.status==='ready'?`<button class="sbtn grn" data-st="done">Picked up ✓</button> `:''}${o.status==='sent'?`<button class="sbtn" data-st="new">Not received</button> `:''}${['new','sent','paid','ready'].includes(o.status)?`<button class="sbtn red" data-st="cancelled">Cancel</button> `:''}<button class="sbtn" data-note>Note</button></td></tr>`; }).join('')}</tbody></table></div>`:'<p class="text-sm text-gray-500">No orders here.</p>'}`; };
  const csv=()=>{ const rows=[['Order','Date','Status','Name','Email','Phone','Athlete','Items','Total','Paid','Method','Reference','Note','Team note']].concat(orders.map(o=>[o.order_no,String(o.created_at).slice(0,10),o.status,o.buyer_name,o.email,o.phone||'',o.athlete_name||'',(o.lines||[]).map(lineText).join('; '),o.total,o.paid_amount||'',o.method||'',o.reference||'',o.note||'',o.admin_note||'']));
    const txt=rows.map(r=>r.map(v=>'"'+String(v??'').replace(/"/g,'""')+'"').join(',')).join('\r\n'); const a=document.createElement('a'); a.href=URL.createObjectURL(new Blob([txt],{type:'text/csv'})); a.download=`${team}-store-orders.csv`; a.click(); };
  el.onclick=async e=>{ const t=e.target; const v=t.closest('[data-view]'); if(v){ view=v.dataset.view; return draw(); }
    if(t.closest('[data-toggle-open]')){ const {error}=await sb.from('team_pages').upsert({team_code:team,store_open:!p.store_open},{onConflict:'team_code'}); if(error) return toast(clean(error),true); p.store_open=!p.store_open; if(ctx.page) ctx.page.store_open=p.store_open; toast(p.store_open?'Store is open':'Store closed'); return draw(); }
    if(t.closest('[data-add]')){ const card=t.closest('[data-item]'), it=items.find(i=>i.id===card.dataset.item); const choices={}; for(const s of card.querySelectorAll('[data-opt]')){ if(!s.value){ toast(`Pick a ${s.dataset.opt.toLowerCase()} for ${it.name}.`,true); s.focus(); return; } choices[s.dataset.opt]=s.value; }
      const qty=Math.max(1,Math.min(50,+card.querySelector('[data-qty]').value||1)); const same=cart.find(l=>l.item_id===it.id&&JSON.stringify(l.choices)===JSON.stringify(choices)); if(same) same.qty=Math.min(50,same.qty+qty); else cart.push({item_id:it.id,qty,choices}); saveCart(); toast('Added to cart'); return draw(); }
    const rm=t.closest('[data-rm]'); if(rm){ cart.splice(+rm.dataset.rm,1); saveCart(); return draw(); }
    if(t.closest('[data-checkout]')) return checkout();
    const sent=t.closest('[data-sent]'); if(sent){ const k=sent.dataset.sent, box=sent.closest('details'); const method=k==='check'?box.querySelector('[data-sub]').value:k; sent.disabled=true;
      const {error}=await sb.rpc('store_report_payment',{p_order:sent.dataset.order,p_method:method,p_reference:box.querySelector('[data-ref]').value.trim()||null}); if(error){ toast(clean(error),true); sent.disabled=false; return; } await load(); return draw(); }
    const cn=t.closest('[data-cancel]'); if(cn){ if(!confirm('Cancel this order?')) return; const {error}=await sb.rpc('store_cancel_order',{p_order:cn.dataset.cancel}); if(error) return toast(clean(error),true); await load(); return draw(); }
    if(t.closest('[data-new-item]')) return itemForm(null);
    const row=t.closest('[data-item]'); if(row&&view==='items'){ const it=items.find(i=>i.id===row.dataset.item);
      if(t.closest('[data-edit-item]')) return itemForm(it);
      if(t.closest('[data-hide-item]')){ const {error}=await sb.from('store_items').update({active:!it.active}).eq('id',it.id); if(error) return toast(clean(error),true); await load(); return draw(); }
      if(t.closest('[data-del-item]')){ if(!confirm(`Delete "${it.name}"? Past orders keep their line items.`)) return; const {error}=await sb.from('store_items').delete().eq('id',it.id); if(error) return toast(clean(error),true); await load(); return draw(); } }
    if(t.closest('[data-csv]')) return csv();
    if(t.closest('[data-tally]')) return el.querySelector('[data-tallybox]').classList.toggle('hide');
    const orow=t.closest('tr[data-order]'); if(orow){ const o=orders.find(x=>x.id===orow.dataset.order); const st=t.closest('[data-st]');
      if(st){ const s=st.dataset.st; let amt=null; if(s==='paid'){ const v=prompt(`Amount received for order #${o.order_no} (${money(o.total)} ordered):`,(+o.total).toFixed(2)); if(v===null) return; amt=+v; if(!(amt>=0)) return toast('Enter a number.',true); }
        if(s==='cancelled'&&!confirm(`Cancel order #${o.order_no}?`)) return;
        const {error}=await sb.rpc('store_update_order',{p_order:o.id,p_status:s,p_paid_amount:amt}); if(error) return toast(clean(error),true); await load(); return draw(); }
      if(t.closest('[data-note]')){ const v=prompt(`Note to the parent on order #${o.order_no} (they see it):`,o.admin_note||''); if(v===null) return; const {error}=await sb.rpc('store_update_order',{p_order:o.id,p_status:o.status,p_admin_note:v}); if(error) return toast(clean(error),true); await load(); return draw(); } } };
  el.addEventListener('change',e=>{ if(e.target.matches('[data-ofilt]')){ ofilt=e.target.value; draw(); } });
  try{ await load(); }catch(e){ el.innerHTML=`<p class="text-sm text-red-700">Couldn't load the store: ${esc(clean(e))}</p>`; return 'none'; }
  draw(); return 'on';
};

/* ============================ meet volunteers ============================ */
const CATS={field:'Field events',track:'On the track',meet:'Running the meet',hospitality:'Snack bar & hospitality',setup:'Set-up & clean-up',other:'Other'};
const CAT_ORDER=['field','track','meet','hospitality','setup','other'];
// Meets this season that a team is at, with today's and future ones first.
async function teamMeets(sb, teams){ const season=+(await window.currentSeason()); const {data,error}=await sb.from('meets').select('id,name,meet_date,location,venue,week_no,host_team_code,team_codes,is_championship,is_invitational,status').eq('season_year',season).order('meet_date'); if(error) throw error;
  const unassigned=m=>m.week_no&&!m.host_team_code&&!(m.team_codes||[]).length&&!m.is_invitational&&!m.is_championship;
  return (data||[]).filter(m=>!unassigned(m)&&m.status!=='archived'&&teams.some(t=>window.meetHasTeam(m,t))); }
const meetLabel=m=>`${fmtD(m.meet_date)} · ${m.week_no?'Week '+m.week_no+(m.host_team_code?' @ '+TEAM(m.host_team_code):''):m.name}`;
TeamHub.mountVolunteers=async function(el, ctx){
  css(); el.classList.add('th'); const sb=ctx.sb, team=ctx.team, role=ctx.role;
  if(!role){ el.innerHTML='<p class="text-sm text-gray-600">Sign in to see the volunteer duties for your team\'s meets.</p>'; return 'none'; }
  // Coaches work one meet at a time (a picker). Parents see EVERY meet their team is at, stacked, so nothing is missed.
  const allMode=role==='parent';
  let meets=[], meet=null, shown=[], duties=[], vols=[], slots=[], counts={}, scounts={}, host=false, mgrTeam=false;
  try{ meets=await teamMeets(sb,[team]); }catch(e){ el.innerHTML=`<p class="text-sm text-red-700">${esc(clean(e))}</p>`; return 'none'; }
  const td=today(); const upcoming=meets.filter(m=>m.meet_date>=td);
  meet=meets.find(m=>m.id===ctx.meet)||upcoming[0]||meets[meets.length-1]||null;
  if(!meet){ el.innerHTML='<p class="text-sm text-gray-600">No meets on the schedule for this team yet.</p>'; return 'none'; }
  let timer=null;
  const isHost=m=>m.host_team_code===team, teamsAt=m=>(m.team_codes||[]).length?m.team_codes:(window.VYC_TEAMS||[]).filter(t=>t.active!==false).map(t=>t.code);
  const deadlineOf=m=>window.attendanceDeadline?window.attendanceDeadline(m.meet_date):null, passedOf=m=>{ const dl=deadlineOf(m); return !!(dl&&Date.now()>dl.getTime()); };
  const load=async()=>{ shown=allMode?(upcoming.length?upcoming:[meet]):[meet]; host=isHost(meet); const ids=shown.map(m=>m.id);
    for(const m of shown){ if(passedOf(m)){ try{ await sb.rpc('duties_settle',{p_meet:m.id}); }catch(e){} } }   // hands anything still open to a visiting team (once)
    const [{data:d,error},{data:v},{data:s}]=await Promise.all([sb.from('meet_duties').select('*').in('meet_id',ids).order('sort_order').order('name'), sb.from('meet_volunteers').select('*').in('meet_id',ids).order('created_at'), sb.from('duty_slots').select('*').in('meet_id',ids).order('sort_order')]);
    if(error) throw error; duties=d||[]; vols=v||[]; slots=s||[]; counts={}; scounts={};
    await Promise.all(ids.map(async id=>{ const [{data:c},{data:sc}]=await Promise.all([sb.rpc('duty_counts',{p_meet:id}),sb.rpc('duty_slot_counts',{p_meet:id})]); (c||[]).forEach(x=>counts[x.duty_id]=x.taken); (sc||[]).forEach(x=>scounts[x.slot_id]=x.taken); }));
    mgrTeam=role!=='parent'; };
  const canHost=()=>role!=='parent'&&(host||role==='admin'&&ctx.siteAdmin);
  const meetOf=d=>meets.find(m=>m.id===d.meet_id)||meet;
  const mine=d=>d.team_code===team, myVols=d=>vols.filter(v=>v.duty_id===d.id), taken=d=>counts[d.id]??myVols(d).length, full=d=>taken(d)>=d.slots;
  const slotsOf=d=>d.slot_mode&&d.slot_mode!=='all'?slots.filter(s=>s.duty_id===d.id):[], sVols=s=>vols.filter(v=>v.slot_id===s.id), sTaken=s=>scounts[s.id]??sVols(s).length, sFull=s=>sTaken(s)>=s.slots;
  const isMe=v=>!!(v.email&&ctx.email&&v.email.toLowerCase()===ctx.email.toLowerCase());
  const canSchedule=d=>mgrTeam&&!!d.team_code&&(mine(d)||canHost());
  const MODE={division:'By division',shift:'Time shifts',custom:'Own list'};
  const dname=d=>esc(d.name)+(d.gender?` <span class="pill" style="background:${d.gender==='Boys'?'#dbeafe;color:#1e40af':'#fce7f3;color:#9d174d'}">${d.gender}</span>`:'');
  const dlText=m=>{ const dl=deadlineOf(m); return dl?window.fmtDeadline(dl):''; };
  const dlBanner=()=>{ const dl=deadlineOf(meet); if(!dl) return ''; return passedOf(meet)?`<div class="note warn"><b>The deadline for picking duties has passed</b> (${esc(dlText(meet))}). Anything that was still open has been assigned to a visiting team. ${canHost()?'You can still move duties around by hand.':'Ask the host team if something needs to change.'}</div>`
    :`<div class="note warn"><b>Visiting teams: take your field event by ${esc(dlText(meet))}.</b> First come, first served — one team per event. Anything still open at the deadline is assigned to a visiting team automatically.</div>`; };
  const openList=()=>{ if(role==='parent'||canHost()||!mgrTeam) return ''; const open=duties.filter(d=>!d.team_code&&!d.host_only); if(!open.length) return '';
    if(passedOf(meet)) return ''; return `<div class="note" style="border-color:var(--ok);background:var(--ok-bg)"><b>Open duties at this meet — take one for ${esc(TEAM(team))}:</b>
      <div class="mt-2 flex flex-wrap gap-2">${open.map(d=>`<button class="sbtn grn" data-claim="${d.id}">${dname(d)} · ${d.slots} people</button>`).join('')}</div>
      <div class="text-xs text-gray-600 mt-1">Once you take one it's yours and closed to the other teams. Then set up its sign-up list (by division, by time shift, or your own list) and add your people, or let parents sign themselves up.</div></div>`; };
  const homeMeets=()=>meets.filter(m=>m.host_team_code===team&&m.meet_date>=td);
  const hostStrip=()=>{ if(role==='parent') return ''; const H=homeMeets(); if(!H.length) return `<div class="note soft"><b>${esc(TEAM(team))} isn't hosting a meet this season</b> (per the league schedule), so there's no duty list to set up — just take open duties at the meets you visit.</div>`;
    return `<div class="note" style="border-color:var(--act);background:var(--act-soft)"><b>You host ${H.length===1?'a meet':H.length+' meets'} this season.</b> As the host you set up the duty list — pick the meet: ${H.map(m=>`<button class="sbtn ${m.id===meet.id?'pri':''}" data-gomeet="${m.id}" style="margin:2px">${esc(fmtD(m.meet_date))}${m.week_no?' · Week '+m.week_no:''}</button>`).join('')}</div>`; };
  const meetPick=()=>`<div class="bar"><label class="text-sm font-semibold">Meet</label><select data-meet>${meets.map(m=>`<option value="${m.id}" ${m.id===meet.id?'selected':''}>${esc(meetLabel(m))}${m.meet_date<td?' (past)':''}</option>`).join('')}</select>
    ${host?'<span class="pill act">We host this meet</span>':meet.host_team_code?`<span class="pill">Host: ${esc(TEAM(meet.host_team_code))}</span>`:''}</div>
    <p class="text-xs text-gray-600 mb-2">${esc([meet.venue,meet.location].filter(Boolean).join(', ')||'')}${meet.meet_date<td?' · This meet is over.':''}</p>`;
  const person=(d,v)=>{ const canRm=isMe(v)||(mgrTeam&&(mine(d)||canHost()));
    return `<span>${esc(v.name)}${v.athlete_name?` <i class="text-gray-500">(${esc(v.athlete_name)})</i>`:''}${v.phone&&mgrTeam?` <i class="text-gray-500">${esc(v.phone)}</i>`:''}${canRm?` <button class="red" data-rmvol="${v.id}" title="Take off" style="border:0;background:none;cursor:pointer;font-weight:700">×</button>`:''}</span>`; };
  const people=(d,L)=>L.length?`<div class="people">${L.map(v=>person(d,v)).join('')}</div>`:'';
  const meter=(t,n)=>`<span class="text-xs text-gray-600" style="white-space:nowrap">${t} of ${n}</span><span class="meter"><i style="width:${Math.min(100,100*t/n)}%"></i></span>`;
  // the sign-up control for one duty (no slots) or one slot of it
  const joinBtn=(d,s)=>{ const L=s?sVols(s):myVols(d), me=L.some(isMe), isFull=s?sFull(s):full(d); const key=s?`data-slot="${s.id}" data-signup="${d.id}"`:`data-signup="${d.id}"`;
    if(role==='parent') return me?`<span class="pill ok">You're signed up ✓</span>`:isFull?'<span class="pill">Full — thank you!</span>':`<button class="sbtn grn" ${key}>Sign me up</button>`;
    return isFull?'<span class="pill">Full</span>':`<button class="sbtn grn" ${s?`data-slot="${s.id}" data-addp="${d.id}"`:`data-addp="${d.id}"`}>+ Add a person</button>`; };
  const slotRows=d=>slotsOf(d).map(s=>`<div class="slot"><span class="sl">${esc(s.label)}</span>${meter(sTaken(s),s.slots)}<span style="flex:1"></span>${d.team_code&&(mine(d)||canHost())?joinBtn(d,s):''}${people(d,sVols(s))}</div>`).join('');
  const dutyCard=d=>{ const S=slotsOf(d), m=meetOf(d), hostHere=canHost(), pastDl=passedOf(m);
    const owner=d.team_code?(mine(d)?'<span class="pill act">Our team</span>':`<span class="pill">${esc(TEAM(d.team_code))}</span>`):'<span class="pill warn">Open — needs a team</span>';
    let act='';
    if(hostHere) act+=`<select data-assign="${d.id}" title="Which team does this"><option value="">Open to visiting teams</option>${teamsAt(m).map(t=>`<option value="${t}" ${d.team_code===t?'selected':''}>${esc(TEAM(t))}${t===m.host_team_code?' (host)':''}</option>`).join('')}</select> <button class="sbtn" data-edit="${d.id}">Edit</button> ${d.category==='field'&&!d.gender?`<button class="sbtn" data-split="${d.id}" title="Make a Boys duty and a Girls duty">Split boys / girls</button> `:''}<button class="sbtn red" data-del="${d.id}">Delete</button> `;
    else if(mgrTeam&&!d.host_only&&!pastDl){ if(!d.team_code) act+=`<button class="sbtn pri" data-claim="${d.id}">Take this for ${esc(TEAM(team))}</button> `; else if(mine(d)&&!d.assigned_by_host) act+=`<button class="sbtn" data-release="${d.id}">Give it back</button> `; }
    if(canSchedule(d)) act+=`<button class="sbtn" data-sched="${d.id}">${S.length?'Change the sign-up list':'Set up the sign-up list'}</button> `;
    if(d.team_code&&(mine(d)||hostHere)&&!S.length) act+=joinBtn(d,null);
    return `<div class="duty ${mine(d)?'mine':''} ${!d.team_code?'open':''}" data-duty="${d.id}"><div class="hd"><span class="nm">${dname(d)}</span>${owner}${d.host_only?'<span class="pill">Host duty</span>':''}${S.length?`<span class="pill">${MODE[d.slot_mode]||'List'}</span>`:''}${d.auto_assigned?'<span class="pill warn">Assigned at the deadline</span>':d.assigned_by_host&&d.team_code?'<span class="pill">Assigned by host</span>':''}<span style="flex:1"></span>${meter(taken(d),d.slots)}</div>
      ${d.time_note||d.notes?`<div class="sub">${esc([d.time_note,d.notes].filter(Boolean).join(' · '))}</div>`:''}${S.length?slotRows(d):people(d,myVols(d))}${act?`<div class="mt-2 flex flex-wrap items-center gap-2">${act}</div>`:''}</div>`; };
  const grouped=L=>CAT_ORDER.filter(c=>L.some(d=>d.category===c)).map(c=>`<div class="cat">${CATS[c]}</div>${L.filter(d=>d.category===c).sort((a,b)=>(mine(b)-mine(a))||a.sort_order-b.sort_order).map(dutyCard).join('')}`).join('');
  // ---- coach / team admin: one meet, with the host tools ----
  const drawOne=()=>{ const ours=duties.filter(mine), open=duties.filter(d=>!d.team_code&&!d.host_only);
    let intro=hostStrip()+dlBanner()+openList();
    if(canHost()) intro+=`<div class="note soft"><b>You're the host.</b> List every job the meet needs, keep the host-team ones, and either hand the field events to a visiting team (pick the team on the duty) or leave them open for the visiting teams to take. Then everyone fills their own jobs — each team can lay out its sign-up list by division, by time shift, or however it likes (<b>Set up the sign-up list</b> on the duty).</div>
      <div class="bar">${duties.length?'':'<button class="sbtn pri" data-standard>Add the standard VYC duty list</button>'}<button class="sbtn ${duties.length?'pri':''}" data-newduty>+ Add a duty</button>${duties.length?`<span class="text-sm text-gray-600">${duties.filter(d=>!d.team_code).length} open · ${duties.filter(full).length} of ${duties.length} filled</span>`:''}</div>`;
    else if(mgrTeam) intro+=`<div class="note soft"><b>Away meet — ${esc(TEAM(meet.host_team_code)||'the host team')} sets up this meet's duty list.</b> ${ours.length?`${esc(TEAM(team))} is covering <b>${ours.length}</b> dut${ours.length===1?'y':'ies'} at this meet — set up each one's sign-up list the way your team likes (by division, time shifts, or your own rows), then add your people or let parents sign themselves up.`:'Your team hasn\'t taken a duty yet.'} ${open.length?`<b>${open.length}</b> open dut${open.length===1?'y is':'ies are'} still up for grabs.`:''}</div>`;
    el.innerHTML=meetPick()+intro+(duties.length?grouped(duties):`<p class="text-sm text-gray-500">${canHost()?'No duties yet — start with the standard list.':'The host team hasn\'t listed the duties for this meet yet.'}</p>`); };
  // ---- parent: every meet, stacked. Home meet = the whole host list; away meet = what our team took. ----
  const drawAll=()=>{ const openId=(meets.find(m=>m.id===ctx.meet)||upcoming[0]||{}).id;
    el.innerHTML=`<p class="text-sm text-gray-600 mb-2">Every meet ${esc(TEAM(team))} is at this season. Tap a meet to see the sign-up list — at our <b>home meet</b> that's everything the meet needs; at an <b>away meet</b> it's the events our team is covering. Tap <b>Sign me up</b> on a spot — thank you!</p>`+
      shown.map(m=>{ const D=duties.filter(d=>d.meet_id===m.id), ours=D.filter(mine), theirs=D.filter(d=>!mine(d)&&d.team_code), hostM=isHost(m); const spots=ours.reduce((a,d)=>a+d.slots,0), got=ours.reduce((a,d)=>a+Math.min(d.slots,taken(d)),0); const meCount=vols.filter(v=>v.meet_id===m.id&&isMe(v)).length;
        let body; if(!D.length) body=`<p class="text-sm text-gray-500">${hostM?'Our coaches haven\'t set up the volunteer list for our home meet yet.':'The host team hasn\'t listed this meet\'s duties yet.'} Check back soon.</p>`;
        else if(hostM) body=`<div class="note soft"><b>We host this meet</b> — here's everything we need help with. ${theirs.length?`<span class="text-gray-600">The visiting teams run: ${theirs.map(d=>esc(d.name)+(d.gender?' ('+d.gender+')':'')+' — '+esc(TEAM(d.team_code))).join(', ')}.</span>`:''}</div>`+grouped(ours);
        else body=(ours.length?`<div class="note soft"><b>${esc(TEAM(team))} is covering:</b> ${ours.map(d=>esc(d.name)+(d.gender?' ('+d.gender+')':'')).join(', ')}${m.host_team_code?' at the '+esc(TEAM(m.host_team_code))+' meet':''}.</div>`+grouped(ours):`<p class="text-sm text-gray-500">${esc(TEAM(team))} doesn't have a duty at this meet yet. Check back once the coaches have picked one.</p>`);
        return `<details class="meetbox" ${m.id===openId?'open':''} data-meetbox="${m.id}"><summary><span class="mt">${esc(meetLabel(m))}</span>${hostM?'<span class="pill act">Home meet</span>':m.host_team_code?`<span class="pill">@ ${esc(TEAM(m.host_team_code))}</span>`:''}<span style="flex:1"></span>${ours.length?`<span class="text-xs text-gray-600">${got} of ${spots} spots filled</span>`:''}${meCount?`<span class="pill ok">You: ${meCount} ✓</span>`:''}</summary>
          <div class="text-xs text-gray-600 mb-2">${esc([m.venue,m.location].filter(Boolean).join(', ')||'')}${m.meet_date<td?' · This meet is over.':''}</div>${body}</details>`; }).join('');
    if(ctx.meet){ const b=el.querySelector(`[data-meetbox="${ctx.meet}"]`); if(b) b.scrollIntoView({behavior:'smooth',block:'start'}); } };
  const draw=()=>allMode?drawAll():drawOne();
  const dutyForm=d=>{ const box=modal(`<h3 class="font-bold text-lg mb-2">${d?'Edit duty':'Add a duty'}</h3><label class="f">Duty<input data-k="name" value="${esc(d?d.name:'')}" maxlength="60" placeholder="e.g. Long jump, Snack bar, Clerk"></label>
    <div class="grid" style="grid-template-columns:1fr 1fr"><label class="f">Category<select data-k="cat">${CAT_ORDER.map(c=>`<option value="${c}" ${d&&d.category===c?'selected':''}>${CATS[c]}</option>`).join('')}</select></label><label class="f">People needed${d&&slotsOf(d).length?' <span class="text-gray-500 font-normal">(set by its sign-up list)</span>':''}<input data-k="slots" type="number" min="1" max="50" value="${d?d.slots:2}" ${d&&slotsOf(d).length?'disabled':''}></label></div>
    <label class="f">Boys / girls<select data-k="gender"><option value="" ${!d||!d.gender?'selected':''}>Both (one crew runs boys and girls)</option><option value="Boys" ${d&&d.gender==='Boys'?'selected':''}>Boys only</option><option value="Girls" ${d&&d.gender==='Girls'?'selected':''}>Girls only</option></select></label>
    <label class="f">Which team<select data-k="team"><option value="">Open — a visiting team can take it</option>${teamsAt(meet).map(t=>`<option value="${t}" ${d&&d.team_code===t?'selected':''}>${esc(TEAM(t))}${t===meet.host_team_code?' (host)':''}</option>`).join('')}</select></label>
    <label class="flex items-center gap-2 text-sm mt-2"><input type="checkbox" data-k="hostonly" ${d&&d.host_only?'checked':''}> Host-team duty (not offered to visiting teams)</label>
    <label class="f">When<input data-k="time" value="${esc(d?d.time_note||'':'')}" placeholder="e.g. 8:30 AM – done, or Shifts"></label><label class="f">Notes<input data-k="notes" value="${esc(d?d.notes||'':'')}" placeholder="What they'll do"></label>
    <div class="flex gap-2 mt-3"><button class="btn pri" data-k="save">Save</button><button class="btn" data-k="cancel">Cancel</button><span class="text-sm text-red-700" data-k="msg"></span></div>`);
    const g=k=>box.querySelector(`[data-k="${k}"]`); g('cancel').onclick=closeModal;
    g('save').onclick=async()=>{ g('save').disabled=true; const {error}=await sb.rpc('duty_save',{p_id:d?d.id:null,p_meet:meet.id,p_name:g('name').value.trim(),p_category:g('cat').value,p_slots:+g('slots').value||1,p_team:g('team').value||null,p_time:g('time').value.trim()||null,p_notes:g('notes').value.trim()||null,p_host_only:g('hostonly').checked,p_sort:null,p_gender:g('gender').value||null});
      if(error){ g('msg').textContent=clean(error); g('save').disabled=false; return; } closeModal(); await load(); draw(); }; };
  // ---- how a team wants its sign-up list: one list, by division, time shifts, or its own rows ----
  const fmtT=h=>{ const H=Math.floor(h), M=Math.round((h-H)*60); const ap=H>=12?'PM':'AM'; return `${((H+11)%12)+1}${M?':'+String(M).padStart(2,'0'):':00'} ${ap}`; };
  const scheduleForm=d=>{ const cur=slotsOf(d), hasPeople=myVols(d).length>0; const DIVS=(window.DIVISIONS||[]).map(x=>x.name);
    const box=modal(`<h3 class="font-bold text-lg mb-1">${dname(d)} — sign-up list</h3><p class="text-xs text-gray-500 mb-2">${esc(meetLabel(meetOf(d)))}. Lay it out however your team runs this event.</p>
      <label class="f">How do you want the list?<select data-k="mode"><option value="all" ${d.slot_mode==='all'?'selected':''}>One list — just a head count</option><option value="division" ${d.slot_mode==='division'?'selected':''}>By division — a crew per division, in running order</option><option value="shift" ${d.slot_mode==='shift'?'selected':''}>Time shifts — rotate every 1, 2 or 3 hours</option><option value="custom" ${d.slot_mode==='custom'?'selected':''}>My own list — type the rows</option></select></label>
      <div data-k="opts"></div>
      <div data-k="preview" class="mt-2"></div>
      ${hasPeople?'<p class="text-xs mt-2" style="color:var(--warn)">People already signed up stay on a row that keeps the same name; anyone whose row goes away comes off the list.</p>':''}
      <div class="flex gap-2 mt-3"><button class="btn pri" data-k="save">Save</button><button class="btn" data-k="cancel">Cancel</button><span class="text-sm text-red-700" data-k="msg"></span></div>`);
    const g=k=>box.querySelector(`[data-k="${k}"]`); g('cancel').onclick=closeModal;
    let rows=cur.map(s=>({label:s.label,slots:s.slots}));
    const opts=()=>{ const mode=g('mode').value; let h='';
      if(mode==='all') h=`<label class="f">People needed<input data-o="n" type="number" min="1" max="50" value="${d.slots||3}"></label>`;
      else if(mode==='division') h=`<div class="text-sm font-semibold mt-2">Divisions, in the order they run</div><div class="flex flex-wrap gap-2 mt-1">${DIVS.map(x=>`<label class="text-sm" style="border:1px solid var(--line);border-radius:999px;padding:3px 10px"><input type="checkbox" data-o="div" value="${esc(x)}" checked> ${esc(x)}</label>`).join('')}</div>
        <div class="grid mt-1" style="grid-template-columns:1fr 1fr"><label class="f">People per division<input data-o="n" type="number" min="1" max="50" value="3"></label>${d.gender?'':`<label class="f">Boys and girls<select data-o="bg"><option value="">One crew does both</option><option value="split">Separate crews for boys and girls</option></select></label>`}</div>`;
      else if(mode==='shift') h=`<div class="grid mt-1" style="grid-template-columns:1fr 1fr"><label class="f">First shift starts<input data-o="start" type="time" value="08:00"></label><label class="f">Last shift ends<input data-o="end" type="time" value="14:00"></label><label class="f">Rotate every<select data-o="hrs"><option value="1">1 hour</option><option value="2" selected>2 hours</option><option value="3">3 hours</option></select></label><label class="f">People per shift<input data-o="n" type="number" min="1" max="50" value="3"></label></div>`;
      else h=`<p class="text-xs text-gray-500 mt-2">Type each row — for example "Morning", "Afternoon", or "Gremlin boys" — and how many people it needs.</p>`;
      g('opts').innerHTML=h; };
    const build=()=>{ const mode=g('mode').value, n=+(box.querySelector('[data-o="n"]')||{}).value||3;
      if(mode==='all') rows=[{label:'Everyone',slots:n}];
      else if(mode==='division'){ const picked=[...box.querySelectorAll('[data-o="div"]:checked')].map(x=>x.value); const split=(box.querySelector('[data-o="bg"]')||{}).value==='split'; rows=[]; picked.forEach(dv=>{ if(split){ rows.push({label:dv+' Boys',slots:n}); rows.push({label:dv+' Girls',slots:n}); } else rows.push({label:dv,slots:n}); }); }
      else if(mode==='shift'){ const st=box.querySelector('[data-o="start"]').value, en=box.querySelector('[data-o="end"]').value, hrs=+box.querySelector('[data-o="hrs"]').value||2; const toH=t=>{ const [a,b]=String(t||'').split(':').map(Number); return (a||0)+(b||0)/60; }; let s=toH(st), e=toH(en); if(e<=s) e=s+hrs; rows=[]; while(s<e&&rows.length<40){ const t=Math.min(e,s+hrs); rows.push({label:`${fmtT(s)} – ${fmtT(t)}`,slots:n}); s=t; } }
      else if(!rows.length) rows=[{label:'',slots:3},{label:'',slots:3}];
      preview(); };
    const preview=()=>{ const mode=g('mode').value; if(mode==='all'){ g('preview').innerHTML=''; return; }
      g('preview').innerHTML=`<div class="text-sm font-semibold">The list parents will see</div><table class="t mt-1"><thead><tr><th>Row</th><th style="width:7rem">People</th><th></th></tr></thead><tbody>${rows.map((r,i)=>`<tr><td><input data-r="label" data-i="${i}" value="${esc(r.label)}" maxlength="60" style="width:100%"></td><td><input data-r="slots" data-i="${i}" type="number" min="1" max="50" value="${r.slots}" style="width:5rem"></td><td><button class="sbtn red" data-rm="${i}" title="Remove">×</button></td></tr>`).join('')}</tbody></table><button class="sbtn mt-2" data-k="addrow">+ Add a row</button>`;
      g('preview').querySelectorAll('[data-r]').forEach(inp=>inp.oninput=()=>{ const r=rows[+inp.dataset.i]; if(inp.dataset.r==='slots') r.slots=+inp.value||1; else r.label=inp.value; });
      g('preview').querySelectorAll('[data-rm]').forEach(b=>b.onclick=()=>{ rows.splice(+b.dataset.rm,1); preview(); });
      g('addrow').onclick=()=>{ rows.push({label:'',slots:3}); preview(); g('preview').querySelector(`[data-r="label"][data-i="${rows.length-1}"]`).focus(); }; };
    opts(); if(d.slot_mode==='all'||d.slot_mode!==g('mode').value||!rows.length) build(); else preview();
    g('mode').onchange=()=>{ opts(); if(g('mode').value===d.slot_mode&&cur.length) rows=cur.map(s=>({label:s.label,slots:s.slots})); else rows=[]; build(); };
    g('opts').addEventListener('change',build); g('opts').addEventListener('input',e=>{ if(e.target.matches('[data-o="n"]')) build(); });
    g('save').onclick=async()=>{ const mode=g('mode').value; const send=mode==='all'?[{label:'Everyone',slots:+(box.querySelector('[data-o="n"]')||{}).value||d.slots}]:rows.map(r=>({label:String(r.label||'').trim(),slots:+r.slots||1}));
      if(mode!=='all'&&send.some(r=>!r.label)){ g('msg').textContent='Every row needs a name.'; return; } if(mode!=='all'&&!send.length){ g('msg').textContent='Add at least one row.'; return; }
      g('save').disabled=true; const {error}=await sb.rpc('duty_schedule',{p_duty:d.id,p_mode:mode,p_rows:send}); if(error){ g('msg').textContent=clean(error); g('save').disabled=false; return; }
      closeModal(); toast('Sign-up list saved'); await load(); draw(); }; };
  const signup=async(d,byName,slot)=>{ const regs=ctx.athletes||[], m=meetOf(d);
    const box=modal(`<h3 class="font-bold text-lg mb-1">${esc(d.name)}${slot?` · ${esc(slot.label)}`:''}</h3><p class="text-xs text-gray-500">${esc(meetLabel(m))}${d.time_note?' · '+esc(d.time_note):''}</p>
      <label class="f">${byName?'Volunteer\'s name':'Your name'}<input data-k="name" value="${esc(byName?'':(ctx.name||''))}"></label><label class="f">Phone (optional — so the coaches can reach you on meet day)<input data-k="phone" type="tel" value="${esc(byName?'':(ctx.phone||''))}"></label>
      ${regs.length&&!byName?`<label class="f">Parent of<select data-k="ath"><option value="">—</option>${regs.map(a=>`<option>${esc(a)}</option>`).join('')}</select></label>`:`<label class="f">Parent of (optional)<input data-k="ath" placeholder="Athlete's name"></label>`}
      <div class="flex gap-2 mt-3"><button class="btn grn" data-k="go">${byName?'Add':'Sign me up'}</button><button class="btn" data-k="cancel">Cancel</button><span class="text-sm text-red-700" data-k="msg"></span></div>`);
    const g=k=>box.querySelector(`[data-k="${k}"]`); g('cancel').onclick=closeModal;
    g('go').onclick=async()=>{ g('go').disabled=true; const {error}=await sb.rpc('volunteer_add',{p_duty:d.id,p_name:g('name').value.trim(),p_phone:g('phone').value.trim()||null,p_registration:null,p_athlete_name:g('ath').value.trim()||null,p_slot:slot?slot.id:null});
      if(error){ g('msg').textContent=clean(error); g('go').disabled=false; return; } closeModal(); toast(byName?'Added':'You\'re signed up — thank you!'); await load(); draw(); document.dispatchEvent(new CustomEvent('th:volunteers')); }; };
  el.onclick=async e=>{ const t=e.target, D=id=>duties.find(d=>d.id===id), S=id=>slots.find(s=>s.id===id); let r;
    if(r=t.closest('[data-gomeet]')){ meet=meets.find(m=>m.id===r.dataset.gomeet); if(ctx.onMeet) ctx.onMeet(meet.id); await load(); return draw(); }
    if(t.closest('[data-standard]')){ const {data,error}=await sb.rpc('duties_add_standard',{p_meet:meet.id}); if(error) return toast(clean(error),true); toast(`${data} duties added`); await load(); return draw(); }
    if(t.closest('[data-newduty]')) return dutyForm(null);
    if(r=t.closest('[data-edit]')) return dutyForm(D(r.dataset.edit));
    if(r=t.closest('[data-sched]')) return scheduleForm(D(r.dataset.sched));
    if(r=t.closest('[data-split]')){ const {error}=await sb.rpc('duty_split',{p_duty:r.dataset.split}); if(error) return toast(clean(error),true); toast('Split into Boys and Girls'); await load(); return draw(); }
    if(r=t.closest('[data-del]')){ const d=D(r.dataset.del); if(!confirm(`Remove "${d.name}"?`)) return; const {error}=await sb.rpc('duty_delete',{p_id:d.id}); if(error) return toast(clean(error),true); await load(); return draw(); }
    if(r=t.closest('[data-claim]')){ const {error}=await sb.rpc('duty_claim',{p_duty:r.dataset.claim,p_team:team,p_take:true}); if(error) return toast(clean(error),true); toast(`${TEAM(team)} has it — now set up its sign-up list`); await load(); return draw(); }
    if(r=t.closest('[data-release]')){ if(!confirm('Give this duty back? Anyone your team signed up for it comes off.')) return; const {error}=await sb.rpc('duty_claim',{p_duty:r.dataset.release,p_team:team,p_take:false}); if(error) return toast(clean(error),true); await load(); return draw(); }
    if(r=t.closest('[data-signup]')) return signup(D(r.dataset.signup),false,r.dataset.slot?S(r.dataset.slot):null);
    if(r=t.closest('[data-addp]')) return signup(D(r.dataset.addp),true,r.dataset.slot?S(r.dataset.slot):null);
    if(r=t.closest('[data-rmvol]')){ const {error}=await sb.rpc('volunteer_remove',{p_id:r.dataset.rmvol}); if(error) return toast(clean(error),true); await load(); draw(); document.dispatchEvent(new CustomEvent('th:volunteers')); return; } };
  el.addEventListener('change',async e=>{ if(e.target.matches('[data-meet]')){ meet=meets.find(m=>m.id===e.target.value); if(ctx.onMeet) ctx.onMeet(meet.id); await load(); draw(); }
    if(e.target.matches('[data-assign]')){ const d=duties.find(x=>x.id===e.target.dataset.assign), t=e.target.value||null; if(d.team_code&&t!==d.team_code&&myVols(d).length&&!confirm(`Move "${d.name}" to ${t?TEAM(t):'open'}? The ${myVols(d).length} people signed up come off it.`)){ e.target.value=d.team_code||''; return; }
      const {error}=await sb.rpc('duty_save',{p_id:d.id,p_meet:meet.id,p_name:d.name,p_category:d.category,p_slots:d.slots,p_team:t,p_time:d.time_note,p_notes:d.notes,p_host_only:d.host_only&&t===meet.host_team_code,p_sort:d.sort_order,p_gender:d.gender||null}); if(error){ toast(clean(error),true); } await load(); draw(); } });
  // keep the board fresh while it's open (another team may take a duty)
  timer=setInterval(async()=>{ if(!document.body.contains(el)){ clearInterval(timer); return; } if(document.hidden||document.getElementById('thModal')) return; try{ await load(); draw(); }catch(e){} },60000);
  try{ await load(); }catch(e){ el.innerHTML=`<p class="text-sm text-red-700">Couldn't load the duties: ${esc(clean(e))}</p>`; return 'none'; }
  draw(); return 'on';
};

/* ============================ the team page itself ============================ */
// mountTeamPage(root, ctx) — the hero (logo, name, tagline), the Home / Photos / Store / Volunteers tabs, and the Home content.
//   Used by team.html (public page) and by the Parent and Coach dashboards, so a signed-in parent or coach lands on THEIR team page
//   with their own things (athletes, messages, meet sign-ups, roster…) built into it.
//   ctx: { sb, team, email, uid, role, siteAdmin, name, phone, athletes, tab, meet, album,
//          slots:{ left:[els], right:[els] }   elements to place in the Home columns (parent dashboard cards)
//          homeEl: el                          use this element as the Home pane instead of the generated columns (coach dashboard)
//          teams:[codes], onTeam(code)         a switcher when the person is on several teams
//          showRegister, showWhoami, onSignOut, onTab(tab) }
const PAGE_CSS=`<style id="thPageStyle">
.thp .hero{position:relative;overflow:hidden;padding:0;background:#fff;border:1px solid var(--line,#e1e7ef);border-radius:12px;margin-bottom:12px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.thp .hero .banner{height:150px;background:var(--navy,#001C3B) center/cover no-repeat;background-image:repeating-linear-gradient(100deg,rgba(255,255,255,.07) 0 2px,transparent 2px 46px)}
.thp .hero .body{padding:0 16px 14px;display:flex;flex-wrap:wrap;gap:10px 16px;align-items:flex-end;margin-top:-44px}
.thp .hero .logo{width:92px;height:92px;border-radius:50%;background:#fff;border:4px solid #fff;box-shadow:0 2px 8px rgba(0,0,0,.2);object-fit:cover;flex:none;display:grid;place-items:center;font-family:var(--head);font-weight:700;font-size:1.5rem;color:var(--navy);overflow:hidden}
.thp .hero .logo img{width:100%;height:100%;object-fit:cover}
.thp .hero h1{font-size:1.6rem;line-height:1.1;margin-top:6px;font-family:var(--head);font-weight:700;text-transform:uppercase;color:var(--navy);letter-spacing:.03em}
.thp .hero .btns{display:flex;flex-wrap:wrap;gap:8px}.thp .hero .btns a,.thp .hero .btns button{padding:.55rem .9rem;border-radius:.5rem;font-weight:600;text-decoration:none;border:1px solid transparent;cursor:pointer;font-size:.9rem}
.thp .sw{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 10px}.thp .sw button{border:1px solid var(--line,#e1e7ef);background:#fff;border-radius:999px;padding:4px 12px;font-size:.85rem;font-weight:600;cursor:pointer}.thp .sw button.on{background:var(--act,#1764c8);color:#fff;border-color:var(--act,#1764c8)}
.thp .tabs{display:flex;flex-wrap:wrap;gap:4px;background:#fff;border:1px solid var(--line,#e1e7ef);border-radius:10px;padding:5px;margin-bottom:12px}
.thp .tab{border:0;border-radius:7px;padding:9px 14px;font-weight:600;font-size:.92rem;background:transparent;color:var(--muted,#5b6878);cursor:pointer}.thp .tab.active{background:var(--act,#1764c8);color:#fff}
.thp .two{display:grid;gap:12px;grid-template-columns:minmax(0,1fr);align-items:start}@media(min-width:900px){ .thp .two{grid-template-columns:minmax(0,3fr) minmax(0,2fr)} }
.thp .pcard{background:#fff;border:1px solid var(--line,#e1e7ef);border-radius:12px;padding:14px;margin-bottom:12px;box-shadow:0 1px 3px rgba(0,0,0,.08)}.thp .pcard h2{font-family:var(--head);font-weight:700;text-transform:uppercase;color:var(--navy);letter-spacing:.03em;margin-bottom:6px}
.thp .pre{white-space:pre-wrap}.thp .schedScroll{max-height:380px;overflow-y:auto;padding-right:4px}.thp .hidden{display:none!important}
</style>`;
TeamHub.mountTeamPage=async function(root, ctx){
  css(); if(!document.getElementById('thPageStyle')) document.head.insertAdjacentHTML('beforeend',PAGE_CSS);
  root.classList.add('thp','th'); const sb=ctx.sb, team=ctx.team; if(window.leagueReady) await window.leagueReady;
  const t=(window.VYC_TEAMS||[]).find(x=>x.code===team); if(!t){ root.innerHTML='<p class="text-sm text-red-700">Team not found.</p>'; return null; }
  root.innerHTML='<p class="text-sm text-gray-500 p-2">Loading team page…</p>';
  const [{data:p},{data:lt},{data:ex}]=await Promise.all([
    sb.from('team_pages').select('*').eq('team_code',team).maybeSingle(),
    sb.from('league_teams').select('code,name,conference,home_venue,home_address').eq('code',team).maybeSingle(),
    sb.rpc('team_has_extras',{t:team})]);
  const page=p||{team_code:team}, extras=!!ex, mgr=ctx.role==='admin', me=ctx.email||null;
  let tab=ctx.tab||'home';
  const link=(href,txt)=>`<a class="underline" style="color:var(--act)" target="_blank" rel="noopener" href="${esc(href)}">${esc(txt)}</a>`;
  const contact=[page.contact_name&&`<div><b>${esc(page.contact_name)}</b></div>`, page.contact_email&&`<div><a class="underline" style="color:var(--act)" href="mailto:${esc(page.contact_email)}">${esc(page.contact_email)}</a></div>`, page.contact_phone&&`<div><a class="underline" style="color:var(--act)" href="tel:${esc(page.contact_phone)}">${esc(page.contact_phone)}</a></div>`,
    page.website&&`<div>${link(/^https?:/.test(page.website)?page.website:'https://'+page.website,'Website')}</div>`,
    page.instagram&&`<div>${link('https://instagram.com/'+page.instagram.replace(/^@|^https?:\/\/(www\.)?instagram\.com\//,''),'Instagram')}</div>`,
    page.facebook&&`<div>${link(/^https?:/.test(page.facebook)?page.facebook:'https://facebook.com/'+page.facebook,'Facebook')}</div>`].filter(Boolean).join('');
  const hv=lt&&(lt.home_venue||lt.home_address);
  const homeField=hv?`<div><b>${esc(lt.home_venue||'')}</b></div>${lt.home_address?`<div>${link('https://www.google.com/maps/search/?api=1&query='+encodeURIComponent([lt.home_venue,lt.home_address].filter(Boolean).join(', ')),lt.home_address)}</div>`:''}`:'<span class="text-gray-500">The league hasn\'t listed this team\'s home field yet.</span>';
  const roleWord=ctx.role==='admin'?'team admin':ctx.role==='coach'?'coach':ctx.role==='parent'?'parent':null;
  const sw=(ctx.teams||[]).length>1?`<div class="sw">${ctx.teams.map(c=>`<button data-sw="${esc(c)}" class="${c===team?'on':''}">${esc(TEAM(c))}</button>`).join('')}</div>`:'';
  root.innerHTML=`${sw}<div class="hero"><div class="banner" ${page.banner_path?`style="background-image:url('${esc(publicUrl(sb,page.banner_path))}')"`:''}></div>
    <div class="body"><div class="logo">${page.logo_path?`<img src="${esc(publicUrl(sb,page.logo_path))}" alt="">`:esc(team)}</div>
      <div style="flex:1;min-width:14rem"><div class="text-xs text-gray-500">${t.conference?esc(t.conference)+'ern Conference · ':''}Valley Youth Conference${roleWord?` · <b>your team</b> (${roleWord})`:''}</div><h1>${esc(t.name)}</h1><p class="text-gray-700">${esc(page.tagline||'')}</p></div>
      <div class="btns">${ctx.showRegister!==false&&!me?'<a href="index.html" style="background:var(--act);color:#fff">Register with this team</a>':''}${mgr?'<button type="button" data-th="edit" style="background:#eef1f5">Edit team page</button>':''}</div></div></div>
    ${ctx.showWhoami&&me?`<p class="text-xs text-gray-500 mb-2">Signed in as ${esc(me)}${roleWord?'':' · not on this team'} · <button type="button" class="underline" data-th="signout">Sign out</button></p>`:''}
    <div class="tabs"><button class="tab" data-tab="home">Home</button><button class="tab ${extras||mgr?'':'hidden'}" data-tab="photos">Photos</button><button class="tab ${(extras||mgr)&&(mgr||page.store_open)?'':'hidden'}" data-tab="store">Store</button><button class="tab" data-tab="volunteers">Volunteers</button></div>
    <div data-pane="home"></div>
    <div data-pane="photos" class="hidden"><div class="pcard"><h2>Photos</h2><div data-th="galleryLogin" class="hidden max-w-md"></div><div data-th="gallery"></div></div></div>
    <div data-pane="store" class="hidden"><div class="pcard"><h2>Team store</h2><div data-th="store"></div><div data-th="storeLogin" class="hidden max-w-md mt-3"></div></div></div>
    <div data-pane="volunteers" class="hidden"><div class="pcard"><h2>Meet-day volunteers</h2><p class="text-xs text-gray-500 mb-2">Every VYC meet runs on volunteers. The host team lists the jobs; the visiting teams run the field events; parents pick a spot.</p><div data-th="volLogin" class="hidden max-w-md"></div><div data-th="volunteers"></div></div></div>`;
  const g=k=>root.querySelector(`[data-th="${k}"]`), pane=k=>root.querySelector(`[data-pane="${k}"]`);
  // Home: either the caller's own element (coach dashboard) or two columns with the team's info and the caller's cards slotted in
  const home=pane('home'); const slots=ctx.slots||{};
  if(ctx.homeEl){ home.remove(); }
  else{
    const card=(title,inner,extra)=>`<div class="pcard ${extra||''}"><h2>${title}</h2>${inner}</div>`;
    home.innerHTML=`<div class="two"><div data-th="left">${card('Team news','<div data-th="posts"><p class="text-sm text-gray-500">Loading…</p></div>')}${page.about?card('About the team',`<div class="text-sm pre">${esc(page.about)}</div>`):''}${page.practice_info?card('Practice',`<div class="text-sm pre">${esc(page.practice_info)}</div>`):''}</div>
      <div data-th="right">${card('Our schedule','<div data-th="schedule" class="text-sm schedScroll"><p class="text-sm text-gray-500">Loading…</p></div>')}${me&&ctx.role?card('Volunteering','<div data-th="volsum" class="text-sm"></div>'):''}${card('Coaches','<div data-th="coaches" class="text-sm"></div>')}${card('Contact',`<div class="text-sm">${contact||'<span class="text-gray-500">Not posted yet.</span>'}</div>`)}${card('Home field',`<div class="text-sm">${homeField}</div>`)}</div></div>`;
    (slots.left||[]).slice().reverse().forEach(el=>{ if(el){ g('left').prepend(el); } });
    (slots.right||[]).slice().reverse().forEach(el=>{ if(el){ g('right').prepend(el); } });
    TeamHub.mountPosts(g('posts'),{sb,team,role:ctx.role});
    window.mountTeamSchedule(g('schedule'),{sb,teams:[team]});
    if(g('volsum')) TeamHub.mountVolunteerSummary(g('volsum'),{sb,teams:[{code:team,role:ctx.role}],email:me,here:true});
    try{ const {data:cs}=await sb.rpc('team_page_coaches',{p_team:team}); const roleL=c=>c.team_admin?(c.admin_title||'Team admin'):c.role_type==='head_coach'?'Head Coach':c.role_type==='division_coach'?'Division Coach'+(c.division_or_age_group?' — '+c.division_or_age_group:''):c.role_type==='event_specialist'?'Event Coach':(c.admin_title||'Team staff');
      g('coaches').innerHTML=(cs||[]).length?cs.map(c=>`<div class="py-1 border-t first:border-t-0"><b>${esc(c.first_name||'')} ${esc(c.last_name||'')}</b> <span class="text-gray-500">· ${esc(roleL(c))}</span></div>`).join(''):'<span class="text-gray-500">No approved coaches listed yet.</span>'; }catch(e){ g('coaches').innerHTML=''; }
  }
  const login=el=>{ el.classList.remove('hidden'); if(!el.dataset.ready){ el.dataset.ready='1'; window.mountLoginWidget(sb,el,{hint:'Sign in with the email you registered with (parents) or your coach login.'}); } };
  const sub=()=>({sb,team,role:ctx.role,email:me,uid:ctx.uid,name:ctx.name,phone:ctx.phone,athletes:ctx.athletes,page,extras,siteAdmin:ctx.siteAdmin});
  const show=k=>{ if(!root.querySelector(`[data-tab="${k}"]`)||root.querySelector(`[data-tab="${k}"]`).classList.contains('hidden')) k='home'; tab=k;
    root.querySelectorAll('.tab').forEach(b=>b.classList.toggle('active',b.dataset.tab===k)); root.querySelectorAll('[data-pane]').forEach(x=>x.classList.toggle('hidden',x.dataset.pane!==k));
    if(ctx.homeEl) ctx.homeEl.classList.toggle('hidden',k!=='home');
    if(ctx.onTab) ctx.onTab(k);
    if(k==='photos'){ if(!me){ g('gallery').innerHTML=''; if(extras) login(g('galleryLogin')); } else { g('galleryLogin').classList.add('hidden'); TeamHub.mountGallery(g('gallery'),Object.assign(sub(),{album:ctx.album||null})); } }
    if(k==='store'){ TeamHub.mountStore(g('store'),sub()); if(!me&&extras&&page.store_open) login(g('storeLogin')); else g('storeLogin').classList.add('hidden'); }
    if(k==='volunteers'){ if(!me){ g('volunteers').innerHTML=''; login(g('volLogin')); } else { g('volLogin').classList.add('hidden'); TeamHub.mountVolunteers(g('volunteers'),Object.assign(sub(),{meet:root.__meet||ctx.meet||null,onMeet:ctx.onMeet})); } } };
  root.querySelectorAll('.tab').forEach(b=>b.onclick=()=>show(b.dataset.tab));
  root.querySelectorAll('[data-sw]').forEach(b=>b.onclick=()=>{ if(ctx.onTeam) ctx.onTeam(b.dataset.sw); });
  if(g('edit')) g('edit').onclick=()=>TeamHub.editPage({sb,team,page,extras,onSaved:()=>location.reload()});
  if(g('signout')) g('signout').onclick=()=>{ if(ctx.onSignOut) ctx.onSignOut(); else { if(window.clearRoleFlags) window.clearRoleFlags(); sb.auth.signOut().then(()=>location.reload()); } };
  show(tab);
  return {page,extras,show};
};

/* ============================ dashboard summary box ============================ */
// mountVolunteerSummary(el, {sb, teams:[{code, role}], email}) — the next meets, what the team is covering, and where I stand.
TeamHub.mountVolunteerSummary=async function(el, ctx){
  css(); el.classList.add('th'); const sb=ctx.sb, teams=(ctx.teams||[]).filter(t=>t&&t.code);
  if(!teams.length){ el.innerHTML=''; return; }
  let meets; try{ meets=await teamMeets(sb,teams.map(t=>t.code)); }catch(e){ el.innerHTML=''; return; }
  const td=today(); const next=meets.filter(m=>m.meet_date>=td).slice(0,3); if(!next.length){ el.innerHTML='<p class="text-sm text-gray-500">No upcoming meets yet.</p>'; return; }
  const ids=next.map(m=>m.id);
  const [{data:d},{data:v}]=await Promise.all([sb.from('meet_duties').select('id,meet_id,name,slots,team_code,host_only,gender').in('meet_id',ids), sb.from('meet_volunteers').select('id,duty_id,meet_id,team_code,name,email').in('meet_id',ids)]);
  const duties=d||[], vols=v||[]; const cnt={}; try{ for(const id of ids){ const {data:c}=await sb.rpc('duty_counts',{p_meet:id}); (c||[]).forEach(x=>cnt[x.duty_id]=x.taken); } }catch(e){}
  el.innerHTML=next.map(m=>{ const mineT=teams.filter(t=>window.meetHasTeam(m,t.code)); const parts=mineT.map(t=>{ const host=m.host_team_code===t.code; const ours=duties.filter(x=>x.meet_id===m.id&&x.team_code===t.code); const open=duties.filter(x=>x.meet_id===m.id&&!x.team_code&&!x.host_only).length;
      const me=vols.filter(x=>x.meet_id===m.id&&x.email&&ctx.email&&x.email.toLowerCase()===ctx.email.toLowerCase()).map(x=>(duties.find(y=>y.id===x.duty_id)||{}).name).filter(Boolean);
      const filled=ours.reduce((a,x)=>a+Math.min(x.slots,cnt[x.id]||0),0), need=ours.reduce((a,x)=>a+x.slots,0);
      const line=host?`<b>${esc(TEAM(t.code))} hosts.</b> ${duties.filter(x=>x.meet_id===m.id).length?`${filled} of ${need} host spots filled · ${open} dut${open===1?'y':'ies'} still open for visiting teams`:'Duty list not set up yet — as the host, start with the standard VYC list'}`
        :ours.length?`<b>${esc(TEAM(t.code))}</b> covers ${ours.map(x=>esc(x.name)+(x.gender?' ('+x.gender+')':'')).join(', ')} — ${filled} of ${need} spots filled`:`<b>${esc(TEAM(t.code))}</b> has no duty yet${open?` · ${open} open`:''}`;
      const dl=window.attendanceDeadline?window.attendanceDeadline(m.meet_date):null; const dlLine=dl&&t.role!=='parent'&&!host&&!ours.length&&open?`<div class="text-xs" style="color:var(--warn)">Pick by ${esc(window.fmtDeadline(dl))} or one is assigned to you.</div>`:'';
      return `<div class="text-sm">${line}${dlLine}${me.length?`<div class="text-xs" style="color:var(--ok)">You're signed up: ${me.map(esc).join(', ')} ✓</div>`:''}</div>`; }).join('');
    const url=ctx.volUrl?ctx.volUrl(m,mineT[0].code):ctx.here?`?tab=volunteers&meet=${m.id}`:`team.html?team=${encodeURIComponent(mineT[0].code)}&tab=volunteers&meet=${m.id}`;
    return `<div class="note" style="margin-bottom:8px"><div class="flex flex-wrap items-center gap-2"><b>${esc(meetLabel(m))}</b><span style="flex:1"></span><a class="sbtn pri" style="text-decoration:none" href="${url}" ${ctx.here?`data-volgo="${m.id}"`:''}>${teams.some(t=>t.role==='parent')?'Volunteer →':mineT.some(t=>m.host_team_code===t.code)&&!duties.some(x=>x.meet_id===m.id)?'Set up duties →':'Duties →'}</a></div>${parts}</div>`; }).join('');
  // inside the team page, "Volunteer →" just switches to the Volunteers tab on that meet
  el.querySelectorAll('[data-volgo]').forEach(a=>a.onclick=e=>{ const page=a.closest('.thp'); const tabBtn=page&&page.querySelector('.tab[data-tab="volunteers"]'); if(!tabBtn) return; e.preventDefault(); page.__meet=a.dataset.volgo; tabBtn.click(); window.scrollTo({top:Math.max(0,page.offsetTop-10),behavior:'smooth'}); });
};
/* ============================ "you're coming — please volunteer" reminder ============================ */
// mountVolunteerNudge(el, {sb, email, regs:[{id, first_name, team_code}]}) — league rule: every family helps at every meet.
//   Shows a reminder on the parent's page when they said an athlete IS coming to the team's next meet but nobody from
//   their login has signed up to volunteer at it. Goes away on its own once they sign up (or say the athlete isn't coming).
TeamHub.mountVolunteerNudge=async function(el, ctx){
  if(!el) return; css(); el.classList.add('th'); const sb=ctx.sb, me=(ctx.email||'').toLowerCase(), regs=(ctx.regs||[]).filter(r=>r&&r.id&&r.team_code);
  const draw=async()=>{ el.innerHTML=''; if(!me||!regs.length) return;
    const teams=[...new Set(regs.map(r=>r.team_code))]; let meets; try{ meets=await teamMeets(sb,teams); }catch(e){ return; }
    const td=today(); const next=teams.map(t=>meets.find(m=>m.meet_date>=td&&window.meetHasTeam(m,t))).filter(Boolean); const ids=[...new Set(next.map(m=>m.id))]; if(!ids.length) return;
    const [{data:att},{data:vols},{data:duties}]=await Promise.all([sb.from('meet_attendance').select('meet_id,registration_id,attending').in('meet_id',ids).in('registration_id',regs.map(r=>r.id)), sb.from('meet_volunteers').select('meet_id,email').in('meet_id',ids), sb.from('meet_duties').select('id,meet_id,team_code,slots').in('meet_id',ids)]);
    const cnt={}; try{ for(const id of ids){ const {data:c}=await sb.rpc('duty_counts',{p_meet:id}); (c||[]).forEach(x=>cnt[x.duty_id]=x.taken); } }catch(e){}
    const out=[]; for(const t of teams){ const m=next.find(x=>window.meetHasTeam(x,t)); if(!m) continue;
      const kids=regs.filter(r=>r.team_code===t&&(att||[]).some(a=>a.meet_id===m.id&&a.registration_id===r.id&&a.attending)); if(!kids.length) continue;
      if((vols||[]).some(v=>v.meet_id===m.id&&v.email&&v.email.toLowerCase()===me)) continue;
      const ours=(duties||[]).filter(d=>d.meet_id===m.id&&d.team_code===t); const openSpots=ours.reduce((a,d)=>a+Math.max(0,d.slots-(cnt[d.id]||0)),0);
      const names=kids.map(k=>k.first_name).filter(Boolean); const who=names.length?names.join(' and '):'your athlete';
      out.push(`<div class="note" style="border-color:#D2451E;background:#fff4ef;margin-bottom:12px"><div class="flex flex-wrap items-center gap-2"><div style="flex:1;min-width:14rem"><b>🙋 Please volunteer at ${esc(meetLabel(m))}</b><div class="text-sm mt-1">You said <b>${esc(who)}</b> ${names.length>1?'are':'is'} coming, but nobody from your family has signed up to help yet. Every VYC family is asked to volunteer at each meet${m.host_team_code===t?' — and this one is our home meet':''}.
        ${ours.length?(openSpots?`<b>${openSpots}</b> spot${openSpots===1?'':'s'} still open on ${esc(TEAM(t))}'s list.`:`${esc(TEAM(t))}'s list is full right now — check back in case a spot opens, or ask your coach where else you can help.`):`${esc(TEAM(t))}'s sign-up list for this meet isn't posted yet — check back here.`}</div></div>
        ${ours.length&&openSpots?`<a class="sbtn" style="background:#D2451E;color:#fff;border-color:#D2451E;text-decoration:none" href="?tab=volunteers&meet=${m.id}" data-nudgego="${m.id}">Pick a spot →</a>`:''}</div></div>`); }
    el.innerHTML=out.join('');
    el.querySelectorAll('[data-nudgego]').forEach(a=>a.onclick=e=>{ const page=document.querySelector('.thp'); const tabBtn=page&&page.querySelector('.tab[data-tab="volunteers"]'); if(!tabBtn) return; e.preventDefault(); page.__meet=a.dataset.nudgego; tabBtn.click(); window.scrollTo({top:Math.max(0,page.offsetTop-10),behavior:'smooth'}); }); };
  document.addEventListener('th:volunteers',()=>{ if(document.body.contains(el)) draw().catch(()=>{}); });
  await draw();
};
})();
