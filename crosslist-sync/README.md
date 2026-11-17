# Mojo Crosslist Sync

Keeps eBay and Vinted in step for discs listed on both. Runs on one always-on Windows PC (the X51).

Every 10 minutes it asks eBay for new orders and reads new Vinted "You sold an item" emails
(mojolists.recycled, read-only). A sale is matched to its Mojonator record by eBay item number
or by the Vinted photo code in the email.

| Mode | What it does |
|---|---|
| `watch` (default) | Changes nothing. Sends a phone alert with the link to remove the other listing yourself. |
| `live` | eBay sale: hides the Vinted listing through Chrome (`vinted-hider.user.js`). Vinted sale: sets the eBay listing to quantity 0. Checks each one and alerts if it did not work. |

To pause it, set `"mode": "watch"` in `config.json` and restart the program.

## Files
- `crosslist-sync.exe` - the program. `Test-connections.bat` runs `crosslist-sync.exe --test` (checks every login, replays the last 7 days, changes nothing).
- `config.json` - settings and logins. Never share this file.
- `vinted-hider.user.js` - Tampermonkey script for Chrome on the same PC, signed in to vinted.com.
- Written while running: `crosslist.log` (everything), `actions.csv` (every action or would-be action), `state.json`.

## Alerts
ntfy topic in `config.json`; optional `alert_email`. The outside watchdog (healthchecks.io) is pinged every cycle and
alerts when the pings stop or a cycle fails.

## Not built yet
- The twice-daily full comparison of both sites.
- Writing Vinted sales into Mojonator (Mojonator still learns of them through its own Vinted sync).

Tests: `python tests/test_crosslist.py path/to/data.json`

## Backup PC (0.2.0)

A second copy can run on another always-on PC with `"role": "backup"` in its `config.json` (plus `"mode": "live"`, a `pc_name`
for alert wording, and its OWN `healthcheck_url` or a blank one - never the main PC's, or a dead main PC would look alive).

The backup watches the same eBay orders and Vinted sale emails, but leaves each sale alone for `backup_delay_minutes` (20).
Then it checks the real listing: if the eBay quantity is already 0, or the Vinted listing is already hidden/gone, it does nothing
and says nothing. If the listing is still for sale it does the job itself and sends a `BACKUP ...` alert, which means the main PC
missed one and needs a look. It needs the same Tampermonkey script in a signed-in Vinted tab in Chrome on the backup PC.
Alerts the main PC already sent are not repeated (it reads the ntfy channel to check).

Easiest set-up: copy the main PC's `config.json` unchanged and start the program with `Start-backup.bat`
(`crosslist-sync.exe --backup --live`). In the backup role the program ignores `healthcheck_url` and pings only
`backup_healthcheck_url` (blank by default).

## 0.3.0 (2026-11-17) - cross-listed items are marked without anyone running a sync

What went wrong: a cassette sold on Vinted while the same title was live on eBay. The program only knew a Vinted listing through
its link in Mojonator, and Mojonator's Vinted sync had not run since Nov 8, so every listing made after that was unknown to it and
a sale only produced a "Check Vinted sale" alert.

What changed:

1. **Marking.** The Chrome helper (`vinted-hider.user.js` 0.3.0) reads the Vinted profile every 15 minutes from the always-open
   Vinted tab. When anything changed it runs Mojonator's own Vinted sync and saves `data.json` (GitHub token from this program's
   `config.json`, handed over on 127.0.0.1 only). A new Vinted listing whose title - minus the ` - SKU` tail - is exactly the title of
   one live eBay item with the same SKU is linked to that item and marked **eBay + Vinted** at once. No sync has to be run by hand,
   whoever made the listing. The backup PC gives the main PC 20 minutes first. Nothing is written at :12-:30 past the hour.
2. **Safety net.** A sale Mojonator has not linked is no longer just an alert:
   - Vinted sale: the live eBay listings are searched for the exact title. One hit -> quantity 0 on eBay and a "Took it off eBay"
     alert. If the Vinted title says one SKU and the eBay listing another, the alert says so (it may be a second copy - put the
     quantity back to 1). Several hits and the SKU does not settle it, or only a near match -> alert naming the eBay item(s).
     Nothing with that title on eBay -> log line only, no alert.
   - eBay sale: the active Vinted listings (from the helper) are searched the same way and the twin is hidden.
   - A linked Vinted sale also checks for a second live eBay listing with the very same title and treats it the same way.
   - `"same_title_twins": "alert"` in `config.json` turns the automatic quantity-0 on title-only matches into an alert.
3. **"Is this cross-listed?"** alert when a new Vinted listing has the same title as a live eBay listing but a different SKU, so it
   could not be marked.

Updating a PC: replace `crosslist-sync.exe` (close the window first, start it again after), and let Tampermonkey update the helper
(or open `vinted-hider.user.js` from GitHub once and press Update). `/status` shows `version`, `live_ebay_unlinked`, `vinted_seen`.
