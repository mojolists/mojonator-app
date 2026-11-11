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
