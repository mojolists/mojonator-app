import 'package:flutter_test/flutter_test.dart';
import 'package:vinted_scout/vinted_client.dart';

void main() {
  test('catalog URL shape', () {
    final u = VintedClient.catalogUri(term: 'blu-ray', page: 2, includeVeryGood: true);
    expect(u.path, '/catalog');
    expect(u.queryParametersAll['status_ids[]'], ['6', '1', '2']);
    expect(u.queryParameters['page'], '2');
    expect(u.queryParameters['order'], 'newest_first');
  });
}
