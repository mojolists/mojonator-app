#!/usr/bin/env node
/* Mark a finished Vinted listing run in Mojonator by EXACT ids (2026-11-17).
   A cross-listing is only ever known from an eBay item number <-> Vinted id pair - never from a matching title.
   Usage:  node tools/mark-run.js <path to mojonator data.json> <pairs.json>
   pairs.json = [{ "vintedId": "107…", "ebayItemId": "3668…", "title": "… - GBC", "price": 5 }, …]
                (MojoVintedRunner.status().done gives "ebayItemId>vintedId"; localStorage __mojo_vinted_log has the same pairs)
   A Vinted-ONLY listing (Mojo Lister Vinted checkbox - a NEW item with no eBay listing of its own) goes in the same file as
     { "vintedOnly": true, "vintedId": "108…", "draftId": "d-…", "sku": "A3", "upc": "0756…", "title": "…", "price": 4.5, "cost": 2 }
   and is written as its own new record: it is never linked to an eBay listing that has the same title (2026-11-18).
   Writes data.json in place: each pair's Mojonator record gets its Vinted link; if its eBay listing is still live it is
   marked crossStatus "both" (eBay + Vinted). Commit and push data.json afterwards, then check the printed list. */
const fs = require('fs'), path = require('path');
const MV = require(path.join(__dirname, '..', 'vinted-merge.js'));
const [dataPath, pairsPath] = process.argv.slice(2);
if (!dataPath || !pairsPath) { console.error('usage: node tools/mark-run.js data.json pairs.json'); process.exit(2); }
const data = JSON.parse(fs.readFileSync(dataPath, 'utf8'));
let pairs = JSON.parse(fs.readFileSync(pairsPath, 'utf8'));
const today = new Date().toISOString().slice(0, 10);
const all = pairs, only = all.filter(p => p.vintedOnly || !p.ebayItemId);
pairs = all.filter(p => !(p.vintedOnly || !p.ebayItemId));
const snap = { vintedOnly: only.map(p => ({ vintedId: String(p.vintedId), draftId: p.draftId || '', sku: p.sku || '', upc: p.upc || '', title: p.title || '', price: p.price, cost: p.cost, listedAt: p.listedAt || today })), at: new Date().toISOString(), complete: false, orders: [],
  wardrobe: all.map(p => ({ id: String(p.vintedId), title: p.title || '', price: p.price, closed: false, hidden: false, reserved: false, closing: '', url: p.url || 'https://www.vinted.com/items/' + p.vintedId, photos: p.photos || [], listedAt: (p.listedAt || today).slice(0, 10) })),
  runner: pairs.map(p => ({ vintedId: String(p.vintedId), ebayItemId: String(p.ebayItemId), title: p.title, price: p.price, listedAt: p.listedAt || today })) };
const rep = MV.syncAll(data, snap, { by: 'mark-run' });
const linked = new Set(data.items.filter(i => i.vintedMatch === 'runner').map(i => String(i.vintedId)));
const missed = pairs.filter(p => !linked.has(String(p.vintedId)));
console.log('linked by exact id: ' + rep.runnerLinked + ' of ' + pairs.length + ' | marked eBay + Vinted: ' + rep.crossMarked.length);
(rep.newOwn || []).forEach(n => console.log('  NEW Vinted-only item (own record, not linked to eBay): Vinted ' + n.vintedId + ' | ' + n.sku + ' | ' + n.title.slice(0, 60)));
rep.crossMarked.forEach(m => console.log('  eBay + Vinted: ' + m.sku + ' | eBay ' + m.ebayItemId + ' | Vinted ' + m.vintedId + ' | ' + m.title.slice(0, 60)));
if (missed.length) { console.log('NOT LINKED (no open Mojonator record has that eBay item number) - fix by hand:'); missed.forEach(p => console.log('  eBay ' + p.ebayItemId + ' / Vinted ' + p.vintedId + ' ' + (p.title || ''))); }
fs.writeFileSync(dataPath, JSON.stringify(data, null, 2));
process.exit(missed.length ? 1 : 0);
