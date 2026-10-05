/* DealBasis settings. Paste your two Supabase values between the quotes, then Commit changes.
   Both are in Supabase: click "Connect" at the top of your project (or Project Settings → API Keys / Data API).
   They are public by design; your data is protected by the database's access rules. Never paste the service_role / secret key here. */
window.DEALBASIS_CONFIG = {
  supabaseUrl: "https://taawzbjorabugeqoddye.supabase.co",        // looks like https://abcdefghijklmnopqrst.supabase.co
  supabaseAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRhYXd6YmpvcmFidWdlcW9kZHllIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTExNzc2MTgsImV4cCI6MjEwNjc1MzYxOH0.Bq5jyrm_WJs-CkInsTELH488SHXEch-BooDhJm11-RA"      // the anon public key (eyJ...) or publishable key (sb_publishable_...)
};

/* ---- leave everything below this line as it is ---- */
(function (c) {
  var u = String(c.supabaseUrl || '').trim(), k = String(c.supabaseAnonKey || '').trim();
  if (/PASTE/i.test(u)) u = ''; if (/PASTE/i.test(k)) k = '';
  if (u && !/^https?:\/\//i.test(u)) u = 'https://' + u;
  try { u = u ? new URL(u).origin : ''; } catch (e) { u = ''; }
  if (/^sb_secret_/.test(k)) { console.error('config.js holds a secret key. Use the public (anon / publishable) key.'); k = ''; c.secretKey = true; }
  c.supabaseUrl = u; c.supabaseAnonKey = k;
})(window.DEALBASIS_CONFIG = window.DEALBASIS_CONFIG || {});
