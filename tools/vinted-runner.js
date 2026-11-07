/* MOJO VINTED RUNNER v1 — saved 2026-11-07 (the low-token eBay -> Vinted listing route, proven 2026-11-06/07).
   Runs inside Doug's signed-in vinted.com tab (his Chrome). Posts straight to Vinted's own API — no clicking
   through the form — one listing per minute, and keeps its progress in localStorage so a run survives the
   tool call that started it and can be resumed.

   LOAD (one call):  inject this file's text into the vinted.com tab (or let the userscript @require it).
   RUN:              MojoVintedRunner.start(jobs)            -> starts in the background, returns at once
   CHECK (once, at the end):  MojoVintedRunner.status()       -> {done, errors, left, finished}
   AFTER:            MojoVintedRunner.dupCheck()              -> duplicate active titles on the profile
                     then end the eBay listings in ONE call:  python3 ebaytrade.py end <ids...>  (tools/ebaytrade.py)
                     then the pull sheet (by eBay SKU/crate).

   job = { ebayItemId:'3667…', title:'…', description:'…', price:3, condition:'very good'|'good'|'new',
           media:'CD'|'DVD'|'Blu-ray'|'Cassette', catalogId:3039 (optional override), photos:['https://i.ebayimg.com/…'] }
   Rules baked in (Doug's standing rules for Vinted runs):
     - photos in the order given — put the FRONT cover first; every photo gets the auto-crop
     - Vinted has no "Like New" for used: like new / very good -> Very good (2); good -> Good (3); sealed/new -> New with tags (6)
     - package size Small (1); price as given (he sets it); at most one listing per minute (default 60 s)
     - results: localStorage '__vrun' {done:[{e,v,n}],errors:[…]} (read by the Mojonator Vinted Sync userscript)
       and '__mojo_vinted_log' [{vintedId, ebayItemId, title, price, listedAt}] — the sync links each new
       listing to its Mojonator item by eBay item number within a minute (decision 4: written at list time).
   Description style he accepted: eBay title as first line + UPC + tracklist + "Original case with front and back inserts." */
(function () {
  'use strict';
  var CATALOG = { CD: 3039 };            // DVD / Blu-ray / Cassette: capture once with captureCatalog(), then add here
  var COND = { 'new': 6, 'new with tags': 6, 'sealed': 6, 'like new': 2, 'very good': 2, 'good': 3 };
  var PACE_MS = 60000;
  var RUN_KEY = '__vrun', LOG_KEY = '__mojo_vinted_log', CAP_KEY = '__vcap';
  var timer = null;

  function load(k, d) { try { var v = JSON.parse(localStorage.getItem(k) || 'null'); return v == null ? d : v; } catch (e) { return d; } }
  function saveK(k, v) { localStorage.setItem(k, JSON.stringify(v)); }
  function uuid() { return (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx'.replace(/x/g, function () { return (Math.random() * 16 | 0).toString(16); })); }
  function csrf() { var m = document.documentElement.outerHTML.match(/CSRF_TOKEN\\?"[:,]\\?"([0-9a-f-]{36})/); return m ? m[1] : ''; }
  function anon() { var m = document.cookie.match(/(?:^|;\s*)anon_id=([^;]+)/); return m ? decodeURIComponent(m[1]) : ''; }
  function headers(json) {
    var h = { 'Accept': 'application/json, text/plain, */*', 'X-CSRF-Token': csrf(), 'X-Upload-Form': 'true', 'Locale': 'en-US' };
    var a = anon(); if (a) h['X-Anon-Id'] = a;
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  /* ---- auto-crop: strip the eBay backdrop. Edge map (Sobel) on a 400 px copy, keep the box that holds the
     real edge mass (rows/cols with >=2% edge pixels), +1% margin; keep the original if the box is under 25%
     of the frame (same rule as the Canny/contour crop used on the 2026-11-06 runs). */
  function cropBlob(blob) {
    return createImageBitmap(blob).then(function (bmp) {
      var W = bmp.width, H = bmp.height, s = Math.min(1, 400 / Math.max(W, H)), w = Math.max(8, Math.round(W * s)), h = Math.max(8, Math.round(H * s));
      var c = document.createElement('canvas'); c.width = w; c.height = h; var x = c.getContext('2d'); x.drawImage(bmp, 0, 0, w, h);
      var d = x.getImageData(0, 0, w, h).data, g = new Float32Array(w * h);
      for (var i = 0; i < w * h; i++) g[i] = 0.299 * d[i * 4] + 0.587 * d[i * 4 + 1] + 0.114 * d[i * 4 + 2];
      var rows = new Uint32Array(h), cols = new Uint32Array(w), TH = 90;
      for (var yy = 1; yy < h - 1; yy++) for (var xx = 1; xx < w - 1; xx++) {
        var p = yy * w + xx;
        var gx = g[p - w + 1] + 2 * g[p + 1] + g[p + w + 1] - g[p - w - 1] - 2 * g[p - 1] - g[p + w - 1];
        var gy = g[p + w - 1] + 2 * g[p + w] + g[p + w + 1] - g[p - w - 1] - 2 * g[p - w] - g[p - w + 1];
        if (Math.abs(gx) + Math.abs(gy) > TH) { rows[yy]++; cols[xx]++; }
      }
      var rMin = Math.max(2, w * 0.02), cMin = Math.max(2, h * 0.02), t = 0, b = h - 1, l = 0, r = w - 1;
      while (t < h && rows[t] < rMin) t++; while (b > t && rows[b] < rMin) b--;
      while (l < w && cols[l] < cMin) l++; while (r > l && cols[r] < cMin) r--;
      var box = { keep: true, W: W, H: H };
      if (t < b && l < r && (b - t) * (r - l) >= 0.25 * w * h) {
        var mx = Math.round(w * 0.01), my = Math.round(h * 0.01);
        t = Math.max(0, t - my); b = Math.min(h - 1, b + my); l = Math.max(0, l - mx); r = Math.min(w - 1, r + mx);
        box = { keep: false, x: Math.round(l / s), y: Math.round(t / s), w: Math.round((r - l + 1) / s), h: Math.round((b - t + 1) / s), W: W, H: H };
      }
      if (box.keep) return { blob: blob, box: box };
      var o = document.createElement('canvas'); o.width = Math.min(box.w, W - box.x); o.height = Math.min(box.h, H - box.y);
      o.getContext('2d').drawImage(bmp, box.x, box.y, o.width, o.height, 0, 0, o.width, o.height);
      return new Promise(function (res) { o.toBlob(function (bb) { res({ blob: bb || blob, box: box }); }, 'image/jpeg', 0.92); });
    });
  }
  function bigEbay(u) { return String(u).replace(/s-l\d+(\.\w+)$/, 's-l1600$1'); }

  function uploadPhoto(url, i, tempUuid) {
    return fetch(bigEbay(url)).then(function (r) { if (!r.ok) throw new Error('photo ' + r.status); return r.blob(); })
      .then(cropBlob).then(function (c) {
        var fd = new FormData();
        fd.append('photo[type]', 'item'); fd.append('photo[file]', new File([c.blob], 'p' + i + '.jpg', { type: 'image/jpeg' })); fd.append('photo[temp_uuid]', tempUuid);
        return fetch('/api/v2/photos', { method: 'POST', headers: headers(false), body: fd, credentials: 'include' });
      }).then(function (r) { return r.text().then(function (t) { if (!r.ok) throw new Error('photo upload ' + r.status + (/<html/i.test(t) ? ' (Vinted check page — stop and let Doug clear it)' : '')); return JSON.parse(t); }); });
  }

  function listOne(job) {
    var media = job.media || 'CD', cat = job.catalogId || CATALOG[media];
    if (!cat) return Promise.reject(new Error('no Vinted catalog id for ' + media + ' — run captureCatalog() once'));
    var cond = COND[String(job.condition || 'very good').toLowerCase()];
    if (!cond) return Promise.reject(new Error('unknown condition "' + job.condition + '"'));
    if (!job.photos || !job.photos.length) return Promise.reject(new Error('no photos'));
    var tu = uuid(), ids = [];
    return job.photos.reduce(function (p, u, i) { return p.then(function () { return uploadPhoto(u, i, tu).then(function (j) { ids.push(j.id); }); }); }, Promise.resolve())
      .then(function () {
        var body = { item: { id: null, currency: 'USD', temp_uuid: tu, title: job.title, description: job.description, brand_id: null, brand: null, catalog_id: cat, isbn: null, ai_photo: false,
          price: String(Number(job.price).toFixed(2)), package_size_id: 1, shipment_prices: { domestic: null }, color_ids: [],
          assigned_photos: ids.map(function (id) { return { id: id, orientation: 0, ai_detected: false, digital_source_type: [], c2pa_read_error: 'other' }; }),
          measurement_length: null, measurement_width: null, item_attributes: [{ code: 'condition', ids: [cond] }], manufacturer: null, manufacturer_labelling: null },
          push_up: false, parcel: null, upload_session_id: tu };
        return fetch('/api/v2/item_upload/items', { method: 'POST', headers: headers(true), body: JSON.stringify(body), credentials: 'include' });
      }).then(function (r) { return r.text().then(function (t) { var j; try { j = JSON.parse(t); } catch (e) { throw new Error('create ' + r.status + ' (not JSON — Vinted check page?)'); } if (!r.ok || !j.item || !j.item.id) throw new Error('create ' + r.status + ' ' + t.slice(0, 160)); return { id: j.item.id, n: ids.length }; }); });
  }

  function step() {
    var st = load(RUN_KEY, null); if (!st || st.stopped || st.finished || !Array.isArray(st.jobs)) return;
    var doneIds = {}; (st.done || []).forEach(function (d) { doneIds[d.e] = 1; }); (st.errors || []).forEach(function (d) { doneIds[d.e] = 1; });
    var job = (st.jobs || []).filter(function (j) { return !doneIds[j.ebayItemId]; })[0];
    if (!job) { st.finished = new Date().toISOString(); st.current = null; saveK(RUN_KEY, st); return; }
    st.current = job.ebayItemId; st.heartbeat = new Date().toISOString(); saveK(RUN_KEY, st);
    listOne(job).then(function (res) {
      var s2 = load(RUN_KEY, st); s2.done = s2.done || []; s2.done.push({ e: job.ebayItemId, v: res.id, n: res.n }); s2.current = null; saveK(RUN_KEY, s2);
      var lg = load(LOG_KEY, []); lg.push({ vintedId: String(res.id), ebayItemId: String(job.ebayItemId), title: job.title, price: Number(job.price), listedAt: new Date().toISOString() }); saveK(LOG_KEY, lg);
      timer = setTimeout(step, PACE_MS);
    }).catch(function (e) {
      var s2 = load(RUN_KEY, st); s2.errors = s2.errors || []; s2.current = null;
      var fatal = /check page|not JSON|401|403|429/.test(e.message);
      s2.errors.push({ e: job.ebayItemId, title: job.title, msg: e.message, fatal: fatal });
      if (fatal) { s2.stopped = 'stopped on: ' + e.message + ' — clear Vinted\'s check, then MojoVintedRunner.resume()'; s2.errors.pop(); s2.lastError = e.message; }
      saveK(RUN_KEY, s2);
      if (!fatal) timer = setTimeout(step, PACE_MS);
    });
  }

  var api = {
    version: 'v1',
    /* Start a run. Jobs already done in the current __vrun are skipped, so calling start() again with the
       same list resumes. Pass {fresh:true} to begin a new run (the old __vrun is kept under __vrun_prev). */
    start: function (jobs, opts) {
      opts = opts || {};
      var st = load(RUN_KEY, null);
      if (opts.fresh || !st || st.finished || !Array.isArray(st.jobs)) { if (st) saveK(RUN_KEY + '_prev', st); st = { started: new Date().toISOString(), jobs: [], done: [], errors: [] }; }
      var have = {}; st.jobs.forEach(function (j) { have[j.ebayItemId] = 1; });
      (jobs || []).forEach(function (j) { if (!have[j.ebayItemId]) st.jobs.push(j); });
      delete st.stopped; delete st.finished; saveK(RUN_KEY, st);
      clearTimeout(timer); step();
      return { queued: st.jobs.length, done: st.done.length, etaMin: Math.max(0, st.jobs.length - st.done.length - st.errors.length) * PACE_MS / 60000 };
    },
    resume: function () { var st = load(RUN_KEY, null); if (!st) return 'nothing to resume'; delete st.stopped; saveK(RUN_KEY, st); clearTimeout(timer); step(); return 'resumed'; },
    stop: function () { clearTimeout(timer); var st = load(RUN_KEY, null); if (st) { st.stopped = 'stopped by hand'; saveK(RUN_KEY, st); } return 'stopped'; },
    /* Compact status — read this ONCE at the end of a run. */
    status: function () {
      var st = load(RUN_KEY, null); if (!st) return { none: true };
      var jobs = st.jobs || [], done = st.done || [], errs = st.errors || [];
      var left = jobs.length - done.length - errs.length;
      return { started: st.started, finished: st.finished || null, stopped: st.stopped || null, left: left, current: st.current || null,
        done: done.map(function (d) { return d.e + '>' + d.v; }), errors: errs.map(function (e) { return e.e + ': ' + e.msg; }) };
    },
    /* After a run: duplicate active titles on the profile (Doug asked for this after every run). */
    dupCheck: function (memberId) {
      memberId = memberId || '3201332793'; var all = [];
      function page(p) { return fetch('/api/v2/wardrobe/' + memberId + '/items?page=' + p + '&per_page=96&order=newest_first', { headers: { accept: 'application/json' } }).then(function (r) { return r.json(); }).then(function (j) { all = all.concat(j.items || []); var tp = (j.pagination && j.pagination.total_pages) || 1; if (p < tp) return page(p + 1); }); }
      return page(1).then(function () {
        var by = {}; all.filter(function (o) { return !o.is_closed; }).forEach(function (o) { var k = o.title.toLowerCase().replace(/\s+/g, ' ').trim(); (by[k] = by[k] || []).push(o.id); });
        return Object.keys(by).filter(function (k) { return by[k].length > 1; }).map(function (k) { return { title: k, ids: by[k] }; });
      });
    },
    /* One-time: list ONE DVD (or Blu-ray/cassette) by hand through Vinted's form; this records the catalog_id
       it sends (survives the page reload after Upload) in localStorage '__vcap'. Then add it to CATALOG above. */
    captureCatalog: function () {
      var of = window.fetch;
      window.fetch = function (u, o) { try { if (/item_upload\/items/.test(String(u)) && o && o.body) { var b = JSON.parse(o.body); var c = load(CAP_KEY, []); c.push({ at: new Date().toISOString(), title: b.item.title, catalog_id: b.item.catalog_id, package_size_id: b.item.package_size_id }); saveK(CAP_KEY, c); } } catch (e) { } return of.apply(this, arguments); };
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__u = u; return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function (b) { try { if (/item_upload\/items/.test(String(this.__u)) && b) { var j = JSON.parse(b); var c = load(CAP_KEY, []); c.push({ at: new Date().toISOString(), title: j.item.title, catalog_id: j.item.catalog_id, package_size_id: j.item.package_size_id }); saveK(CAP_KEY, c); } } catch (e) { } return os.apply(this, arguments); };
      return 'capturing — submit one listing through the Vinted form, then read localStorage __vcap';
    },
    /* Check the crop on one photo without listing anything. */
    cropTest: function (url) { return fetch(bigEbay(url)).then(function (r) { return r.blob(); }).then(cropBlob).then(function (c) { return c.box; }); },
    CATALOG: CATALOG
  };
  window.MojoVintedRunner = api;
  // no auto-resume on load: a second open Vinted tab must never start posting by itself — call resume().
})();
