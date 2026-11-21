import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

/// A binary request got no usable reply. The outcome is unknown: the node may
/// still have acted, so callers must never turn this into a success.
class RepeaterRequestException implements Exception {
  const RepeaterRequestException(this.message);

  final String message;

  @override
  String toString() => 'RepeaterRequestException: $message';
}

/// Extract the fixed-length report from a `PUSH_CODE_BINARY_RESPONSE` frame.
///
/// Both companion record layouts are accepted: `[8C][00][tag(4)][payload…]`
/// and `[8C][00][pubkey_prefix(6)][tag(4)][payload…]`. Reports here are fixed
/// size (unlike OTA frames), so [exactLength] slices the payload directly and
/// ignores the crypto layer's zero padding. A CRC would be ambiguous when the
/// report ends in zero bytes.
Uint8List? binaryResponsePayload(
  Uint8List frame,
  Uint8List contactPubKey, {
  int? askTag,
  required int exactLength,
}) {
  if (frame.isEmpty || frame[0] != pushCodeBinaryResponse) return null;
  var prefixMatches = contactPubKey.length >= 6;
  for (var i = 0; i < 6 && prefixMatches; i++) {
    prefixMatches = frame.length > 2 + i && frame[2 + i] == contactPubKey[i];
  }
  // Prefer the prefix layout when the responder's key matches: with no CRC to
  // frame the payload, the tag-first layout is ambiguous with its first four
  // bytes. A genuine tag-first frame cannot start with our contact's prefix.
  final candidates = prefixMatches ? [8, 2] : [2, 8];
  for (final tagAt in candidates) {
    if (frame.length < tagAt + 4 + exactLength) continue;
    if (tagAt == 8 && !prefixMatches) continue;
    final tag = frame[tagAt] |
        (frame[tagAt + 1] << 8) |
        (frame[tagAt + 2] << 16) |
        (frame[tagAt + 3] << 24);
    if (askTag != null && tag != askTag) continue;
    return Uint8List.fromList(
        frame.sublist(tagAt + 4, tagAt + 4 + exactLength));
  }
  return null;
}

/// Sends `[reqType][data…]` through `CMD_SEND_BINARY_REQ` and waits for the
/// tagged response. Pure Dart: the caller owns serialization of exchanges.
class RepeaterReqClient {
  RepeaterReqClient(this.link);

  final RadioLink link;

  Future<Uint8List> request(
    Contact contact,
    int reqType, {
    List<int> data = const [],
    required int exactLength,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final done = Completer<Uint8List?>();
    int? askTag;
    late final StreamSubscription<Uint8List> sub;
    sub = link.pushes.listen((frame) {
      if (done.isCompleted) return;
      final payload = binaryResponsePayload(
        frame,
        contact.publicKey,
        askTag: askTag,
        exactLength: exactLength,
      );
      if (payload != null) done.complete(payload);
    });
    try {
      final sent = await link.sendBinaryRequest(contact, [reqType, ...data]);
      askTag = sent.tag;
      final payload = await done.future.timeout(timeout, onTimeout: () => null);
      if (payload == null) {
        throw RepeaterRequestException(
            'no reply to request 0x${reqType.toRadixString(16)}');
      }
      return payload;
    } finally {
      await sub.cancel();
    }
  }
}
