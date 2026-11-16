import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_ota/services/foreground.dart';

void main() {
  // The desktop targets have no foreground service; the wrapper must be a
  // silent no-op instead of a MissingPluginException after every transfer.
  test('the foreground service is a no-op off mobile', () async {
    if (TransferForegroundService.supported) return;
    await TransferForegroundService.start('testing');
    await TransferForegroundService.update('testing');
    await TransferForegroundService.stop();
  });
}
