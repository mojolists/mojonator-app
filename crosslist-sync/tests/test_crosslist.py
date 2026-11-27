"""Offline tests: python3 tests/test_crosslist.py /path/to/data.json"""
import json, os, sys, tempfile, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import crosslist as X
from email.message import EmailMessage

data_path = sys.argv[1]
tmp = tempfile.mkdtemp()
for n in ('STATE_FILE', 'LOG_FILE', 'ACTIONS_FILE', 'CACHE_FILE', 'WARD_FILE', 'ORDERS_FILE'): setattr(X, n, os.path.join(tmp, n))
sent = []
X.Alerts.send = lambda self, title, body, click=None, key=None, repeat_hours=6, high=False: sent.append((title, body, click)) or True

def vinted_mail(mid, title, code, subject='You sold an item on Vinted', extra=''):
    m = EmailMessage(); m['Subject'] = subject; m['From'] = 'Team Vinted <no-reply@vinted.com>'; m['To'] = 'x@example.com'; m['Message-ID'] = mid
    m.set_content('Hello mojolists,\nbuyer has bought\n%s\n$2.50' % title)
    img = '<img width=48 src="https://images1.vinted.net/t/%s/150x210/26783d13.jpeg?s=abc" alt="%s">' % (code, title) if code else ''
    m.add_alternative('<html><body><p>Hello mojolists,</p><p><b>buyer</b> has bought</p>%s<b>%s</b><b>$2.50</b>%s</body></html>' % (img, title, extra), subtype='html')
    return m.as_bytes()

ORDERS_XML = '''<GetOrdersResponse><Ack>Success</Ack><HasMoreOrders>false</HasMoreOrders><OrderArray>
<Order><OrderID>11-1</OrderID><OrderStatus>Completed</OrderStatus><CreatedTime>2026-11-11T10:00:00.000Z</CreatedTime><TransactionArray><Transaction><Buyer><Email>x</Email></Buyer><Item><ItemID>%s</ItemID><Title>T &amp; one</Title></Item></Transaction></TransactionArray></Order>
<Order><OrderID>11-2</OrderID><OrderStatus>Cancelled</OrderStatus><CreatedTime>2026-11-11T10:00:00.000Z</CreatedTime><TransactionArray><Transaction><Item><ItemID>999</ItemID><Title>x</Title></Item></Transaction></TransactionArray></Order>
<Order><OrderID>11-3</OrderID><OrderStatus>Active</OrderStatus><CreatedTime>2026-11-11T10:05:00.000Z</CreatedTime><TransactionArray><Transaction><Item><ItemID>123456</ItemID><Title>Not cross listed</Title></Item></Transaction></TransactionArray></Order>
</OrderArray></GetOrdersResponse>'''

class FakeEbay:
    def __init__(self): self.orders = []; self.items = {}; self.zeroed = []
    def token(self): return 't'
    def orders_since(self, since): return list(self.orders)
    def item_state(self, item_id, follow=3):
        return dict(self.items.get(str(item_id), {'id': str(item_id), 'status': 'Active', 'available': 1, 'title': ''}))
    def zero(self, item_id): self.zeroed.append(str(item_id)); self.items[str(item_id)] = {'id': str(item_id), 'status': 'Active', 'available': 0, 'title': ''}; return 'quantity set to 0'
class FakeMail:
    def __init__(self): self.raws = []
    def sale_emails(self, days=3): return list(self.raws)

def make(mode, every=False, backstop=False):
    for f in os.listdir(tmp): os.remove(os.path.join(tmp, f))
    del sent[:]
    cfg = json.loads(json.dumps(X.DEFAULT_CONFIG)); cfg['mode'] = mode; cfg['github']['local_file'] = data_path
    assert cfg['notify_every_sale'] is True; cfg['notify_every_sale'] = every  # the older tests below run with the 0.3.3 'needed nothing' alerts off
    s = X.Service(cfg); s.ebay = FakeEbay(); s.mail = FakeMail()
    if not backstop: s.backstop = lambda: (0, 0)  # the older tests below run without the 0.3.4 backstop (today's real sales would trigger it)
    assert s.cycle()  # baseline
    return s

items = json.load(open(data_path))['items']
both = [i for i in items if i.get('crossStatus') == 'both']
A, B = both[0], both[1]
codeA = X.PHOTO_RE.search(A['vintedPhotos'][0]).group(1)

# parsing
o = X.parse_orders(ORDERS_XML % A['ebayItemId'])
assert [x[0] for x in o] == ['11-1', '11-3'] and o[0][2][0] == (str(A['ebayItemId']), 'T & one'), o
m = X.parse_vinted_email(vinted_mail('<m1@v>', 'Gothika DVD 2004', '02_022f6_Q2a2AHCqDvJWgm1oCvYi5A6x'))
assert m['sold'] and m['codes'] == ['02_022f6_Q2a2AHCqDvJWgm1oCvYi5A6x'] and m['titles'] == ['Gothika DVD 2004'], m
assert not X.parse_vinted_email(vinted_mail('<m2@v>', 'x', codeA, subject='Your order has been shipped'))['sold']
print('parse ok')

# links on the real data
s = make('watch')
assert s.links.count >= 190 and len(s.links.for_ebay_item(A['ebayItemId'])) == 1 and len(s.links.for_photo_codes([codeA])) == 1
goth = s.links.for_photo_codes(['02_022f6_Q2a2AHCqDvJWgm1oCvYi5A6x']); assert len(goth) == 1 and goth[0]['vintedId'] == '10711095085'
old = A['relist']['prevIds'][-1]; assert s.links.for_ebay_item(old)[0]['id'] == A['id']  # an order under the pre-relist number still matches
print('links ok:', s.links.count, 'records')

# baseline: existing orders/emails are recorded, not acted on
s = make('watch'); s.ebay.orders = X.parse_orders(ORDERS_XML % A['ebayItemId']); s.mail.raws = [vinted_mail('<old@v>', B['title'], X.PHOTO_RE.search(B['vintedPhotos'][0]).group(1))]
s.state.pop('baselined'); s.state['orders'].clear(); s.state['emails'].clear(); assert s.cycle(); assert not sent and not s.state['sold']
print('baseline ok')

# watch mode: eBay sale -> alert with the Vinted link, nothing queued; repeat cycle is silent
s = make('watch'); s.ebay.orders = X.parse_orders(ORDERS_XML % A['ebayItemId']); s.cycle()
assert len(sent) == 1 and sent[0][0].startswith('Sold on eBay') and sent[0][2] == A['vintedUrl'] and not s.state['queue'], sent
s.cycle(); assert len(sent) == 1
# watch mode: Vinted sale -> alert with eBay link, nothing zeroed
s.mail.raws = [vinted_mail('<n1@v>', B['title'], X.PHOTO_RE.search(B['vintedPhotos'][0]).group(1))]; s.cycle()
assert len(sent) == 2 and sent[1][0].startswith('Sold on Vinted') and str(B['ebayItemId']) in sent[1][2] and not s.ebay.zeroed
print('watch mode ok')

# live mode: eBay sale -> queue; browser confirms; Vinted sale -> eBay zeroed and checked
s = make('live'); s.state['browser_seen'] = time.time(); s.ebay.orders = X.parse_orders(ORDERS_XML % A['ebayItemId']); s.cycle()
assert [q['vintedId'] for q in s.state['queue']] == [str(A['vintedId'])] and not sent
s.mail.raws = [vinted_mail('<n2@v>', B['title'], X.PHOTO_RE.search(B['vintedPhotos'][0]).group(1))]; s.state['browser_seen'] = time.time(); s.cycle()
# 0.3.2: a handled sale always says so (normal priority) - silence is never the 'it worked' signal
assert s.ebay.zeroed == [str(B['ebayItemId'])] and len(sent) == 1 and sent[0][0].startswith('Sold on Vinted, off eBay: ') and (B.get('location') or '?') in sent[0][1], sent
s.cycle(); assert len(sent) == 1, 'said once only'
del sent[:]
# hide not confirmed for 31 min -> alert once
s.state['queue'][0]['queued'] -= 31 * 60; s.state['browser_seen'] = time.time(); s.check_queue(); s.check_queue()
assert len(sent) == 1 and sent[0][0].startswith('Hide on Vinted')
# 0.3.2: notify_success off -> a handled sale is quiet again
q = make('live'); q.cfg['notify_success'] = False; q.state['browser_seen'] = time.time()
q.mail.raws = [vinted_mail('<n2q@v>', B['title'], X.PHOTO_RE.search(B['vintedPhotos'][0]).group(1))]; q.cycle(); assert q.ebay.zeroed and not sent, sent
# browser silent -> alert
s.state['browser_seen'] = time.time() - 3600; s.started -= 3600; s.check_queue(); assert sent[-1][0].startswith('Vinted browser')
print('live mode ok')

# double sale
s = make('watch'); s.ebay.orders = X.parse_orders(ORDERS_XML % A['ebayItemId']); s.cycle()
s.mail.raws = [vinted_mail('<n3@v>', A['title'], codeA)]; s.cycle(); assert sent[-1][0].startswith('SOLD ON BOTH'), sent
# unknown Vinted listing, and an email with no photo
s = make('watch'); s.mail.raws = [vinted_mail('<n4@v>', 'Some brand new listing', '01_00abc_ZZZZZZZZZZZZZZZZZZZZZZZZ'), vinted_mail('<n5@v>', 'No photo', '')]; s.cycle()
assert len(sent) == 1 and sent[0][0] == 'Check Vinted sale', sent  # 0.3.0: an unknown listing with no eBay twin is not an alert any more; a sale email with no photo still is
# Vinted-only item sells (not on eBay): no alert
vonly = [i for i in items if i.get('vintedId') and i.get('account') == 'V' and not i.get('ebayItemId') and i.get('vintedPhotos') and i.get('status') == 'listed'][0]
s = make('watch'); s.mail.raws = [vinted_mail('<n6@v>', vonly['title'], X.PHOTO_RE.search(vonly['vintedPhotos'][0]).group(1))]; s.cycle(); assert not sent, sent
# eBay listing already ended -> no alert
s = make('watch'); s.ebay.items[str(B['ebayItemId'])] = {'id': str(B['ebayItemId']), 'status': 'Completed', 'available': 0, 'title': ''}
s.mail.raws = [vinted_mail('<n7@v>', B['title'], X.PHOTO_RE.search(B['vintedPhotos'][0]).group(1))]; s.cycle(); assert not sent
# failures: one blip quiet, two in a row alert
s = make('watch')
def boom(since): raise RuntimeError('eBay down')
s.ebay.orders_since = boom; assert not s.cycle() and not sent; assert not s.cycle() and len(sent) == 1 and 'eBay orders' in sent[0][0]
print('edge cases ok')

# ---- backup role (second PC)
phone = set()
X.Alerts.recent_titles = lambda self, hours=12: set(phone)
def makeb():
    b = make('live'); b.cfg['role'] = 'backup'; b.cfg['backup_delay_minutes'] = 20; b.state['browser_seen'] = time.time(); return b
def age(b, mins):
    for k in b.state.get('first_seen', {}): b.state['first_seen'][k] -= mins * 60
codeB = X.PHOTO_RE.search(B['vintedPhotos'][0]).group(1)
# Vinted sale, main PC did its job (eBay already at 0): backup waits, then changes nothing.
# 0.3.2: it confirms the sale was handled ONLY when the main PC did not already send that same confirmation
b = makeb(); b.mail.raws = [vinted_mail('<b1@v>', B['title'], codeB)]; b.cycle()
assert not b.ebay.zeroed and not sent and not b.state['sold'], 'backup must wait'
b.ebay.items[str(B['ebayItemId'])] = {'id': str(B['ebayItemId']), 'status': 'Active', 'available': 0, 'title': ''}
age(b, 21); b.state['browser_seen'] = time.time(); b.cycle()
assert not b.ebay.zeroed and len(sent) == 1 and sent[0][0].startswith('Sold on Vinted, off eBay: '), sent
b = makeb(); b.mail.raws = [vinted_mail('<b1b@v>', B['title'], codeB)]; b.cycle()
b.ebay.items[str(B['ebayItemId'])] = {'id': str(B['ebayItemId']), 'status': 'Active', 'available': 0, 'title': ''}
phone.add('Sold on Vinted, off eBay: ' + X.html.unescape(B['title'])[:45]); age(b, 21); b.state['browser_seen'] = time.time(); b.cycle(); assert not b.ebay.zeroed and not sent, sent
phone.clear()
# Vinted sale, main PC did nothing: backup zeroes eBay after the delay and alerts
b = makeb(); b.mail.raws = [vinted_mail('<b2@v>', B['title'], codeB)]; b.cycle(); age(b, 10); b.cycle(); assert not b.ebay.zeroed
age(b, 11); b.state['browser_seen'] = time.time(); b.cycle()
assert b.ebay.zeroed == [str(B['ebayItemId'])] and len(sent) == 1 and sent[0][0].startswith('BACKUP took it off eBay'), sent
b.cycle(); assert len(sent) == 1 and len(b.ebay.zeroed) == 1
# eBay sale: nothing queued until the delay passes, then queued for the browser to check
b = makeb(); b.ebay.orders = X.parse_orders(ORDERS_XML % A['ebayItemId']); b.cycle(); assert not b.state['queue']
age(b, 21); b.state['browser_seen'] = time.time(); b.cycle(); assert [q['vintedId'] for q in b.state['queue']] == [str(A['vintedId'])] and not sent
# ... and a hide the browser has not confirmed does not raise the per-item alert on the backup
b.state['queue'][0]['queued'] -= 40 * 60; b.check_queue(); assert not sent, sent
# browser replies through the local endpoint: already hidden -> quiet; had to hide -> BACKUP alert
import threading, urllib.request
from http.server import ThreadingHTTPServer
def post(b, body):
    srv = ThreadingHTTPServer(('127.0.0.1', 0), X.make_handler(b)); threading.Thread(target=srv.handle_request, daemon=True).start()
    r = urllib.request.Request('http://127.0.0.1:%d/done' % srv.server_address[1], data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
    urllib.request.urlopen(r, timeout=5).read(); srv.server_close()
post(b, {'vintedId': str(A['vintedId']), 'ok': True, 'acted': False, 'detail': 'hidden'})
assert b.state['queue'][0]['done'] and len(sent) == 1 and sent[0][0].startswith('Sold on eBay, off Vinted: '), sent
b = makeb(); b.ebay.orders = X.parse_orders(ORDERS_XML % A['ebayItemId']); b.cycle(); age(b, 21); b.cycle()
phone.add('Sold on eBay, off Vinted: ' + X.html.unescape(A['title'])[:45]); post(b, {'vintedId': str(A['vintedId']), 'ok': True, 'acted': False, 'detail': 'hidden'}); assert not sent, sent
phone.clear()
b = makeb(); b.ebay.orders = X.parse_orders(ORDERS_XML % A['ebayItemId']); b.cycle(); age(b, 21); b.cycle()
post(b, {'vintedId': str(A['vintedId']), 'ok': True, 'acted': True, 'detail': 'hidden'})
assert len(sent) == 1 and sent[0][0].startswith('BACKUP hid it on Vinted'), sent
# unknown Vinted listing: backup stays quiet when the main PC already alerted, speaks up when it did not
b = makeb(); b.mail.raws = [vinted_mail('<b4@v>', 'Some brand new listing', '01_00abc_ZZZZZZZZZZZZZZZZZZZZZZZZ')]
phone.add('Check Vinted sale: Some brand new listing'); b.cycle(); age(b, 21); b.cycle(); assert not sent, sent
phone.clear(); b = makeb(); b.mail.raws = [vinted_mail('<b5@v>', 'Some brand new listing', '01_00abc_ZZZZZZZZZZZZZZZZZZZZZZZZ')]; b.cycle(); age(b, 21); b.cycle()
assert not sent, sent  # 0.3.0: nothing on eBay has that title, so there is nothing to tell
# main role is unchanged by all this: acts at once
s = make('live'); s.state['browser_seen'] = time.time(); s.mail.raws = [vinted_mail('<b6@v>', B['title'], codeB)]; s.cycle(); assert s.ebay.zeroed == [str(B['ebayItemId'])] and len(sent) == 1 and sent[0][0].startswith('Sold on Vinted, off eBay: '), sent
print('backup role ok')
print('ALL PASS')


# ---------------------------------------------------------------- 0.3.0: sales Mojonator has not linked
assert X.split_sku('Queen The Game Cassette 1980 - A4') == ('Queen The Game Cassette 1980', 'A4') and X.split_sku('Plain') == ('Plain', '')
pool = [{'title': 'Queen The Game Cassette', 'sku': 'A3', 'ebayItemId': '1', 'id': 'a'}, {'title': 'Queen The Game Cassette', 'sku': 'A4', 'ebayItemId': '2', 'id': 'b'}, {'title': 'Queen Jazz Cassette', 'sku': 'A4', 'ebayItemId': '3', 'id': 'c'}]
pk, ex, nr = X.twins('Queen The Game Cassette - A4', pool); assert pk['id'] == 'b' and len(ex) == 2
pk, ex, nr = X.twins('Queen The Game Cassette - GBA', pool); assert pk is None and len(ex) == 2
pk, ex, nr = X.twins('Queen The Game Cassette', pool[:1]); assert pk['id'] == 'a'
pk, ex, nr = X.twins('Queen The Game Tape Cassette 1980', pool[:1]); assert pk is None and not ex and nr and nr[0][1]['id'] == 'a', nr
pk, ex, nr = X.twins('Steve Winwood Back in the High Life Cassette', pool); assert pk is None and not ex and not nr
print('twins ok')

s = make('live')
lv = s.links.live
assert len(lv) > 300, len(lv)
titles = {}
for e in lv: titles.setdefault(X.norm_title(e['title']), []).append(e)
solo = [v[0] for v in titles.values() if len(v) == 1 and not X.split_sku(v[0]['title'])[1]]
L1, L2 = solo[0], solo[1]
# 0.3.1 RULE: a title match NEVER changes anything - it is only an alert naming the eBay listing.
# 1. unmarked Vinted sale, same title + same SKU live on eBay -> alert, eBay untouched
s.mail.raws.append(vinted_mail('<u1@v>', L1['title'] + ' - ' + (L1['sku'] or 'ZZ'), '09_0aaaa_UnknownCodeAAAAAAAAAAAAAAAA')); s.cycle()
assert not s.ebay.zeroed and len(sent) == 1 and sent[0][0].startswith('Sold on Vinted - on eBay too?') and L1['ebayItemId'] in sent[0][1], sent
# 2. same title, different SKU (the 2026-11-17 Queen case) -> alert, eBay untouched
del sent[:]
s.mail.raws.append(vinted_mail('<u2@v>', L2['title'] + ' - QQ9', '09_0bbbb_UnknownCodeBBBBBBBBBBBBBBBB')); s.cycle()
assert not s.ebay.zeroed and len(sent) == 1 and L2['ebayItemId'] in sent[0][1], sent
# 3. nothing like it on eBay -> no alert at all (Vinted-only item)
del sent[:]
s.mail.raws.append(vinted_mail('<u3@v>', 'Zzyzx Qwfp Plugh Xyzzy Cassette 1901 - A4', '09_0cccc_UnknownCodeCCCCCCCCCCCCCCCC')); s.cycle()
assert not s.ebay.zeroed and not sent, sent
# 4. unmarked eBay sale whose title is active on Vinted -> alert, nothing queued for hiding
s = make('live')
X.save_json(X.WARD_FILE, {'at': X.iso(), 'items': [{'id': '777', 'title': 'Some Unlinked Album CD 1999 - GBA', 'closed': False, 'hidden': False, 'url': 'https://www.vinted.com/items/777', 'codes': []},
                                                   {'id': '778', 'title': 'Closed One CD', 'closed': True, 'hidden': False, 'url': '', 'codes': []}]})
s.ebay.orders = [('22-1', '2026-11-17T10:00:00.000Z', [('555000111', 'Some Unlinked Album CD 1999')]), ('22-2', '2026-11-17T10:00:00.000Z', [('555000112', 'Closed One CD')])]
s.cycle()
assert not s.state['queue'] and len(sent) == 1 and sent[0][0].startswith('Sold on eBay - on Vinted too?'), (s.state['queue'], sent)
# 5. a MARKED item still acts at once, and a second live eBay listing with the same title is left alone
s = make('live'); s.state['browser_seen'] = time.time()
s.links.live.append({'id': 'dup', 'title': B['title'], 'sku': 'ZZ', 'ebayItemId': '999000999'})
s.mail.raws = [vinted_mail('<u5@v>', B['title'], codeB)]; s.cycle()
assert s.ebay.zeroed == [str(B['ebayItemId'])] and len(sent) == 1 and sent[0][0].startswith('Sold on Vinted, off eBay'), (s.ebay.zeroed, sent)
print('unmarked-sale alerts ok (nothing changed on a title match)')


# ---------------------------------------------------------------- 0.3.3: a sale that needed nothing says so too (both sites)
s = make('live', every=True); s.state['browser_seen'] = time.time()
X.save_json(X.WARD_FILE, {'at': X.iso(), 'items': [{'id': '777', 'title': 'Some Unlinked Album CD 1999 - GBA', 'closed': False, 'hidden': False, 'url': 'https://www.vinted.com/items/777', 'codes': []}]})
# eBay sale, not cross-listed, nothing like it on Vinted -> one normal-priority note, nothing queued; said once
s.ebay.orders = [('33-1', '2026-11-19T01:00:00.000Z', [('555000201', 'Terminator 3 Rise of the Machines Blu-ray 2003')])]; s.cycle()
assert not s.state['queue'] and len(sent) == 1 and sent[0][0] == 'Sold on eBay, not cross-listed: ' + 'Terminator 3 Rise of the Machines Blu-ray 2003'[:45] and '1 active Vinted' in sent[0][1], sent
s.cycle(); assert len(sent) == 1, sent
# eBay sale, not marked but same title active on Vinted -> the high 'on Vinted too?' alert only, not both
del sent[:]; s.ebay.orders.append(('33-2', '2026-11-19T01:00:00.000Z', [('555000202', 'Some Unlinked Album CD 1999')])); s.cycle()
assert len(sent) == 1 and sent[0][0].startswith('Sold on eBay - on Vinted too?'), sent
# a cross-listed eBay sale still gets its own handling, and the unmarked line item in the same batch gets the note
del sent[:]; s.ebay.orders = X.parse_orders(ORDERS_XML % A['ebayItemId']); s.cycle()
assert [q['vintedId'] for q in s.state['queue']] == [str(A['vintedId'])] and [t[0][:30] for t in sent] == ['Sold on eBay, not cross-listed'], sent
# Vinted sale of something that is nowhere on eBay -> note, eBay untouched
del sent[:]; s.mail.raws.append(vinted_mail('<e1@v>', 'Zzyzx Qwfp Plugh Xyzzy Cassette 1901 - A4', '09_0dddd_UnknownCodeDDDDDDDDDDDDDDDD')); s.cycle()
assert not s.ebay.zeroed and len(sent) == 1 and sent[0][0].startswith('Sold on Vinted, not on eBay: '), sent
# no wardrobe list from the browser yet -> the note says the Vinted side could not be checked
s = make('live', every=True); s.state['browser_seen'] = time.time()
s.ebay.orders = [('33-3', '2026-11-19T01:00:00.000Z', [('555000203', 'Another Plain Disc')])]; s.cycle()
assert len(sent) == 1 and 'could not be checked' in sent[0][1], sent
# watch mode stays quiet about these
s = make('watch', every=True); s.ebay.orders = [('33-4', '2026-11-19T01:00:00.000Z', [('555000204', 'Watch Mode Disc')])]; s.cycle(); assert not sent, sent
# backup: waits its delay, then sends the note only if the main PC has not
phone.clear(); b = make('live', every=True); b.cfg['role'] = 'backup'; b.cfg['backup_delay_minutes'] = 20; b.state['browser_seen'] = time.time()
b.ebay.orders = [('33-5', '2026-11-19T01:00:00.000Z', [('555000205', 'Backup Disc One')])]; b.cycle(); assert not sent, sent
age(b, 21); b.cycle(); assert len(sent) == 1 and sent[0][0] == 'Sold on eBay, not cross-listed: Backup Disc One', sent
b = make('live', every=True); b.cfg['role'] = 'backup'; b.cfg['backup_delay_minutes'] = 20; b.state['browser_seen'] = time.time()
b.ebay.orders = [('33-6', '2026-11-19T01:00:00.000Z', [('555000206', 'Backup Disc Two')])]; b.cycle(); phone.add('Sold on eBay, not cross-listed: Backup Disc Two'); age(b, 21); b.cycle(); assert not sent, sent
phone.clear()
print('every-sale notes ok')


# ---------------------------------------------------------------- 0.3.4: Vinted bundles - every item of the order comes off eBay
data = json.load(open(data_path)); its = data['items']
pairs = [i for i in its if i.get('vintedId') and i.get('ebayItemId') and i.get('vintedStatus') == 'active' and i.get('status') == 'listed' and i.get('vintedMatch') == 'runner' and i.get('vintedPhotos')]
title_only = [i for i in its if i.get('vintedId') and i.get('ebayItemId') and i.get('vintedStatus') == 'active' and i.get('vintedMatch') == 'auto' and i.get('crossStatus') not in ('both', 'sold-vinted')]
assert len(pairs) >= 4, len(pairs)
P1, P2, P3, P4 = pairs[:4]
today = time.strftime('%Y-%m-%d')
for i in its:  # older sales in the copy are not part of these tests
    if i.get('vintedStatus') == 'sold': i['saleDate'] = '2026-01-01'
tdata = os.path.join(tmp, '..', 'data-0.3.4-%d.json' % os.getpid())
def write_data(): json.dump(data, open(tdata, 'w'))
write_data()
def make4(mode='live'):
    for f in os.listdir(tmp): os.remove(os.path.join(tmp, f))
    del sent[:]
    cfg = json.loads(json.dumps(X.DEFAULT_CONFIG)); cfg['mode'] = mode; cfg['github']['local_file'] = tdata; cfg['notify_every_sale'] = False
    s = X.Service(cfg); s.ebay = FakeEbay(); s.mail = FakeMail(); assert s.cycle(); s.state['browser_seen'] = time.time(); return s
code = lambda r: X.PHOTO_RE.search(r['vintedPhotos'][0]).group(1)

# 1. a 3-item bundle: the email shows item 1 only; the helper reports the order -> all 3 off eBay, each said once
s = make4()
s.mail.raws = [vinted_mail('<bun1@v>', P1['title'], code(P1))]; s.cycle()
assert s.ebay.zeroed == [str(P1['ebayItemId'])] and s.state.get('want_orders'), s.ebay.zeroed
srv = ThreadingHTTPServer(('127.0.0.1', 0), X.make_handler(s)); threading.Thread(target=srv.serve_forever, daemon=True).start()
port = srv.server_address[1]
def call(path, body=None):
    r = urllib.request.Request('http://127.0.0.1:%d%s' % (port, path), data=json.dumps(body).encode() if body is not None else None, headers={'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(r, timeout=5).read())
assert call('/queue')['want_orders'] is True
order = {'txId': '900001', 'itemIds': [str(P1['vintedId']), str(P2['vintedId']), str(P3['vintedId'])], 'side': 'seller', 'sale': True, 'statusCode': 230, 'date': today + 'T10:00:00Z', 'title': P1['title']}
assert call('/orders', {'orders': [order, {'txId': '900002', 'itemIds': [str(P4['vintedId'])], 'side': 'seller', 'sale': False, 'statusCode': 500, 'date': today, 'title': 'x'}]})['count'] == 2
assert X.wake.is_set(); X.wake.clear()
assert call('/queue')['want_orders'] is False  # answered
s.cycle()
assert sorted(s.ebay.zeroed) == sorted(str(p['ebayItemId']) for p in (P1, P2, P3)), s.ebay.zeroed  # P4's order was not a sale
assert len([t for t in sent if t[0].startswith('Sold on Vinted, off eBay')]) == 3, sent
s.cycle(); assert len(s.ebay.zeroed) == 3 and len(sent) == 3, 'said once only'
srv.shutdown()
print('bundle order ok')

# 2. no order from the helper, but Mojonator marks the bundle items sold on Vinted -> backstop takes them off eBay
s = make4()
for p in (P2, P3): p['vintedStatus'] = 'sold'; p['crossStatus'] = 'sold-vinted'; p['saleDate'] = today
write_data(); s.cycle()
assert sorted(s.ebay.zeroed) == sorted([str(P2['ebayItemId']), str(P3['ebayItemId'])]), s.ebay.zeroed
s.cycle(); assert len(s.ebay.zeroed) == 2
# ... already off eBay: recorded, nothing said
s = make4(); s.ebay.items[str(P2['ebayItemId'])] = {'id': str(P2['ebayItemId']), 'status': 'Completed', 'available': 0, 'title': ''}
s.ebay.items[str(P3['ebayItemId'])] = {'id': str(P3['ebayItemId']), 'status': 'Active', 'available': 0, 'title': ''}
s.cycle(); assert not s.ebay.zeroed and not sent, sent
# ... a listing with more copies is never zeroed - alert only
s = make4(); s.ebay.items[str(P2['ebayItemId'])] = {'id': str(P2['ebayItemId']), 'status': 'Active', 'available': 3, 'title': ''}
s.cycle(); assert s.ebay.zeroed == [str(P3['ebayItemId'])] and any(t[0].startswith('Sold on Vinted - check eBay') and '3 available' in t[1] for t in sent), sent
# ... an old sale is left alone
for p in (P2, P3): p['saleDate'] = '2026-10-01'
write_data(); s = make4(); s.cycle(); assert not s.ebay.zeroed and not sent
for p in (P2, P3): p['vintedStatus'] = 'active'; p['crossStatus'] = ''; p['saleDate'] = ''
write_data()
print('backstop ok')

# 3. the Vinted profile shows it sold (helper wardrobe), Mojonator not yet -> taken off eBay
s = make4()
X.save_json(X.WARD_FILE, {'at': X.iso(), 'items': [{'id': str(P4['vintedId']), 'title': P4['title'], 'closed': True, 'closing': 'sold', 'hidden': False, 'url': '', 'codes': []},
                                                   {'id': str(P1['vintedId']), 'title': P1['title'], 'closed': False, 'closing': '', 'hidden': False, 'url': '', 'codes': []}]})
s.cycle(); assert s.ebay.zeroed == [str(P4['ebayItemId'])], s.ebay.zeroed
# ... an order whose item is for sale again on the profile (order cancelled) is not acted on
s = make4(); X.save_json(X.WARD_FILE, {'at': X.iso(), 'items': [{'id': str(P1['vintedId']), 'title': P1['title'], 'closed': False, 'closing': '', 'hidden': False, 'url': '', 'codes': []}]})
s.take_orders([dict(order, itemIds=[str(P1['vintedId'])])]); s.cycle(); assert not s.ebay.zeroed, s.ebay.zeroed
print('profile ok')

# 4. exact pairs only: a title-only link is an alert, never a change
if title_only:
    T = title_only[0]
    s = make4(); s.take_orders([dict(order, txId='900009', itemIds=[str(T['vintedId'])])]); s.cycle()
    assert not s.ebay.zeroed and len(sent) == 1 and sent[0][0].startswith('Sold on Vinted - on eBay too?') and 'title only' in sent[0][1], sent
    print('title-only link ok')
# 5. watch mode changes nothing; backup waits its delay
s = make4('watch'); s.take_orders([order]); s.cycle(); assert not s.ebay.zeroed and len(sent) == 3 and all(t[0].startswith('Sold on Vinted: ') for t in sent), sent
b = make4(); b.cfg['role'] = 'backup'; b.take_orders([order]); b.cycle(); assert not b.ebay.zeroed
age(b, 21); b.cycle(); assert len(b.ebay.zeroed) == 3 and all(t[0].startswith('BACKUP took it off eBay') for t in sent), sent
# 6. too many at once -> stop and alert
s = make4(); s.BACKSTOP_MAX = 2; s.take_orders([order]); s.cycle(); assert len(s.ebay.zeroed) == 2 and any('too many' in t[0] for t in sent), sent
print('modes ok')
os.remove(tdata)
print('0.3.4 ALL PASS')
