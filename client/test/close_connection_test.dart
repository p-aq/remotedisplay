import 'package:flutter_hbb/common.dart'
    show closeConnection, closeConnectionFallback;
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The session window registers no DesktopTabController, so the engine's
  // boxes whose Cancel calls closeConnection() threw there (#82).
  tearDown(() => closeConnectionFallback = null);

  test('without a tab controller, closeConnection() calls the fallback', () {
    final closed = <String?>[];
    closeConnectionFallback = closed.add;
    closeConnection();
    closeConnection(id: '192.168.1.115');
    expect(closed, [null, '192.168.1.115']);
  });

  test('without a fallback either, closeConnection() still fails loudly', () {
    expect(() => closeConnection(), throwsA(anything));
  });
}
