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
