// ==UserScript==
// @name         Mojonator Vinted Sync
// @namespace    https://mojolists.com/mojonator-app/
// @version      1.0.1
// @description  Reads your Vinted listings and sold orders and writes them into Mojonator's data.json (mojolists/mojonator) — Vinted channel.
// @author       Mojolists
// @match        https://www.vinted.com/*
// @require      https://mojolists.com/mojonator-app/vinted-merge.js?v=133
// @grant        GM_xmlhttpRequest
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_registerMenuCommand
// @connect      api.github.com
// @run-at       document-idle
// @downloadURL  https://mojolists.com/mojonator-app/vinted-sync.user.js
// @updateURL    https://mojolists.com/mojonator-app/vinted-sync.user.js
// ==/UserScript==
/* MOJO_VINTED_SYNC_V1
   - Runs on vinted.com while you are signed in. Every 30 minutes (and on the ⟳ button) it reads
     your profile listings (/api/v2/wardrobe/<id>/items) and sold orders (/api/v2/my_orders), merges
     them into data.json with vinted-merge.js, and saves with the GitHub token you pasted once.
   - Listing-runner records (localStorage __mojo_vinted_log, and the older __vrun "done" list) give
     exact eBay item number -> Vinted id links; they are picked up within a minute of a listing run.
   - Never writes between :12 and :30 past the hour — the hourly eBay sync commits at :17.
   - Only Vinted fields change; sku/location are never touched. */
(function () {
  'use strict';
  var REPO = 'mojolists/mojonator', BRANCH = 'main', PATH = 'data.json';
  var EVERY_MIN = 30, QUIET_FROM = 12, QUIET_TO = 30;
  var MEMBER = GM_getValue('memberId', '3201332793');
  var busy = false;

  function token() { return GM_getValue('ghToken', ''); }
  function askToken() {
    var t = prompt('Mojonator Vinted Sync\n\nPaste your Mojonator GitHub token (Mojonator → Vinted → "copy it here", or Settings → Copy token):', '');
    if (t && t.trim()) { GM_setValue('ghToken', t.trim()); setBtn('Token saved — syncing…'); run(true); }
  }
  GM_registerMenuCommand('Sync now', function () { run(true); });
  GM_registerMenuCommand('Set GitHub token', askToken);
  GM_registerMenuCommand('Set Vinted member id (now ' + MEMBER + ')', function () {
    var v = prompt('Vinted member id (the number in your profile URL):', MEMBER); if (v && /^\d+$/.test(v.trim())) { GM_setValue('memberId', v.trim()); MEMBER = v.trim(); }
  });

  /* ---- tiny UI: a ⟳ chip bottom-left ---- */
  var btn = document.createElement('div');
  btn.style.cssText = 'position:fixed;left:12px;bottom:12px;z-index:2147483646;background:#0f766e;color:#fff;font:12px/1.3 system-ui,sans-serif;padding:6px 10px;border-radius:16px;box-shadow:0 2px 8px rgba(0,0,0,.25);cursor:pointer;max-width:340px;opacity:.85';
  btn.title = 'Mojonator Vinted Sync — click to sync now';
  btn.textContent = 'Mojo ⟳';
  btn.addEventListener('click', function () { if (!token()) askToken(); else run(true); });
  (document.body || document.documentElement).appendChild(btn);
  function setBtn(t, err) { btn.textContent = 'Mojo ⟳ ' + t; btn.style.background = err ? '#b3261e' : '#0f766e'; }
  var last = GM_getValue('lastResult', '');
  if (last) setBtn(last);

  /* ---- GitHub via GM_xmlhttpRequest (vinted.com's page security blocks direct fetches) ---- */
  function gh(method, url, body, accept) {
    return new Promise(function (resolve, reject) {
      GM_xmlhttpRequest({
        method: method, url: 'https://api.github.com' + url,
        headers: { Authorization: 'Bearer ' + token(), Accept: accept || 'application/vnd.github+json', 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' },
        data: body ? JSON.stringify(body) : undefined,
        timeout: 120000,
        onload: function (r) { resolve({ status: r.status, text: r.responseText }); },
        onerror: function () { reject(new Error('network error talking to GitHub')); },
        ontimeout: function () { reject(new Error('GitHub timed out')); }
      });
    });
  }
  function b64(s) { var bytes = new TextEncoder().encode(s), bin = '', CH = 0x8000; for (var i = 0; i < bytes.length; i += CH) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CH)); return btoa(bin); }
  function readData() {
    return gh('GET', '/repos/' + REPO + '/contents/' + PATH + '?ref=' + BRANCH + '&t=' + Date.now()).then(function (r) {
      if (r.status === 401 || r.status === 403) throw new Error('GitHub refused the token (' + r.status + ') — set it again from the Tampermonkey menu');
      if (r.status !== 200) throw new Error('GitHub read ' + r.status);
      var meta = JSON.parse(r.text);
      if (meta.content && meta.encoding === 'base64') return { sha: meta.sha, data: JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(meta.content.replace(/\s/g, '')), function (c) { return c.charCodeAt(0); }))) };
      return gh('GET', '/repos/' + REPO + '/git/blobs/' + meta.sha, null, 'application/vnd.github.raw+json').then(function (b) {
        if (b.status !== 200) throw new Error('GitHub blob ' + b.status);
        return { sha: meta.sha, data: JSON.parse(b.text) };
      });
    });
  }
  function writeData(sha, data, msg) {
    if (data.settings) data.settings.ghToken = '';
    return gh('PUT', '/repos/' + REPO + '/contents/' + PATH, { message: msg, content: b64(JSON.stringify(data, null, 2)), branch: BRANCH, sha: sha })
      .then(function (r) { return r.status; });
  }

  /* ---- Vinted side ---- */
  function vget(url) {
    return fetch(url, { headers: { accept: 'application/json' }, credentials: 'include' }).then(function (r) {
      if (!r.ok) throw new Error('Vinted ' + r.status + ' on ' + url.split('?')[0]);
      return r.json();
    });
  }
  function runnerLog() {
    var out = [];
    try { out = out.concat(JSON.parse(localStorage.getItem('__mojo_vinted_log') || '[]')); } catch (e) { }
    try { // older listing runner: {done:[{e:ebayItemId, v:vintedId}]}
      var o = JSON.parse(localStorage.getItem('__vrun') || 'null');
      ((o && o.done) || []).forEach(function (d) { if (d && d.v && d.e) out.push({ vintedId: String(d.v), ebayItemId: String(d.e) }); });
    } catch (e) { }
    return out;
  }
  function inQuiet() { var m = new Date().getMinutes(); return m >= QUIET_FROM && m < QUIET_TO; }

  function run(manual) {
    if (busy) return;
    if (!token()) { setBtn('needs token — click', true); return; }
    if (inQuiet()) { setBtn('waiting for eBay sync (:' + QUIET_TO + ')'); if (manual) setTimeout(function () { run(true); }, ((QUIET_TO - new Date().getMinutes()) * 60 + 5) * 1000); return; }
    busy = true; setBtn('reading Vinted…');
    var snapP = window.MojoVinted ? MojoVinted.collect(vget, MEMBER, runnerLog()) : Promise.reject(new Error('vinted-merge.js missing'));
    snapP.then(function (snap) {
      var attempt = 0;
      function once() {
        attempt++; setBtn('saving to Mojonator…');
        return readData().then(function (got) {
          var rep = MojoVinted.merge(got.data, snap, { by: 'userscript' });
          if (!rep.changed) return rep;
          var msg = 'Vinted sync: ' + (rep.runnerLinked + rep.autoLinked.length) + ' linked, ' + rep.pending.length + ' to confirm, ' + rep.newSales.length + ' new sale(s), ' + rep.updated + ' updated';
          return writeData(got.sha, got.data, msg).then(function (st) {
            if (st === 409 || st === 422) { if (attempt < 3) return new Promise(function (r) { setTimeout(r, 2000); }).then(once); throw new Error('data.json kept changing'); }
            if (st !== 200 && st !== 201) throw new Error('GitHub write ' + st);
            return rep;
          });
        });
      }
      return once();
    }).then(function (rep) {
      GM_setValue('lastRun', Date.now());
      GM_setValue('runnerSeen', runnerLog().length);
      var t = new Date().toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
      var s = rep.changed ? (t + ' · ' + (rep.runnerLinked + rep.autoLinked.length ? (rep.runnerLinked + rep.autoLinked.length) + ' linked · ' : '') + (rep.newSales.length ? rep.newSales.length + ' sold · ' : '') + (rep.pending.length ? rep.pending.length + ' to confirm · ' : '') + 'saved') : (t + ' · up to date');
      GM_setValue('lastResult', s); setBtn(s);
      // trim runner records older than 30 days (merge is idempotent, this just keeps storage small)
      try { var lg = JSON.parse(localStorage.getItem('__mojo_vinted_log') || '[]'); var cut = Date.now() - 30 * 864e5; localStorage.setItem('__mojo_vinted_log', JSON.stringify(lg.filter(function (x) { return !x.listedAt || Date.parse(x.listedAt) > cut; }))); } catch (e) { }
    }).catch(function (e) {
      setBtn('failed: ' + e.message, true); GM_setValue('lastResult', '');
    }).then(function () { busy = false; });
  }

  // first run on load if due; then check every minute (due time, or new listing-runner records)
  setTimeout(function () {
    var due = Date.now() - GM_getValue('lastRun', 0) > EVERY_MIN * 60000;
    if (due) run(false);
  }, 4000);
  setInterval(function () {
    var due = Date.now() - GM_getValue('lastRun', 0) > EVERY_MIN * 60000;
    var newRunner = runnerLog().length !== GM_getValue('runnerSeen', -1);
    if (due || newRunner) run(false);
  }, 60000);
})();
