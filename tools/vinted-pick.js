/* Mojo Vinted pick helper (2026-11-14) - run in the MOJONATOR tab (mojolists.com/mojonator-app/) to choose what
   may go to Vinted. It only returns records that are safe to list:
     - status "listed" on eBay store A, eBay available quantity >= 1 (a sold-out listing stays active at 0)
     - not sold in a multi-item order (soldInOrder), not bundled, not already on Vinted
     - a lot/bundle or a multi-quantity listing is left out unless asked for
   Usage:  MojoVintedPick({ match:/cassette/i, maxPrice:4.99, count:10 })  ->  [{ebayItemId, sku, title, price, ebayQty, listed}]
   Copy ebayQty into each runner job. Photos still have to be looked at before photosChecked:true is set. */
(function () {
  'use strict';
  window.MojoVintedPick = function (o) {
    o = o || {};
    var items = (window.DATA && window.DATA.items) || (typeof DATA !== 'undefined' ? DATA.items : []);
    var soldTitles = {};
    items.forEach(function (i) { if ((i.status === 'sold' || i.status === 'shipped') && /\s\+\s/.test(i.title || '')) String(i.title).split(' + ').forEach(function (t) { soldTitles[t.replace(/&amp;/g, '&').trim().toLowerCase()] = i.ebayOrderId || 1; }); });
    var skipped = [];
    var out = items.filter(function (i) {
      if (i.status !== 'listed' || i.account !== 'A') return false;
      var t = String(i.title || '').replace(/&amp;/g, '&');
      if (o.match && !o.match.test(t)) return false;
      if (o.maxPrice != null && !(Number(i.askingPrice) <= o.maxPrice)) return false;
      var why = !(Number(i.quantity) >= 1) ? 'eBay quantity ' + i.quantity : i.soldInOrder ? 'sold in order ' + i.soldInOrder : (i.vintedId || i.crossStatus) ? 'already on Vinted' :
        soldTitles[t.trim().toLowerCase()] ? 'same title sold in multi-item order ' + soldTitles[t.trim().toLowerCase()] + ' - check eBay' :
        (!o.lots && (Number(i.quantity) > 1 || /\blot\b|bundle|\d+\s*(cd|dvd|cassette|blu-?ray)s?\s+lot/i.test(t))) ? 'lot or multi-quantity' : '';
      if (why) { skipped.push(i.ebayItemId + ' ' + t.slice(0, 40) + ' - ' + why); return false; }
      return true;
    }).sort(function (a, b) { return String(a.firstListed || a.listedDate || '') < String(b.firstListed || b.listedDate || '') ? -1 : 1; })
      .slice(0, o.count || 10)
      .map(function (i) { return { ebayItemId: i.ebayItemId, sku: i.sku || i.location || '', title: String(i.title).replace(/&amp;/g, '&'), price: i.askingPrice, ebayQty: Number(i.quantity), listed: i.firstListed || i.listedDate }; });
    return { picks: out, skipped: skipped };
  };
})();
