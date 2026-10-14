// Athlete registration in 4 short steps, with a progress bar and a saved draft.
// Look-and-flow only: the form, its fields and the submit code in index.html are unchanged.
// The draft keeps typed answers on this device (never files, passwords or signatures) and is cleared after a successful submit.
(function(){
  var form=document.getElementById('parentForm'); if(!form) return;
  var STEPS=[
    {name:'Athlete',   match:/^(Team|Sport|Athlete Information)/},
    {name:'Documents', match:/^(Proof of Birth|Insurance)/},
    {name:'Parents',   match:/^Parent \/ Guardian/},
    {name:'Sign',      match:/./}            // agreements, contract and the submit button
  ];
  var DRAFT='vyc_reg_draft', DRAFT_DAYS=7;
  var cards=[].slice.call(form.children).filter(function(el){ return el.classList.contains('card'); });
  var stepOf=function(card){ var h=card.querySelector('h2'), t=h?h.textContent.trim():''; for(var i=0;i<STEPS.length;i++) if(t&&STEPS[i].match.test(t)) return i; return STEPS.length-1; };
  cards.forEach(function(c){ c.dataset.step=stepOf(c); });
  var cur=0;

  // ---- progress bar ----
  var bar=document.createElement('div'); bar.className='regsteps'; bar.setAttribute('role','navigation'); bar.setAttribute('aria-label','Registration steps');
  bar.innerHTML='<div class="regsteps-top"><span class="regsteps-count"></span><button type="button" class="regsteps-reset">Start over</button></div>'+
    '<div class="regsteps-track" aria-hidden="true"><div class="regsteps-fill"></div></div>'+
    '<ol class="regsteps-list">'+STEPS.map(function(s,i){ return '<li><button type="button" data-go="'+i+'"><span class="n">'+(i+1)+'</span><span class="t">'+s.name+'</span></button></li>'; }).join('')+'</ol>'+
    '<p class="regsteps-note" hidden></p>';
  form.insertBefore(bar, cards[0]);
  var note=bar.querySelector('.regsteps-note');
  window.regStepNote=function(html){ note.innerHTML=html||''; note.hidden=!html; };

  // ---- Back / Continue under each step ----
  STEPS.forEach(function(s,i){
    var last=cards.filter(function(c){ return +c.dataset.step===i; }).pop(); if(!last) return;
    var nav=document.createElement('div'); nav.className='regnav'; nav.dataset.step=i;
    nav.innerHTML=(i>0?'<button type="button" class="btn lite" data-back>← Back</button>':'<span></span>')+
      (i<STEPS.length-1?'<button type="button" class="btn pri" data-next>Continue to '+STEPS[i+1].name+' →</button>':'');
    last.after(nav);
  });

  function fieldsIn(step){ return [].slice.call(form.querySelectorAll('.card[data-step="'+step+'"] input, .card[data-step="'+step+'"] select, .card[data-step="'+step+'"] textarea')); }
  function valid(step){
    var bad=fieldsIn(step).find(function(el){ return el.offsetParent!==null && !el.checkValidity(); });
    if(bad){ bad.reportValidity(); return false; }
    return true;
  }
  function show(step, scroll){
    cur=Math.max(0,Math.min(STEPS.length-1,step));
    form.querySelectorAll('[data-step]').forEach(function(el){ el.classList.toggle('step-off', +el.dataset.step!==cur); });
    bar.querySelector('.regsteps-count').textContent='Step '+(cur+1)+' of '+STEPS.length+' · '+STEPS[cur].name;
    bar.querySelector('.regsteps-fill').style.width=((cur+1)/STEPS.length*100)+'%';
    bar.querySelectorAll('[data-go]').forEach(function(b,i){ b.classList.toggle('done',i<cur); b.classList.toggle('now',i===cur); if(i===cur) b.setAttribute('aria-current','step'); else b.removeAttribute('aria-current'); });
    if(scroll!==false){ var reduce=window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches; bar.scrollIntoView({behavior:reduce?'auto':'smooth',block:'start'}); }
    // the signature pads size themselves from their box, which is 0 wide while hidden
    try{ window.dispatchEvent(new Event('resize')); }catch(e){}
  }
  window.regGoStep=function(i){ show(i); };

  bar.addEventListener('click',function(e){ var b=e.target.closest('[data-go]'); if(!b) return; var to=+b.dataset.go;
    if(to>cur){ for(var s=cur;s<to;s++){ if(!valid(s)){ if(s!==cur) show(s); return; } } } show(to); });
  form.addEventListener('click',function(e){
    if(e.target.closest('[data-next]')){ if(valid(cur)) show(cur+1); }
    else if(e.target.closest('[data-back]')) show(cur-1);
  });
  // If the browser blocks the final submit over a field on an earlier step, jump to that step.
  form.addEventListener('invalid',function(e){ var c=e.target.closest('.card[data-step]'); if(c&&+c.dataset.step!==cur){ show(+c.dataset.step,false); setTimeout(function(){ e.target.reportValidity(); },50); } },true);
  // Pressing Enter in a text box moves on instead of submitting from the middle of the form.
  form.addEventListener('keydown',function(e){ if(e.key==='Enter'&&e.target.tagName==='INPUT'&&cur<STEPS.length-1){ e.preventDefault(); if(valid(cur)) show(cur+1); } });

  // ---- saved draft ----
  var SKIP=/^(file|password|hidden|submit|button)$/;
  var saveable=function(el){ return (el.id||el.name) && !SKIP.test(el.type||'') && !el.closest('.sigpad,[data-sig]'); };
  function save(){ try{
    var d={t:Date.now(),step:cur,v:{}};
    [].slice.call(form.elements).forEach(function(el){ if(!saveable(el)) return;
      if(el.type==='radio'){ if(el.checked) d.v['r:'+el.name]=el.value; }
      else if(el.type==='checkbox'){ if(el.id) d.v['c:'+el.id]=el.checked; }
      else if(el.id) d.v[el.id]=el.value; });
    localStorage.setItem(DRAFT,JSON.stringify(d));
  }catch(e){} }
  function restore(){ try{
    if(new URLSearchParams(location.search).get('another')==='1') return; // the "another child" flow fills the form itself
    var d=JSON.parse(localStorage.getItem(DRAFT)||'null'); if(!d) return;
    if(Date.now()-d.t>DRAFT_DAYS*864e5){ localStorage.removeItem(DRAFT); return; }
    var any=false;
    Object.keys(d.v).forEach(function(k){ var val=d.v[k], el;
      if(k.slice(0,2)==='r:'){ el=form.querySelector('input[type=radio][name="'+k.slice(2)+'"][value="'+String(val).replace(/"/g,'')+'"]'); if(el&&!el.checked){ el.checked=true; el.dispatchEvent(new Event('change',{bubbles:true})); any=true; } return; }
      if(k.slice(0,2)==='c:'){ el=document.getElementById(k.slice(2)); if(el&&el.form===form&&el.checked!==val){ el.checked=val; el.dispatchEvent(new Event('change',{bubbles:true})); } return; }
      el=document.getElementById(k); if(!el||el.form!==form||el.value||!val) return;
      el.value=val; any=true; el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true}));
    });
    if(any){ window.regStepNote('Welcome back — we kept what you typed last time. You\'ll still need to re-attach the proof of birth and sign again.'); show(d.step||0,false); }
  }catch(e){} }
  var t=null; form.addEventListener('input',function(){ clearTimeout(t); t=setTimeout(save,400); }); form.addEventListener('change',function(){ clearTimeout(t); t=setTimeout(save,400); });
  window.regClearDraft=function(){ try{ localStorage.removeItem(DRAFT); }catch(e){} };
  bar.querySelector('.regsteps-reset').addEventListener('click',function(){
    if(!confirm('Clear everything on this form and start over?')) return;
    window.regClearDraft(); location.href=location.pathname;
  });

  show(0,false);
  // Team list and other choices load a moment after the page, so restore once they're in.
  window.addEventListener('load',function(){ var go=function(){ setTimeout(restore,350); }; if(window.leagueReady) window.leagueReady.then(go,go); else go(); });
})();
