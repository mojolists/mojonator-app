# Vinted run tools (saved 2026-11-07)

The low-token eBay → Vinted route, proven on the 2026-11-06/07 CD runs. Nothing here holds a key.

| Step | Tool | Where it runs |
|---|---|---|
| 1. List on Vinted | `tools/vinted-runner.js` (this repo, served at https://mojolists.com/mojonator-app/tools/vinted-runner.js) | Doug's signed-in vinted.com tab (his Chrome) |
| 2. Link to Mojonator | `vinted-sync.user.js` / `vinted-merge.js` (repo root) | same tab — picks up the runner's records within a minute |
| 3. End on eBay | `tools/ebaytrade.py` in the **private** repo `mojolists/mojonator` (copy also in `Mojo Lister\Claude outputs\tools\` on the data PC) | device VM, from the Mojo Lister settings folder |

## Run order (≈8 tool calls per batch, any size)
0. **Pick only stock that still exists — and look at it (added 2026-11-14).** On 2026-11-13 an MC Hammer cassette that had
   sold on eBay four days earlier was listed on Vinted and sold again, and a Fastway tape went up with another band's
   photos. Both checks are now mandatory and the runner refuses a run without them:
   - **Stock:** an eBay listing being *active* proves nothing — with out-of-stock control a sold-out listing stays in the
     Active list at quantity 0. Pick with `tools/vinted-pick.js` in the Mojonator tab (`MojoVintedPick({match:/cassette/i,maxPrice:4.99,count:10})`),
     which only returns records with eBay available quantity ≥ 1 and no sale on them, and put that number in each job as `ebayQty`.
     If picking by hand, read "Available quantity" in Seller Hub for every item.
   - **Photos:** download the main photo of every job and look at it; the artist and album on the case must match the title.
     Only then set `photosChecked: true`. A mismatch is reported to Doug, not listed.
1. Prepare the job list (`ebayQty` and `photosChecked: true` from step 0, eBay item id, **eBay SKU** (required — the runner appends ` - SKU` to the end of every Vinted title, since Vinted has no SKU field; rule from 2026-11-08, new listings only), title, description, Doug's price, condition, media, eBay photo URLs — **front cover first**).
2. In the vinted.com tab: load the runner, then `MojoVintedRunner.start(jobs)` — returns at once; it lists one item per minute in the background.
3. Wait (≈1 min per item), then read `MojoVintedRunner.status()` **once**.
4. `MojoVintedRunner.dupCheck()` — duplicate active titles on the profile.
5. End the whole batch on eBay in ONE call: `cd "$HOME/mnt/Mojo Lister" && python3 "Claude outputs/tools/ebaytrade.py" end <id> <id> …`
6. Pull sheet by eBay SKU/crate for Doug.

Condition map: like new / very good → Very good (2) · good → Good (3) · sealed/new → New with tags (6). Package size Small (1).
CD catalog id 3039. DVD/Blu-ray/cassette: run `MojoVintedRunner.captureCatalog()` and list ONE by hand through the form, then add the id to `CATALOG` in the runner.
If Vinted shows a check page, the runner stops itself — clear it in the browser, then `MojoVintedRunner.resume()`.

## Cross-listing (one disc live on eBay AND Vinted) — added 2026-11-11
- To cross-list, run steps 1–4 above and **skip step 5** (do not end the eBay listing). The runner record links the
  Vinted listing to the item; the next eBay sync sees the eBay listing still live and marks the item `crossStatus: both`.
- One disc = one Mojonator record, whatever happens: `both` → `sold-vinted` (Vinted sale) or
  `sold-ebay-pending-vinted-hide` → `sold-ebay` (eBay sale, then hidden/deleted on Vinted). `double-sale` = sold on both.
- Singles only. Never cross-list a disc that is inside a bundle, or two listings with the same title.
- Hide/unhide a Vinted listing: `PUT /api/v2/items/{id}/is_hidden` with `{"is_hidden":true|false}` and the same
  headers the runner uses (X-CSRF-Token, X-Anon-Id). Verified 2026-11-09.
- The original first-listed date is never changed by a relist, a cross-list or a sale.

## Vinted-only items (Mojo Lister 0.8.22, 2026-11-14)
Drafts with Mojo Lister's **Vinted** box checked never go in the eBay file. Upload All hosts their photos on eBay
Picture Services and writes a `vinted-*.json` job file (copy in `Mojo Lister\data\exports\`). Doug says when to list.
- Jobs carry `vintedOnly: true` + `draftId` — no eBay listing, so no ebayQty check and nothing to end on eBay.
- Price is exactly what Doug typed (no floor, no $4.99 math).
- Conditions: Like New -> New without tags, Very Good -> Very good, Good -> Good, Brand New -> New with tags, Acceptable -> flagged.
- Before `start()`: view each main photo against the title, check edition/UPC against the case photo, fill any
  `needs` (missing SKU, DVD/Blu-ray catalogId, Acceptable grade), then set `photosChecked: true` per job.
- Descriptions: title + UPC + tracklist — NO case line (he swaps broken cases).
- The eBay HTML description is saved in `Mojo Lister\data\ebay-description-library.json` (keyed by UPC) for a later identical item.
- After the run: `dupCheck()`; results also in localStorage `__mojo_vinted_only_log`.
