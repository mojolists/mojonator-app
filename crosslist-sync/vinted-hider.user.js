// ==UserScript==
// @name         Mojo Crosslist - Vinted hider
// @namespace    https://mojolists.com/
// @version      0.2.1
// @description  Hides a Vinted listing when the Crosslist Sync program on this PC says its twin sold on eBay.
// @match        https://www.vinted.com/*
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @run-at       document-idle
// @updateURL    https://raw.githubusercontent.com/mojolists/mojonator-app/main/crosslist-sync/vinted-hider.user.js
// @downloadURL  https://raw.githubusercontent.com/mojolists/mojonator-app/main/crosslist-sync/vinted-hider.user.js
// ==/UserScript==
/* Runs only in the top window of a signed-in vinted.com tab. Every 3 minutes it asks the local program
   (http://127.0.0.1:8765) for listings to hide, hides each with Vinted's own request
   (PUT /api/v2/items/{id}/is_hidden), checks the listing really is hidden, and reports back.
   In watch-only mode the program hands it nothing, so it only checks in.
   One tab does the work at a time (a lock in localStorage), and it stops on any Vinted check page. */
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
  }
  setTimeout(tick, 15000); setInterval(tick, EVERY);
})();
