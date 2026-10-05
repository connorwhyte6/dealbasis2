/* DealBasis on Supabase.
   The platform talks to a small storage interface: claude.use('db' | 'assets' | 'user' | 'downloads').
   This file provides that interface on top of Supabase (sign-in, Postgres, Storage, Realtime), so the
   platform runs unchanged on its own domain. Loaded before the platform's scripts in app.html. */
(function () {
  'use strict';
  var cfg = window.DEALBASIS_CONFIG || {};
  var demo = /[?&]demo=1\b/.test(location.search);
  if (demo) return; /* the sample deal runs entirely in the browser, with no account */
  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey || !window.supabase) {
    document.addEventListener('DOMContentLoaded', function () {
      document.body.innerHTML = '<div style="font:15px/1.5 sans-serif;max-width:560px;margin:80px auto;padding:0 16px"><h1 style="font-size:22px">DealBasis is not configured yet</h1><p>On GitHub, open config.js, click the pencil icon, paste your Supabase Project URL and public key between the quotes, and click Commit changes. The site updates in about a minute.</p></div>';
    });
    return;
  }

  var sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
  window.DEALBASIS_SB = sb;
  var never = new Promise(function () { });
  var me = null, role = null;

  var ready = (async function () {
    var got = await sb.auth.getSession();
    var session = got && got.data && got.data.session;
    if (!session) { location.replace('/?next=' + encodeURIComponent(location.pathname + location.hash)); return never; }
    var j = await sb.rpc('join_workspace');
    if (j.error || !j.data || j.data === 'none' || j.data === 'unconfirmed') { location.replace('/?access=' + encodeURIComponent((j.data) || 'error')); return never; }
    role = j.data;
    var u = session.user, md = u.user_metadata || {};
    var prof = await sb.from('profiles').select('name, avatar_url').eq('id', u.id).maybeSingle();
    me = { id: u.id, name: (prof.data && prof.data.name) || md.full_name || md.name || (u.email || '').split('@')[0], email: u.email || null,
      avatarUrl: (prof.data && prof.data.avatar_url) || md.avatar_url || '', isOwner: role === 'admin', canEdit: role === 'admin' };
    /* the platform opens straight into the workspace for the person signed in here */
    try { sessionStorage.setItem('sorai.session', u.id); } catch (e) { }
    return true;
  })();

  sb.auth.onAuthStateChange(function (event) { if (event === 'SIGNED_OUT') location.replace('/'); });

  /* ---------------- errors, in the codes the platform branches on ---------------- */
  function dbError(e) {
    var msg = (e && e.message) || 'The database did not respond.';
    var x = new Error(msg);
    x.code = (e && e.code === '42501') || /row-level security|permission denied/i.test(msg) ? 'invalid_argument'
      : /JWT|expired|not authenticated/i.test(msg) ? 'revoked'
      : /quota|exceeded|too large|payload/i.test(msg) ? 'quota_exceeded' : 'unavailable';
    return x;
  }
  function assetError(e) {
    var msg = (e && e.message) || 'Storage did not respond.';
    var x = new Error(msg);
    x.code = /exceeded the maximum allowed size|too large|payload/i.test(msg) ? 'too_large' : /quota/i.test(msg) ? 'quota_exceeded'
      : /row-level security|not authorized|permission/i.test(msg) ? 'not_granted' : 'unavailable';
    return x;
  }

  /* ---------------- db: documents keyed by path, live through Realtime ---------------- */
  function freeze(v) { if (v && typeof v === 'object') { Object.freeze(v); Object.keys(v).forEach(function (k) { freeze(v[k]); }); } return v; }
  function copy(v) { return v == null ? v : JSON.parse(JSON.stringify(v)); }
  function parentOf(p) { return p.split('/').slice(0, -1).join('/'); }
  function snapOf(path, data) { return { id: path.split('/').pop(), ref: { path: path }, exists: data != null, data: function () { return data == null ? undefined : freeze(copy(data)); } }; }
  function newId() { var a = new Uint8Array(15), s = '', c = 'abcdefghijklmnopqrstuvwxyz0123456789'; crypto.getRandomValues(a); for (var i = 0; i < a.length; i++) s += c[a[i] % c.length]; return s + Date.now().toString(36).slice(-5); }

  var listeners = {}; var timers = {};
  async function fetchCollection(c) {
    var r = await sb.from('kv').select('path, data').eq('collection', c);
    if (r.error) throw dbError(r.error);
    var docs = r.data.map(function (row) { return snapOf(row.path, row.data); });
    return { docs: docs, size: docs.length, empty: !docs.length };
  }
  function notify(c) {
    var set = listeners[c]; if (!set || !set.length) return;
    clearTimeout(timers[c]);
    timers[c] = setTimeout(async function () {
      try { var snap = await fetchCollection(c); set.slice().forEach(function (l) { try { l.fn(snap); } catch (e) { console.error(e); } }); }
      catch (e) { set.slice().forEach(function (l) { if (l.err) l.err(e); }); }
    }, 80);
  }
  var channel = null;
  function live() {
    if (channel) return;
    channel = sb.channel('dealbasis-kv').on('postgres_changes', { event: '*', schema: 'public', table: 'kv' }, function (payload) {
      var c = (payload.new && payload.new.collection) || (payload.old && payload.old.collection);
      if (c) notify(c); else Object.keys(listeners).forEach(notify);
    }).subscribe();
    /* after the tab sleeps or the connection drops, catch up on anything missed */
    document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') Object.keys(listeners).forEach(notify); });
    window.addEventListener('online', function () { Object.keys(listeners).forEach(notify); });
  }

  function docRef(path) {
    return {
      id: path.split('/').pop(), path: path,
      get: async function () {
        var r = await sb.from('kv').select('data').eq('path', path).maybeSingle();
        if (r.error) throw dbError(r.error);
        return snapOf(path, r.data ? r.data.data : null);
      },
      set: async function (data) {
        var r = await sb.from('kv').upsert({ path: path, collection: parentOf(path), data: copy(data), updated_by: me && me.id, updated_at: new Date().toISOString() });
        if (r.error) throw dbError(r.error);
        notify(parentOf(path));
      },
      update: async function (patch) {
        var cur = await this.get(); var base = cur.exists ? copy(cur.data()) : {};
        Object.keys(patch).forEach(function (k) { var v = patch[k]; if (v && typeof v === 'object' && v.__delete__) delete base[k]; else base[k] = v; });
        return this.set(base);
      },
      delete: async function () {
        var r = await sb.from('kv').delete().eq('path', path);
        if (r.error) throw dbError(r.error);
        notify(parentOf(path));
      },
      onSnapshot: function (fn, err) {
        return collectionRef(parentOf(path)).onSnapshot(function (snap) { var d = snap.docs.find(function (x) { return x.ref.path === path; }); fn(d || snapOf(path, null)); }, err);
      }
    };
  }
  function collectionRef(c) {
    return {
      path: c,
      doc: function (id) { return docRef(c + '/' + (id || newId())); },
      get: function () { return fetchCollection(c); },
      onSnapshot: function (fn, err) {
        live();
        var l = { fn: fn, err: err }; (listeners[c] = listeners[c] || []).push(l);
        fetchCollection(c).then(fn, function (e) { if (err) err(e); });
        return function () { listeners[c] = (listeners[c] || []).filter(function (x) { return x !== l; }); };
      }
    };
  }
  var db = Object.freeze({ collection: collectionRef, doc: docRef });

  /* ---------------- assets: documents and originals in a private Storage bucket ---------------- */
  var BUCKET = 'assets';
  var assets = Object.freeze({
    upload: async function (blob, opts) {
      var id = (crypto.randomUUID ? crypto.randomUUID() : newId()).replace(/-/g, '');
      var type = (opts && opts.type) || blob.type || 'application/octet-stream';
      var r = await sb.storage.from(BUCKET).upload(id, blob, { contentType: type, upsert: false });
      if (r.error) throw assetError(r.error);
      return { id: id, url: '/_blob/' + id, sizeBytes: blob.size, contentType: type };
    },
    list: async function () {
      var all = [], offset = 0;
      for (; ;) {
        var r = await sb.storage.from(BUCKET).list('', { limit: 1000, offset: offset });
        if (r.error) throw assetError(r.error);
        all = all.concat(r.data || []); if (!r.data || r.data.length < 1000) break; offset += 1000;
      }
      var bytes = all.reduce(function (s, o) { return s + ((o.metadata && o.metadata.size) || 0); }, 0);
      return { assets: all.map(function (o) { return { id: o.name, url: '/_blob/' + o.name, sizeBytes: (o.metadata && o.metadata.size) || 0, contentType: (o.metadata && o.metadata.mimetype) || '', createdAt: o.created_at }; }),
        usage: { bytes: bytes, maxBytes: cfg.storageMaxBytes || 1073741824, count: all.length } };
    },
    delete: async function (id) {
      var r = await sb.storage.from(BUCKET).remove([String(id)]);
      if (r.error) throw assetError(r.error);
    }
  });

  /* stored files are fetched by the platform at /_blob/<id>: serve them from Storage with the signed-in person's access */
  var nativeFetch = window.fetch.bind(window);
  window.fetch = async function (input, init) {
    var url = typeof input === 'string' ? input : (input && input.url) || '';
    var m = /^(?:https?:\/\/[^/]+)?\/_blob\/([A-Za-z0-9_-]+)$/.exec(url);
    if (!m || (m[0].indexOf('http') === 0 && url.indexOf(location.origin) !== 0)) return nativeFetch(input, init);
    await ready;
    var r = await sb.storage.from(BUCKET).download(m[1]);
    if (r.error || !r.data) return new Response('Not found', { status: 404 });
    return new Response(r.data, { status: 200, headers: { 'Content-Type': r.data.type || 'application/octet-stream' } });
  };
  /* links to an original open a short-lived signed link */
  document.addEventListener('click', function (e) {
    var a = e.target && e.target.closest && e.target.closest('a[href^="/_blob/"]'); if (!a) return;
    e.preventDefault(); var id = a.getAttribute('href').slice(7); var w = window.open('about:blank', '_blank');
    sb.storage.from(BUCKET).createSignedUrl(id, 300).then(function (r) { if (r.data && r.data.signedUrl && w) w.location.href = r.data.signedUrl; else if (w) w.close(); });
  }, true);

  /* ---------------- user ---------------- */
  var user = Object.freeze({
    me: async function () { await ready; return Object.assign({}, me); },
    id: async function () { await ready; return me.id; },
    isOwner: function () { return role === 'admin'; },
    canEdit: function () { return role === 'admin'; },
    can: async function (name) { await ready; return name === 'data.write' ? role !== 'viewer' : null; },
    profiles: async function (ids) {
      var out = {}; ids = (ids || []).filter(function (x) { return /^[0-9a-f-]{36}$/i.test(x); }); if (!ids.length) return out;
      var r = await sb.from('profiles').select('id, name, email, avatar_url').in('id', ids);
      (r.data || []).forEach(function (p) { out[p.id] = { id: p.id, name: p.name || '', email: p.email || null, avatarUrl: p.avatar_url || '' }; });
      return out;
    },
    search: async function (q) {
      var r = await sb.from('profiles').select('id, name, email, avatar_url').or('name.ilike.%' + String(q || '').replace(/[%,()]/g, '') + '%,email.ilike.%' + String(q || '').replace(/[%,()]/g, '') + '%').limit(20);
      return (r.data || []).map(function (p) { return { id: p.id, name: p.name || '', email: p.email || null, avatarUrl: p.avatar_url || '' }; });
    }
  });

  /* ---------------- downloads: hand the viewer a file ---------------- */
  var downloads = Object.freeze({
    save: async function (req) {
      var data = req.data instanceof Blob ? req.data : new Blob([req.data]);
      var url = URL.createObjectURL(data); var a = document.createElement('a'); a.href = url; a.download = req.filename || 'download';
      document.body.appendChild(a); a.click(); a.remove(); setTimeout(function () { URL.revokeObjectURL(url); }, 30000);
      return { status: 'saved' };
    }
  });

  var caps = { db: db, assets: assets, user: user, downloads: downloads };
  window.claude = Object.freeze({
    use: async function (name) {
      await ready;
      if (name === 'assets' && role === 'viewer') return null; /* viewers read; they never upload */
      return caps[name] || null;
    }
  });

  /* signing out ends the Supabase session too */
  window.addEventListener('load', function () {
    window.signOut = async function () { try { sessionStorage.removeItem('sorai.session'); } catch (e) { } await sb.auth.signOut(); location.replace('/'); };
  });
})();
