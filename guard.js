/* DealBasis session guard for the Admin and Account pages: two-factor sign-in and sign-out after inactivity.
   The platform itself (app.html) does the same inside adapter.js. */
(function () {
  'use strict';
  var IDLE_KEY = 'dealbasis.lastActive';
  function stamp() { try { localStorage.setItem(IDLE_KEY, String(Date.now())); } catch (e) { } }
  function last() { try { return +localStorage.getItem(IDLE_KEY) || 0; } catch (e) { return 0; } }

  /* sign out after `minutes` without a click, key press or scroll in any DealBasis tab */
  function watchIdle(sb, minutes) {
    var limit = Math.max(5, +minutes || 30) * 60000, mine = Date.now(), leaving = false;
    stamp();
    ['pointerdown', 'keydown', 'scroll', 'touchstart'].forEach(function (ev) { window.addEventListener(ev, function () { mine = Date.now(); stamp(); }, { passive: true }); });
    setInterval(async function () {
      if (leaving || Date.now() - Math.max(mine, last()) < limit) return;
      leaving = true;
      try { await sb.rpc('log_event', { act: 'auth.idle_sign_out' }); } catch (e) { }
      await sb.auth.signOut();
      location.replace('/signin?access=idle');
    }, 20000);
  }

  /* where this session has to go before it can use the workspace: a code, a new authenticator, or nowhere */
  async function mfaStep(sb, ws) {
    var a = await sb.auth.mfa.getAuthenticatorAssuranceLevel();
    var cur = a.data && a.data.currentLevel, nxt = a.data && a.data.nextLevel;
    if (cur === 'aal2') return null;
    if (nxt === 'aal2') return 'code';          /* they have an authenticator: ask for its code */
    if (ws && ws.requireMfa) return 'setup';     /* the firm requires one and they have none yet */
    return null;
  }
  function mfaRedirect(step, next) {
    var n = encodeURIComponent(next || (location.pathname + location.search + location.hash));
    location.replace(step === 'code' ? '/signin?mfa=1&next=' + n : '/account?setup=1&next=' + n);
  }

  window.DealBasisGuard = Object.freeze({ watchIdle: watchIdle, mfaStep: mfaStep, mfaRedirect: mfaRedirect, stamp: stamp });
})();
