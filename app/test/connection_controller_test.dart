import 'package:companion_client/companion_client.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/controllers/connection_controller.dart';

void main() {
  test('TCP connect adopts the link and reports connected', () async {
    final link = FakeDeviceLink();
    final controller = ConnectionController(tcpLinkFactory: (_, __) => link);
    RadioLink? adopted;
    controller.onAdopt = (l) async {
      adopted = l;
      controller.companionName = (await l.selfInfo()).nodeName;
    };

    await controller.connectTcp(host: '127.0.0.1', port: 5000);

    expect(controller.phase, ConnectionPhase.connected);
    expect(controller.link, same(link));
    expect(controller.client, isA<CompanionClient>());
    expect(adopted, same(link));
    expect(controller.transportKind, 'tcp');
    expect(controller.companionName, 'Fake companion');
    expect(controller.lastEndpoint, '127.0.0.1:5000');
  });

  test('a failed connect leaves the phase disconnected with a plain error',
      () async {
    final controller = ConnectionController(
      tcpLinkFactory: (_, __) => FakeDeviceLink(connectFailures: 1),
    );
    await controller.connectTcp(host: '127.0.0.1', port: 5000);
    expect(controller.phase, ConnectionPhase.disconnected);
    expect(controller.link, isNull);
    expect(controller.connectError, startsWith('TCP connect failed'));
  });

  test('disconnect drops the link and invokes onLost', () async {
    var lost = 0;
    final controller = ConnectionController(
      tcpLinkFactory: (_, __) => FakeDeviceLink(),
    )..onLost = () async => lost++;
    await controller.connectTcp(host: '127.0.0.1', port: 5000);
    await controller.disconnect();
    expect(controller.phase, ConnectionPhase.disconnected);
    expect(controller.link, isNull);
    expect(lost, 1);
    // The last endpoint survives so reconnect can reuse it.
    expect(controller.lastEndpoint, '127.0.0.1:5000');
  });

  test('reconnect reuses the last successful endpoint', () async {
    final endpoints = <String>[];
    final controller = ConnectionController(
      tcpLinkFactory: (host, port) {
        endpoints.add('$host:$port');
        return FakeDeviceLink();
      },
    );
    await controller.connectTcp(host: '10.0.0.8', port: 4000);
    await controller.disconnect();
    await controller.reconnect();
    expect(endpoints, ['10.0.0.8:4000', '10.0.0.8:4000']);
    expect(controller.phase, ConnectionPhase.connected);
  });

  test('draining without a link is a no-op', () async {
    final controller = ConnectionController();
    expect(await controller.drainAfterLogin(), 0);
  });
}
