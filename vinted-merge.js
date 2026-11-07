/* MOJO_VINTED_V1 — shared Vinted -> data.json merge.
   One copy of the logic, used by:
     - the Mojonator app (index.html) for the link / paste-in import and the confirm queue
     - the Tampermonkey userscript vinted-sync.user.js (@require)
   Pure: works on a data object ({settings, items, ...}), mutates data.items, returns a report.

   Item fields it owns (all other fields are left alone; sku/location are NEVER changed —
   an item keeps the crate it had on eBay):
     account 'V', marketplace 'Vinted', askingPrice, listedDate, status, salePrice, saleDate,
     ebayFees 0, shipCost 0 (Vinted pays shipping), vintedId, vintedUrl, vintedPrice,
     vintedListedDate, vintedStatus (active|reserved|hidden|sold|removed), vintedTxId,
     vintedOrderStatus, vintedLastSeen, vintedMatch (runner|auto|confirmed|pending),
     vintedCandidates [item ids], vintedNote, vintedCreated (item was created by the sync),
     prevAccount / prevAskingPrice / prevListedDate (eBay values, for unlinking), vUpdated (ISO).

   Snapshot shape (built on vinted.com by the userscript or the bookmarklet):
     { at, complete, wardrobe:[{id,title,price,cond,closed,reserved,hidden,closing,url}],
       orders:[{txId,title,price,date,status}], runner:[{vintedId,ebayItemId,title,price,listedAt}] } */
(function (root) {
  'use strict';
  var VERSION = 'v1';
  var STOP = {}; 'cd cds dvd dvds blu ray bluray the of a an and with new like good very used disc discs edition lot in to for by on movie movies album'.split(' ').forEach(function (w) { STOP[w] = 1; });

  function toks(s) {
    var m = String(s || '').toLowerCase().replace(/&/g, ' and ').replace(/'/g, '').match(/[a-z0-9]+/g) || [];
    var out = {}; m.forEach(function (w) { if (w.length > 1 && !STOP[w]) out[w] = 1; });
    return out;
  }
  function score(a, b) { // cosine overlap of two token sets
    var ka = Object.keys(a), kb = Object.keys(b); if (!ka.length || !kb.length) return 0;
    var n = 0; ka.forEach(function (w) { if (b[w]) n++; });
    return n / Math.sqrt(ka.length * kb.length);
  }
  function media(t) {
    t = String(t || '').toLowerCase();
    if (/blu[- ]?ray|4k uhd|\buhd\b/.test(t)) return 'BD';
    if (/\bdvds?\b/.test(t)) return 'DVD';
    if (/cassette|\btape\b/.test(t)) return 'CS';
    if (/\bcds?\b|\bsacd\b|compact disc/.test(t)) return 'CD';
    return '';
  }
  function years(t) { return (String(t || '').match(/\b(19[4-9]\d|20[0-3]\d)\b/g) || []); }
  function compatible(vt, it) {
    var a = media(vt), b = media(it); if (a && b && a !== b) return false;
    return true;
  }
  function yearFactor(vt, it) { // film year vs DVD release year differ often, so a mismatch only lowers the score
    var ya = years(vt), yb = years(it);
    return (ya.length && yb.length && !ya.some(function (y) { return yb.indexOf(y) >= 0; })) ? 0.75 : 1;
  }
  function today() { return new Date().toISOString().slice(0, 10); }
  function uid() { return Math.random().toString(36).slice(2, 9); }
  function normT(s) { return String(s || '').toLowerCase().replace(/\s+/g, ' ').trim(); }
  function isSold(it) { return it.status === 'sold' || it.status === 'shipped'; }
  function shippedStatus(s) { return /complet|deliver|shipped|on (its|the) way|in transit|received|sent to buyer/i.test(String(s || '')); }

  // Thresholds — tuned on Doug's data 2026-11-07 (see repo history).
  var AUTO_MIN = 0.55, AUTO_GAP = 0.2, COPY_SIM = 0.8;

  /* Rank candidate items for a Vinted title. Pool = ended/unlisted eBay items (status sourced,
     incl. bundle items) with no Vinted link. Items still live on eBay are scored separately so a
     listing that was never ended on eBay is flagged, never auto-linked. */
  function rank(items, title, taken) {
    var vt = toks(title), res = [];
    items.forEach(function (it) {
      if (it.vintedId || taken[it.id]) return;
      if (it.account === 'V') return;
      if (it.status !== 'sourced' && it.status !== 'listed') return;
      if (!compatible(title, it.title)) return;
      var s = score(vt, toks(it.title)) * yearFactor(title, it.title); if (s < 0.25) return;
      res.push({ it: it, s: s, live: it.status === 'listed' });
    });
    res.sort(function (a, b) { return b.s - a.s; });
    return res;
  }
  function decide(cands) {
    var off = cands.filter(function (c) { return !c.live; });
    var liveHit = cands.filter(function (c) { return c.live && c.s >= 0.4; })[0];
    var best = off[0];
    if (!best || best.s < AUTO_MIN) {
      if (liveHit) return { auto: null, why: 'matches an item still listed on eBay (' + (liveHit.it.sku || 'no SKU') + ') — end it there or link it here' };
      return { auto: null, why: best ? 'weak title match' : 'no match in Mojonator' };
    }
    var bt = toks(best.it.title);
    var copies = cands.filter(function (c) { return c !== best && score(bt, toks(c.it.title)) >= COPY_SIM; });
    if (copies.length) return { auto: null, why: (copies.length + 1) + ' copies in Mojonator' + (copies.some(function (c) { return c.live; }) ? ' (one still listed on eBay)' : '') + ' — pick the one you moved' };
    var liveClose = cands.filter(function (c) { return c.live && c.s >= best.s - AUTO_GAP; });
    if (liveClose.length) return { auto: null, why: 'other copies still listed on eBay (' + liveClose.map(function (c) { return c.it.sku || 'no SKU'; }).join(', ') + ') — pick the one you moved' };
    var second = off[1]; if (second && best.s - second.s < AUTO_GAP) return { auto: null, why: 'two close matches' };
    return { auto: best.it, why: '' };
  }

  function convert(it, L, how, now) {
    if (it.account !== 'V') { it.prevAccount = it.account; it.prevAskingPrice = it.askingPrice; it.prevListedDate = it.listedDate; }
    if (!it.firstListed && it.listedDate) { it.firstListed = it.listedDate; it.firstListedSource = it.firstListedSource || 'estimate'; }
    it.account = 'V'; it.marketplace = 'Vinted';
    it.vintedId = String(L.id); it.vintedUrl = L.url || it.vintedUrl || '';
    it.vintedListedDate = L.listedAt || it.vintedListedDate || today();
    it.listedDate = it.vintedListedDate;
    if (!isSold(it)) it.status = 'listed';
    it.vintedMatch = how; it.vintedCandidates = ''; it.vintedNote = '';
    it.vUpdated = now;
  }

  function newPending(L, cands, why, now) {
    return {
      id: uid(), itemId: 'V-' + L.id, title: L.title || '', account: 'V', marketplace: 'Vinted', status: 'listed',
      category: 'Other', sku: '', location: '', cost: '', source: '', purchaseDate: '', tags: [], custom: {}, notes: '',
      ebayItemId: '', askingPrice: '', listedDate: '', salePrice: '', saleDate: '', ebayFees: '', shipCost: '',
      vintedId: String(L.id), vintedUrl: L.url || '', vintedListedDate: L.listedAt || today(),
      vintedMatch: 'pending', vintedCreated: true,
      vintedCandidates: cands.slice(0, 5).map(function (c) { return c.it.id; }), vintedNote: why, vUpdated: now
    };
  }

  /* Keep one item per vintedId. A sync-created placeholder loses to a real inventory item
     (happens when a link made on one computer meets a stale copy from another). */
  function dedupe(items) {
    var by = {}, drop = {}, n = 0;
    items.forEach(function (it) { if (!it.vintedId) return; (by[it.vintedId] = by[it.vintedId] || []).push(it); });
    Object.keys(by).forEach(function (k) {
      var g = by[k]; if (g.length < 2) return;
      var real = g.filter(function (it) { return !it.vintedCreated; });
      var keep = real.length ? real[0] : g.slice().sort(function (a, b) { return String(b.vUpdated || '').localeCompare(String(a.vUpdated || '')); })[0];
      g.forEach(function (it) { if (it !== keep && it.vintedCreated) { drop[it.id] = 1; n++; } });
    });
    if (n) { for (var i = items.length - 1; i >= 0; i--) if (drop[items[i].id]) items.splice(i, 1); }
    return n;
  }

  function merge(data, snap, opts) {
    opts = opts || {};
    var now = new Date().toISOString(), day = now.slice(0, 10);
    var items = data.items, rep = { at: now, version: VERSION, listings: (snap.wardrobe || []).length, runnerLinked: 0, autoLinked: [], pending: [], newSales: [], updated: 0, removed: 0, deduped: 0, changed: false };
    rep.deduped = dedupe(items);
    var byVid = {}; items.forEach(function (it) { if (it.vintedId) byVid[it.vintedId] = it; });
    var byEbay = {}; items.forEach(function (it) {
      if (it.ebayItemId) (byEbay[String(it.ebayItemId)] = byEbay[String(it.ebayItemId)] || []).push(it);
      ((it.relist && it.relist.prevIds) || []).forEach(function (p) { (byEbay[String(p)] = byEbay[String(p)] || []).push(it); });
    });
    var wardrobe = {}; (snap.wardrobe || []).forEach(function (L) { wardrobe[String(L.id)] = L; });
    var taken = {};
    var before = {}; items.forEach(function (it) { if (it.vintedId || it.account === 'V') before[it.id] = JSON.stringify(it); });

    // 1. Listing-runner records: exact eBay item number -> exact link.
    (snap.runner || []).forEach(function (r) {
      var vid = String(r.vintedId || ''); if (!vid || byVid[vid]) return;
      var it = (byEbay[String(r.ebayItemId || '')] || []).filter(function (x) { return !x.vintedId; })[0];
      var L = wardrobe[vid] || { id: vid, title: r.title, price: r.price, url: 'https://www.vinted.com/items/' + vid };
      L.listedAt = (r.listedAt || '').slice(0, 10) || L.listedAt;
      if (wardrobe[vid]) wardrobe[vid].listedAt = L.listedAt;
      if (it) { convert(it, L, 'runner', now); byVid[vid] = it; taken[it.id] = 1; rep.runnerLinked++; }
    });

    // 2. Every listing on the Vinted profile.
    var usedOrders = {};
    var orders = (snap.orders || []).slice();
    Object.keys(wardrobe).forEach(function (vid) {
      var L = wardrobe[vid], it = byVid[vid];
      if (!it) {
        var cands = rank(items, L.title, taken), d = decide(cands);
        if (d.auto && opts.autoMatch !== false) { it = d.auto; convert(it, L, 'auto', now); rep.autoLinked.push({ title: L.title, to: it.title, sku: it.sku || '' }); }
        else { it = newPending(L, cands, d.why, now); items.push(it); rep.pending.push({ title: L.title, why: d.why }); }
        byVid[vid] = it; taken[it.id] = 1;
      }
      var price = parseFloat(L.price); if (!isNaN(price)) { it.vintedPrice = price; it.askingPrice = price; }
      if (L.url) it.vintedUrl = L.url;
      if (!it.vintedListedDate) { it.vintedListedDate = L.listedAt || day; it.listedDate = it.vintedListedDate; }
      it.vintedLastSeen = day;
      var sold = L.closed && (L.closing === 'sold' || !L.closing);
      if (sold) {
        it.vintedStatus = 'sold';
        if (!it.vintedTxId) {
          var o = orders.filter(function (o) { return !usedOrders[o.txId] && normT(o.title) === normT(L.title); })[0];
          if (o) { usedOrders[o.txId] = 1; it.vintedTxId = String(o.txId); }
        }
        var ord = it.vintedTxId && orders.filter(function (o) { return String(o.txId) === String(it.vintedTxId); })[0];
        if (ord) {
          usedOrders[ord.txId] = 1;
          it.salePrice = parseFloat(ord.price) || it.salePrice || price; it.saleDate = String(ord.date || '').slice(0, 10) || it.saleDate || day;
          it.vintedOrderStatus = ord.status || '';
          it.status = shippedStatus(ord.status) || it.status === 'shipped' ? 'shipped' : 'sold';
        } else {
          if (!isSold(it)) { it.status = 'sold'; }
          if (it.salePrice === '' || it.salePrice == null) it.salePrice = price;
          if (!it.saleDate) it.saleDate = day;
        }
        it.ebayFees = 0; it.shipCost = 0;
      } else {
        it.vintedStatus = L.hidden ? 'hidden' : (L.reserved ? 'reserved' : 'active');
        if (isSold(it) && !it.vintedTxId) it.status = 'listed'; // relisted/undone on Vinted
        else if (!isSold(it)) it.status = 'listed';
      }
    });

    // 3. Listings that disappeared from the profile (deleted on Vinted) -> back on hand.
    if (snap.complete) {
      items.forEach(function (it) {
        if (!it.vintedId || wardrobe[it.vintedId] || isSold(it)) return;
        if (it.vintedStatus === 'removed') return;
        it.vintedStatus = 'removed'; it.status = 'sourced'; it.vUpdated = now; rep.removed++;
      });
    }

    // 4. Stamp what changed.
    items.forEach(function (it) {
      if (!(it.vintedId || it.account === 'V')) return;
      var b = before[it.id], a = JSON.stringify(it);
      if (b === a) return;
      if (b) {
        var ob = JSON.parse(b);
        if (!isSold(ob) && isSold(it)) rep.newSales.push({ title: it.title, price: it.salePrice, date: it.saleDate });
        rep.updated++;
      }
      it.vUpdated = now; rep.changed = true;
    });
    if (rep.runnerLinked || rep.autoLinked.length || rep.pending.length || rep.removed || rep.deduped) rep.changed = true;
    data.vintedSync = { at: now, by: opts.by || 'app', report: { listings: rep.listings, runnerLinked: rep.runnerLinked, auto: rep.autoLinked.length, pending: rep.pending.length, newSales: rep.newSales.length, updated: rep.updated, removed: rep.removed } };
    return rep;
  }

  /* Confirm queue actions (app). */
  function link(items, pendingId, targetId) {
    var p = items.filter(function (x) { return x.id === pendingId; })[0], t = items.filter(function (x) { return x.id === targetId; })[0];
    if (!p || !t || t.vintedId) return false;
    var now = new Date().toISOString();
    convert(t, { id: p.vintedId, url: p.vintedUrl, listedAt: p.vintedListedDate }, 'confirmed', now);
    ['vintedPrice', 'askingPrice', 'vintedStatus', 'vintedTxId', 'vintedOrderStatus', 'vintedLastSeen'].forEach(function (f) { if (p[f] !== undefined) t[f] = p[f]; });
    if (isSold(p)) { t.status = p.status; t.salePrice = p.salePrice; t.saleDate = p.saleDate; t.ebayFees = 0; t.shipCost = 0; }
    else if (p.status === 'sourced') t.status = 'sourced';
    items.splice(items.indexOf(p), 1);
    return true;
  }
  function keepAsNew(items, pendingId) {
    var p = items.filter(function (x) { return x.id === pendingId; })[0]; if (!p) return false;
    p.vintedMatch = 'confirmed'; p.vintedCandidates = ''; p.vintedNote = ''; p.vUpdated = new Date().toISOString(); return true;
  }
  function unlink(items, id) {
    var t = items.filter(function (x) { return x.id === id; })[0]; if (!t || !t.vintedId) return false;
    var now = new Date().toISOString();
    if (t.vintedCreated) { t.vintedMatch = 'pending'; t.vintedNote = 'unlinked by you'; t.vUpdated = now; return true; }
    var p = newPending({ id: t.vintedId, title: t.title, url: t.vintedUrl, listedAt: t.vintedListedDate }, [], 'unlinked by you', now);
    ['vintedPrice', 'askingPrice', 'vintedStatus', 'vintedTxId', 'vintedOrderStatus', 'vintedLastSeen', 'salePrice', 'saleDate', 'status'].forEach(function (f) { if (t[f] !== undefined) p[f] = t[f]; });
    p.vintedCandidates = [t.id];
    t.account = t.prevAccount || 'A'; t.marketplace = 'eBay';
    t.askingPrice = t.prevAskingPrice != null ? t.prevAskingPrice : ''; t.listedDate = t.prevListedDate || '';
    if (isSold(t)) { t.salePrice = ''; t.saleDate = ''; t.ebayFees = ''; t.shipCost = ''; }
    t.status = 'sourced';
    ['vintedId', 'vintedUrl', 'vintedPrice', 'vintedListedDate', 'vintedStatus', 'vintedTxId', 'vintedOrderStatus', 'vintedLastSeen', 'vintedMatch', 'vintedCandidates', 'vintedNote'].forEach(function (f) { t[f] = ''; });
    t.vUpdated = now;
    items.push(p);
    return true;
  }
  /* Free search for the confirm queue. */
  function search(items, q, title) {
    var qt = toks(q || title), out = [];
    items.forEach(function (it) {
      if (it.vintedId || it.account === 'V' || isSold(it) || it.status === 'bundled' || it.status === 'returned') return;
      var s = score(qt, toks(it.title)); if (s > 0.15) out.push({ it: it, s: s });
    });
    out.sort(function (a, b) { return b.s - a.s; });
    return out.slice(0, 8).map(function (o) { return o.it; });
  }

  /* Build a snapshot on vinted.com (userscript + bookmarklet). fetchJson(url) -> Promise<json>. */
  function collect(fetchJson, memberId, runnerLog) {
    var wardrobe = [], orders = [], complete = true;
    function pageW(p) {
      return fetchJson('/api/v2/wardrobe/' + memberId + '/items?page=' + p + '&per_page=96&order=newest_first').then(function (j) {
        (j.items || []).forEach(function (o) {
          wardrobe.push({ id: o.id, title: o.title, price: o.price && o.price.amount, cond: o.status, closed: !!o.is_closed, reserved: !!o.is_reserved, hidden: !!o.is_hidden, closing: o.item_closing_action || '', url: o.url });
        });
        var tp = (j.pagination && j.pagination.total_pages) || 1;
        if (p < tp && p < 50) return pageW(p + 1);
      });
    }
    function pageO(p) {
      return fetchJson('/api/v2/my_orders?type=sold&status=all&per_page=100&page=' + p).then(function (j) {
        var arr = j.my_orders || [];
        arr.forEach(function (o) { orders.push({ txId: o.transaction_id, title: o.title, price: o.price && o.price.amount, date: o.date, status: o.status }); });
        var tp = (j.pagination && j.pagination.total_pages) || (arr.length >= 100 ? p + 1 : p);
        if (p < tp && p < 50) return pageO(p + 1);
      });
    }
    return pageW(1).catch(function (e) { complete = false; throw e; })
      .then(function () { return pageO(1).catch(function () { /* orders are optional */ }); })
      .then(function () { return { at: new Date().toISOString(), complete: complete, memberId: String(memberId), wardrobe: wardrobe, orders: orders, runner: runnerLog || [] }; });
  }

  var api = { VERSION: VERSION, merge: merge, dedupe: dedupe, link: link, keepAsNew: keepAsNew, unlink: unlink, search: search, rank: rank, decide: decide, collect: collect, _score: function (a, b) { return score(toks(a), toks(b)); } };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.MojoVinted = api;
})(typeof window !== 'undefined' ? window : this);
