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
  var VERSION = 'v8'; // v8: sold orders come from Vinted's messages (my_orders is gone), a bundle's items are matched by item id and its total is split (2026-11-27); v7: a Vinted-only listing (Mojo Lister Vinted checkbox) is ALWAYS its own new item, made before any title matching, and syncAll never auto-links by title (MOJO_VINTED_V7_NEWITEM, Doug 2026-11-18: a newly listed item is not the one that already exists); v6: a title match is never a link - only exact eBay item numbers are (2026-11-17); v5: syncAll() marks cross-listed items at once (MOJO_VINTED_V5_CROSSMARK); v2: listing photo URLs (vintedPhotos); v3: multi-copy items (quantity) split one copy per Vinted listing; v4: cross-listed items (crossStatus, MOJO_SYNC_V7_CROSSLIST)
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
  /* v4: a cross-listed item that sold on EBAY (the eBay sync turned its record into the eBay sale). Its Vinted
     listing is only tracked from here on: the sale, price, status and channel are eBay's and are never touched. */
  function ebaySold(it) { return isSold(it) && it.account !== 'V' && !!it.ebayOrderId; }
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
      var grp = byEbay[String(r.ebayItemId || '')] || [];
      var it = grp.filter(function (x) { return !x.vintedId && !isSold(x) && x.status !== 'bundled'; })[0];
      if (it && qty(it) > 1) it = splitCopy(items, it);
      if (!it) { var multi = grp.filter(function (x) { return qty(x) > 1; })[0]; if (multi) it = splitCopy(items, multi); }
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
      var price = parseFloat(L.price);
      if (ebaySold(it)) { // v4: sold on eBay — just follow what happened to the Vinted listing
        if (!isNaN(price)) it.vintedPrice = price;
        it.vintedLastSeen = day;
        var vSold = L.closed && (L.closing === 'sold' || !L.closing);
        it.vintedStatus = vSold ? 'sold' : (L.hidden ? 'hidden' : (L.reserved ? 'reserved' : 'active'));
        it.crossStatus = vSold ? 'double-sale' : (L.hidden ? 'sold-ebay' : 'sold-ebay-pending-vinted-hide');
        return;
      }
      if (!isNaN(price)) { it.vintedPrice = price; it.askingPrice = price; }
      if (L.url) it.vintedUrl = L.url;
      if (L.photos && L.photos.length) it.vintedPhotos = L.photos.slice(0, 20);
      if (!it.vintedListedDate) { it.vintedListedDate = L.listedAt || day; it.listedDate = it.vintedListedDate; }
      it.vintedLastSeen = day;
      var sold = L.closed && (L.closing === 'sold' || !L.closing);
      if (sold) {
        it.vintedStatus = 'sold';
        var byId = orders.filter(function (o) { return o.sale !== false && (o.itemIds || []).map(String).indexOf(String(vid)) >= 0; })[0]; // v8: exact item id from the order
        if (byId && String(it.vintedTxId || '') !== String(byId.txId)) it.vintedTxId = String(byId.txId);
        if (!it.vintedTxId) {
          var o = orders.filter(function (o) { return !usedOrders[o.txId] && o.sale !== false && !(o.itemIds && o.itemIds.length > 1) && normT(o.title) === normT(L.title); })[0];
          if (o) { usedOrders[o.txId] = 1; it.vintedTxId = String(o.txId); }
        }
        var ord = it.vintedTxId && orders.filter(function (o) { return String(o.txId) === String(it.vintedTxId); })[0];
        if (ord) {
          usedOrders[ord.txId] = 1;
          var share = parseFloat(ord.price);
          if (ord.itemIds && ord.itemIds.length > 1 && !isNaN(share)) { // v8: a bundle - split its total by the listed prices
            var tot = 0; ord.itemIds.forEach(function (i) { var w = wardrobe[String(i)]; tot += (w && parseFloat(w.price)) || 0; });
            share = tot > 0 && !isNaN(price) ? Math.round(share * price / tot * 100) / 100 : Math.round(share / ord.itemIds.length * 100) / 100;
          }
          it.salePrice = share || it.salePrice || price; it.saleDate = String(ord.date || '').slice(0, 10) || it.saleDate || day;
          it.vintedOrderStatus = ord.status || '';
          it.status = shippedStatus(ord.status) || it.status === 'shipped' ? 'shipped' : 'sold';
        } else {
          if (!isSold(it)) { it.status = 'sold'; }
          if (it.salePrice === '' || it.salePrice == null) it.salePrice = price;
          if (!it.saleDate) it.saleDate = day;
        }
        it.ebayFees = 0; it.shipCost = 0;
        if (it.crossStatus === 'both' || (it.crossListedEbay && !it.crossStatus)) it.crossStatus = 'sold-vinted'; // v4
      } else {
        it.vintedStatus = L.hidden ? 'hidden' : (L.reserved ? 'reserved' : 'active');
        if (isSold(it) && !it.vintedTxId) it.status = 'listed'; // relisted/undone on Vinted
        else if (!isSold(it)) it.status = 'listed';
      }
    });

    // 3. Listings that disappeared from the profile (deleted on Vinted) -> back on hand.
    if (snap.complete) {
      items.forEach(function (it) {
        if (!it.vintedId || wardrobe[it.vintedId]) return;
        if (ebaySold(it)) { if (it.vintedStatus !== 'removed') { it.vintedStatus = 'removed'; if (it.crossStatus === 'sold-ebay-pending-vinted-hide') it.crossStatus = 'sold-ebay'; it.vUpdated = now; rep.removed++; } return; } // v4: its Vinted listing was deleted after the eBay sale
        if (isSold(it)) return;
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

  /* v3: an item can stand for several copies (quantity, from a multi-quantity eBay listing). Each Vinted
     listing gets ONE copy: splitCopy() peels one copy off into its own item (same SKU/location/cost),
     leaving the rest on the original. */
  function qty(it) { var q = parseInt(it && it.quantity, 10); return q > 1 ? q : 1; }
  function splitCopy(items, t) {
    var n = JSON.parse(JSON.stringify(t)); n.id = uid(); n.quantity = 1; t.quantity = qty(t) - 1;
    if (n.account === 'V') { n.account = n.prevAccount || 'A'; n.marketplace = 'eBay'; n.askingPrice = n.prevAskingPrice != null ? n.prevAskingPrice : ''; n.listedDate = n.prevListedDate || ''; n.status = 'sourced'; }
    ['vintedId', 'vintedUrl', 'vintedPrice', 'vintedListedDate', 'vintedStatus', 'vintedTxId', 'vintedOrderStatus', 'vintedLastSeen', 'vintedMatch', 'vintedCandidates', 'vintedNote', 'vintedPhotos', 'vintedCreated'].forEach(function (f) { delete n[f]; });
    if (isSold(n)) { n.status = 'sourced'; n.salePrice = ''; n.saleDate = ''; }
    items.push(n); return n;
  }
  /* Confirm queue actions (app). */
  function link(items, pendingId, targetId) {
    var p = items.filter(function (x) { return x.id === pendingId; })[0], t = items.filter(function (x) { return x.id === targetId; })[0];
    if (!p || !t) return false;
    if (t.vintedId || qty(t) > 1) { if (qty(t) < 2) return false; t = splitCopy(items, t); }
    var now = new Date().toISOString();
    convert(t, { id: p.vintedId, url: p.vintedUrl, listedAt: p.vintedListedDate }, 'confirmed', now);
    ['vintedPrice', 'askingPrice', 'vintedStatus', 'vintedTxId', 'vintedOrderStatus', 'vintedLastSeen', 'vintedPhotos'].forEach(function (f) { if (p[f] !== undefined) t[f] = p[f]; });
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
    ['vintedPrice', 'askingPrice', 'vintedStatus', 'vintedTxId', 'vintedOrderStatus', 'vintedLastSeen', 'vintedPhotos', 'salePrice', 'saleDate', 'status'].forEach(function (f) { if (t[f] !== undefined) p[f] = t[f]; });
    p.vintedCandidates = [t.id];
    t.account = t.prevAccount || 'A'; t.marketplace = 'eBay';
    t.askingPrice = t.prevAskingPrice != null ? t.prevAskingPrice : ''; t.listedDate = t.prevListedDate || '';
    if (isSold(t)) { t.salePrice = ''; t.saleDate = ''; t.ebayFees = ''; t.shipCost = ''; }
    t.status = 'sourced';
    ['vintedId', 'vintedUrl', 'vintedPrice', 'vintedListedDate', 'vintedStatus', 'vintedTxId', 'vintedOrderStatus', 'vintedLastSeen', 'vintedMatch', 'vintedCandidates', 'vintedNote', 'vintedPhotos'].forEach(function (f) { t[f] = ''; });
    t.vUpdated = now;
    items.push(p);
    return true;
  }
  /* Free search for the confirm queue. */
  function search(items, q, title) {
    var qt = toks(q || title), out = [];
    items.forEach(function (it) {
      if (((it.vintedId || it.account === 'V') && qty(it) < 2) || isSold(it) || it.status === 'bundled' || it.status === 'returned') return;
      var s = score(qt, toks(it.title)); if (s > 0.15) out.push({ it: it, s: s });
    });
    out.sort(function (a, b) { return b.s - a.s; });
    return out.slice(0, 8).map(function (o) { return o.it; });
  }

  /* Build a snapshot on vinted.com (userscript + bookmarklet). fetchJson(url) -> Promise<json>. */
  function photoUrls(o) { return (o.photos || []).map(function (p) { return p.full_size_url || p.url || ''; }).filter(Boolean); }
  /* v8 (2026-11-27): Vinted retired /api/v2/my_orders (404), so sold orders come from Vinted's messages instead:
     every sale has a conversation whose transaction lists ALL its item ids (a bundle too). Seller side only.
     opts.cache {get(k), set(k,v)} keeps each conversation's order so only changed conversations are read again;
     opts.days (default 60) stops at older conversations; opts.pages (default 6, 50 a page). */
  function orderOf(cv, upd) {
    var t = cv && cv.transaction; if (!t || t.current_user_side !== 'seller') return null;
    var code = Number(t.status) || 0, ship = Number(t.shipment_status) || 0, msgs = cv.messages || [];
    var ts = msgs.length && msgs[0].created_at_ts ? new Date(msgs[0].created_at_ts * 1000).toISOString() : String(upd || '');
    var ids = (t.item_ids && t.item_ids.length ? t.item_ids : (t.item_id ? [t.item_id] : [])).map(String);
    return { txId: String(t.id), title: t.item_title || '', price: t.offer_price && t.offer_price.amount, date: ts, itemIds: ids, count: Number(t.item_count) || ids.length,
      statusCode: code, sale: code >= 200 && code < 500, side: 'seller',
      status: code >= 500 ? 'canceled' : (code >= 450 ? 'completed' : (ship >= 300 ? 'shipped' : (code >= 200 ? 'paid' : 'offer'))) };
  }
  function readOrders(fetchJson, opts) {
    var orders = [];
    function pageO(p) {
      var days = (opts && opts.days) || 60, pages = (opts && opts.pages) || 6, cache = opts && opts.cache, cut = Date.now() - days * 86400000, more = true;
      return fetchJson('/api/v2/inbox?page=' + p + '&per_page=50').then(function (j) {
        var convs = j.conversations || [];
        if (!convs.length) more = false;
        return convs.reduce(function (pr, c) {
          return pr.then(function () {
            if (!more) return;
            if (c.updated_at && new Date(c.updated_at).getTime() < cut) { more = false; return; }
            var key = c.id + '@' + (c.updated_at || ''), hit = cache && cache.get(key);
            if (hit !== undefined && hit !== null) { if (hit) orders.push(hit); return; }
            return fetchJson('/api/v2/conversations/' + c.id).then(function (k) {
              var o = orderOf(k.conversation, c.updated_at); if (cache) cache.set(key, o || false);
              if (o) orders.push(o);
            }).catch(function () {}).then(function () { return new Promise(function (r) { setTimeout(r, 250); }); });
          });
        }, Promise.resolve()).then(function () { if (more && p < pages) return pageO(p + 1); });
      });
    }
    return pageO(1).then(function () { return orders; });
  }
  function collect(fetchJson, memberId, runnerLog, opts) {
    var wardrobe = [], orders = [], complete = true;
    function pageW(p) {
      return fetchJson('/api/v2/wardrobe/' + memberId + '/items?page=' + p + '&per_page=96&order=newest_first').then(function (j) {
        (j.items || []).forEach(function (o) {
          wardrobe.push({ id: o.id, title: o.title, price: o.price && o.price.amount, cond: o.status, closed: !!o.is_closed, reserved: !!o.is_reserved, hidden: !!o.is_hidden, closing: o.item_closing_action || '', url: o.url, photos: photoUrls(o) });
        });
        var tp = (j.pagination && j.pagination.total_pages) || 1;
        if (p < tp && p < 50) return pageW(p + 1);
      });
    }
    return pageW(1).catch(function (e) { complete = false; throw e; })
      .then(function () { return readOrders(fetchJson, opts).then(function (o) { orders = o; }).catch(function () { /* orders are optional */ }); })
      .then(function () { return { at: new Date().toISOString(), complete: complete, memberId: String(memberId), wardrobe: wardrobe, orders: orders, runner: runnerLog || [] }; });
  }


  /* -------- MOJO_VINTED_V5_CROSSMARK (2026-11-17) --------
     Why: a cassette sold on Vinted while a twin listing was live on eBay, and nothing had marked the pair, so the
     crosslist sync tool could not end the eBay side. Every sync now goes through syncAll(), which
       1. crossPrep: NEVER links by title (v6, Doug 2026-11-17: the same title is often another copy, another condition
          or a multi-quantity listing). A link comes only from an exact eBay item number <-> Vinted id pair: a listing-runner
          record (snap.runner) or tools/mark-run.js. A new Vinted listing whose title is also live on eBay is only REPORTED
          (rep.unsure) so Doug can be asked whether it is cross-listed;
       2. merge();
       3. crossMark: every record that is live on eBay and active on Vinted is marked crossStatus 'both' right away
          (the hourly eBay sync used to be the only thing that set it);
       4. Vinted-only listings made by the Mojo Lister "Vinted" checkbox (snap.vintedOnly) are kept as their own
          items instead of sitting in the confirm queue.
     A title-only match lands in the confirm queue and in rep.unsure so the caller can alert. */
  function splitSku(t) {
    t = String(t || '').trim();
    var m = t.match(/^(.*\S)\s+-\s+([A-Za-z0-9]{1,8}(?: [A-Za-z0-9]{1,8})?)$/);
    return m ? { base: m[1], sku: m[2] } : { base: t, sku: '' };
  }
  function unesc(s) { return String(s || '').replace(/&amp;/g, '&').replace(/&#0?39;|&apos;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>'); }
  function normX(s) { return normT(unesc(s)); }
  function liveOnEbay(it) { return it.status === 'listed' && it.account !== 'V' && !!it.ebayItemId && !it.vintedId && !(it.quantity != null && it.quantity !== '' && Number(it.quantity) < 1); }
  /* Live eBay items whose title is exactly this Vinted title. -> { hit: item|null, same: [items], sku } */
  function ebayTwin(items, vintedTitle) {
    var sp = splitSku(vintedTitle), full = normX(vintedTitle), base = normX(sp.base);
    var same = items.filter(function (it) { if (!liveOnEbay(it)) return false; var t = normX(it.title); return t === full || t === base; });
    var hit = null;
    if (sp.sku) { var bySku = same.filter(function (it) { return normT(it.sku) === normT(sp.sku) && normX(it.title) === base; }); if (bySku.length === 1) hit = bySku[0]; }
    else if (same.length === 1) hit = same[0];
    return { hit: hit, same: same, sku: sp.sku };
  }
  function crossPrep(data, snap) {
    var known = {}; data.items.forEach(function (it) { if (it.vintedId) known[String(it.vintedId)] = 1; });
    var runner = (snap.runner || []).slice(), have = {}; runner.forEach(function (r) { have[String(r.vintedId)] = 1; });
    var used = {}, added = [], unsure = [];
    (snap.wardrobe || []).forEach(function (L) {
      var vid = String(L.id); if (known[vid] || have[vid] || L.closed) return;
      var tw = ebayTwin(data.items, L.title);
      if (tw.same.length) unsure.push({ vintedId: vid, title: L.title, ebay: tw.same.map(function (it) { return { ebayItemId: String(it.ebayItemId), sku: it.sku || '' }; }) });
    });
    snap.runner = runner;
    return { added: added, unsure: unsure };
  }
  function syncAll(data, snap, opts) {
    var pre = {}; data.items.forEach(function (it) { pre[it.id] = { account: it.account, status: it.status, askingPrice: it.askingPrice, listedDate: it.listedDate, quantity: it.quantity, ebayItemId: it.ebayItemId }; });
    var prep = crossPrep(data, snap), rep0 = new Date().toISOString();
    /* MOJO_VINTED_V7_NEWITEM: every Vinted-only listing becomes its own record right here, before merge() looks at titles.
       It is a new physical item - never the eBay listing (live, ended or sold) that happens to carry the same title. */
    var haveV = {}; data.items.forEach(function (it) { if (it.vintedId) haveV[String(it.vintedId)] = 1; });
    var wById = {}; (snap.wardrobe || []).forEach(function (L) { wById[String(L.id)] = L; });
    var newOwn = [];
    (snap.vintedOnly || []).forEach(function (x) {
      var vid = String(x.vintedId || ''); if (!vid || haveV[vid]) return; haveV[vid] = 1;
      var L = wById[vid] || { id: vid, title: x.title, price: x.price, url: 'https://www.vinted.com/items/' + vid };
      var it = newPending({ id: vid, title: L.title || x.title, url: L.url, listedAt: String(x.listedAt || L.listedAt || '').slice(0, 10) || today() }, [], '', rep0);
      it.vintedMatch = 'new'; it.vintedCandidates = ''; it.vintedNew = true;
      it.vintedNote = 'New item listed on Vinted only - not any eBay listing with the same title';
      it.listedDate = it.vintedListedDate; it.vintedStatus = 'active';
      if (x.price != null && x.price !== '' && !isNaN(parseFloat(x.price))) { it.askingPrice = parseFloat(x.price); it.vintedPrice = it.askingPrice; }
      if (x.sku) { it.sku = x.sku; it.location = x.sku; }
      if (x.draftId) it.listerDraftId = String(x.draftId);
      if (x.upc) it.upc = String(x.upc);
      if (x.cost != null && x.cost !== '') it.cost = x.cost;
      data.items.push(it); newOwn.push({ vintedId: vid, title: it.title, sku: it.sku || '' });
    });
    var o2 = {}; Object.keys(opts || {}).forEach(function (k) { o2[k] = opts[k]; });
    if (o2.autoMatch === undefined) o2.autoMatch = false; // v7: a title match goes to the confirm queue, it is never a link
    var rep = merge(data, snap, o2);
    var marked = [];
    data.items.forEach(function (it) {
      var p = pre[it.id]; if (!p) return;
      if (it.account === 'V' && p.account !== 'V' && p.status === 'listed' && p.ebayItemId && !(p.quantity != null && p.quantity !== '' && Number(p.quantity) < 1)
          && it.status === 'listed' && (it.vintedStatus === 'active' || it.vintedStatus === 'reserved' || it.vintedStatus === 'hidden')) {
        it.ebayPrice = p.askingPrice; it.ebayListedDate = p.listedDate; it.ebayQty = (p.quantity == null || p.quantity === '') ? 1 : Number(p.quantity);
        it.crossStatus = 'both'; if (!it.crossListedEbay) it.crossListedEbay = it.vintedListedDate || rep.at.slice(0, 10);
        it.vUpdated = rep.at; marked.push({ title: it.title, sku: it.sku || '', ebayItemId: String(it.ebayItemId), vintedId: String(it.vintedId) });
      }
    });
    var vo = {}; (snap.vintedOnly || []).forEach(function (x) { vo[String(x.vintedId)] = x; });
    data.items.forEach(function (it) {
      if (!it.vintedCreated || it.vintedMatch !== 'pending' || pre[it.id] || !vo[String(it.vintedId)]) return;
      it.vintedMatch = 'confirmed'; it.vintedCandidates = ''; it.vintedNote = '';
      var l = vo[String(it.vintedId)]; if (l.sku && !it.sku) { it.sku = l.sku; it.location = l.sku; }
    });
    var ownIds = {}; newOwn.forEach(function (n) { ownIds[n.vintedId] = 1; }); (snap.vintedOnly || []).forEach(function (x) { ownIds[String(x.vintedId)] = 1; });
    rep.newOwn = newOwn; if (newOwn.length) rep.changed = true;
    rep.crossMarked = marked; rep.unsure = (prep.unsure || []).filter(function (u) { return !ownIds[String(u.vintedId)]; }); // a known new item is not a 'maybe cross-listed' question
    if (marked.length) rep.changed = true;
    return rep;
  }

  var api = { VERSION: VERSION, splitCopy: splitCopy, merge: merge, dedupe: dedupe, link: link, keepAsNew: keepAsNew, unlink: unlink, search: search, rank: rank, decide: decide, collect: collect, readOrders: readOrders, syncAll: syncAll, crossPrep: crossPrep, ebayTwin: ebayTwin, splitSku: splitSku, _score: function (a, b) { return score(toks(a), toks(b)); } };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.MojoVinted = api;
})(typeof window !== 'undefined' ? window : this);
