#!/usr/bin/env python3
"""Mojo Crosslist Sync - keeps eBay and Vinted in step for items listed on both.

Every few minutes it:
  1. asks eBay for new orders (Trading API GetOrders)
  2. reads new Vinted "You sold an item" emails over IMAP (read-only, never marks them read)
  3. matches each sale to its Mojonator record (eBay item number / Vinted photo code)
  4. watch mode: logs and alerts what it WOULD do.  live mode: sets the eBay listing to
     quantity 0, or queues a Vinted "hide" for the browser helper (vinted-hider.user.js)
  5. pings the outside watchdog (healthchecks.io)

A second copy can run on another PC with "role": "backup".  The backup looks at every sale again
backup_delay_minutes later, checks the real listing, and acts only if the main PC has not.

Python standard library only.  Settings: config.json beside the program.
  crosslist-sync            run the service
  crosslist-sync --test     check every connection once, replay the last 7 days, change nothing
"""
import base64, csv, email, email.policy, html, imaplib, json, os, re, smtplib, ssl, sys, threading, time, traceback
import urllib.error, urllib.parse, urllib.request
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = '0.2.0'
BASE = os.path.dirname(os.path.abspath(sys.executable if getattr(sys, 'frozen', False) else __file__))
CONFIG_FILE = os.path.join(BASE, 'config.json')
STATE_FILE = os.path.join(BASE, 'state.json')
LOG_FILE = os.path.join(BASE, 'crosslist.log')
ACTIONS_FILE = os.path.join(BASE, 'actions.csv')
CACHE_FILE = os.path.join(BASE, 'mojonator-cache.json')

DEFAULT_CONFIG = {
    'mode': 'watch',                       # 'watch' = alert only, change nothing.  'live' = act.
    'poll_minutes': 10,
    'gmail': {'user': 'mojolists.recycled@gmail.com', 'app_password': ''},
    'ebay': {'client_id': '', 'client_secret': '', 'refresh_token': ''},
    'github': {'token': '', 'repo': 'mojolists/mojonator'},
    'ntfy_topic': '',
    'healthcheck_url': '',
    'alert_email': '',                     # optional second alert channel (sent through the Gmail account above)
    'port': 8765,
    'hide_alert_minutes': 30,
    'role': 'main',                        # 'main' = acts at once.  'backup' = second PC: re-checks each sale later, acts only if still needed.
    'backup_delay_minutes': 20,
    'pc_name': '',                         # shown in alerts; blank = 'X51' for main, 'backup PC' for backup
}

PHOTO_RE = re.compile(r'images\d*\.vinted\.net/t[a-z]*/(\d+_[0-9a-fA-F]+_[A-Za-z0-9]+)/')
EBAY_SCOPE = 'https://api.ebay.com/oauth/api_scope/sell.inventory'
lock = threading.RLock()


# ---------------------------------------------------------------- small helpers
def now(): return time.time()
def iso(t=None): return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t if t is not None else now()))


def log(msg):
    line = iso() + ' ' + msg
    try: print(line, flush=True)
    except Exception: pass
    try:
        with open(LOG_FILE, 'a', encoding='utf-8') as f: f.write(line + '\n')
    except Exception: pass


def record_action(kind, title, ebay_id, vinted_id, result):
    new = not os.path.exists(ACTIONS_FILE)
    try:
        with open(ACTIONS_FILE, 'a', newline='', encoding='utf-8') as f:
            w = csv.writer(f)
            if new: w.writerow(['time', 'action', 'title', 'ebay_item', 'vinted_item', 'result'])
            w.writerow([iso(), kind, title, ebay_id, vinted_id, result])
    except Exception as e:
        log('could not write actions.csv: %s' % e)


def load_json(path, default):
    try:
        with open(path, 'r', encoding='utf-8') as f: return json.load(f)
    except Exception: return default


def save_json(path, obj):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f: json.dump(obj, f, indent=1)
    os.replace(tmp, path)


def merged_config():
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    user = load_json(CONFIG_FILE, None)
    if user is None: return None
    for k, v in user.items():
        if isinstance(v, dict) and isinstance(cfg.get(k), dict): cfg[k].update(v)
        else: cfg[k] = v
    return cfg


def http(url, data=None, headers=None, method=None, timeout=30):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, dict(r.headers), r.read()


# ---------------------------------------------------------------- alerts
class Alerts:
    def __init__(self, cfg, state):
        self.cfg, self.state = cfg, state

    def send(self, title, body, click=None, key=None, repeat_hours=6, high=False):
        """key: the same key is not re-sent within repeat_hours."""
        if key:
            sent = self.state.setdefault('alerts', {})
            if now() - sent.get(key, 0) < repeat_hours * 3600: return False
            sent[key] = now()
        log('ALERT: %s | %s%s' % (title, body, (' | ' + click) if click else ''))
        ok = False
        topic = self.cfg.get('ntfy_topic')
        if topic:
            try:
                h = {'Title': title.encode('utf-8').decode('latin-1', 'replace'), 'Priority': 'high' if high else 'default'}
                if click: h['Click'] = click
                http('https://ntfy.sh/' + topic, data=body.encode('utf-8'), headers=h, timeout=20)
                ok = True
            except Exception as e:
                log('ntfy send failed: %s' % e)
        to = self.cfg.get('alert_email'); g = self.cfg.get('gmail', {})
        if to and g.get('app_password'):
            try:
                m = EmailMessage(); m['Subject'] = '[Crosslist] ' + title; m['From'] = g['user']; m['To'] = to
                m.set_content(body + ('\n\n' + click if click else ''))
                with smtplib.SMTP_SSL('smtp.gmail.com', 465, timeout=30) as s:
                    s.login(g['user'], g['app_password'].replace(' ', '')); s.send_message(m)
                ok = True
            except Exception as e:
                log('email alert failed: %s' % e)
        return ok


    def recent_titles(self, hours=12):
        """Titles already sent to the phone channel (by any PC) in the last hours.  None = could not tell."""
        topic = self.cfg.get('ntfy_topic')
        if not topic: return None
        try:
            st, hd, raw = http('https://ntfy.sh/%s/json?poll=1&since=%dh' % (topic, hours), timeout=20)
            out = set()
            for line in raw.decode('utf-8', 'replace').splitlines():
                try: out.add(json.loads(line).get('title') or '')
                except Exception: pass
            return out
        except Exception as e:
            log('could not read the alert channel: %s' % e); return None


# ---------------------------------------------------------------- Mojonator links (data.json)
class Links:
    """Which eBay item number / Vinted photo belongs to which Mojonator record."""
    def __init__(self, cfg, state):
        self.cfg, self.state = cfg, state
        self.by_ebay, self.by_photo, self.by_title, self.count = {}, {}, {}, 0

    def refresh(self):
        g = self.cfg['github']
        if g.get('local_file'):  # testing: read a local copy of data.json
            self.build(load_json(g['local_file'], {}).get('items', [])); return
        h = {'Accept': 'application/vnd.github.raw', 'User-Agent': 'mojo-crosslist-sync'}
        if g.get('token'): h['Authorization'] = 'Bearer ' + g['token']
        etag = self.state.get('data_etag')
        if etag and os.path.exists(CACHE_FILE): h['If-None-Match'] = etag
        try:
            st, hd, body = http('https://api.github.com/repos/%s/contents/data.json' % g['repo'], headers=h, timeout=60)
            data = json.loads(body.decode('utf-8'))
            with open(CACHE_FILE, 'wb') as f: f.write(body)
            self.state['data_etag'] = hd.get('ETag') or hd.get('Etag') or ''
        except urllib.error.HTTPError as e:
            if e.code != 304: raise
            data = load_json(CACHE_FILE, None)
            if data is None: self.state['data_etag'] = ''; raise RuntimeError('Mojonator cache missing')
        self.build(data.get('items', []))

    def build(self, items):
        by_ebay, by_photo, by_title, n = {}, {}, {}, 0
        for it in items:
            if not it.get('vintedId'): continue
            if it.get('status') == 'bundled': continue
            n += 1
            rec = {'id': it.get('id'), 'title': html.unescape(it.get('title') or ''), 'location': it.get('location') or it.get('sku') or '',
                   'ebayItemId': str(it.get('ebayItemId') or ''), 'vintedId': str(it.get('vintedId')),
                   'vintedUrl': it.get('vintedUrl') or ('https://www.vinted.com/items/' + str(it.get('vintedId'))),
                   'vintedStatus': it.get('vintedStatus') or '', 'crossStatus': it.get('crossStatus') or '',
                   'status': it.get('status') or '', 'account': it.get('account') or ''}
            ids = [rec['ebayItemId']] + [str(p) for p in ((it.get('relist') or {}).get('prevIds') or [])]
            for i in ids:
                if i: by_ebay.setdefault(i, []).append(rec)
            for u in it.get('vintedPhotos') or []:
                m = PHOTO_RE.search(u)
                if m: by_photo.setdefault(m.group(1), []).append(rec)
            by_title.setdefault(norm_title(rec['title']), []).append(rec)
        self.by_ebay, self.by_photo, self.by_title, self.count = by_ebay, by_photo, by_title, n

    def for_ebay_item(self, item_id):
        recs = {r['id']: r for r in self.by_ebay.get(str(item_id), [])}
        return list(recs.values())

    def for_photo_codes(self, codes):
        recs = {}
        for c in codes:
            for r in self.by_photo.get(c, []): recs[r['id']] = r
        return list(recs.values())


def norm_title(s): return re.sub(r'\s+', ' ', html.unescape(s or '')).strip().lower()


# ---------------------------------------------------------------- eBay (Trading API)
class Ebay:
    def __init__(self, cfg):
        self.c = cfg['ebay']; self.tok = None; self.exp = 0

    def token(self):
        if self.tok and self.exp > now() + 120: return self.tok
        b = base64.b64encode(('%s:%s' % (self.c['client_id'], self.c['client_secret'])).encode()).decode()
        body = urllib.parse.urlencode({'grant_type': 'refresh_token', 'refresh_token': self.c['refresh_token'], 'scope': EBAY_SCOPE}).encode()
        try:
            st, hd, raw = http('https://api.ebay.com/identity/v1/oauth2/token', data=body,
                               headers={'Authorization': 'Basic ' + b, 'Content-Type': 'application/x-www-form-urlencoded'})
        except urllib.error.HTTPError as e:
            raise RuntimeError('eBay sign-in failed (%s): %s' % (e.code, e.read().decode('utf-8', 'replace')[:200]))
        j = json.loads(raw); self.tok = j['access_token']; self.exp = now() + int(j.get('expires_in', 7200))
        return self.tok

    def call(self, name, inner):
        xml = '<?xml version="1.0" encoding="utf-8"?><%sRequest xmlns="urn:ebay:apis:eBLBaseComponents">%s</%sRequest>' % (name, inner, name)
        h = {'X-EBAY-API-SITEID': '0', 'X-EBAY-API-COMPATIBILITY-LEVEL': '1227', 'X-EBAY-API-CALL-NAME': name,
             'X-EBAY-API-IAF-TOKEN': self.token(), 'Content-Type': 'text/xml'}
        st, hd, raw = http('https://api.ebay.com/ws/api.dll', data=xml.encode('utf-8'), headers=h, timeout=45)
        out = raw.decode('utf-8', 'replace')
        ack = xval(out, 'Ack')
        if ack not in ('Success', 'Warning'):
            raise RuntimeError('%s failed: %s' % (name, ' | '.join(re.findall(r'<LongMessage>(.*?)</LongMessage>', out, re.S))[:300] or 'no detail'))
        return out

    def orders_since(self, since_ts):
        """[(order_id, created, [(item_id, title)])] for orders created since since_ts."""
        out, page = [], 1
        while True:
            inner = ('<CreateTimeFrom>%s</CreateTimeFrom><CreateTimeTo>%s</CreateTimeTo><OrderRole>Seller</OrderRole><OrderStatus>All</OrderStatus>'
                     '<Pagination><EntriesPerPage>100</EntriesPerPage><PageNumber>%d</PageNumber></Pagination>'
                     % (ebay_time(since_ts), ebay_time(now()), page))
            x = self.call('GetOrders', inner)
            out.extend(parse_orders(x))
            if xval(x, 'HasMoreOrders') != 'true' or page >= 20: break
            page += 1
        return out

    def item_state(self, item_id, follow=3):
        """{'id','status','available','title'} - follows a relist chain to the newest listing."""
        cur = str(item_id)
        for _ in range(follow + 1):
            x = self.call('GetItem', '<ItemID>%s</ItemID>' % cur)
            nxt = xval(x, 'RelistedItemID')
            status = xval(x, 'ListingStatus')
            if nxt and status != 'Active': cur = nxt; continue
            q = int(xval(x, 'Quantity') or 0); sold = int(xval(x, 'QuantitySold') or 0)
            return {'id': cur, 'status': status, 'available': max(0, q - sold) if status == 'Active' else 0, 'title': html.unescape(xval(x, 'Title'))}
        return {'id': cur, 'status': 'Unknown', 'available': 0, 'title': ''}

    def zero(self, item_id):
        """Take a listing off sale: quantity 0 (out-of-stock control keeps the listing); falls back to ending it."""
        try:
            self.call('ReviseInventoryStatus', '<InventoryStatus><ItemID>%s</ItemID><Quantity>0</Quantity></InventoryStatus>' % item_id)
            return 'quantity set to 0'
        except Exception as e1:
            self.call('EndFixedPriceItem', '<ItemID>%s</ItemID><EndingReason>NotAvailable</EndingReason>' % item_id)
            return 'listing ended (quantity 0 was refused: %s)' % str(e1)[:120]


def xval(x, tag):
    m = re.search(r'<%s(?:\s[^>]*)?>(.*?)</%s>' % (tag, tag), x, re.S)
    return m.group(1) if m else ''


def ebay_time(t): return time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime(t))


def parse_orders(x):
    out = []
    for o in re.findall(r'<Order>(.*?)</Order>', x, re.S):
        oid = xval(o, 'OrderID'); created = xval(o, 'CreatedTime'); status = xval(o, 'OrderStatus')
        if status in ('Cancelled', 'Inactive'): continue
        lines = []
        for t in re.findall(r'<Transaction>(.*?)</Transaction>', o, re.S):
            item = xval(t, 'Item')
            iid = xval(item, 'ItemID') or xval(t, 'ItemID')
            if iid: lines.append((iid, html.unescape(xval(item, 'Title'))))
        if oid and lines: out.append((oid, created, lines))
    return out


# ---------------------------------------------------------------- Vinted sale emails (Gmail IMAP, read-only)
def parse_vinted_email(raw_bytes):
    """-> {'id','subject','sold':bool,'codes':[...],'titles':[...]}"""
    msg = email.message_from_bytes(raw_bytes, policy=email.policy.default)
    subject = str(msg.get('Subject') or '')
    mid = str(msg.get('Message-ID') or '').strip() or ('no-id:' + subject + str(msg.get('Date')))
    body_html, body_text = '', ''
    for part in msg.walk():
        ct = part.get_content_type()
        if ct == 'text/html' and not body_html:
            try: body_html = part.get_content()
            except Exception: body_html = (part.get_payload(decode=True) or b'').decode('utf-8', 'replace')
        elif ct == 'text/plain' and not body_text:
            try: body_text = part.get_content()
            except Exception: body_text = (part.get_payload(decode=True) or b'').decode('utf-8', 'replace')
    both = body_html + '\n' + body_text
    codes = []
    for c in PHOTO_RE.findall(both):
        if c not in codes: codes.append(c)
    titles = []
    for m in re.finditer(r'<img[^>]+src="[^"]*vinted\.net/t[^"]*"[^>]*alt="([^"]*)"', body_html):
        t = html.unescape(m.group(1)).strip()
        if t and t not in titles: titles.append(t)
    for m in re.finditer(r'<img[^>]+alt="([^"]*)"[^>]+src="[^"]*vinted\.net/t[^"]*"', body_html):
        t = html.unescape(m.group(1)).strip()
        if t and t not in titles: titles.append(t)
    sold = bool(re.search(r'you sold an item|has bought', subject + ' ' + both[:4000], re.I)) and bool(re.search(r'sold', subject, re.I))
    return {'id': mid, 'subject': subject, 'sold': sold, 'codes': codes, 'titles': titles}


class Mail:
    def __init__(self, cfg): self.g = cfg['gmail']

    def sale_emails(self, days=3):
        """Raw bytes of recent Vinted sale emails, from All Mail (works even if they were archived or read)."""
        M = imaplib.IMAP4_SSL('imap.gmail.com', 993, ssl_context=ssl.create_default_context(), timeout=60)
        try:
            M.login(self.g['user'], self.g['app_password'].replace(' ', ''))
            box = 'INBOX'
            typ, boxes = M.list()
            for b in boxes or []:
                s = b.decode('utf-8', 'replace')
                if '\\All' in s:
                    m = re.search(r'"([^"]+)"\s*$', s) or re.search(r'(\S+)\s*$', s)
                    if m: box = m.group(1)
            typ, _ = M.select('"%s"' % box, readonly=True)
            if typ != 'OK': M.select('INBOX', readonly=True)
            q = 'from:vinted.com subject:(sold) newer_than:%dd' % days
            typ, data = M.uid('SEARCH', None, 'X-GM-RAW', '"%s"' % q)
            if typ != 'OK': raise RuntimeError('mail search failed')
            out = []
            for uid in (data[0] or b'').split()[-60:]:
                typ, d = M.uid('FETCH', uid, '(BODY.PEEK[])')
                if typ == 'OK' and d and isinstance(d[0], tuple): out.append(d[0][1])
            return out
        finally:
            try: M.logout()
            except Exception: pass


# ---------------------------------------------------------------- the service
class Service:
    def __init__(self, cfg, dry=False):
        self.cfg = cfg; self.dry = dry
        self.state = load_json(STATE_FILE, {}) if not dry else {}
        self.state.setdefault('orders', {}); self.state.setdefault('emails', {}); self.state.setdefault('sold', {})
        self.state.setdefault('queue', []); self.state.setdefault('alerts', {})
        self.alerts = Alerts(cfg, self.state); self.links = Links(cfg, self.state)
        self.ebay = Ebay(cfg); self.mail = Mail(cfg)
        self.report = []; self.started = now()

    live = property(lambda self: self.cfg.get('mode') == 'live' and not self.dry)
    backup = property(lambda self: self.cfg.get('role') == 'backup')
    pc = property(lambda self: self.cfg.get('pc_name') or ('backup PC' if self.backup else 'X51'))

    def too_fresh(self, key):
        """Backup only: a sale is left alone until backup_delay_minutes after this PC first saw it, so the main PC goes first."""
        if not self.backup or self.dry: return False
        seen = self.state.setdefault('first_seen', {})
        seen.setdefault(key, now())
        if now() - seen[key] < float(self.cfg.get('backup_delay_minutes', 20)) * 60: return True
        seen.pop(key, None); return False

    def save(self):
        if self.dry: return
        with lock:
            for k in ('orders', 'emails', 'alerts'):  # keep the state file small
                d = self.state[k]
                if len(d) > 3000:
                    for key in sorted(d, key=lambda x: d[x] if isinstance(d[x], (int, float)) else 0)[:len(d) - 2000]: d.pop(key, None)
            save_json(STATE_FILE, self.state)

    def note(self, msg):
        self.report.append(msg)
        if not self.dry: log(msg)

    def act(self, kind, rec, ebay_id, result):
        if not self.dry: record_action(kind, rec['title'], ebay_id, rec['vintedId'], result)

    def tell(self, title, body, click=None, key=None, high=False):
        if self.dry: self.note('  (alert it would send) %s - %s' % (title, body)); return
        if self.backup and not title.startswith('BACKUP'):
            got = self.alerts.recent_titles()
            if got is not None and title in got:  # the main PC already told Doug exactly this
                log('alert not repeated (already sent by the main PC): %s' % title); return
        self.alerts.send(title, body, click=click, key=key, high=high)

    # ---- an item sold on one site
    def sold_on(self, site, rec, ref):
        other = 'vinted' if site == 'ebay' else 'ebay'
        prev = self.state['sold'].get(rec['id'])
        if prev and prev.get('site') == other:
            self.tell('SOLD ON BOTH: ' + rec['title'][:60], 'Sold on eBay and on Vinted. Cancel the Vinted sale.', click=rec['vintedUrl'], key='double:' + rec['id'], high=True)
            self.act('double-sale', rec, rec['ebayItemId'], 'alerted'); return
        if prev: return
        self.state['sold'][rec['id']] = {'site': site, 'at': now(), 'ref': ref}
        if site == 'ebay': self.hide_on_vinted(rec)
        else: self.zero_on_ebay(rec)

    def hide_on_vinted(self, rec):
        if rec['vintedStatus'] in ('sold', 'removed', 'hidden'):
            self.note('  eBay sale: "%s" - Vinted listing already %s, nothing to do' % (rec['title'][:60], rec['vintedStatus'])); return
        if self.live:
            with lock:
                self.state['queue'].append({'vintedId': rec['vintedId'], 'title': rec['title'], 'url': rec['vintedUrl'], 'location': rec['location'], 'queued': now(), 'done': False, 'alerted': False, 'ebayId': rec['ebayItemId']})
            self.note('  eBay sale: "%s" -> queued Vinted hide (%s)' % (rec['title'][:60], rec['vintedId']))
            self.act('hide-vinted', rec, rec['ebayItemId'], 'queued')
        else:
            self.note('  eBay sale: "%s" -> WOULD hide on Vinted (%s)' % (rec['title'][:60], rec['vintedId']))
            self.act('hide-vinted', rec, rec['ebayItemId'], 'watch-only')
            self.tell('Sold on eBay: ' + rec['title'][:60], 'Watch-only: hide or delete it on Vinted yourself. Location %s.' % (rec['location'] or '?'), click=rec['vintedUrl'], key='w-ebay:' + rec['id'])

    def zero_on_ebay(self, rec):
        if not rec['ebayItemId']:
            self.note('  Vinted sale: "%s" - not on eBay, nothing to do' % rec['title'][:60]); return
        try: st = self.ebay.item_state(rec['ebayItemId'])
        except Exception as e:
            self.tell('Check eBay: ' + rec['title'][:60], 'Sold on Vinted, but the eBay listing could not be checked (%s). End it on eBay if it is live.' % str(e)[:120],
                      click='https://www.ebay.com/itm/' + rec['ebayItemId'], key='chk:' + rec['id'], high=True); return
        link = 'https://www.ebay.com/itm/' + st['id']
        if st['available'] < 1:
            self.note('  Vinted sale: "%s" - eBay listing %s not for sale (%s), nothing to do%s' % (rec['title'][:60], st['id'], st['status'], ' (the main PC or you already handled it)' if self.backup else '')); return
        if self.live:
            try:
                res = self.ebay.zero(st['id']); after = self.ebay.item_state(st['id'], follow=0)
                if after['available'] > 0: raise RuntimeError('still shows %d available' % after['available'])
                self.note('  Vinted sale: "%s" -> eBay %s: %s (checked)' % (rec['title'][:60], st['id'], res))
                self.act('zero-ebay', rec, st['id'], res)
                if self.backup:
                    self.tell('BACKUP took it off eBay: ' + rec['title'][:50], 'Sold on Vinted. The X51 had not taken it off eBay after %d min, so the %s did (%s). Check the X51.' % (float(self.cfg.get('backup_delay_minutes', 20)), self.pc, res), click=link, key='bzero:' + rec['id'], high=True)
            except Exception as e:
                self.act('zero-ebay', rec, st['id'], 'FAILED ' + str(e)[:150])
                self.tell('End on eBay: ' + rec['title'][:60], 'Sold on Vinted. Taking it off eBay FAILED (%s). End the eBay listing yourself.' % str(e)[:120], click=link, key='zero:' + rec['id'], high=True)
        else:
            self.note('  Vinted sale: "%s" -> WOULD set eBay %s to quantity 0' % (rec['title'][:60], st['id']))
            self.act('zero-ebay', rec, st['id'], 'watch-only')
            self.tell('Sold on Vinted: ' + rec['title'][:60], 'Watch-only: end the eBay listing yourself. Location %s.' % (rec['location'] or '?'), click=link, key='w-vinted:' + rec['id'])

    # ---- checks
    def check_ebay(self, baseline=False, days=None):
        last = self.state.get('ebay_checked') or (now() - 86400 * 3)
        since = now() - 86400 * days if days else last - 7200  # 2 h overlap; seen orders are skipped
        orders = self.ebay.orders_since(since)
        new = 0
        for oid, created, lines in orders:
            for iid, title in lines:
                key = oid + ':' + iid
                if key in self.state['orders']: continue
                if not baseline and self.too_fresh('o:' + key): continue
                self.state['orders'][key] = now(); new += 1
                if baseline: continue
                recs = self.links.for_ebay_item(iid)
                if not recs:
                    if not self.dry: log('eBay order %s: %s (item %s) - not cross-listed, nothing to do' % (oid, title[:60], iid))
                    continue
                if len(recs) > 1:
                    self.tell('Check sale: ' + title[:60], 'eBay order %s matches %d Mojonator records. Check Vinted by hand.' % (oid, len(recs)), key='amb:' + key, high=True); continue
                self.note('eBay order %s (%s): %s' % (oid, created[:16], title[:70]))
                self.sold_on('ebay', recs[0], oid)
        self.state['ebay_checked'] = now()
        return len(orders), new

    def check_mail(self, baseline=False, days=3):
        raws = self.mail.sale_emails(days=days)
        new = 0
        for raw in raws:
            try: m = parse_vinted_email(raw)
            except Exception as e:
                self.tell('Vinted email unreadable', 'A Vinted email could not be read (%s). Check your Vinted sales.' % str(e)[:100], key='mailparse', high=True); continue
            if m['id'] in self.state['emails']: continue
            if not baseline and m['sold'] and self.too_fresh('m:' + m['id']): continue
            self.state['emails'][m['id']] = now(); new += 1
            if baseline or not m['sold']: continue
            name = (m['titles'][0] if m['titles'] else m['subject'])[:70]
            if not m['codes']:
                self.tell('Check Vinted sale', 'A Vinted sale email had no item photo to match (%s). Check whether the item is on eBay.' % name, key='nocode:' + m['id'], high=True); continue
            self.note('Vinted sale email: %s' % name)
            recs = self.links.for_photo_codes(m['codes'])
            unmatched = [c for c in m['codes'] if not self.links.by_photo.get(c)]
            for rec in recs: self.sold_on('vinted', rec, m['id'])
            if unmatched:
                # fall back to an exact title match before bothering Doug
                left = []
                for t in m['titles']:
                    hit = self.links.by_title.get(norm_title(t), [])
                    if len(hit) == 1 and hit[0]['id'] not in [r['id'] for r in recs]: self.sold_on('vinted', hit[0], m['id'])
                    elif not hit: left.append(t)
                if (left or not m['titles']) and len(recs) < len(m['codes']):
                    self.tell('Check Vinted sale: ' + name, 'Mojonator does not know this Vinted listing yet. If the item is also on eBay, end it there.', key='nomatch:' + m['id'], high=True)
        self.state['mail_checked'] = now()
        return len(raws), new

    def check_queue(self):
        """Hides the browser has not confirmed in time -> alert with the link."""
        mins = float(self.cfg.get('hide_alert_minutes', 30))
        with lock:
            for q in self.state['queue']:
                if q['done'] or q.get('alerted') or self.backup: continue  # backup: the 'browser not answering' alert below covers it
                if now() - q['queued'] > mins * 60:
                    q['alerted'] = True
                    self.alerts.send('Hide on Vinted: ' + q['title'][:60], 'Sold on eBay. The automatic hide has not happened in %d min. Hide or delete it on Vinted. Location %s.' % (mins, q.get('location') or '?'), click=q['url'], high=True)
            self.state['queue'] = [q for q in self.state['queue'] if not (q['done'] and now() - q['queued'] > 7 * 86400)]
        seen = self.state.get('browser_seen', 0)
        if self.live and now() - seen > 20 * 60 and now() - self.started > 20 * 60:  # 20 min grace after start-up
            waiting = len([q for q in self.state['queue'] if not q['done']])
            self.alerts.send('Vinted browser on the %s is not answering' % self.pc, 'The Chrome helper on the %s has not checked in for %s. Open Chrome there on vinted.com and make sure you are signed in.%s' % (self.pc, 'over 20 minutes' if seen else 'yet (never seen)', (' %d Vinted listing(s) are waiting to be checked.' % waiting) if waiting else ''),
                             key='browser', high=not self.backup or bool(waiting), repeat_hours=24 if self.backup and not waiting else 6)

    def cycle(self):
        ok = True; first = not self.state.get('baselined')
        steps = [('Mojonator links', lambda: self.links.refresh()),
                 ('eBay orders', lambda: self.check_ebay(baseline=first)),
                 ('Vinted sale emails', lambda: self.check_mail(baseline=first))]
        for name, fn in steps:
            try:
                r = fn()
                if name == 'eBay orders': log('eBay: %d order(s) in window, %d new%s' % (r[0], r[1], ' (baseline, not acted on)' if first else ''))
                if name == 'Vinted sale emails': log('mail: %d Vinted sale email(s) in window, %d new%s' % (r[0], r[1], ' (baseline, not acted on)' if first else ''))
                self.state.get('fails', {}).pop(name, None)
            except Exception as e:
                ok = False
                log('%s FAILED: %s' % (name, e)); log(traceback.format_exc(limit=3))
                fails = self.state.setdefault('fails', {}); fails[name] = fails.get(name, 0) + 1
                if fails[name] >= 2:  # one blip is retried quietly; two in a row is an alert
                    self.alerts.send('Crosslist sync problem on the %s: %s' % (self.pc, name), '%s failed twice in a row: %s' % (name, str(e)[:200]), key='fail:' + name, high=True)
                if name == 'Mojonator links' and not self.links.count: break
        if ok and first:
            self.state['baselined'] = iso()
            log('baseline done: existing orders and emails recorded; watching for new sales from now on (%d linked Vinted records)' % self.links.count)
        try: self.check_queue()
        except Exception as e: log('queue check failed: %s' % e)
        self.state['last_cycle'] = now(); self.state['last_ok'] = ok
        self.save()
        url = self.cfg.get('healthcheck_url')
        if url:
            try: http(url.rstrip('/') + ('' if ok else '/fail'), timeout=20)
            except Exception as e: log('watchdog ping failed: %s' % e)
        return ok


# ---------------------------------------------------------------- local endpoint for the Chrome helper
def make_handler(svc):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass

        def _send(self, code, obj):
            b = json.dumps(obj).encode()
            self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)

        def _ok(self):
            if self.headers.get('Origin'):  # web pages are refused; only the userscript (no Origin) and local tools get in
                self._send(403, {'error': 'forbidden'}); return False
            return True

        def do_GET(self):
            if not self._ok(): return
            if self.path.startswith('/queue'):
                with lock:
                    svc.state['browser_seen'] = now()
                    q = [{'vintedId': x['vintedId'], 'title': x['title']} for x in svc.state['queue'] if not x['done']] if svc.live else []
                self._send(200, {'mode': svc.cfg.get('mode'), 'queue': q})
            elif self.path.startswith('/status'):
                with lock:
                    s = svc.state
                    self._send(200, {'version': VERSION, 'mode': svc.cfg.get('mode'), 'role': 'backup' if svc.backup else 'main', 'last_cycle': iso(s.get('last_cycle')) if s.get('last_cycle') else None,
                                     'last_ok': s.get('last_ok'), 'linked_records': svc.links.count, 'pending_hides': len([x for x in s['queue'] if not x['done']]),
                                     'browser_seen': iso(s['browser_seen']) if s.get('browser_seen') else None})
            else: self._send(404, {'error': 'not found'})

        def do_POST(self):
            if not self._ok(): return
            if self.path.startswith('/done'):
                try: body = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)) or b'{}')
                except Exception: body = {}
                vid = str(body.get('vintedId') or ''); good = bool(body.get('ok')); acted = body.get('acted', True)
                with lock:
                    svc.state['browser_seen'] = now()
                    for x in svc.state['queue']:
                        if x['vintedId'] == vid and not x['done']:
                            if good: x['done'] = True
                            log('Vinted hide %s: %s %s' % (vid, ('confirmed hidden' if acted else 'was already off sale, nothing to do -') if good else 'FAILED', body.get('detail') or ''))
                            record_action('hide-vinted', x['title'], x.get('ebayId', ''), vid, ('hidden (checked)' if acted else 'already off sale') if good else 'FAILED ' + str(body.get('detail') or '')[:150])
                            if good and acted and svc.backup:
                                svc.alerts.send('BACKUP hid it on Vinted: ' + x['title'][:50], 'Sold on eBay. The X51 had not hidden it on Vinted, so the %s did. Check the X51.' % svc.pc, click=x['url'], high=True)
                            if not good and not x.get('alerted'):
                                x['alerted'] = True
                                svc.alerts.send('Hide on Vinted: ' + x['title'][:60], 'Sold on eBay. The automatic hide failed (%s). Hide or delete it on Vinted.' % str(body.get('detail') or '')[:100], click=x['url'], high=True)
                    svc.save()
                self._send(200, {'ok': True})
            else: self._send(404, {'error': 'not found'})
    return H


# ---------------------------------------------------------------- entry points
def self_test(cfg):
    print('Mojo Crosslist Sync %s - connection test (changes nothing)\n' % VERSION)
    svc = Service(cfg, dry=True); good = True

    def step(name, fn):
        nonlocal good
        try: print('[ OK ] %s: %s' % (name, fn()))
        except Exception as e: good = False; print('[FAIL] %s: %s' % (name, e))
    step('Mojonator data', lambda: (svc.links.refresh(), '%d Vinted-linked records, %d eBay numbers, %d photo codes' % (svc.links.count, len(svc.links.by_ebay), len(svc.links.by_photo)))[1])
    step('eBay sign-in', lambda: (svc.ebay.token(), 'token issued')[1])

    def ebay_replay():
        n, new = svc.check_ebay(days=7); return '%d order(s) in the last 7 days' % n
    step('eBay orders', ebay_replay)

    def mail_replay():
        n, new = svc.check_mail(days=7); return '%d Vinted sale email(s) in the last 7 days' % n
    step('Gmail (Vinted sale emails)', mail_replay)
    if cfg.get('ntfy_topic'):
        step('Phone alert', lambda: ('sent - check your phone' if Alerts(cfg, {}).send('Crosslist sync test', 'Connection test from the %s.' % svc.pc) else 'NOT sent'))
    if cfg.get('healthcheck_url'):
        step('Watchdog ping', lambda: (http(cfg['healthcheck_url'], timeout=20), 'pinged')[1])
    print('\nReplay of the last 7 days (what it would have done):')
    lines = [l for l in svc.report if l.strip()]
    print('\n'.join(lines) if lines else '  no cross-listed sales found in that window')
    print('\n' + ('ALL CHECKS PASSED' if good else 'SOME CHECKS FAILED - fix the lines marked FAIL'))
    return good


def main():
    cfg = merged_config()
    if cfg is None:
        save_json(CONFIG_FILE, DEFAULT_CONFIG)
        print('Created %s - fill it in, then start again.' % CONFIG_FILE); input('Press Enter to close.'); return 1
    if '--test' in sys.argv:
        ok = self_test(cfg)
        if getattr(sys, 'frozen', False): input('\nPress Enter to close.')
        return 0 if ok else 1
    svc = Service(cfg)
    try: server = ThreadingHTTPServer(('127.0.0.1', int(cfg.get('port', 8765))), make_handler(svc))
    except OSError:
        print('Crosslist sync is already running (port %s in use).' % cfg.get('port')); time.sleep(5); return 1
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log('Mojo Crosslist Sync %s started - mode %s, role %s, every %s min' % (VERSION, cfg.get('mode'), 'BACKUP (acts %s min after a sale, only if the main PC has not)' % cfg.get('backup_delay_minutes') if svc.backup else 'main', cfg.get('poll_minutes')))
    if cfg.get('mode') != 'live': log('WATCH-ONLY: nothing on eBay or Vinted will be changed')
    while True:
        try: svc.cycle()
        except Exception as e:
            log('cycle crashed: %s' % e); log(traceback.format_exc(limit=5))
        time.sleep(max(60, float(cfg.get('poll_minutes', 10)) * 60))


if __name__ == '__main__':
    sys.exit(main() or 0)
