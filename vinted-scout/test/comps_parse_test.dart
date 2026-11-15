import 'package:flutter_test/flutter_test.dart';
import 'package:vinted_scout/comps/comp_engine.dart';
import 'package:vinted_scout/comps/listing_reader.dart';

void main() {
  group('ListingReader.parse', () {
    test('eBay app share text with tracking params', () {
      final r = ListingReader.parse(
          'Check out this listing I found on eBay! Black Metal Cassette Tape Lot x8 '
          'https://www.ebay.com/itm/227614668616?mkcid=16&mkevt=1&mkrid=711-127632-2357-0&ssspo=abc&sssrc=2047675');
      expect(r.source, ListingSource.ebay);
      expect(r.id, '227614668616');
    });

    test('eBay item URL with slug', () {
      final r = ListingReader.parse('https://www.ebay.com/itm/Some-Title-Here/366810777006');
      expect(r.id, '366810777006');
    });

    test('eBay mobile URL', () {
      final r = ListingReader.parse('https://m.ebay.com/itm/366810777006');
      expect(r.id, '366810777006');
    });

    test('eBay short link needs resolving', () {
      final r = ListingReader.parse('https://ebay.us/m/AbC123');
      expect(r.id, isNull);
      expect(r.link.toString(), 'https://ebay.us/m/AbC123');
    });

    test('Vinted share text', () {
      final r = ListingReader.parse(
          'Check out Fastway Bad Bad Girls on Vinted! https://www.vinted.com/items/10811401111-fastway-bad-bad-girls?referrer=share&utm_source=android');
      expect(r.source, ListingSource.vinted);
      expect(r.id, '10811401111');
    });

    test('bare eBay item number', () {
      final r = ListingReader.parse('227614668616');
      expect(r.source, ListingSource.ebay);
      expect(r.id, '227614668616');
    });

    test('nothing usable', () {
      expect(() => ListingReader.parse('hello there'), throwsA(isA<ListingException>()));
    });
  });

  group('CompsReport math', () {
    test('net after fees and label', () {
      // $10 buyer total: 10*0.864 - 0.40 - 4.39 = 3.85
      expect(SellCosts.net(10).toStringAsFixed(2), '3.85');
      expect(SellCosts.net(3), 0);
    });

    test('verdicts', () {
      final snap = ListingSnapshot(
          source: ListingSource.ebay, id: '1', url: 'u', pageText: '', descriptionText: '');
      final r = CompsReport(snap)
        ..price = 10
        ..shipping = 5;
      ItemComp item(double? lvl) => ItemComp(
          name: 'x', format: 'Cassette', edition: '', query: 'x', compCondition: 'used', soldUrl: '')
        ..level = lvl;
      r.items = [item(20), item(20), item(20)]; // net 3 x 12.49 = 37.47 vs cost 15
      expect(r.verdict, CompsVerdict.good);
      r.items = [item(20)]; // 12.49 < 19.5
      expect(r.verdict, CompsVerdict.no);
      r.items = [item(null)];
      expect(r.verdict, CompsVerdict.noComps);
      r.flags = [RedFlag(true, 'NSBM')];
      expect(r.verdict, CompsVerdict.pass);
    });
  });
}
