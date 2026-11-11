// ==UserScript==
// @name         Mojo Crosslist - Vinted hider
// @namespace    https://mojolists.com/
// @version      0.1.0
// @description  Hides a Vinted listing when the Crosslist Sync program on this PC says its twin sold on eBay.
// @match        https://www.vinted.com/*
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @run-at       document-idle
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
      GM_xmlhttpRequest({ method: method, url: BASE + path, data: body ? JSON.stringify(body) : undefined,
        headers: { 'Content-Type': 'application/json' }, timeout: 15000,
        onload: function (r) { try { res(JSON.parse(r.responseText)); } catch (e) { rej(e); } },
        onerror: function () { rej(new Error('program not reachable')); }, ontimeout: function () { rej(new Error('program timeout')); } });
    });
  }
  function csrf() { var m = document.documentElement.outerHTML.match(/CSRF_TOKEN\\?"[:,]\\?"([0-9a-f-]{36})/); return m ? m[1] : ''; }
  function anon() { var m = document.cookie.match(/anon_id=([^;]+)/); return m ? m[1] : ''; }
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
      var r = await fetch('/api/v2/wardrobe/' + MEMBER + '/items?page=' + p + '&per_page=96&order=newest_first', { headers: { accept: 'application/json' } });
      if (!r.ok) throw new Error('wardrobe ' + r.status);
      var j = await r.json(), items = j.items || [];
      for (var i = 0; i < items.length; i++) if (String(items[i].id) === String(id)) return items[i].is_hidden ? 'hidden' : (items[i].is_closed ? 'closed' : 'visible');
      if (!items.length || p >= ((j.pagination || {}).total_pages || 1)) break;
    }
    return 'gone';
  }
  async function hide(id) {
    var token = csrf(); if (!token) throw new Error('not signed in to Vinted (no page token)');
    var r = await fetch('/api/v2/items/' + id + '/is_hidden', { method: 'PUT',
      headers: { 'Accept': 'application/json', 'Content-Type': 'application/json', 'X-CSRF-Token': token, 'X-Anon-Id': anon() },
      body: JSON.stringify({ is_hidden: true }) });
    if (r.status === 403 || r.status === 429) throw new Error('Vinted refused (' + r.status + ') - possible check page');
    if (!r.ok && r.status !== 404) throw new Error('hide HTTP ' + r.status);
    var st = await isHidden(id);
    if (st === 'visible') throw new Error('still visible after hide');
    return st; // hidden | closed (sold on Vinted) | gone (deleted)
  }
  async function tick() {
    if (!haveLock()) return;
    var q;
    try { q = await local('GET', '/queue'); } catch (e) { return; } // program not running: nothing to do
    var list = (q && q.queue) || [];
    for (var i = 0; i < list.length; i++) {
      var it = list[i];
      try { var st = await hide(it.vintedId); await local('POST', '/done', { vintedId: it.vintedId, ok: st !== 'closed', detail: st === 'closed' ? 'already SOLD on Vinted' : st }); }
      catch (e) { try { await local('POST', '/done', { vintedId: it.vintedId, ok: false, detail: String(e.message || e) }); } catch (e2) {} break; } // stop on the first failure
      await sleep(20000 + Math.random() * 20000); // unhurried, like a person
    }
  }
  setTimeout(tick, 15000); setInterval(tick, EVERY);
})();
