import 'package:flutter_test/flutter_test.dart';
import 'package:vinted_scout/net.dart';
import 'package:vinted_scout/ebay_client.dart';

void main() {
  test('htmlToText strips scripts and tags', () {
    const html = '<html><head><style>.x{}</style><script>var a=1;</script></head>'
        '<body><div class="s-item">Sold Oct 29, 2026</div><span>\$499.00</span>'
        '<div>+\$35.00 delivery</div></body></html>';
    final t = htmlToText(html);
    expect(t.contains('var a'), isFalse);
    expect(t.contains('Sold Oct 29, 2026'), isTrue);
    expect(t.contains('\$499.00'), isTrue);
  });

  test('eBay sold URL has the right filters', () {
    final u = EbayClient.soldSearchUri('prestige manta lab', compCondition: 'sealed');
    expect(u.queryParameters['LH_Sold'], '1');
    expect(u.queryParameters['LH_Complete'], '1');
    expect(u.queryParameters['LH_ItemCondition'], '1000');
    expect(u.queryParameters['_sop'], '13');
    final used = EbayClient.soldSearchUri('x', compCondition: 'used');
    expect(used.queryParameters['LH_ItemCondition'], '3000');
  });
}
