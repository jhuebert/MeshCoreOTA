import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

Uint8List _contactFrameFor(Contact contact) {
  final body = contact.toCompanionFrameBody();
  return Uint8List.fromList([respCodeContact, ...body]);
}

ContactMessage _v3Frame({
  required Contact sender,
  required int txtType,
  required int timestamp,
  required String text,
}) {
  final w = BufferWriter();
  w.writeByte(respCodeContactMsgRecvV3);
  w.writeByte(12); // snr
  w.writeByte(0);
  w.writeByte(0);
  w.writeBytes(sender.publicKey.sublist(0, 6));
  w.writeByte(0x00); // path_len: direct, zero hop
  w.writeByte(txtType);
  w.writeUInt32Le(timestamp);
  w.writeBytes(utf8.encode(text));
  w.writeByte(0);
  return parseContactMessage(w.toBytes())!;
}

Contact _repeater({int advType = advTypeRepeater, String? name}) => Contact(
      publicKey:
          Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF)),
      name: name ?? 'tower-1',
      advType: advType,
    );

Contact _stranger() => Contact(
      publicKey:
          Uint8List.fromList(List<int>.generate(32, (i) => (0xA0 + i) & 0xFF)),
      name: 'stranger',
      advType: advTypeChat,
    );

Future<void> _pump() => Future<void>.delayed(Duration.zero);

/// A link whose message-sync write can be made to fail, modelling a companion
/// that dropped the session mid-exchange.
class _SyncFailingLink extends FakeDeviceLink {
  bool failSync = false;

  @override
  Future<void> sendFrame(Uint8List frame) async {
    if (failSync && frame.isNotEmpty && frame[0] == cmdSyncNextMessage) {
      throw const DeviceCommandError.disconnected(message: 'gone');
    }
    await super.sendFrame(frame);
  }
}

void main() {
  late FakeDeviceLink link;
  late CompanionClient client;

  setUp(() async {
    link = FakeDeviceLink();
    await link.connect();
    client = CompanionClient(link);
  });

  group('frame builders', () {
    test('login frame is cmd + pubkey + password NUL', () {
      final target = _repeater();
      final frame = buildLoginFrame(target.publicKey, 'hunter2');
      expect(frame[0], cmdSendLogin);
      expect(frame.sublist(1, 33), target.publicKey);
      expect(frame.sublist(33, frame.length - 1), utf8.encode('hunter2'));
      expect(frame.last, 0);
    });

    test('cli frame is txt_type CLI_DATA with the target prefix', () {
      final target = _repeater();
      final frame =
          buildCliFrame(target.publicKey, 'ota status', timestamp: 42);
      expect(frame[0], cmdSendTxtMsg);
      expect(frame[1], txtTypeCliData);
      expect(frame[2], 0); // attempt
      expect(
          frame[3] | (frame[4] << 8) | (frame[5] << 16) | (frame[6] << 24), 42);
      expect(frame.sublist(7, 13), target.publicKey.sublist(0, 6));
      expect(String.fromCharCodes(frame.sublist(13, frame.length - 1)),
          'ota status');
      expect(frame.last, 0);
    });
  });

  group('parseContactMessage', () {
    test('parses the v3 contact message layout', () {
      final sender = _repeater();
      final parsed = _v3Frame(
        sender: sender,
        txtType: txtTypeCliData,
        timestamp: 99,
        text: 'state=ready',
      );
      expect(parsed.senderPrefix, sender.publicKey.sublist(0, 6));
      expect(parsed.txtType, txtTypeCliData);
      expect(parsed.timestamp, 99);
      expect(parsed.text, 'state=ready');
    });

    test('decodes a real v3 frame with trailing NUL', () {
      final sender = _repeater();
      final w = BufferWriter();
      w.writeByte(respCodeContactMsgRecvV3);
      w.writeByte(12); // snr
      w.writeByte(0);
      w.writeByte(0);
      w.writeBytes(sender.publicKey.sublist(0, 6));
      w.writeByte(0x00);
      w.writeByte(txtTypeCliData);
      w.writeUInt32Le(99);
      w.writeBytes(utf8.encode('state=ready'));
      w.writeByte(0);
      final msg = parseContactMessage(w.toBytes());
      expect(msg, isNotNull);
      expect(msg!.senderPrefix, sender.publicKey.sublist(0, 6));
      expect(msg.txtType, txtTypeCliData);
      expect(msg.timestamp, 99);
      expect(msg.text, 'state=ready');
    });

    test('decodes a v7 (pre-v3) frame', () {
      final sender = _repeater();
      final w = BufferWriter();
      w.writeByte(respCodeContactMsgRecv);
      w.writeBytes(sender.publicKey.sublist(0, 6));
      w.writeByte(0xFF);
      w.writeByte(0);
      w.writeUInt32Le(7);
      w.writeBytes(utf8.encode('hello'));
      w.writeByte(0);
      final msg = parseContactMessage(w.toBytes());
      expect(msg!.text, 'hello');
      expect(msg.txtType, 0);
    });

    test('channel messages are not contact messages', () {
      expect(
          parseContactMessage(Uint8List.fromList([respCodeChannelMsgRecv, 7])),
          isNull);
    });

    test('signed messages skip the 4-byte signature', () {
      final sender = _repeater();
      final w = BufferWriter();
      w.writeByte(respCodeContactMsgRecvV3);
      w.writeByte(0);
      w.writeByte(0);
      w.writeByte(0);
      w.writeBytes(sender.publicKey.sublist(0, 6));
      w.writeByte(0xFF);
      w.writeByte(2); // signed
      w.writeUInt32Le(5);
      w.writeBytes([0xDE, 0xAD, 0xBE, 0xEF]);
      w.writeBytes(utf8.encode('signed text'));
      w.writeByte(0);
      final msg = parseContactMessage(w.toBytes());
      expect(msg!.text, 'signed text');
    });
  });

  group('listContacts', () {
    test('collects contact records until END_OF_CONTACTS', () async {
      final first = _repeater();
      final second = Contact(
        publicKey: Uint8List.fromList(List<int>.generate(32, (i) => 0x55 + i)),
        name: 'tower-2',
        advType: advTypeRepeater,
      );
      final listFuture = client.listContacts();
      await _pump();
      expect(link.sentFrames.last, [cmdGetContacts]);
      link.simulatePush(
          Uint8List.fromList([respCodeContactsStart, 2, 0, 0, 0]));
      link.simulatePush(_contactFrameFor(first));
      link.simulatePush(_contactFrameFor(second));
      link.simulatePush(
          Uint8List.fromList([respCodeEndOfContacts, 0, 0, 0, 0]));
      final contacts = await listFuture;
      expect(contacts, hasLength(2));
      expect(contacts[0].name, 'tower-1');
      expect(contacts[1].name, 'tower-2');
    });

    test('a device error during enumeration throws', () {
      expect(
        () async {
          final listFuture = client.listContacts();
          await _pump();
          link.simulatePush(Uint8List.fromList([respCodeErr, 2]));
          await listFuture;
        }(),
        throwsA(isA<CompanionDeviceError>()),
      );
    });
  });

  group('login', () {
    test('success with admin permissions completes', () async {
      final target = _repeater();
      final loginFuture = client.login(target, 'hunter2');
      await _pump();
      link.simulatePush(Uint8List.fromList([
        pushCodeLoginSuccess,
        1,
        ...target.publicKey.sublist(0, 6),
        0,
        0,
        0,
        0,
        7,
        14
      ]));
      final result = await loginFuture;
      expect(result.ok, isTrue);
      expect(result.isAdmin, isTrue);
    });

    test('failure push completes with ok=false', () async {
      final target = _repeater();
      final loginFuture = client.login(target, 'hunter2');
      await _pump();
      link.simulatePush(Uint8List.fromList(
          [pushCodeLoginFail, 0, ...target.publicKey.sublist(0, 6)]));
      final result = await loginFuture;
      expect(result.ok, isFalse);
      expect(result.isAdmin, isFalse);
    });

    test('pushes for other pubkeys are ignored', () async {
      final target = _repeater();
      final loginFuture = client.login(target, 'hunter2');
      await _pump();
      link.simulatePush(Uint8List.fromList(
          [pushCodeLoginSuccess, 1, ..._stranger().publicKey.sublist(0, 6)]));
      link.simulatePush(Uint8List.fromList(
          [pushCodeLoginSuccess, 1, ...target.publicKey.sublist(0, 6)]));
      final result = await loginFuture;
      expect(result.ok, isTrue);
    });
  });

  group('remoteCli', () {
    test('reply arrives via MSG_WAITING + sync pump', () async {
      final target = _repeater();
      final cliFuture = client.remoteCli(target, 'ver');
      await _pump();
      expect(link.sentFrames[0][0], cmdSendTxtMsg);
      link.simulatePush(Uint8List.fromList([pushCodeMsgWaiting]));
      await _pump();
      expect(link.sentFrames.last, [cmdSyncNextMessage]);
      // The repeater's answer: a v3 contact message from the target.
      final w = BufferWriter();
      w.writeByte(respCodeContactMsgRecvV3);
      w.writeByte(6);
      w.writeByte(0);
      w.writeByte(0);
      w.writeBytes(target.publicKey.sublist(0, 6));
      w.writeByte(0);
      w.writeByte(txtTypeCliData);
      w.writeUInt32Le(100);
      w.writeBytes(utf8.encode('v1.18.0-lora-ota'));
      w.writeByte(0);
      link.simulatePush(w.toBytes());
      expect(await cliFuture, 'v1.18.0-lora-ota');
    });

    test("another sender's message is surfaced, not eaten as the reply",
        () async {
      final target = _repeater();
      UnexpectedMessage? unexpected;
      client = CompanionClient(link, onUnexpectedMessage: (m) {
        unexpected = m;
      });
      final cliFuture = client.remoteCli(target, 'ota status');
      await _pump();
      link.simulatePush(Uint8List.fromList([pushCodeMsgWaiting]));
      await _pump();
      // stranger's message arrives first
      final stranger = _stranger();
      final w = BufferWriter();
      w.writeByte(respCodeContactMsgRecvV3);
      w.writeByte(0);
      w.writeByte(0);
      w.writeByte(0);
      w.writeBytes(stranger.publicKey.sublist(0, 6));
      w.writeByte(0xFF);
      w.writeByte(0);
      w.writeUInt32Le(50);
      w.writeBytes(utf8.encode('hi from stranger'));
      w.writeByte(0);
      link.simulatePush(w.toBytes());
      await _pump();
      expect(unexpected, isNotNull);
      expect(unexpected!.text, 'hi from stranger');
      // NO_MORE_MESSAGES ends the pump for that push
      link.simulatePush(Uint8List.fromList([respCodeNoMoreMessages]));
      await _pump();
      // Now the actual CLI reply arrives on the second push cycle
      link.simulatePush(Uint8List.fromList([pushCodeMsgWaiting]));
      await _pump();
      final reply = BufferWriter();
      reply.writeByte(respCodeContactMsgRecvV3);
      reply.writeByte(0);
      reply.writeByte(0);
      reply.writeByte(0);
      reply.writeBytes(target.publicKey.sublist(0, 6));
      reply.writeByte(0);
      reply.writeByte(txtTypeCliData);
      reply.writeUInt32Le(60);
      reply.writeBytes(utf8.encode('running=x state=ready'));
      reply.writeByte(0);
      link.simulatePush(reply.toBytes());
      expect(await cliFuture, 'running=x state=ready');
    });

    test('a device error fails the CLI call fast', () {
      final target = _repeater();
      expect(
        () async {
          final cliFuture = client.remoteCli(target, 'ver');
          await _pump();
          link.simulatePush(Uint8List.fromList([respCodeErr, 7]));
          await cliFuture;
        }(),
        throwsA(isA<CompanionDeviceError>()),
      );
    });

    test('CLI reply times out fast when nothing is queued', () {
      final target = _repeater();
      expect(
        client.remoteCli(target, 'ver',
            timeout: const Duration(milliseconds: 50)),
        throwsA(isA<CompanionTimeoutException>()),
      );
    });

    test('a sync failure fails the CLI call instead of timing out', () async {
      final target = _repeater();
      final syncLink = _SyncFailingLink();
      await syncLink.connect();
      final syncClient = CompanionClient(syncLink);
      final cliFuture = syncClient.remoteCli(target, 'ver');
      await _pump();
      // The message pump cannot reach the companion any more: the failure
      // belongs to this exchange, not to a 45 s wait.
      syncLink.failSync = true;
      syncLink.simulatePush(Uint8List.fromList([pushCodeMsgWaiting]));

      await expectLater(cliFuture, throwsA(isA<CompanionException>()));
    });
  });

  group('drainMessages', () {
    Uint8List cliMessageFrame(Contact from, String text) {
      final w = BufferWriter();
      w.writeByte(respCodeContactMsgRecvV3);
      w.writeByte(0);
      w.writeByte(0);
      w.writeByte(0);
      w.writeBytes(from.publicKey.sublist(0, 6));
      w.writeByte(0);
      w.writeByte(txtTypeCliData);
      w.writeUInt32Le(100);
      w.writeBytes(utf8.encode(text));
      w.writeByte(0);
      return w.toBytes();
    }

    test('drops every queued message and reports the count', () async {
      final target = _repeater();
      var queued = <Uint8List>[
        cliMessageFrame(target, 'stale one'),
        cliMessageFrame(target, 'stale two'),
      ];
      link.frameHandler = (frame) {
        if (frame[0] != cmdSyncNextMessage) return;
        if (queued.isNotEmpty) {
          link.simulatePush(queued.removeAt(0));
        } else {
          link.simulatePush(Uint8List.fromList([respCodeNoMoreMessages]));
        }
      };
      expect(await client.drainMessages(), 2);
      expect(queued, isEmpty);
    });

    test('reports zero on an empty queue', () async {
      link.frameHandler = (frame) {
        if (frame[0] != cmdSyncNextMessage) return;
        link.simulatePush(Uint8List.fromList([respCodeNoMoreMessages]));
      };
      expect(await client.drainMessages(), 0);
    });

    test('remoteCli answers a fresh reply after a drain', () async {
      final target = _repeater();
      var queued = <Uint8List>[cliMessageFrame(target, 'stale')];
      link.frameHandler = (frame) {
        if (frame[0] != cmdSyncNextMessage) return;
        if (queued.isNotEmpty) {
          link.simulatePush(queued.removeAt(0));
        } else {
          link.simulatePush(Uint8List.fromList([respCodeNoMoreMessages]));
        }
      };
      expect(await client.drainMessages(), 1);
      // After the drain, the next CLI call gets the fresh reply, not the stale one.
      final reply = BufferWriter()
        ..writeByte(respCodeContactMsgRecvV3)
        ..writeByte(0)
        ..writeByte(0)
        ..writeByte(0)
        ..writeBytes(target.publicKey.sublist(0, 6))
        ..writeByte(0)
        ..writeByte(txtTypeCliData)
        ..writeUInt32Le(60)
        ..writeBytes(utf8.encode('vfresh'))
        ..writeByte(0);
      link.frameHandler = (frame) {
        if (frame[0] != cmdSyncNextMessage) return;
        link.simulatePush(reply.toBytes());
      };
      final cliFuture = client.remoteCli(target, 'ver');
      await _pump();
      link.simulatePush(Uint8List.fromList([pushCodeMsgWaiting]));
      expect(await cliFuture, 'vfresh');
    });
  });
}
