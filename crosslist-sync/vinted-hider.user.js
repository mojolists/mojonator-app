// ==UserScript==
// @name         Mojo Crosslist - Vinted hider
// @namespace    https://mojolists.com/
// @version      0.3.0
// @description  Hides a Vinted listing when the Crosslist Sync program on this PC says its twin sold on eBay, and keeps Mojonator's Vinted links and cross-listed marks up to date.
// @match        https://www.vinted.com/*
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @connect      api.github.com
// @require      https://mojolists.com/mojonator-app/vinted-merge.js?v=138
// @run-at       document-idle
// @updateURL    https://raw.githubusercontent.com/mojolists/mojonator-app/main/crosslist-sync/vinted-hider.user.js
// @downloadURL  https://raw.githubusercontent.com/mojolists/mojonator-app/main/crosslist-sync/vinted-hider.user.js
// ==/UserScript==
/* Runs only in the top window of a signed-in vinted.com tab. Every 3 minutes it asks the local program
   (http://127.0.0.1:8765) for listings to hide, hides each with Vinted's own request
   (PUT /api/v2/items/{id}/is_hidden), checks the listing really is hidden, and reports back.
   In watch-only mode the program hands it nothing, so it only checks in.
   One tab does the work at a time (a lock in localStorage), and it stops on any Vinted check page.
   0.3.0: the same tab also keeps Mojonator's Vinted links and cross-listed marks current - see mojoSync() below. */
(function () {
  'use strict';
  if (window.top !== window.self) return;
  var BASE = 'http://127.0.0.1:8765', EVERY = 3 * 60 * 1000, LOCK = '__mojo_hider_lock', MEMBER = '3201332793';
  var me = Math.random().toString(36).slice(2);

  function local(method, path, body) {
    return new Promise(function (res, rej) {
      setTimeout(function () { rej(new Error('program did not answer')); }, 25000); // a stale tab may never get an answer at all
      GM_xmlhttpRequest({ method: method, url: BASE + path, data: body ? JSON.stringify(body) : undefined,
        headers: { 'Content-Type': 'application/json' }, timeout: 15000,
        onload: function (r) { try { res(JSON.parse(r.responseText)); } catch (e) { rej(e); } },
        onerror: function () { rej(new Error('program not reachable')); }, ontimeout: function () { rej(new Error('program timeout')); } });
    });
  }
  function csrf() { var m = document.documentElement.outerHTML.match(/CSRF_TOKEN\\?"[:,]\\?"([0-9a-f-]{36})/); return m ? m[1] : ''; }
  function anon() { var m = document.cookie.match(/anon_id=([^;]+)/); return m ? m[1] : ''; }
  function hdrs() { return { 'Accept': 'application/json', 'Content-Type': 'application/json', 'X-CSRF-Token': csrf(), 'X-Anon-Id': anon() }; }
  /* 0.1.1: a tab left open for hours has an expired Vinted login pass, and Vinted answers 401. Ask Vinted for a new
     pass (the same request the site itself makes) and try once more. If that fails the account is really signed out. */
  async function vfetch(url, opt) {
    var r = await fetch(url, opt);
    if (r.status !== 401) return r;
    var f = await fetch('/web/api/auth/refresh', { method: 'POST', headers: hdrs() });
    if (!f.ok) throw new Error('signed out of Vinted (login refresh ' + f.status + ') - sign in again in this Chrome');
    return fetch(url, opt);
  }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function haveLock() {
    try {
      var l = JSON.parse(localStorage.getItem(LOCK) || 'null'), t = Date.now();
      if (l && l.id !== me && t - l.at < EVERY * 1.5) return false;
      localStorage.setItem(LOCK, JSON.stringify({ id: me, at: t })); return true;
    } catch (e) { return true; }
  }
  async function isHidden(id) {
    for (var p = 1; p < 12; p++) {
      var r = await vfetch('/api/v2/wardrobe/' + MEMBER + '/items?page=' + p + '&per_page=96&order=newest_first', { headers: { accept: 'application/json' } });
      if (!r.ok) throw new Error('wardrobe ' + r.status);
      var j = await r.json(), items = j.items || [];
      for (var i = 0; i < items.length; i++) if (String(items[i].id) === String(id)) return items[i].is_hidden ? 'hidden' : (items[i].is_closed ? 'closed' : 'visible');
      if (!items.length || p >= ((j.pagination || {}).total_pages || 1)) break;
    }
    return 'gone';
  }
  async function hide(id) {
    var token = csrf(); if (!token) throw new Error('not signed in to Vinted (no page token)');
    var before = await isHidden(id); // 0.2.0: look first - the other PC (or Doug) may already have dealt with it
    if (before !== 'visible') return { st: before, acted: false };
    var r = await vfetch('/api/v2/items/' + id + '/is_hidden', { method: 'PUT', headers: hdrs(),
      body: JSON.stringify({ is_hidden: true }) });
    if (r.status === 403 || r.status === 429) throw new Error('Vinted refused (' + r.status + ') - possible check page');
    if (!r.ok && r.status !== 404) throw new Error('hide HTTP ' + r.status);
    var st = await isHidden(id);
    if (st === 'visible') throw new Error('still visible after hide');
    return { st: st, acted: true }; // hidden | closed (sold on Vinted) | gone (deleted)
  }
  /* 0.2.1: a tab left open for a long time can stop talking to the program (the page goes stale, or Chrome or
     Tampermonkey updates under it) and only a refresh fixed it. So the tab now refreshes itself: every ~30 minutes,
     or sooner if it cannot reach the program twice in a row. Never while a hide is running, never while Doug is
     using the tab (mouse/keys in the last 10 minutes on a visible tab), never on a listing form. */
  var loaded = Date.now(), lastInput = 0, busy = false, misses = 0, holder = false, RELOAD_EVERY = (28 + Math.random() * 6) * 60 * 1000;
  ['mousedown', 'keydown', 'wheel', 'touchstart'].forEach(function (ev) { window.addEventListener(ev, function () { lastInput = Date.now(); }, { passive: true, capture: true }); });
  async function maybeReload() {
    if (busy || !holder) return; // only the one tab doing the work refreshes itself
    var age = Date.now() - loaded;
    if (!(age > RELOAD_EVERY || (misses >= 2 && age > 12 * 60 * 1000))) return;
    if (/\/items\/(new|\d+\/edit)|\/inbox|\/checkout/.test(location.pathname)) return;
    if (!document.hidden && Date.now() - lastInput < 10 * 60 * 1000) return;
    try { var r = await fetch('/api/v2/wardrobe/' + MEMBER + '/items?page=1&per_page=1', { headers: { accept: 'application/json' } }); if (r.status >= 500) return; }
    catch (e) { return; } // Vinted or the internet is down right now: a refresh would land on an error page, so wait
    location.reload();
  }
  async function tick() {
    try { await tick2(); } finally { busy = false; maybeReload(); }
  }
  async function tick2() {
    holder = haveLock(); if (!holder) return;
    var q;
    try { q = await local('GET', '/queue'); misses = 0; } catch (e) { misses++; return; } // program not reachable
    busy = true;
    var list = (q && q.queue) || [];
    for (var i = 0; i < list.length; i++) {
      var it = list[i];
      try { var h = await hide(it.vintedId), st = h.st; await local('POST', '/done', { vintedId: it.vintedId, ok: st !== 'closed', acted: h.acted, detail: st === 'closed' ? 'already SOLD on Vinted' : st }); }
      catch (e) { try { await local('POST', '/done', { vintedId: it.vintedId, ok: false, detail: String(e.message || e) }); } catch (e2) {} break; } // stop on the first failure
      await sleep(20000 + Math.random() * 20000); // unhurried, like a person
    }
    try { await mojoSync(); } catch (e) {} // 0.3.0
  }
  /* ---- 0.3.0 (2026-11-17): keep Mojonator's Vinted links and "eBay + Vinted" marks current, from this always-open tab.
     Why: Mojonator only learned about Vinted listings when its own sync was run, and that had not happened since Nov 8.
     A cassette then sold on Vinted with a twin live on eBay and the program had nothing to go on.
     Every 15 minutes this reads the profile (listings + sold orders), tells the local program what is on Vinted, and - when
     something changed - runs Mojonator's own Vinted sync (vinted-merge.js syncAll: links new listings, marks items live on
     both sites) and saves data.json with the GitHub token from the program's config.json. The backup PC gives the main PC
     20 minutes to do it first. Nothing is written between :12 and :30 (the hourly eBay sync commits at :17). */
  var SYNC_EVERY = 15 * 60 * 1000, XKEY = '__mojo_xsync';
  function lget(k, d) { try { var v = JSON.parse(localStorage.getItem(k) || 'null'); return v == null ? d : v; } catch (e) { return d; } }
  function lset(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }
  async function vget(url) { var r = await vfetch(url, { headers: { accept: 'application/json' }, credentials: 'include' }); if (!r.ok) throw new Error('Vinted ' + r.status + ' on ' + url.split('?')[0]); return r.json(); }
  function runnerLog() {
    var out = lget('__mojo_vinted_log', []).slice();
    var o = lget('__vrun', null);
    ((o && o.done) || []).forEach(function (d) { if (d && d.v && d.e && !/^draft:/.test(String(d.e))) out.push({ vintedId: String(d.v), ebayItemId: String(d.e) }); });
    return out;
  }
  function gh(token, method, url, body, accept) {
    return new Promise(function (resolve, reject) {
      GM_xmlhttpRequest({ method: method, url: 'https://api.github.com' + url,
        headers: { Authorization: 'Bearer ' + token, Accept: accept || 'application/vnd.github+json', 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' },
        data: body ? JSON.stringify(body) : undefined, timeout: 120000,
        onload: function (r) { resolve({ status: r.status, text: r.responseText }); },
        onerror: function () { reject(new Error('network error talking to GitHub')); }, ontimeout: function () { reject(new Error('GitHub timed out')); } });
    });
  }
  function b64(str) { var bytes = new TextEncoder().encode(str), bin = '', CH = 0x8000; for (var i = 0; i < bytes.length; i += CH) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CH)); return btoa(bin); }
  async function readData(cfg) {
    var r = await gh(cfg.token, 'GET', '/repos/' + cfg.repo + '/contents/data.json?ref=main&t=' + Date.now());
    if (r.status !== 200) throw new Error('GitHub read ' + r.status);
    var meta = JSON.parse(r.text);
    if (meta.content && meta.encoding === 'base64') return { sha: meta.sha, data: JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(meta.content.replace(/\s/g, '')), function (c) { return c.charCodeAt(0); }))) };
    var b = await gh(cfg.token, 'GET', '/repos/' + cfg.repo + '/git/blobs/' + meta.sha, null, 'application/vnd.github.raw+json');
    if (b.status !== 200) throw new Error('GitHub blob ' + b.status);
    return { sha: meta.sha, data: JSON.parse(b.text) };
  }
  async function pushMojonator(cfg, snap) {
    for (var attempt = 1; attempt <= 3; attempt++) {
      var got = await readData(cfg);
      var rep = MojoVinted.syncAll(got.data, snap, { by: 'crosslist helper' });
      if (!rep.changed) return rep;
      if (got.data.settings) got.data.settings.ghToken = '';
      var msg = 'Vinted sync (crosslist helper): ' + (rep.runnerLinked + rep.autoLinked.length) + ' linked, ' + rep.crossMarked.length + ' marked eBay + Vinted, ' + rep.pending.length + ' to confirm, ' + rep.newSales.length + ' new sale(s)';
      var w = await gh(cfg.token, 'PUT', '/repos/' + cfg.repo + '/contents/data.json', { message: msg, content: b64(JSON.stringify(got.data, null, 2)), branch: 'main', sha: got.sha });
      if (w.status === 200 || w.status === 201) return rep;
      if (w.status !== 409 && w.status !== 422) throw new Error('GitHub write ' + w.status);
      await sleep(3000);
    }
    throw new Error('data.json kept changing');
  }
  function hashOf(snap) {
    var s = JSON.stringify([snap.wardrobe.map(function (o) { return [o.id, o.title, o.price, o.closed, o.hidden, o.reserved]; }), (snap.orders || []).map(function (o) { return [o.txId, o.status]; }), (snap.runner || []).length]);
    var h = 0; for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
    return String(h) + ':' + s.length;
  }
  async function mojoSync() {
    var st = lget(XKEY, {});
    if (Date.now() - (st.at || 0) < SYNC_EVERY) return;
    if (typeof MojoVinted === 'undefined' || !MojoVinted.syncAll) return;
    if (/\/items\/(new|\d+\/edit)|\/checkout/.test(location.pathname)) return;
    st.at = Date.now(); lset(XKEY, st);
    var snap = await MojoVinted.collect(vget, MEMBER, runnerLog());
    snap.vintedOnly = lget('__mojo_vinted_only_log', []);
    if (!snap.wardrobe.length) return;
    var out = { items: snap.wardrobe.map(function (o) { return { id: o.id, title: o.title, closed: o.closed, hidden: o.hidden, url: o.url, photos: o.photos }; }) };
    var cfg = null; try { cfg = await local('GET', '/ghtoken'); } catch (e) {}
    var hash = hashOf(snap), need = hash !== st.hash || Date.now() - (st.synced || 0) > 12 * 3600 * 1000;
    if (cfg && cfg.token && cfg.repo && need) {
      if (hash !== st.pendingHash) { st.pendingHash = hash; st.pendingSince = Date.now(); }
      var wait = cfg.role === 'backup' ? 20 * 60 * 1000 : 0, min = new Date().getMinutes();
      if (Date.now() - st.pendingSince >= wait && !(min >= 12 && min < 30)) {
        try {
          var rep = await pushMojonator(cfg, snap);
          st.hash = hash; st.synced = Date.now();
          out.sync = (rep.changed ? 'saved' : 'up to date') + ': ' + rep.listings + ' listings, ' + (rep.runnerLinked + rep.autoLinked.length) + ' linked, ' + rep.crossMarked.length + ' marked eBay + Vinted, ' + rep.pending.length + ' to confirm, ' + rep.newSales.length + ' new sale(s)';
          out.marked = rep.crossMarked; out.unsure = rep.unsure;
        } catch (e) { out.sync = 'FAILED ' + String(e.message || e); }
      }
    }
    lset(XKEY, st);
    try { await local('POST', '/wardrobe', out); } catch (e) {}
  }
  setTimeout(tick, 15000); setInterval(tick, EVERY);
})();
