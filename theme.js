// Look-only helpers for the top bar: the phone "Menu" button, the logo, and the current-page highlight.
// Nothing here reads or writes app data. If logo.png is missing the logo spot simply stays empty.
(function(){
  function setup(){ try{
    var bar=document.querySelector('.topnav'), inner=document.querySelector('.topnav-inner'), nav=document.querySelector('.topnav nav');
    if(!bar||!inner||!nav) return;
    var brand=inner.querySelector('.brand');
    if(brand && !brand.querySelector('.brand-logo')){
      var img=document.createElement('img'); img.className='brand-logo'; img.alt=''; img.setAttribute('data-redesign','');
      img.onerror=function(){ img.remove(); }; img.src='logo.png'; brand.insertBefore(img, brand.firstChild);
    }
    if(!inner.querySelector('.navtoggle')){
      var b=document.createElement('button'); b.type='button'; b.className='navtoggle'; b.setAttribute('data-redesign','');
      b.setAttribute('aria-expanded','false'); b.innerHTML='<i></i><span>Menu</span>';
      b.addEventListener('click',function(){ var open=bar.classList.toggle('open'); b.setAttribute('aria-expanded',open?'true':'false'); b.lastChild.textContent=open?'Close':'Menu'; });
      inner.insertBefore(b, nav);
      document.documentElement.classList.add('js-nav');
    }
    mark();
  }catch(e){} }
  function mark(){ try{
    var here=location.pathname.split('/').pop()||'home.html', view=new URLSearchParams(location.search).get('view')||'';
    var links=[].slice.call(document.querySelectorAll('.topnav nav a')), best=null;
    links.forEach(function(a){ a.removeAttribute('aria-current'); var u=new URL(a.getAttribute('href'), location.href);
      if((u.pathname.split('/').pop()||'home.html')!==here) return; var v=u.searchParams.get('view')||'';
      if(v===view) best=a; else if(!v && !best) best=a; });
    if(best) best.setAttribute('aria-current','page');
  }catch(e){} }
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',setup); else setup();
  window.addEventListener('load',mark);
})();

// Installable app: register the service worker, and drive the "Get the app" card on Home (#getApp).
(function(){
  if('serviceWorker' in navigator && location.protocol!=='file:'){
    window.addEventListener('load',function(){ navigator.serviceWorker.register('sw.js').catch(function(){}); });
  }
  var deferred=null;
  var standalone=function(){ return (window.matchMedia&&matchMedia('(display-mode: standalone)').matches)||navigator.standalone===true; };
  var ua=navigator.userAgent||'', ios=/iPhone|iPad|iPod/.test(ua)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
  function draw(){ try{
    var box=document.getElementById('getApp'); if(!box) return;
    if(standalone()){ box.hidden=true; return; }
    var btn=box.querySelector('[data-install]'), how=box.querySelector('[data-how]');
    box.hidden=false;
    if(deferred){ btn.hidden=false; how.textContent='One tap and it lives on your home screen like any other app.'; }
    else if(ios){ btn.hidden=true; how.innerHTML='On iPhone / iPad: open this page in <b>Safari</b>, tap the <b>Share</b> button (square with an arrow), then <b>Add to Home Screen</b>.'; }
    else { btn.hidden=true; how.innerHTML='Open your browser menu (<b>⋮</b>) and choose <b>Install app</b> or <b>Add to Home screen</b>.'; }
  }catch(e){} }
  window.addEventListener('beforeinstallprompt',function(e){ e.preventDefault(); deferred=e; draw(); });
  window.addEventListener('appinstalled',function(){ deferred=null; var b=document.getElementById('getApp'); if(b) b.hidden=true; });
  document.addEventListener('click',function(e){
    var t=e.target.closest&&e.target.closest('#getApp [data-install]'); if(!t||!deferred) return;
    deferred.prompt(); deferred.userChoice.finally(function(){ deferred=null; draw(); });
  });
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',draw); else draw();
})();

// "Look around" banner (2026-10-23): while a reviewer is in the look-around view (flag vyc_demo_role, set by the sign-in
// widget in shared.js and cleared by every sign-out), each page says so at the top and offers a way out or a switch of view.
(function(){
  function draw(){ try{
    var k=localStorage.getItem('vyc_demo_role'); if(!k||document.getElementById('demoBanner')) return;
    var role={coach:'coach',teamadmin:'team admin',parent:'parent',timer:'timer'}[k]||'reviewer';
    var bar=document.createElement('div'); bar.id='demoBanner';
    bar.style.cssText='position:sticky;top:0;z-index:60;background:#fef3c7;color:#78350f;border-bottom:1px solid #f59e0b;padding:8px 16px;font:600 14px/1.4 Archivo,system-ui,sans-serif;display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center;justify-content:center;text-align:center';
    var btn='style="text-decoration:underline;font:inherit;background:none;border:0;color:inherit;cursor:pointer;padding:0"';
    bar.innerHTML='<span>👀 You are looking around as a demo <b></b> on the sample team (AVTC). Everything is view-only; changes are turned off.</span>'+
      '<span><button type="button" data-demo-switch '+btn+'>Switch view</button> · <button type="button" data-demo-exit '+btn+'>Exit look-around</button></span>';
    bar.querySelector('b').textContent=role;
    var leave=function(to){
      var done=function(){ location.href=to; };
      try{ var sb=(window.supabase&&window.APP_CONFIG)?window.supabase.createClient(window.APP_CONFIG.SUPABASE_URL,window.APP_CONFIG.SUPABASE_ANON_KEY):null;
        if(window.endLookAround){ window.endLookAround(sb).then(done,done); return; } }catch(e){}
      try{ localStorage.removeItem('vyc_demo_role'); }catch(e){} done(); };
    bar.querySelector('[data-demo-exit]').onclick=function(){ leave('home.html'); };
    bar.querySelector('[data-demo-switch]').onclick=function(){ leave(location.pathname.split('/').pop()||'home.html'); };   // back to this page's sign-in screen, where the look-around buttons are
    document.body.insertBefore(bar, document.body.firstChild);
  }catch(e){} }
  window.drawDemoBanner=draw;   // the sign-in widget calls this right after a look-around sign-in, so the banner shows without a reload
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',draw); else draw();
})();
