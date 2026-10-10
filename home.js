(function () {
  var nav = document.getElementById('nav'), btn = document.getElementById('menuBtn');
  /* phone menu */
  btn.addEventListener('click', function () { var open = nav.classList.toggle('open'); btn.setAttribute('aria-expanded', open); btn.setAttribute('aria-label', open ? 'Close menu' : 'Open menu'); });
  document.querySelectorAll('#mobileMenu a').forEach(function (a) { a.addEventListener('click', function () { nav.classList.remove('open'); btn.setAttribute('aria-expanded', 'false'); }); });
  /* shadow under the nav once the page scrolls */
  var onScroll = function () { nav.classList.toggle('scrolled', window.scrollY > 8); }; window.addEventListener('scroll', onScroll, { passive: true }); onScroll();
  /* product tour tabs, with arrow keys */
  var tabs = [].slice.call(document.querySelectorAll('[role="tab"]'));
  function show(t) { tabs.forEach(function (x) { var on = x === t; x.setAttribute('aria-selected', on); x.tabIndex = on ? 0 : -1; document.getElementById(x.getAttribute('aria-controls')).hidden = !on; }); }
  tabs.forEach(function (t, i) { t.addEventListener('click', function () { show(t); });
    t.addEventListener('keydown', function (e) { var k = e.key, j = k === 'ArrowRight' ? i + 1 : k === 'ArrowLeft' ? i - 1 : k === 'Home' ? 0 : k === 'End' ? tabs.length - 1 : null; if (j == null) return; e.preventDefault(); var n = tabs[(j + tabs.length) % tabs.length]; show(n); n.focus(); }); });
  /* stats count up once, when they come into view */
  var still = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  var nums = document.querySelectorAll('[data-count]');
  if (!still && 'IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (es) { es.forEach(function (e) { if (!e.isIntersecting) return; io.unobserve(e.target); var el = e.target, end = +el.dataset.count, pre = el.dataset.pre || '', suf = el.dataset.suf || '', t0 = null;
      function step(ts) { if (!t0) t0 = ts; var p = Math.min(1, (ts - t0) / 900), v = Math.round(end * (1 - Math.pow(1 - p, 3))); el.textContent = pre + v + suf; if (p < 1) requestAnimationFrame(step); }
      requestAnimationFrame(step); }); }, { threshold: .4 });
    nums.forEach(function (n) { io.observe(n); });
  }
})();
