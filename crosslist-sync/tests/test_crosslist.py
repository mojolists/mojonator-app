"""Offline tests: python3 tests/test_crosslist.py /path/to/data.json"""
import json, os, sys, tempfile, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import crosslist as X
from email.message import EmailMessage

data_path = sys.argv[1]
tmp = tempfile.mkdtemp()
for n in ('STATE_FILE', 'LOG_FILE', 'ACTIONS_FILE', 'CACHE_FILE'): setattr(X, n, os.path.join(tmp, n))
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

def make(mode):
    for f in os.listdir(tmp): os.remove(os.path.join(tmp, f))
    del sent[:]
    cfg = json.loads(json.dumps(X.DEFAULT_CONFIG)); cfg['mode'] = mode; cfg['github']['local_file'] = data_path
    s = X.Service(cfg); s.ebay = FakeEbay(); s.mail = FakeMail()
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
assert s.ebay.zeroed == [str(B['ebayItemId'])] and not sent
# hide not confirmed for 31 min -> alert once
s.state['queue'][0]['queued'] -= 31 * 60; s.state['browser_seen'] = time.time(); s.check_queue(); s.check_queue()
assert len(sent) == 1 and sent[0][0].startswith('Hide on Vinted')
# browser silent -> alert
s.state['browser_seen'] = time.time() - 3600; s.started -= 3600; s.check_queue(); assert sent[-1][0].startswith('Vinted browser')
print('live mode ok')

# double sale
s = make('watch'); s.ebay.orders = X.parse_orders(ORDERS_XML % A['ebayItemId']); s.cycle()
s.mail.raws = [vinted_mail('<n3@v>', A['title'], codeA)]; s.cycle(); assert sent[-1][0].startswith('SOLD ON BOTH'), sent
# unknown Vinted listing, and an email with no photo
s = make('watch'); s.mail.raws = [vinted_mail('<n4@v>', 'Some brand new listing', '01_00abc_ZZZZZZZZZZZZZZZZZZZZZZZZ'), vinted_mail('<n5@v>', 'No photo', '')]; s.cycle()
assert len(sent) == 2 and all(t[0].startswith('Check Vinted sale') for t in sent), sent
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
print('ALL PASS')
