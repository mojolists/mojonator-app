# Vinted run tools (saved 2026-11-07)

The low-token eBay → Vinted route, proven on the 2026-11-06/07 CD runs. Nothing here holds a key.

| Step | Tool | Where it runs |
|---|---|---|
| 1. List on Vinted | `tools/vinted-runner.js` (this repo, served at https://mojolists.com/mojonator-app/tools/vinted-runner.js) | Doug's signed-in vinted.com tab (his Chrome) |
| 2. Link to Mojonator | `vinted-sync.user.js` / `vinted-merge.js` (repo root) | same tab — picks up the runner's records within a minute |
| 3. End on eBay | `tools/ebaytrade.py` in the **private** repo `mojolists/mojonator` (copy also in `Mojo Lister\Claude outputs\tools\` on the data PC) | device VM, from the Mojo Lister settings folder |

## Run order (≈8 tool calls per batch, any size)
1. Prepare the job list (eBay item id, **eBay SKU** (required — the runner appends ` - SKU` to the end of every Vinted title, since Vinted has no SKU field; rule from 2026-11-08, new listings only), title, description, Doug's price, condition, media, eBay photo URLs — **front cover first**).
2. In the vinted.com tab: load the runner, then `MojoVintedRunner.start(jobs)` — returns at once; it lists one item per minute in the background.
3. Wait (≈1 min per item), then read `MojoVintedRunner.status()` **once**.
4. `MojoVintedRunner.dupCheck()` — duplicate active titles on the profile.
5. End the whole batch on eBay in ONE call: `cd "$HOME/mnt/Mojo Lister" && python3 "Claude outputs/tools/ebaytrade.py" end <id> <id> …`
6. Pull sheet by eBay SKU/crate for Doug.

Condition map: like new / very good → Very good (2) · good → Good (3) · sealed/new → New with tags (6). Package size Small (1).
CD catalog id 3039. DVD/Blu-ray/cassette: run `MojoVintedRunner.captureCatalog()` and list ONE by hand through the form, then add the id to `CATALOG` in the runner.
If Vinted shows a check page, the runner stops itself — clear it in the browser, then `MojoVintedRunner.resume()`.
