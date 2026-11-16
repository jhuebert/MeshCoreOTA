import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

/// Base error for companion exchanges.
class CompanionException implements Exception {
  CompanionException(this.message);

  final String message;

  @override
  String toString() => 'CompanionException: $message';
}

/// The device did not answer within the allotted time.
class CompanionTimeoutException extends CompanionException {
  CompanionTimeoutException(super.message);
}

/// The device rejected the request `(frame[1] = error code)`.
class CompanionDeviceError extends CompanionException {
  CompanionDeviceError(this.code) : super('device error $code');

  final int code;

  @override
  String toString() => 'CompanionDeviceError: $code';
}

/// A pushed contact message that belongs to someone other than the current
/// exchange target. The app logs these; they are not interpreted.
class UnexpectedMessage {
  const UnexpectedMessage({required this.senderPrefix, required this.text});

  final Uint8List senderPrefix;
  final String text;
}

/// Outcome of a remote login attempt.
class LoginResult {
  const LoginResult({required this.ok, required this.isAdmin});

  final bool ok;
  final bool isAdmin;
}

/// Parsed `RESP_CODE_CONTACT_MSG_RECV(_V3)` frame.
class ContactMessage {
  const ContactMessage({
    required this.senderPrefix,
    required this.txtType,
    required this.timestamp,
    required this.text,
  });

  final Uint8List senderPrefix;
  final int txtType;
  final int timestamp;
  final String text;
}

/// Build a `CMD_SEND_LOGIN` frame.
Uint8List buildLoginFrame(Uint8List recipientPubKey, String password) {
  final w = BufferWriter();
  w.writeByte(cmdSendLogin);
  w.writeBytes(recipientPubKey);
  w.writeBytes(utf8.encode(password));
  w.writeByte(0);
  return w.toBytes();
}

/// Build a `CMD_SEND_TXT_MSG` frame carrying CLI data.
Uint8List buildCliFrame(
  Uint8List recipientPubKey,
  String command, {
  int? timestamp,
}) {
  final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final w = BufferWriter();
  w.writeByte(cmdSendTxtMsg);
  w.writeByte(txtTypeCliData);
  w.writeByte(0); // attempt 0
  w.writeUInt32Le(ts & 0x7FFFFFFF);
  w.writeBytes(recipientPubKey.sublist(0, 6));
  w.writeBytes(utf8.encode(command));
  w.writeByte(0);
  return w.toBytes();
}

/// Parse a `RESP_CODE_CONTACT_MSG_RECV` (7) or `RESP_CODE_CONTACT_MSG_RECV_V3`
/// (16) frame. Returns null for channel messages and malformed input.
ContactMessage? parseContactMessage(Uint8List frame) {
  if (frame.length < 14) return null;
  final reader = BufferReader(frame);
  final code = reader.readByte();
  if (code == respCodeContactMsgRecvV3) {
    reader.skipBytes(3); // snr + reserved
  } else if (code != respCodeContactMsgRecv) {
    return null;
  }
  final senderPrefix = reader.readBytes(6);
  reader.skipBytes(1); // path_len (0xFF when flooded)
  final txtType = reader.readByte() & 0xFF;
  final timestamp = reader.readUInt32Le();
  if (txtType == 2) {
    reader.skipBytes(4); // signed-message signature
  }
  // The text is a NUL-terminated cstring running to the end of the frame.
  var remaining = frame.length - reader.position;
  if (remaining < 0) return null;
  final textBytes = frame.sublist(reader.position);
  final nul = textBytes.indexOf(0);
  final payload = nul >= 0 ? textBytes.sublist(0, nul) : textBytes;
  return ContactMessage(
    senderPrefix: senderPrefix,
    txtType: txtType,
    timestamp: timestamp,
    text: utf8.decode(payload, allowMalformed: true),
  );
}

/// Companion-protocol client for the frames the raw-radio view does not
/// cover. Not concurrency-safe: run exchanges one at a time.
class CompanionClient {
  CompanionClient(this.link, {this.onUnexpectedMessage});

  final RadioLink link;

  /// Called for every synced contact message that is not addressed to the
  /// current exchange (i.e. not from the current target). The app logs these.
  final void Function(UnexpectedMessage message)? onUnexpectedMessage;

  /// Enumerate the companion's contacts (`CMD_GET_CONTACTS`).
  ///
  /// Completes when `RESP_CODE_END_OF_CONTACTS` arrives; throws on a device
  /// error or timeout. The companion reports the unfiltered total up front —
  /// handy for progress display but not returned.
  Future<List<Contact>> listContacts({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final contacts = <Contact>[];
    final done = Completer<void>();
    final pushes = link.pushes;
    late StreamSubscription<Uint8List> sub;
    sub = pushes.listen((frame) {
      if (done.isCompleted || frame.isEmpty) return;
      final code = frame[0];
      if (code == respCodeContact && frame.length > 1) {
        final record =
            decodeCompanionContactRecord(Uint8List.sublistView(frame, 1));
        if (record != null) contacts.add(record.contact);
        return;
      }
      if (code == respCodeEndOfContacts) {
        done.complete();
        return;
      }
      if (code == respCodeErr) {
        done.completeError(
            CompanionDeviceError(frame.length > 1 ? frame[1] : 0));
      }
    });
    try {
      await link.sendFrame(Uint8List.fromList([cmdGetContacts]));
      await done.future.timeout(timeout, onTimeout: () {
        throw CompanionTimeoutException('contacts list timed out');
      });
      return contacts;
    } finally {
      await sub.cancel();
    }
  }

  /// Login to [target] as an admin (`CMD_SEND_LOGIN`).
  ///
  /// Returns whether the login succeeded and whether the node granted admin.
  /// Fails fast when the companion rejects the frame (e.g. unknown contact or
  /// a full request table), and with a timeout otherwise.
  Future<LoginResult> login(
    Contact target,
    String password, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final done = Completer<LoginResult>();
    final pushes = link.pushes;
    late StreamSubscription<Uint8List> sub;
    sub = pushes.listen((frame) {
      if (done.isCompleted || frame.isEmpty) return;
      final code = frame[0];
      if (code == pushCodeLoginSuccess || code == pushCodeLoginFail) {
        if (frame.length < 8) return;
        final prefix = frame.sublist(2, 8);
        if (!_prefixMatches(prefix, target)) return;
        done.complete(
          LoginResult(ok: code == pushCodeLoginSuccess, isAdmin: frame[1] == 1),
        );
        return;
      }
      if (code == respCodeErr) {
        done.completeError(
          CompanionDeviceError(frame.length > 1 ? frame[1] : 0),
        );
      }
    });
    try {
      await link.sendFrame(buildLoginFrame(target.publicKey, password));
      return await done.future.timeout(timeout, onTimeout: () {
        throw CompanionTimeoutException('repeater login timed out');
      });
    } finally {
      await sub.cancel();
    }
  }

  /// Run [command] on [target]'s remote admin CLI and return the reply text.
  ///
  /// The reply arrives as an incoming contact message: `pushCodeMsgWaiting`
  /// tells us a message is queued, `CMD_SYNC_NEXT_MESSAGE` dequeues it.
  /// Messages from other senders are reported via [onUnexpectedMessage] and
  /// do not complete the call.
  Future<String> remoteCli(
    Contact target,
    String command, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final reply = Completer<String>();
    late StreamSubscription<Uint8List> sub;
    sub = link.pushes.listen((frame) {
      if (reply.isCompleted || frame.isEmpty) return;
      final code = frame[0];
      if (code == respCodeErr) {
        reply.completeError(
          CompanionDeviceError(frame.length > 1 ? frame[1] : 0),
        );
        return;
      }
      if (code == pushCodeMsgWaiting) {
        // A message is queued; dequeue and inspect it. If it is not the CLI
        // reply, keep waiting for the next one.
        unawaited(_syncAndCheck(target, reply));
      }
    });
    try {
      await link.sendFrame(buildCliFrame(target.publicKey, command));
      return await reply.future.timeout(timeout, onTimeout: () {
        throw CompanionTimeoutException('CLI reply timed out for "$command"');
      });
    } finally {
      await sub.cancel();
    }
  }

  /// Whether a message-sync pump is already running (multiple MSG_WAITING
  /// pushes coalesce into one drain).
  bool _syncInFlight = false;

  Future<void> _syncAndCheck(
    Contact target,
    Completer<String> reply,
  ) async {
    if (reply.isCompleted || _syncInFlight) return;
    _syncInFlight = true;
    try {
      // One sync call dequeues one message. Drain until the queue empties or
      // the reply lands.
      for (int attempt = 0; attempt < 8 && !reply.isCompleted; attempt++) {
        final response = await _syncNext();
        if (response.isEmpty || response[0] == respCodeNoMoreMessages) return;
        final message = parseContactMessage(response);
        if (message == null) continue; // channel messages: not ours
        final txt = message.txtType & 0x3F;
        if (!_prefixMatches(message.senderPrefix, target) ||
            (txt != txtTypeCliData && txt != 0)) {
          onUnexpectedMessage?.call(UnexpectedMessage(
            senderPrefix: message.senderPrefix,
            text: message.text,
          ));
          continue;
        }
        reply.complete(message.text);
        return;
      }
    } finally {
      _syncInFlight = false;
    }
  }

  /// Dequeue and drop every queued message. Returns how many were dropped.
  ///
  /// Intended for bring-up drains after a connect: a companion that missed
  /// replies while the app was away holds them in its offline queue, and the
  /// next `remoteCli` call would otherwise consume a stale one as if it were
  /// the answer to the command it just sent. Each sync is answered straight
  /// from the companion's local queue, so the per-message round trip is fast;
  /// the drain stops at the first empty/timeout response.
  Future<int> drainMessages({
    Duration perMessageTimeout = const Duration(seconds: 2),
    int maxMessages = 64,
  }) async {
    var drained = 0;
    while (drained < maxMessages) {
      final response = await _syncNext(perMessageTimeout);
      if (response.isEmpty || response[0] == respCodeNoMoreMessages) break;
      drained++;
    }
    return drained;
  }

  /// Send one `CMD_SYNC_NEXT_MESSAGE` and capture its response frame from the
  /// pushes stream. Returns a zero-length frame on timeout.
  Future<Uint8List> _syncNext(
      [Duration timeout = const Duration(seconds: 10)]) {
    final response = Completer<Uint8List>();
    late StreamSubscription<Uint8List> syncSub;
    syncSub = link.pushes.listen((frame) {
      if (frame.isEmpty) return;
      final code = frame[0];
      if (code == respCodeContactMsgRecv ||
          code == respCodeContactMsgRecvV3 ||
          code == respCodeChannelMsgRecv ||
          code == respCodeChannelMsgRecvV3 ||
          code == respCodeNoMoreMessages) {
        if (!response.isCompleted) {
          response.complete(Uint8List.fromList(frame));
        }
      }
    });
    return link
        .sendFrame(Uint8List.fromList([cmdSyncNextMessage]))
        .then((_) => response.future.timeout(
              timeout,
              onTimeout: () => Uint8List(0),
            ))
        .whenComplete(syncSub.cancel);
  }

  static bool _prefixMatches(List<int> prefix, Contact target) {
    if (prefix.length != 6 || target.publicKey.length < 6) return false;
    for (int i = 0; i < 6; i++) {
      if (prefix[i] != target.publicKey[i]) return false;
    }
    return true;
  }
}
