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

## 0.3.2 (2026-11-18) - a handled sale always says so

Before this, a cross-listed sale that was handled correctly produced no alert at all, so silence could mean "handled" or
"never seen". Now every handled sale sends one normal-priority alert with the item's location:
`Sold on Vinted, off eBay: <title>` or `Sold on eBay, off Vinted: <title>`. The backup PC sends the same confirmation
20 minutes later only if the main PC has not already sent it (so it also covers a main PC on an older version).
Problems still arrive as high-priority alerts. `"notify_success": false` in config.json turns the confirmations off.

## 0.3.1 (2026-11-17) - only MARKED items are ever changed; marks come from exact ids

What went wrong: a cassette sold on Vinted while the same title was live on eBay. The program only knows a Vinted listing through
its link in Mojonator, and Mojonator's Vinted sync had not run since Nov 8, so listings made after that - including 9 CDs that
really were cross-listed - were unknown to it.

The rule (Doug, 2026-11-17): **a matching title is never proof.** The same title is often another copy, another condition, or a
multi-quantity listing (the Criterion Princess Bride). The program must KNOW which item is cross-listed.

1. **A mark is an exact pair**: eBay item number <-> Vinted listing id, recorded when the listing is made.
   - Listing runs: the runner records the pair; `node tools/mark-run.js data.json pairs.json` writes it into Mojonator right
     after the run (required step, see tools/README.md), and the Chrome helper on the PC where the run was made does the same
     within 15 minutes as a second line.
   - The Chrome helper (`vinted-hider.user.js` 0.3.1) runs Mojonator's Vinted sync from the always-open Vinted tab every 15
     minutes when Vinted changed (GitHub token from this program's `config.json`, 127.0.0.1 only), so Mojonator no longer
     depends on anyone running a sync. Never at :12-:30 past the hour. The backup PC gives the main PC 20 minutes first.
2. **Only marked items are acted on.** Vinted sale of a marked item -> its eBay listing goes to quantity 0. eBay sale of a marked
   item -> its Vinted listing is hidden. Nothing else is ever ended or hidden.
3. **Unmarked sale, same title live on the other site -> alert only**, naming the listing(s): "Sold on Vinted - on eBay too?" /
   "Sold on eBay - on Vinted too?". Doug decides. No title on the other site -> log line, no alert.
4. **"Is this cross-listed?"** - once per new Vinted listing whose title is also live on eBay and that has no mark (e.g. listed by
   hand). Link it in Mojonator (Vinted, Needs confirmation) or tell Claude; until then the program will not touch it.

Updating a PC: replace `crosslist-sync.exe` (close the window first, start it again after), and let Tampermonkey update the helper
(or open `vinted-hider.user.js` from GitHub once and press Update). `/status` shows `version`, `live_ebay_unlinked`, `vinted_seen`.
